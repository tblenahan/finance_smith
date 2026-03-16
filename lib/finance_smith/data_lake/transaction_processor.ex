defmodule FinanceSmith.DataLake.TransactionProcessor do
  @moduledoc """
  Applies a Plaid transaction sync payload to the PostgreSQL database.

  ## Entry points

  - `process/2` — primary path used by `SyncWorker`. Accepts a loaded
    `PlaidItem` (with accounts) and a string-keyed payload map produced by
    `Uploader.to_sync_payload/1`. No network I/O — works entirely from data
    already in memory.

  - `process_from_b2/1` — secondary path reserved for the future webhook
    pipeline. Downloads the archived JSON from B2 by object key, parses it,
    loads the matching PlaidItem, then delegates to `process/2`.

  ## Processing flow

  1. Build a lookup map of Plaid account ID -> internal account UUID.
  2. Run all DB operations inside a single Repo transaction:
     - `added` / `modified` → upsert on `:unique_plaid_transaction_id`
     - `removed` → bulk destroy by `plaid_transaction_id`
  3. Return `:ok` on success or raise on failure.

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
      upsert_transactions!(payload["added"] || [], account_lookup)
      upsert_transactions!(payload["modified"] || [], account_lookup)
      remove_transactions!(payload["removed"] || [])
    end)
    |> case do
      {:ok, _} ->
        Logger.info("[TransactionProcessor] Done. plaid_item=#{plaid_item.id}")
        :ok

      {:error, reason} ->
        raise "[TransactionProcessor] DB transaction failed for plaid_item=#{plaid_item.id}: #{inspect(reason)}"
    end
  end

  @doc """
  Downloads the B2 archive at `object_key`, parses it, and calls `process/2`.

  Reserved for the future webhook-driven ingestion path. The PlaidItem is
  resolved from the object key path, loaded with its accounts, then passed
  to `process/2`.

  Returns `:ok` or raises on failure.
  """
  @spec process_from_b2(String.t()) :: :ok
  def process_from_b2(object_key) do
    Logger.info("[TransactionProcessor] Downloading from B2. key=#{object_key}")

    json = download_from_b2!(object_key)
    payload = Jason.decode!(json)

    plaid_item_id = extract_plaid_item_id!(object_key)
    plaid_item = load_plaid_item_by_plaid_id!(plaid_item_id)

    process(plaid_item, payload)
  end

  # --- Account lookup -------------------------------------------------------

  defp build_account_lookup(%PlaidItem{accounts: accounts}) do
    Map.new(accounts, fn account -> {account.plaid_account_id, account.id} end)
  end

  # --- Transaction writes ---------------------------------------------------

  defp upsert_transactions!(transactions, account_lookup) do
    Enum.each(transactions, fn txn ->
      plaid_account_id = txn["account_id"]

      case Map.fetch(account_lookup, plaid_account_id) do
        {:ok, account_id} ->
          attrs = build_transaction_attrs(txn, account_id)

          Transaction
          |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
          |> Ash.create!(
            upsert?: true,
            upsert_identity: :unique_plaid_transaction_id,
            authorize?: false
          )

        :error ->
          Logger.warning(
            "[TransactionProcessor] Unknown plaid_account_id=#{plaid_account_id} — skipping transaction #{txn["transaction_id"]}"
          )
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

  defp build_transaction_attrs(txn, account_id) do
    date =
      case txn["date"] do
        nil -> nil
        date_str -> Date.from_iso8601!(date_str)
      end

    category = extract_category(txn["personal_finance_category"])

    %{
      plaid_transaction_id: txn["transaction_id"],
      amount: dollars_to_cents(txn["amount"]),
      date: date,
      merchant_name: txn["merchant_name"],
      category: category,
      is_pending: txn["pending"] || false,
      account_id: account_id
    }
  end

  defp extract_category(nil), do: nil

  defp extract_category(pfc) when is_map(pfc) do
    [pfc["primary"], pfc["detailed"]]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      categories -> categories
    end
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
