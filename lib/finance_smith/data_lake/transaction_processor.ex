defmodule FinanceSmith.DataLake.TransactionProcessor do
  @moduledoc """
  Applies a Plaid transaction sync payload to the PostgreSQL database.

  ## Entry points

  - `process_from_b2/1` — primary path used by `ProcessWorker`. Accepts a B2
    object key, downloads the archived JSON, resolves the matching PlaidItem,
    and delegates to `process/2`.

  - `process/2` — low-level path called directly when a B2 upload or Oban
    enqueue fails and in-memory fallback processing is needed. Accepts a loaded
    `PlaidItem` (with accounts) and a string-keyed payload map produced by
    `Uploader.to_sync_payload/1`. No network I/O.

  ## Processing flow

  1. Ensure the PlaidItem has `user.household` loaded; derive `household_id`.
  2. Build a lookup map of Plaid account ID -> internal account UUID.
  3. Resolve a `%{source_category_token => meta_category_id}` lookup for all
     unique category tokens present in the payload batch via
     `CategoryResolution.resolve_tokens!/2`:
     - Batch-load existing `CategoryMapping` rows in one query.
     - For missing tokens, try prefix matching against the 16 Plaid primary
       tokens first (e.g. `FOOD_AND_DRINK_GROCERIES` → `FOOD_AND_DRINK`).
     - Tokens with no prefix match fall back to the household's "Uncategorized"
       `MetaCategory`, creating it first if needed.
     - Bulk-upsert new mappings, then re-read from DB so the lookup reflects
       the actual DB winner (race-safe under concurrent Oban workers).
  4. Run all transaction DB operations inside a single Repo transaction:
     - `added` / `modified` → resolve pending records in-place when Plaid
       provides `pending_transaction_id`, otherwise upsert on `:unique_plaid_id`,
       stamping `meta_category_id` from the resolved lookup and collecting
       `Ash.Notifier.Notification` structs via `return_notifications?: true`
     - `removed` → bulk destroy by `plaid_transaction_id`, skipping pending IDs
       that were already promoted in-place during the same batch
  5. After the transaction commits, flush the collected notifications via
     `Ash.Notifier.notify/1` so PubSub subscribers (e.g. the Dashboard LiveView)
     receive transaction broadcasts without missed-notification warnings.
  6. Return `:ok` on success or raise on failure.

  ## Amount convention

  Plaid amounts are floats in dollars (positive = money leaving the account).
  We store amounts as integers in cents (rounded half-up).
  """

  alias FinanceSmith.DataLake.{B2, KeyBuilder}
  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.{CategoryResolution, PlaidItem, Transaction}

  require Ash.Query
  require Logger

  @doc """
  Processes a sync payload directly from memory.

  `plaid_item` must have `:accounts` loaded; `user.household` is loaded lazily
  inside `process/2` if not already present.
  `payload` is a string-keyed map as produced by `Uploader.to_sync_payload/1`.

  Returns `:ok` or raises on failure.
  """
  @spec process(PlaidItem.t(), map()) :: :ok
  def process(%PlaidItem{} = plaid_item, payload) when is_map(payload) do
    Logger.info(
      "[TransactionProcessor] Processing. plaid_item=#{plaid_item.id} added=#{length(payload["added"] || [])} modified=#{length(payload["modified"] || [])} removed=#{length(payload["removed"] || [])}"
    )

    plaid_item = ensure_user_household_loaded!(plaid_item)
    household_id = plaid_item.user.household_id
    account_lookup = build_account_lookup(plaid_item)
    category_lookup = resolve_category_mappings!(payload, household_id)

    FinanceSmith.Repo.transaction(fn ->
      pending_lookup = build_pending_lookup(payload)

      {notifications, resolved_pending_ids} =
        {[], MapSet.new()}
        |> collect_transaction_notifications(
          payload["added"] || [],
          account_lookup,
          category_lookup,
          pending_lookup
        )
        |> collect_transaction_notifications(
          payload["modified"] || [],
          account_lookup,
          category_lookup,
          pending_lookup
        )

      remove_transactions!(payload["removed"] || [], resolved_pending_ids)
      Enum.reverse(notifications)
    end)
    |> case do
      {:ok, notifications} when is_list(notifications) ->
        Ash.Notifier.notify(notifications)

        Logger.info("[TransactionProcessor] Done. plaid_item=#{plaid_item.id}")
        :ok

      {:error, reason} ->
        raise "[TransactionProcessor] DB transaction failed for plaid_item=#{plaid_item.id}: #{inspect(reason)}"
    end
  end

  @doc """
  Downloads the B2 archive at `object_key`, parses it, and calls `process/2`.

  The PlaidItem is resolved from the object key path, loaded with its accounts
  and household context, then passed to `process/2`. This is the primary path
  called by `ProcessWorker`.

  Returns `:ok` or raises on failure.
  """
  @spec process_from_b2(String.t()) :: :ok
  def process_from_b2(object_key) do
    Logger.info("[TransactionProcessor] Downloading from B2. key=#{object_key}")

    body = download_from_b2!(object_key)

    payload =
      case body do
        %{} = map -> map
        bin when is_binary(bin) -> Jason.decode!(bin)
      end

    plaid_item_id = extract_plaid_item_id!(object_key)
    plaid_item = load_plaid_item_by_plaid_id!(plaid_item_id)

    process(plaid_item, payload)
  end

  # --- Household context normalization --------------------------------------

  # Raises on failure — the processor has no recovery path if household context
  # cannot be established. `Ash.load!/3` is idempotent for already-loaded fields.
  defp ensure_user_household_loaded!(%PlaidItem{} = item) do
    Ash.load!(item, [user: :household], authorize?: false)
  end

  # --- Account lookup -------------------------------------------------------

  defp build_account_lookup(%PlaidItem{accounts: accounts}) do
    Map.new(accounts, fn account -> {account.plaid_account_id, account.id} end)
  end

  # --- Category mapping resolution ------------------------------------------

  defp resolve_category_mappings!(payload, household_id) do
    CategoryResolution.resolve_tokens!(category_tokens(payload), household_id)
  end

  defp category_tokens(payload) do
    (payload["added"] || [])
    |> Kernel.++(payload["modified"] || [])
    |> Enum.map(&personal_finance_category_token/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Safe structural navigation — returns nil if the nested map or "detailed"
  # key is missing, nil, or not a non-empty string.
  defp personal_finance_category_token(txn) do
    case get_in(txn, ["personal_finance_category", "detailed"]) do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  # --- Transaction writes ---------------------------------------------------

  defp build_pending_lookup(payload) do
    pending_ids =
      (payload["added"] || [])
      |> Kernel.++(payload["modified"] || [])
      |> Enum.map(& &1["pending_transaction_id"])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    if pending_ids == [] do
      %{}
    else
      Transaction
      |> Ash.Query.filter(plaid_transaction_id in ^pending_ids)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.plaid_transaction_id, &1})
    end
  end

  defp collect_transaction_notifications(
         acc,
         transactions,
         account_lookup,
         category_lookup,
         pending_lookup
       ) do
    Enum.reduce(transactions, acc, fn txn, {notifications, resolved_pending_ids} = acc ->
      plaid_account_id = txn["account_id"]

      case Map.fetch(account_lookup, plaid_account_id) do
        {:ok, account_id} ->
          attrs = build_transaction_attrs(txn, account_id, category_lookup)

          process_transaction(attrs, notifications, resolved_pending_ids, pending_lookup)

        :error ->
          Logger.warning(
            "[TransactionProcessor] Unknown plaid_account_id=#{plaid_account_id} — skipping transaction #{txn["transaction_id"]}"
          )

          acc
      end
    end)
  end

  defp process_transaction(
         %{pending_transaction_id: pending_transaction_id} = attrs,
         notifications,
         resolved_pending_ids,
         pending_lookup
       )
       when is_binary(pending_transaction_id) and pending_transaction_id != "" do
    case Map.get(pending_lookup, pending_transaction_id) do
      nil ->
        upsert_transaction(attrs, notifications, resolved_pending_ids)

      pending_transaction ->
        maybe_resolve_pending_transaction(
          pending_transaction,
          attrs,
          notifications,
          resolved_pending_ids
        )
    end
  end

  defp process_transaction(attrs, notifications, resolved_pending_ids, _pending_lookup) do
    upsert_transaction(attrs, notifications, resolved_pending_ids)
  end

  defp maybe_resolve_pending_transaction(
         pending_transaction,
         %{plaid_transaction_id: posted_transaction_id} = attrs,
         notifications,
         resolved_pending_ids
       ) do
    if pending_transaction.plaid_transaction_id != posted_transaction_id and
         is_nil(find_transaction_by_plaid_id(posted_transaction_id)) do
      {_record, notifs} =
        pending_transaction
        |> Ash.Changeset.for_update(:resolve_pending, resolve_pending_attrs(attrs))
        |> Ash.update!(authorize?: false, return_notifications?: true)

      {List.wrap(notifs) ++ notifications,
       MapSet.put(resolved_pending_ids, pending_transaction.plaid_transaction_id)}
    else
      if pending_transaction.plaid_transaction_id != posted_transaction_id do
        destroy_pending_transaction!(pending_transaction)
      end

      upsert_transaction(attrs, notifications, resolved_pending_ids)
    end
  end

  defp resolve_pending_attrs(attrs) do
    Map.take(attrs, [
      :plaid_transaction_id,
      :amount,
      :date,
      :merchant_name,
      :website,
      :personal_finance_category,
      :meta_category_id,
      :metadata,
      :pending_transaction_id
    ])
  end

  defp upsert_transaction(attrs, notifications, resolved_pending_ids) do
    {_record, notifs} =
      Transaction
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create!(
        upsert?: true,
        upsert_identity: :unique_plaid_id,
        authorize?: false,
        return_notifications?: true
      )

    {List.wrap(notifs) ++ notifications, resolved_pending_ids}
  end

  defp find_transaction_by_plaid_id(plaid_transaction_id) do
    Transaction
    |> Ash.Query.filter(plaid_transaction_id == ^plaid_transaction_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp destroy_pending_transaction!(pending_transaction) do
    Transaction
    |> Ash.Query.filter(id == ^pending_transaction.id)
    |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, return_errors?: true)
  end

  defp remove_transactions!(removed_transactions, resolved_pending_ids) do
    Enum.each(removed_transactions, fn txn ->
      plaid_transaction_id = txn["transaction_id"]

      unless MapSet.member?(resolved_pending_ids, plaid_transaction_id) do
        Transaction
        |> Ash.Query.filter(plaid_transaction_id == ^plaid_transaction_id)
        |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, return_errors?: true)
      end
    end)
  end

  # Keys that are mapped to dedicated core columns — stripped before metadata dump
  # to avoid duplicating data in the JSONB column.
  @core_plaid_keys ~w(
    transaction_id
    amount
    date
    merchant_name
    website
    pending
    pending_transaction_id
    account_id
    personal_finance_category
  )

  defp build_transaction_attrs(txn, account_id, category_lookup) do
    date =
      case txn["date"] do
        nil -> nil
        date_str -> Date.from_iso8601!(date_str)
      end

    personal_finance_category = personal_finance_category_token(txn)

    metadata =
      txn
      |> Map.drop(@core_plaid_keys)
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    %{
      plaid_transaction_id: txn["transaction_id"],
      amount: dollars_to_cents(txn["amount"]),
      date: date,
      merchant_name: txn["merchant_name"],
      website: txn["website"],
      personal_finance_category: personal_finance_category,
      meta_category_id: category_lookup[personal_finance_category],
      is_pending: txn["pending"] || false,
      pending_transaction_id: txn["pending_transaction_id"],
      account_id: account_id,
      metadata: metadata
    }
  end

  defp dollars_to_cents(nil), do: nil

  defp dollars_to_cents(amount) when is_number(amount) do
    round(amount * 100)
  end

  # --- B2 download helpers (webhook path) -----------------------------------

  defp download_from_b2!(object_key) do
    case B2.download_file(object_key) do
      {:ok, body} ->
        body

      {:error, reason} ->
        raise "[TransactionProcessor] B2 download failed for #{object_key}: #{inspect(reason)}"
    end
  end

  defp extract_plaid_item_id!(object_key) do
    case KeyBuilder.extract_plaid_item_id(object_key) do
      {:ok, id} ->
        id

      :error ->
        raise "[TransactionProcessor] Unrecognized key layout: #{object_key}. " <>
                "Expected plaid_sync/{household_id}/{user_id}/{plaid_item_id}/YYYY/MM/timestamp.json. " <>
                "Legacy 3-segment keys must be re-keyed before replay."
    end
  end

  defp load_plaid_item_by_plaid_id!(plaid_item_id) do
    Banking.PlaidItem
    |> Ash.Query.filter(plaid_item_id == ^plaid_item_id)
    |> Ash.Query.load([:accounts, user: :household])
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> raise "[TransactionProcessor] PlaidItem not found: plaid_item_id=#{plaid_item_id}"
      item -> item
    end
  end
end
