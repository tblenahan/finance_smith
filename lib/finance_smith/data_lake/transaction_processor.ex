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

  1. Build a lookup map of Plaid account ID -> internal account UUID.
  2. Run all DB operations inside a single Repo transaction:
     - `added` / `modified` → upsert on `:unique_plaid_transaction_id`, collecting
       `Ash.Notifier.Notification` structs via `return_notifications?: true`
     - `removed` → bulk destroy by `plaid_transaction_id`
  3. After the transaction commits, flush the collected notifications via
     `Ash.Notifier.notify/1` so PubSub subscribers (e.g. the Dashboard LiveView)
     receive `"transaction:created"` broadcasts without missed-notification warnings.
  4. Return `:ok` on success or raise on failure.

  ## Amount convention

  Plaid amounts are floats in dollars (positive = money leaving the account).
  We store amounts as integers in cents (rounded half-up).
  """

  alias FinanceSmith.DataLake.{B2, KeyBuilder}
  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.{PlaidItem, Transaction}

  require Ash.Query
  require Logger

  @doc """
  Processes a sync payload directly from memory.

  `plaid_item` must have `:accounts` loaded.
  `payload` is a string-keyed map as produced by `Uploader.to_sync_payload/1`.

  Returns `:ok` or raises on failure.
  """
  @spec process(PlaidItem.t(), map()) :: :ok
  def process(%PlaidItem{} = plaid_item, payload) when is_map(payload) do
    Logger.info(
      "[TransactionProcessor] Processing. plaid_item=#{plaid_item.id} added=#{length(payload["added"] || [])} modified=#{length(payload["modified"] || [])} removed=#{length(payload["removed"] || [])}"
    )

    account_lookup = build_account_lookup(plaid_item)

    FinanceSmith.Repo.transaction(fn ->
      notifications =
        []
        |> collect_upsert_notifications(payload["added"] || [], account_lookup)
        |> collect_upsert_notifications(payload["modified"] || [], account_lookup)
        |> Enum.reverse()

      remove_transactions!(payload["removed"] || [])
      notifications
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

  The PlaidItem is resolved from the object key path, loaded with its accounts,
  then passed to `process/2`. This is the primary path called by `ProcessWorker`.

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

  # --- Account lookup -------------------------------------------------------

  defp build_account_lookup(%PlaidItem{accounts: accounts}) do
    Map.new(accounts, fn account -> {account.plaid_account_id, account.id} end)
  end

  # --- Transaction writes ---------------------------------------------------

  defp collect_upsert_notifications(acc, transactions, account_lookup) do
    Enum.reduce(transactions, acc, fn txn, acc ->
      plaid_account_id = txn["account_id"]

      case Map.fetch(account_lookup, plaid_account_id) do
        {:ok, account_id} ->
          attrs = build_transaction_attrs(txn, account_id)

          {_record, notifs} =
            Transaction
            |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
            |> Ash.create!(
              upsert?: true,
              upsert_identity: :unique_plaid_transaction_id,
              authorize?: false,
              return_notifications?: true
            )

          List.wrap(notifs) ++ acc

        :error ->
          Logger.warning(
            "[TransactionProcessor] Unknown plaid_account_id=#{plaid_account_id} — skipping transaction #{txn["transaction_id"]}"
          )

          acc
      end
    end)
  end

  defp remove_transactions!(removed_transactions) do
    Enum.each(removed_transactions, fn txn ->
      plaid_transaction_id = txn["transaction_id"]

      Transaction
      |> Ash.Query.filter(plaid_transaction_id == ^plaid_transaction_id)
      |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, return_errors?: true)
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
    account_id
    personal_finance_category
  )

  defp build_transaction_attrs(txn, account_id) do
    date =
      case txn["date"] do
        nil -> nil
        date_str -> Date.from_iso8601!(date_str)
      end

    personal_finance_category =
      case txn["personal_finance_category"] do
        %{"detailed" => detailed} when is_binary(detailed) -> detailed
        _ -> nil
      end

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
      is_pending: txn["pending"] || false,
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
      {:ok, id} -> id
      :error -> raise "[TransactionProcessor] Malformed object key: #{object_key}"
    end
  end

  defp load_plaid_item_by_plaid_id!(plaid_item_id) do
    Banking.PlaidItem
    |> Ash.Query.filter(plaid_item_id == ^plaid_item_id)
    |> Ash.Query.load(:accounts)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> raise "[TransactionProcessor] PlaidItem not found: plaid_item_id=#{plaid_item_id}"
      item -> item
    end
  end
end
