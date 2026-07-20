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

  defp sync_all_pages(plaid_item), do: sync_all_pages(plaid_item, %{})

  # `accounts_by_id` accumulates `payload["accounts"]` across every page,
  # keyed by Plaid's `account_id` — see `handle_page/3` for why a single
  # page's accounts are not sufficient on their own.
  defp sync_all_pages(plaid_item, accounts_by_id) do
    params = build_sync_params(plaid_item)

    case plaid_client().sync_transactions(params) do
      {:ok, sync_response} ->
        handle_page(plaid_item, sync_response, accounts_by_id)

      {:error, reason} ->
        handle_plaid_error(plaid_item, reason)
    end
  end

  # Plaid's `/transactions/sync` only includes an account in a page's
  # `accounts` array when that account had activity on that page — it is not
  # the full account list repeated on every page. Using only the last page's
  # `accounts` (as a previous version of this worker did) would silently miss
  # cached-balance updates for any account whose only activity landed on an
  # earlier page. Merging by `account_id` across all pages, with the later
  # page winning on conflict (Plaid balances are already point-in-time as of
  # each page, so the last-seen value for a given account is also the most
  # recent), fixes this.
  defp handle_page(plaid_item, sync_response, accounts_by_id) do
    payload = Uploader.to_sync_payload(sync_response)

    dispatch_processing(plaid_item, sync_response, payload)

    updated_item = persist_cursor!(plaid_item, payload["next_cursor"])

    accounts_by_id = merge_accounts_by_id(accounts_by_id, payload["accounts"] || [])

    if payload["has_more"] do
      Logger.debug("[SyncWorker] has_more=true, fetching next page. plaid_item=#{plaid_item.id}")
      sync_all_pages(updated_item, accounts_by_id)
    else
      Logger.info("[SyncWorker] Sync complete. plaid_item=#{plaid_item.id}")

      loaded_item =
        Ash.load!(updated_item, [:access_token, :accounts, :last_balance_synced_at],
          authorize?: false
        )

      apply_cached_balances_and_maybe_refresh_realtime(loaded_item, Map.values(accounts_by_id))
      complete_sync!(loaded_item)
      :ok
    end
  end

  defp merge_accounts_by_id(accounts_by_id, page_accounts) do
    Enum.reduce(page_accounts, accounts_by_id, fn plaid_account, acc ->
      Map.put(acc, plaid_account["account_id"], plaid_account)
    end)
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
  # 2. Applying free cached balances from the sync payload without winning
  #    that claim could overwrite a fresher paid refresh that completed
  #    concurrently (e.g. a `force: true` UI refresh). A `force: true` UI
  #    refresh also claims (and stamps `last_balance_synced_at`) via
  #    BalanceRefresh.force_claim_paid_refresh/1 *before* it calls Plaid — see
  #    BalanceRefresh's "The `force: true` claim" moduledoc section — so once
  #    that claim commits, this claim sees a fresh timestamp and skips both
  #    the paid fetch and any cached fallback entirely.
  #
  # After winning the claim, this run issues the paid fetch first. Free
  # cached balances from the sync payload are applied only as a same-run
  # fallback when the paid fetch fails *and* the claim is still held —
  # never before the paid attempt. That ordering closes the residual race
  # where a concurrent force refresh could land fresher paid balances while
  # this run was still applying older cached values, then skip its own paid
  # fetch after noticing the claim was superseded.
  #
  # BalanceRefresh.claim_still_held?/2 re-checks ownership before the paid
  # fetch and again before any cached fallback, and skips the remaining
  # work — without restoring — if a newer claim has already superseded this
  # one; see BalanceRefresh moduledoc for why proceeding after losing
  # ownership, or restoring in that case, would be wrong.
  #
  # A paid-fetch failure (Plaid API error or partial persistence failure)
  # logs a warning but does NOT raise (stale balances never abort a sync run
  # or trigger Oban retries) and does NOT restore the claimed timestamp —
  # see BalanceRefresh's "SyncWorker does not restore on paid failure"
  # moduledoc section for why leaving the window spent, rather than
  # re-opening it for every subsequent sync run, is the correct behavior
  # here. When the window is already fresh or the item can no longer be
  # found, neither the cached nor the paid write is attempted — a fresher
  # value (paid or otherwise) already won.
  defp apply_cached_balances_and_maybe_refresh_realtime(
         %PlaidItem{} = plaid_item,
         payload_accounts
       ) do
    case BalanceRefresh.claim_paid_refresh(plaid_item.id) do
      {:claimed, _previous, claimed_at} ->
        apply_claimed_balances(plaid_item, payload_accounts, claimed_at)

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

  defp apply_claimed_balances(%PlaidItem{} = plaid_item, payload_accounts, claimed_at) do
    if BalanceRefresh.claim_still_held?(plaid_item.id, claimed_at) do
      Logger.info(
        "[SyncWorker] Balance stale — fetching real-time (cached fallback only on paid failure). plaid_item=#{plaid_item.id}"
      )

      case BalanceRefresh.run(plaid_item) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[SyncWorker] Real-time balance fetch failed — sync still complete, leaving the 24h window spent. plaid_item=#{plaid_item.id} reason=#{inspect(reason)}"
          )

          if BalanceRefresh.claim_still_held?(plaid_item.id, claimed_at) do
            TransactionProcessor.apply_cached_balances(plaid_item, payload_accounts)
          else
            Logger.info(
              "[SyncWorker] Claim superseded by a concurrent refresh after paid fetch failed — skipping cached fallback. plaid_item=#{plaid_item.id}"
            )
          end
      end
    else
      Logger.info(
        "[SyncWorker] Claim superseded by a concurrent refresh before paid fetch — skipping paid and cached updates. plaid_item=#{plaid_item.id}"
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
