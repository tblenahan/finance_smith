defmodule FinanceSmith.Banking.PlaidItem.Changes.FetchRealtimeBalances do
  @moduledoc """
  Performs a real-time Plaid `/accounts/balance/get` call for the given
  `PlaidItem` and persists the returned balances via `Account.update_cached_balances`.

  On success, sets `last_balance_synced_at` to the current UTC time so that
  `SyncWorker` and the UI can gate subsequent paid calls.

  On failure, adds an Ash changeset error and does NOT advance the timestamp,
  preventing a silent stale-timestamp update.

  ## Concurrency

  When `force: false` (the default), the 24h window is claimed atomically via
  `BalanceRefresh.claim_paid_refresh/1` *before* calling Plaid — this closes a
  check-then-act race where a background `SyncWorker` run and a user-triggered
  UI refresh (or two browser tabs) could otherwise both observe "stale" and
  both issue a paid Plaid call. If the subsequent Plaid call or persistence
  fails, the previous timestamp is restored via
  `BalanceRefresh.restore_balance_timestamp/3`, a compare-and-swap on the
  claimed timestamp so it won't clobber a concurrent successful refresh, so
  the window re-opens for a legitimate retry. `force: true` intentionally
  bypasses the claim — the user has already acknowledged the cost advisory in
  the UI, so there is no window to protect (though two overlapping forced
  refreshes, or a forced refresh racing a background claim, can still both
  bill Plaid — this is an accepted tradeoff of the explicit user
  acknowledgment).

  ## Security (AGENT_SECURITY.md rule 6 — permitted access_token load sites)

  The `authorize?: false` scope is **strictly limited** to a single
  `Ash.read_one!/2` call that loads only `:access_token` and `:accounts` for
  the network request. It never escapes into broad reads, is never called from
  the UI read layer, and is sandboxed within `before_action` so the calling
  LiveView receives no token-bearing struct.
  """

  use Ash.Resource.Change

  alias FinanceSmith.Banking.BalanceRefresh
  alias FinanceSmith.Banking.PlaidItem

  require Ash.Query
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      plaid_item_id = changeset.data.id
      force? = Ash.Changeset.get_argument(changeset, :force)

      if force? do
        refresh_balances(changeset, plaid_item_id)
      else
        case BalanceRefresh.claim_paid_refresh(plaid_item_id) do
          :already_fresh ->
            Ash.Changeset.add_error(
              changeset,
              Ash.Error.Changes.InvalidChanges.exception(
                message:
                  "We have a... discrepancy. Balances were updated less than #{BalanceRefresh.refresh_interval_hours()} hours ago."
              )
            )

          {:claimed, previous_last_balance_synced_at, claimed_at} ->
            refresh_claimed_balances(
              changeset,
              plaid_item_id,
              previous_last_balance_synced_at,
              claimed_at
            )
        end
      end
    end)
  end

  # `force: true` path — the caller already acknowledged the cost advisory,
  # so there is no 24h window to claim/protect. Nothing is persisted until
  # Plaid succeeds, so there is nothing to restore on failure.
  defp refresh_balances(changeset, plaid_item_id) do
    case load_item_with_token(plaid_item_id) do
      nil ->
        add_not_found_error(changeset)

      item ->
        case BalanceRefresh.run(item) do
          :ok ->
            Ash.Changeset.force_change_attribute(
              changeset,
              :last_balance_synced_at,
              DateTime.utc_now()
            )

          {:error, reason} ->
            add_refresh_error(changeset, plaid_item_id, reason)
        end
    end
  end

  # Non-force path — the 24h window has already been atomically claimed (see
  # `change/3`), advancing `last_balance_synced_at` in the DB. Any failure
  # here must restore `previous_last_balance_synced_at` so the window
  # re-opens instead of being silently "spent" on a failed attempt.
  defp refresh_claimed_balances(
         changeset,
         plaid_item_id,
         previous_last_balance_synced_at,
         claimed_at
       ) do
    case load_item_with_token(plaid_item_id) do
      nil ->
        BalanceRefresh.restore_balance_timestamp(
          plaid_item_id,
          previous_last_balance_synced_at,
          claimed_at
        )

        add_not_found_error(changeset)

      item ->
        case BalanceRefresh.run(item) do
          :ok ->
            Ash.Changeset.force_change_attribute(
              changeset,
              :last_balance_synced_at,
              DateTime.utc_now()
            )

          {:error, reason} ->
            BalanceRefresh.restore_balance_timestamp(
              plaid_item_id,
              previous_last_balance_synced_at,
              claimed_at
            )

            add_refresh_error(changeset, plaid_item_id, reason)
        end
    end
  end

  # authorize?: false is tightly scoped: single-record load of access_token
  # + accounts for the Plaid network call only. See module doc / AGENT_SECURITY rule 6.
  defp load_item_with_token(plaid_item_id) do
    PlaidItem
    |> Ash.Query.filter(id == ^plaid_item_id)
    |> Ash.Query.load([:access_token, :accounts])
    |> Ash.read_one!(authorize?: false)
  end

  defp add_not_found_error(changeset) do
    Ash.Changeset.add_error(
      changeset,
      Ash.Error.Changes.InvalidChanges.exception(
        message: "We have a... discrepancy. The item could not be located."
      )
    )
  end

  defp add_refresh_error(changeset, plaid_item_id, :partial_update) do
    Logger.error(
      "[FetchRealtimeBalances] Partial balance update failure for plaid_item=#{plaid_item_id}"
    )

    Ash.Changeset.add_error(
      changeset,
      Ash.Error.Changes.InvalidChanges.exception(
        message: "We have a... discrepancy. Some balances could not be persisted."
      )
    )
  end

  defp add_refresh_error(changeset, plaid_item_id, reason) do
    Logger.error(
      "[FetchRealtimeBalances] Plaid balance fetch failed for plaid_item=#{plaid_item_id}: #{inspect(reason)}"
    )

    Ash.Changeset.add_error(
      changeset,
      Ash.Error.Changes.InvalidChanges.exception(
        message: "We have a... discrepancy. The real-time balance fetch failed."
      )
    )
  end
end
