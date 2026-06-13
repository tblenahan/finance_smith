defmodule FinanceSmith.Banking.BalanceRefresh do
  @moduledoc """
  Shared helper that performs a real-time Plaid `/accounts/balance/get` call
  for a `PlaidItem` and persists the returned balances via the system-only
  `Account.update_cached_balances` action.

  ## Callers

  - `FinanceSmith.DataLake.SyncWorker` — conditional path, only when
    `last_balance_synced_at` is nil or older than 24 hours.
  - `FinanceSmith.Banking.PlaidItem.Changes.FetchRealtimeBalances` — actor-
    authorized UI-triggered path.

  ## Error resilience

  Per-account update failures are logged as warnings; the run continues for
  remaining accounts but returns `{:error, :partial_update}` if any matched
  non-duplicate account fails to persist. Callers must only advance
  `last_balance_synced_at` on `:ok`. A Plaid API error returns
  `{:error, reason}`. Duplicates and unknown `plaid_account_id` values are
  skipped and do not count as failures.

  ## Security

  This module never loads `access_token` itself. It receives a `PlaidItem`
  struct that already has `:access_token` and `:accounts` loaded by the caller
  (either `SyncWorker.load_plaid_item!/1` or `FetchRealtimeBalances`).
  `authorize?: false` on the account writes is intentional — writes are
  system-only per the Account write policy (see `AGENT_SECURITY.md` rule 8).
  """

  alias FinanceSmith.Banking.{Account, PlaidBalances, PlaidItem}

  require Logger

  @refresh_interval_hours 24

  @doc """
  Returns the configured real-time balance refresh interval in hours.
  """
  @spec refresh_interval_hours() :: pos_integer()
  def refresh_interval_hours, do: @refresh_interval_hours

  @doc """
  Returns `true` when a paid real-time balance fetch is due (never synced or
  older than `refresh_interval_hours/0`).
  """
  @spec stale?(DateTime.t() | nil) :: boolean()
  def stale?(nil), do: true

  def stale?(last_balance_synced_at) do
    DateTime.diff(DateTime.utc_now(), last_balance_synced_at, :hour) >= @refresh_interval_hours
  end

  @doc """
  Returns `true` when balances were synced within `refresh_interval_hours/0`.
  `nil` is treated as not fresh (UI may proceed without a cost warning).
  """
  @spec fresh?(DateTime.t() | nil) :: boolean()
  def fresh?(nil), do: false

  def fresh?(last_balance_synced_at) do
    DateTime.diff(DateTime.utc_now(), last_balance_synced_at, :hour) < @refresh_interval_hours
  end

  @doc """
  Calls Plaid `/accounts/balance/get` using the `access_token` already loaded
  on `plaid_item`, then persists current/available/limit for each matching
  non-duplicate account.

  Returns `:ok` when all matched account updates succeed, `{:error, :partial_update}`
  when any matched non-duplicate account fails to persist, or `{:error, reason}`
  if the Plaid API call fails.
  """
  @spec run(PlaidItem.t()) :: :ok | {:error, term()}
  def run(%PlaidItem{access_token: token, accounts: accounts} = plaid_item) do
    case plaid_client().get_balance(%{access_token: token}) do
      {:ok, %{accounts: plaid_accounts}} ->
        account_lookup = Map.new(accounts, fn a -> {a.plaid_account_id, a} end)

        failed? =
          Enum.any?(plaid_accounts, fn plaid_account ->
            update_account_balance(plaid_account, account_lookup, plaid_item.id) == :error
          end)

        if failed? do
          Logger.warning(
            "[BalanceRefresh] Partial balance update failure. plaid_item=#{plaid_item.id} accounts=#{length(plaid_accounts)}"
          )

          {:error, :partial_update}
        else
          Logger.info(
            "[BalanceRefresh] Balances refreshed. plaid_item=#{plaid_item.id} accounts=#{length(plaid_accounts)}"
          )

          :ok
        end

      {:error, reason} ->
        Logger.warning(
          "[BalanceRefresh] Plaid balance fetch failed. plaid_item=#{plaid_item.id} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # --- Private helpers --------------------------------------------------------

  defp update_account_balance(plaid_account, account_lookup, plaid_item_id) do
    case Map.fetch(account_lookup, plaid_account.account_id) do
      {:ok, %Account{duplicate_of_id: nil} = account} ->
        attrs = %{
          current_balance: PlaidBalances.balance_to_cents(plaid_account.balances),
          available_balance: PlaidBalances.balance_available_to_cents(plaid_account.balances),
          credit_limit: PlaidBalances.balance_limit_to_cents(plaid_account.balances)
        }

        account
        |> Ash.Changeset.for_update(:update_cached_balances, attrs, authorize?: false)
        |> Ash.update(authorize?: false)
        |> case do
          {:ok, _updated} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[BalanceRefresh] Balance update failed for account=#{account.id} — skipping. reason=#{inspect(reason)}"
            )

            :error
        end

      {:ok, %Account{id: account_id, duplicate_of_id: _}} ->
        Logger.debug(
          "[BalanceRefresh] Skipping duplicate account=#{account_id} plaid_account_id=#{plaid_account.account_id}"
        )

        :ok

      :error ->
        Logger.warning(
          "[BalanceRefresh] Unknown plaid_account_id=#{plaid_account.account_id} for plaid_item=#{plaid_item_id} — skipping"
        )

        :ok
    end
  end

  defp plaid_client do
    Application.get_env(:finance_smith, :plaid_client, FinanceSmith.Banking.Plaid)
  end
end
