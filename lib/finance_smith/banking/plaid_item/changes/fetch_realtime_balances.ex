defmodule FinanceSmith.Banking.PlaidItem.Changes.FetchRealtimeBalances do
  @moduledoc """
  Performs a real-time Plaid `/accounts/balance/get` call for the given
  `PlaidItem` and persists the returned balances via `Account.update_cached_balances`.

  On success, sets `last_balance_synced_at` to the current UTC time so that
  `SyncWorker` and the UI can gate subsequent paid calls.

  On failure, adds an Ash changeset error and does NOT advance the timestamp,
  preventing a silent stale-timestamp update.

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

      if BalanceRefresh.fresh?(changeset.data.last_balance_synced_at) and not force? do
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Changes.InvalidChanges.exception(
            message:
              "We have a... discrepancy. Balances were updated less than #{BalanceRefresh.refresh_interval_hours()} hours ago."
          )
        )
      else
        refresh_balances(changeset, plaid_item_id)
      end
    end)
  end

  defp refresh_balances(changeset, plaid_item_id) do
    # authorize?: false is tightly scoped: single-record load of access_token
    # + accounts for the Plaid network call only. See module doc / AGENT_SECURITY rule 6.
    item_with_token =
      PlaidItem
      |> Ash.Query.filter(id == ^plaid_item_id)
      |> Ash.Query.load([:access_token, :accounts])
      |> Ash.read_one!(authorize?: false)

    case item_with_token do
      nil ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Changes.InvalidChanges.exception(
            message: "We have a... discrepancy. The item could not be located."
          )
        )

      item ->
        case BalanceRefresh.run(item) do
          :ok ->
            Ash.Changeset.force_change_attribute(
              changeset,
              :last_balance_synced_at,
              DateTime.utc_now()
            )

          {:error, :partial_update} ->
            Logger.error(
              "[FetchRealtimeBalances] Partial balance update failure for plaid_item=#{plaid_item_id}"
            )

            Ash.Changeset.add_error(
              changeset,
              Ash.Error.Changes.InvalidChanges.exception(
                message: "We have a... discrepancy. Some balances could not be persisted."
              )
            )

          {:error, reason} ->
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
  end
end
