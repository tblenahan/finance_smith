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

  ## Concurrency — the 24h claim

  `stale?/1` and `fresh?/1` are pure read-only predicates; checking one and
  then later calling `run/1` is a check-then-act race; two concurrent callers
  (e.g. a background `SyncWorker` run racing a user-triggered UI refresh, or
  two browser tabs) could both observe "stale" and both issue a paid Plaid
  call within the same 24h window.

  `claim_paid_refresh/1` closes that gap by running inside a single DB
  transaction that first locks the target row with `SELECT ... FOR UPDATE`,
  then checks staleness against the locked value, and only then issues the
  `UPDATE`. This is what makes the claim safe: a concurrent claimant blocks on
  the row lock itself (not merely on the `UPDATE`'s implicit lock), and once
  it acquires the lock its own `SELECT ... FOR UPDATE` re-fetches the
  now-committed row — so it observes the winner's freshly-set timestamp
  rather than a frozen pre-lock snapshot. At most one caller receives
  `{:claimed, _, _}` per window; no lock is held across the subsequent Plaid
  HTTP call (the transaction commits before `run/1` is invoked). A missing
  row (the `PlaidItem` was deleted concurrently) is distinguished as
  `:not_found` rather than folded into `:already_fresh`.

  Callers that go on to fail (Plaid error or partial persistence failure)
  may call `restore_balance_timestamp/3` with the `previous` and `claimed_at`
  values returned by the claim to re-open the window for a legitimate retry.
  The restore is a compare-and-swap: it only reverts the timestamp if it
  still equals `claimed_at`, i.e. nothing else has advanced it since this
  call claimed the window. This protects against a second scenario: a
  restore happening at the same moment a concurrent `force: true` UI refresh
  has already succeeded and advanced the timestamp again — without the CAS,
  the restore would silently erase that successful refresh's timestamp.

  Restoring is a caller-specific choice, not a universal rule: the
  actor-facing `FetchRealtimeBalances` path always restores on failure,
  since a real user is waiting on the outcome and deserves an immediate
  retry. `SyncWorker`, by contrast, deliberately does **not** restore on a
  paid-fetch failure — see "SyncWorker does not restore on paid failure"
  below.

  `claim_still_held?/2` lets a caller re-check, after claiming, whether its
  claim is still the most recent write to `last_balance_synced_at` — i.e.
  nothing else (most commonly a concurrent `force_claim_paid_refresh/1`) has
  advanced the timestamp again since. A caller that has lost ownership this
  way should skip its remaining work rather than proceed: applying free
  cached balances after losing ownership could overwrite a fresher paid
  write that landed in between, and issuing its own paid fetch after losing
  ownership would spend Plaid quota redundantly. Losing ownership is not a
  failure of the caller's own claim, so it must not call
  `restore_balance_timestamp/3` in that case — the row's timestamp already
  reflects the newer claim's work, not this caller's.

  ## SyncWorker does not restore on paid failure

  Unlike the actor-facing path, `SyncWorker` leaves the claimed window
  "spent" when its own paid fetch fails (Plaid API error or partial
  persistence failure) — it does not call `restore_balance_timestamp/3`.
  Restoring would re-open the window for every subsequent sync run during a
  sustained outage (e.g. `ITEM_LOGIN_REQUIRED`, or an account that
  persistently fails to update), causing every periodic sync to re-attempt
  — and re-bill — the paid call. Leaving the window spent means a broken
  item is retried at most once per `refresh_interval_hours/0`, with the
  cached balances from the sync payload already applied as a same-run
  fallback. A user can still force an immediate retry via `force: true` in
  the UI, which claims (and, on failure, restores) independently.

  ## The `force: true` claim

  `force_claim_paid_refresh/1` shares the same `SELECT ... FOR UPDATE` +
  `UPDATE` transaction as `claim_paid_refresh/1`, but skips the `stale?/1`
  gate — it always advances `last_balance_synced_at` (or returns `:not_found`
  for a deleted item), since a `force: true` caller has already acknowledged
  the cost advisory and is not subject to the 24h window.

  Stamping *before* the Plaid call — inside the same locked transaction,
  exactly like the non-force claim — matters because it closes the gap where
  a concurrent `SyncWorker` run's own `claim_paid_refresh/1` would otherwise
  still observe a stale/nil timestamp for the full duration of the force
  call's Plaid round-trip, claim the window itself, and apply free cached
  balances that could land after the force call's fresher paid balances.
  Once the force claim's transaction commits, any concurrent
  `claim_paid_refresh/1` immediately observes the just-set timestamp as
  fresh and skips both the cached apply and its own paid fetch.

  This does not fully serialize the two calls' Plaid round-trips or account
  writes — only the claim step is transactional, so a background claim that
  wins the row lock *before* a `force: true` claim can still complete its own
  cached-apply-then-paid-fetch sequence concurrently with (and interleaved
  with) the force call's own fetch. Two overlapping `force: true` calls, or a
  forced refresh racing a background claim that already won, can still both
  bill Plaid — this remains an accepted tradeoff of the explicit user
  acknowledgment (see `FetchRealtimeBalances` moduledoc).
  """

  alias FinanceSmith.Banking.{Account, PlaidBalances, PlaidItem}
  alias FinanceSmith.Repo

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
  Atomically claims the right to perform a paid Plaid balance fetch for the
  `PlaidItem` with the given id.

  Locks the target row with `SELECT ... FOR UPDATE` before checking
  staleness, then advances `last_balance_synced_at` to now only if the locked
  value is `nil` or older than `refresh_interval_hours/0`. A concurrent
  claimant blocks on the row lock itself (not merely on the `UPDATE`'s
  implicit target-row lock); once it acquires the lock, `FOR UPDATE`
  re-fetches the current committed row rather than a pre-lock snapshot, so it
  correctly observes the winner's just-set timestamp as "not stale". At most
  one caller receives `{:claimed, _, _}` per window.

  Returns `{:claimed, previous_last_balance_synced_at, claimed_at}` on
  success — the caller must persist both values via
  `restore_balance_timestamp/3` if the subsequent Plaid call or persistence
  fails. Returns `:already_fresh` when another caller already holds the
  window, or `:not_found` when no `PlaidItem` with this id exists (e.g. it
  was deleted concurrently) — callers must not treat this the same as
  `:already_fresh`, since no window was ever held.
  """
  @spec claim_paid_refresh(Ecto.UUID.t()) ::
          {:claimed, DateTime.t() | nil, DateTime.t()} | :already_fresh | :not_found
  def claim_paid_refresh(plaid_item_id) do
    do_claim(plaid_item_id, force?: false)
  end

  @doc """
  Atomically claims the right to perform a `force: true` paid Plaid balance
  fetch for the `PlaidItem` with the given id, bypassing the 24h staleness
  gate (see "The `force: true` claim" above).

  Shares the same locked claim transaction as `claim_paid_refresh/1`, so it
  always advances `last_balance_synced_at` to now and returns
  `{:claimed, previous_last_balance_synced_at, claimed_at}` — the caller must
  persist both values via `restore_balance_timestamp/3` if the subsequent
  Plaid call or persistence fails. Returns `:not_found` when no `PlaidItem`
  with this id exists.
  """
  @spec force_claim_paid_refresh(Ecto.UUID.t()) ::
          {:claimed, DateTime.t() | nil, DateTime.t()} | :not_found
  def force_claim_paid_refresh(plaid_item_id) do
    case do_claim(plaid_item_id, force?: true) do
      {:claimed, _previous, _claimed_at} = claimed -> claimed
      :not_found -> :not_found
    end
  end

  defp do_claim(plaid_item_id, force?: force?) do
    dumped_id = Ecto.UUID.dump!(plaid_item_id)

    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.query!(
               """
               SELECT last_balance_synced_at
               FROM core.plaid_items
               WHERE id = $1
               FOR UPDATE
               """,
               [dumped_id]
             ) do
          %{rows: []} ->
            :not_found

          %{rows: [[previous]]} ->
            previous_utc = naive_to_utc(previous)

            if force? or stale?(previous_utc) do
              %{rows: [[claimed]]} =
                Repo.query!(
                  """
                  UPDATE core.plaid_items
                  SET last_balance_synced_at = (now() AT TIME ZONE 'utc')
                  WHERE id = $1
                  RETURNING last_balance_synced_at
                  """,
                  [dumped_id]
                )

              {:claimed, previous_utc, naive_to_utc(claimed)}
            else
              :already_fresh
            end
        end
      end)

    result
  end

  @doc """
  Restores `last_balance_synced_at` to `previous_last_balance_synced_at` after
  a claimed paid fetch (see `claim_paid_refresh/1`) fails, re-opening the 24h
  window for a legitimate retry instead of leaving it "spent" on a failed
  attempt.

  This is a compare-and-swap guarded by `claimed_at`: the restore is only
  applied if `last_balance_synced_at` still equals the value this call
  claimed. If some other write has advanced it since (e.g. a concurrent
  `force: true` refresh that succeeded), the restore is a no-op and the newer
  value is preserved — a blind unconditional restore could otherwise erase a
  legitimate concurrent success.
  """
  @spec restore_balance_timestamp(Ecto.UUID.t(), DateTime.t() | nil, DateTime.t()) :: :ok
  def restore_balance_timestamp(plaid_item_id, previous_last_balance_synced_at, claimed_at) do
    Repo.query!(
      """
      UPDATE core.plaid_items
      SET last_balance_synced_at = $2
      WHERE id = $1 AND last_balance_synced_at = $3
      """,
      [
        Ecto.UUID.dump!(plaid_item_id),
        previous_last_balance_synced_at && DateTime.to_naive(previous_last_balance_synced_at),
        DateTime.to_naive(claimed_at)
      ]
    )

    :ok
  end

  @doc """
  Returns `true` when `last_balance_synced_at` in the database still equals
  `claimed_at` — i.e. this caller's claim (from `claim_paid_refresh/1` or
  `force_claim_paid_refresh/1`) has not been superseded by a newer claim.
  Returns `false` if it has been superseded, or if the `PlaidItem` was
  deleted concurrently.

  Intended for callers with multiple steps between claiming and finishing
  (e.g. applying cached balances, then issuing a paid fetch) that want to
  re-check ownership before each step rather than only trusting the
  original claim result. See the "Concurrency — the 24h claim" module
  section for why losing ownership must not be treated as this caller's own
  failure.
  """
  @spec claim_still_held?(Ecto.UUID.t(), DateTime.t()) :: boolean()
  def claim_still_held?(plaid_item_id, claimed_at) do
    case Repo.query!(
           "SELECT last_balance_synced_at FROM core.plaid_items WHERE id = $1",
           [Ecto.UUID.dump!(plaid_item_id)]
         ) do
      %{rows: [[current]]} -> DateTime.compare(naive_to_utc(current), claimed_at) == :eq
      %{rows: []} -> false
    end
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

        # Enum.map/2 ensures every account is attempted even if an earlier one
        # fails to persist — Enum.any?/2 would short-circuit on the first
        # :error and silently skip the remaining accounts.
        results =
          Enum.map(plaid_accounts, fn plaid_account ->
            update_account_balance(plaid_account, account_lookup, plaid_item.id)
          end)

        failed? = Enum.any?(results, &(&1 == :error))

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

  defp naive_to_utc(nil), do: nil
  defp naive_to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")

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
