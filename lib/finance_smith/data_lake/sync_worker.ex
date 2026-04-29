defmodule FinanceSmith.DataLake.SyncWorker do
  @moduledoc """
  Oban worker that syncs transactions for a single Plaid item.

  Calls `Plaid.sync_transactions/1` in a cursor-based loop until all pages
  have been fetched. For each page it:

  1. Archives the raw response to Backblaze B2 via `Uploader`.
  2. On a successful upload, enqueues a `ProcessWorker` job to download the
     archived JSON and upsert transactions. This decouples the sync loop from
     the database write — the sync advances immediately while processing runs
     asynchronously.
  3. On a failed upload (B2 unavailable), falls back to processing transactions
     directly from the in-memory payload so that data is never lost.
  4. Persists the new cursor to `PlaidItem.next_cursor` so subsequent runs
     resume where this one left off.

  ## Scheduling

  - **On-demand**: call `SyncWorker.enqueue(plaid_item_id)` from anywhere in
    the app to trigger an immediate sync (e.g. after a user connects a new bank).

  ## Error handling

  - **Plaid errors** (e.g. `ITEM_LOGIN_REQUIRED`): the item's status is set
    to `:error` and the job is discarded (not retried) — the item needs human
    action before it can sync again.
  - **Transient errors** (network, DB): Oban retries up to `max_attempts`
    times using its default backoff. The cursor is only updated on success,
    so retries re-process the same page safely.
  """

  use Oban.Worker,
    queue: :data_lake,
    max_attempts: 3,
    unique: [period: 300, fields: [:args]]

  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.{PlaidBalances, PlaidItem}
  alias FinanceSmith.DataLake.{ProcessWorker, TransactionProcessor, Uploader}

  require Ash.Query
  require Logger

  @doc """
  Enqueues a sync job for the `PlaidItem` with the given internal UUID.

  The unique constraint prevents duplicate jobs for the same item within 5
  minutes, so this is safe to call on every request or event.
  """
  @spec enqueue(Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(plaid_item_id) when is_binary(plaid_item_id) do
    %{plaid_item_id: plaid_item_id}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"plaid_item_id" => plaid_item_id}}) do
    plaid_item = load_plaid_item!(plaid_item_id)

    Logger.info(
      "[SyncWorker] Starting sync. plaid_item=#{plaid_item.id} institution=#{plaid_item.institution_name}"
    )

    sync_all_pages(plaid_item)
  end

  # --- Sync loop ------------------------------------------------------------

  defp sync_all_pages(plaid_item) do
    params = build_sync_params(plaid_item)

    case FinanceSmith.Banking.Plaid.sync_transactions(params) do
      {:ok, sync_response} ->
        handle_page(plaid_item, sync_response)

      {:error, reason} ->
        handle_plaid_error(plaid_item, reason)
    end
  end

  defp handle_page(plaid_item, sync_response) do
    payload = Uploader.to_sync_payload(sync_response)

    dispatch_processing(plaid_item, sync_response, payload)

    updated_item = persist_cursor!(plaid_item, payload["next_cursor"])

    if payload["has_more"] do
      Logger.debug("[SyncWorker] has_more=true, fetching next page. plaid_item=#{plaid_item.id}")
      sync_all_pages(updated_item)
    else
      Logger.info("[SyncWorker] Sync complete. plaid_item=#{plaid_item.id}")
      refresh_balances(updated_item)
      complete_sync!(updated_item)
      :ok
    end
  end

  # --- Processing dispatch --------------------------------------------------

  # Uploads the raw response to B2 and enqueues a ProcessWorker job.
  # Falls back to immediate in-memory processing if the upload fails.
  defp dispatch_processing(plaid_item, sync_response, payload) do
    case Uploader.upload_sync_response(plaid_item, sync_response) do
      {:ok, object_key} ->
        Logger.debug("[SyncWorker] Archived to B2. plaid_item=#{plaid_item.id} key=#{object_key}")

        case ProcessWorker.enqueue(object_key) do
          {:ok, _job} ->
            Logger.debug(
              "[SyncWorker] Enqueued ProcessWorker. plaid_item=#{plaid_item.id} key=#{object_key}"
            )

          {:error, reason} ->
            Logger.warning(
              "[SyncWorker] ProcessWorker enqueue failed, falling back to in-memory processing. plaid_item=#{plaid_item.id} reason=#{inspect(reason)}"
            )

            TransactionProcessor.process(plaid_item, payload)
        end

      {:error, reason} ->
        Logger.warning(
          "[SyncWorker] B2 upload failed, falling back to in-memory processing. plaid_item=#{plaid_item.id} reason=#{inspect(reason)}"
        )

        TransactionProcessor.process(plaid_item, payload)
    end
  end

  # --- Error handling -------------------------------------------------------

  defp handle_plaid_error(plaid_item, reason) do
    Logger.error(
      "[SyncWorker] Plaid API error. plaid_item=#{plaid_item.id} reason=#{inspect(reason)}"
    )

    plaid_item
    |> Ash.Changeset.for_update(:update, %{status: :error}, authorize?: false)
    |> Ash.update!(authorize?: false)

    # Discard prevents Oban from retrying — the item needs re-authentication
    {:discard, "Plaid error: #{inspect(reason)}"}
  end

  # --- Helpers --------------------------------------------------------------

  defp build_sync_params(%PlaidItem{access_token: token, next_cursor: cursor}) do
    base = %{access_token: token, options: %{include_personal_finance_category: true}}

    if cursor, do: Map.put(base, :cursor, cursor), else: base
  end

  defp persist_cursor!(plaid_item, next_cursor) do
    plaid_item
    |> Ash.Changeset.for_update(:update, %{next_cursor: next_cursor}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp complete_sync!(plaid_item) do
    plaid_item
    |> Ash.Changeset.for_update(:complete_sync, %{}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  # Fetches real-time balances from Plaid and persists them for each account.
  # A failure here logs a warning but does NOT raise — stale balances are
  # preferable to losing a sync run or triggering Oban retries.
  defp refresh_balances(%PlaidItem{access_token: token, accounts: accounts} = plaid_item) do
    case plaid_client().get_balance(%{access_token: token}) do
      {:ok, %{accounts: plaid_accounts}} ->
        account_lookup = Map.new(accounts, fn a -> {a.plaid_account_id, a} end)

        # TODO: For households with many accounts, consider Ash.bulk_update or
        # Task.async_stream with bounded concurrency to reduce sequential DB round-trips.
        Enum.each(plaid_accounts, fn plaid_account ->
          case Map.fetch(account_lookup, plaid_account.account_id) do
            {:ok, account} ->
              new_balance = PlaidBalances.balance_to_cents(plaid_account.balances)
              new_limit = PlaidBalances.balance_limit_to_cents(plaid_account.balances)

              account
              |> Ash.Changeset.for_update(
                :update_balance,
                %{current_balance: new_balance, credit_limit: new_limit},
                authorize?: false
              )
              |> Ash.update(authorize?: false)
              |> case do
                {:ok, _updated} ->
                  :ok

                {:error, reason} ->
                  Logger.warning(
                    "[SyncWorker] Balance update failed for account=#{account.id} — skipping. reason=#{inspect(reason)}"
                  )
              end

            :error ->
              Logger.warning(
                "[SyncWorker] Balance refresh: unknown plaid_account_id=#{plaid_account.account_id} — skipping"
              )
          end
        end)

        Logger.info(
          "[SyncWorker] Balances refreshed. plaid_item=#{plaid_item.id} accounts=#{length(plaid_accounts)}"
        )

      {:error, reason} ->
        Logger.warning(
          "[SyncWorker] Balance refresh failed — sync still complete. plaid_item=#{plaid_item.id} reason=#{inspect(reason)}"
        )
    end
  end

  defp load_plaid_item!(id) do
    Banking.PlaidItem
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load([:access_token, :accounts, user: :household])
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> raise "[SyncWorker] PlaidItem not found: #{id}"
      item -> item
    end
  end

  defp plaid_client do
    Application.get_env(:finance_smith, :plaid_client, FinanceSmith.Banking.Plaid)
  end
end
