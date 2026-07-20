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
  alias FinanceSmith.Banking.{BalanceRefresh, PlaidItem}
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

    case plaid_client().sync_transactions(params) do
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

      loaded_item =
        Ash.load!(updated_item, [:access_token, :accounts, :last_balance_synced_at],
          authorize?: false
        )

      apply_cached_balances_and_maybe_refresh_realtime(loaded_item, payload["accounts"] || [])
      complete_sync!(loaded_item)
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

            TransactionProcessor.process(plaid_item, payload, apply_cached_balances?: false)
        end

      {:error, reason} ->
        Logger.warning(
          "[SyncWorker] B2 upload failed, falling back to in-memory processing. plaid_item=#{plaid_item.id} reason=#{inspect(reason)}"
        )

        TransactionProcessor.process(plaid_item, payload, apply_cached_balances?: false)
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

  # Atomically claims the 24h paid-fetch window via
  # BalanceRefresh.claim_paid_refresh/1 (a FOR UPDATE-locked claim) *before*
  # touching balances at all — this closes two races at once:
  #
  # 1. This background run and a concurrent user-triggered UI refresh could
  #    otherwise both observe "stale" and both issue a paid Plaid call.
  # 2. Applying free cached balances from the sync payload before checking
  #    staleness could overwrite a fresher paid refresh that completed
  #    concurrently (e.g. a `force: true` UI refresh) — claiming first and
  #    only applying cached balances when the claim succeeds means cached
  #    values are never written after a fresher paid refresh has landed.
  #
  # On a successful claim, free cached balances from the sync payload are
  # applied first, then the paid fetch runs. A paid failure logs a warning
  # and restores the previous timestamp (compare-and-swap on claimed_at, so
  # it won't clobber a concurrent successful refresh) so the window re-opens
  # for a later retry, but does NOT raise — stale balances never abort a
  # sync run or trigger Oban retries. When the window is already fresh or the
  # item can no longer be found, neither the cached nor the paid write is
  # attempted — a fresher value (paid or otherwise) already won.
  defp apply_cached_balances_and_maybe_refresh_realtime(
         %PlaidItem{} = plaid_item,
         payload_accounts
       ) do
    case BalanceRefresh.claim_paid_refresh(plaid_item.id) do
      {:claimed, previous_last_balance_synced_at, claimed_at} ->
        Logger.info(
          "[SyncWorker] Balance stale — applying cached and fetching real-time. plaid_item=#{plaid_item.id}"
        )

        TransactionProcessor.apply_cached_balances(plaid_item, payload_accounts)

        case BalanceRefresh.run(plaid_item) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[SyncWorker] Real-time balance fetch failed — sync still complete. plaid_item=#{plaid_item.id} reason=#{inspect(reason)}"
            )

            BalanceRefresh.restore_balance_timestamp(
              plaid_item.id,
              previous_last_balance_synced_at,
              claimed_at
            )
        end

      :already_fresh ->
        Logger.debug(
          "[SyncWorker] Balance fresh (< #{BalanceRefresh.refresh_interval_hours()}h) — skipping cached and paid updates. plaid_item=#{plaid_item.id}"
        )

      :not_found ->
        Logger.warning(
          "[SyncWorker] PlaidItem not found while claiming balance refresh window — skipping cached and paid updates. plaid_item=#{plaid_item.id}"
        )
    end
  end

  defp load_plaid_item!(id) do
    Banking.PlaidItem
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load([:access_token, :accounts, :last_balance_synced_at, user: :household])
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
