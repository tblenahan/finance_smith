defmodule FinanceSmith.DataLake.SyncWorkerBalanceGatingTest do
  @moduledoc """
  Tests the 24h balance-refresh gate in SyncWorker without running a full sync.
  Uses direct Ash calls to set up the `last_balance_synced_at` timestamp and
  then verifies that `get_balance` is (or is not) called via Mox expectations.
  """

  use FinanceSmith.DataCase, async: false
  use Oban.Testing, repo: FinanceSmith.Repo, prefix: "machine"

  import Mox
  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking.{MockPlaid, PlaidItem}
  alias FinanceSmith.Banking.Plaid.SyncTransactionsResponse
  alias FinanceSmith.DataLake.SyncWorker
  alias FinanceSmith.Identity

  require Ash.Query

  setup :verify_on_exit!

  setup do
    Mox.set_mox_global()
    on_exit(fn -> Mox.set_mox_private() end)
    :ok
  end

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  # Builds a minimal valid sync response to get the worker through the sync loop.
  # The no-op sync response has no transactions and no further pages.
  defp stub_noop_sync(token) do
    stub(MockPlaid, :sync_transactions, fn %{access_token: ^token} ->
      {:ok,
       %SyncTransactionsResponse{
         added: [],
         modified: [],
         removed: [],
         next_cursor: "cursor_#{System.unique_integer([:positive])}",
         has_more: false
       }}
    end)
  end

  defp stub_balance_success(token, plaid_account_id) do
    stub(MockPlaid, :get_balance, fn %{access_token: ^token} ->
      {:ok,
       %Plaid.Accounts{
         accounts: [
           %Plaid.Accounts.Account{
             account_id: plaid_account_id,
             balances: %Plaid.Accounts.Account.Balance{
               current: 100.0,
               available: nil,
               limit: nil
             }
           }
         ],
         item: nil,
         request_id: "req_gating"
       }}
    end)
  end

  describe "balance fetch gating" do
    test "calls get_balance when last_balance_synced_at is nil" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item, %{plaid_account_id: "acc_gate_nil"})
      assert is_nil(plaid_item.last_balance_synced_at)

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      stub_noop_sync(token)

      expect(MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: account.plaid_account_id,
               balances: %Plaid.Accounts.Account.Balance{
                 current: 200.0,
                 available: nil,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_nil_gate"
         }}
      end)

      assert :ok = perform_job(SyncWorker, %{"plaid_item_id" => plaid_item.id})

      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      refute is_nil(reloaded.last_balance_synced_at)
    end

    test "calls get_balance when last_balance_synced_at is older than 24 hours" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item, %{plaid_account_id: "acc_gate_stale"})

      # Force last_balance_synced_at to 25 hours ago
      stale_ts = DateTime.add(DateTime.utc_now(), -(25 * 60 * 60), :second)

      plaid_item
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:last_balance_synced_at, stale_ts)
      |> Ash.update!(authorize?: false)

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      stub_noop_sync(token)
      stub_balance_success(token, account.plaid_account_id)

      assert :ok = perform_job(SyncWorker, %{"plaid_item_id" => plaid_item.id})

      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      # Timestamp should now be recent, not the stale value
      diff = DateTime.diff(DateTime.utc_now(), reloaded.last_balance_synced_at, :second)
      assert diff < 10
    end

    test "does NOT call get_balance when last_balance_synced_at is within 24 hours" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      _account = create_account!(plaid_item)

      # Force last_balance_synced_at to 1 hour ago
      fresh_ts = DateTime.add(DateTime.utc_now(), -(1 * 60 * 60), :second)

      plaid_item
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:last_balance_synced_at, fresh_ts)
      |> Ash.update!(authorize?: false)

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      stub_noop_sync(token)
      # Explicitly assert get_balance is NEVER called
      expect(MockPlaid, :get_balance, 0, fn _ -> :not_called end)

      assert :ok = perform_job(SyncWorker, %{"plaid_item_id" => plaid_item.id})
    end

    # Regression test for review finding: SyncWorker used to call
    # BalanceRefresh.restore_balance_timestamp/3 on a paid-fetch failure,
    # re-opening the 24h window. That meant every subsequent periodic sync
    # would re-attempt (and re-bill) the paid call for as long as the
    # failure persisted (e.g. ITEM_LOGIN_REQUIRED, or an institution outage).
    # SyncWorker now leaves the claimed window spent on failure instead —
    # the timestamp still advances even though the paid fetch failed — so a
    # sustained failure is retried at most once per refresh_interval_hours/0.
    # A user can still force an immediate retry via force: true in the UI.
    test "leaves the claimed timestamp spent (does not restore) when Plaid get_balance fails" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      _account = create_account!(plaid_item)
      assert is_nil(plaid_item.last_balance_synced_at)

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      stub_noop_sync(token)

      expect(MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:error, %Plaid.Error{error_code: "INSTITUTION_DOWN"}}
      end)

      # Job still succeeds — balance failure should not abort the sync
      assert :ok = perform_job(SyncWorker, %{"plaid_item_id" => plaid_item.id})

      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      refute is_nil(reloaded.last_balance_synced_at)
      assert DateTime.diff(DateTime.utc_now(), reloaded.last_balance_synced_at, :second) < 10
    end

    # See the regression note above — the same "leave the claim spent"
    # behavior applies to a partial persistence failure, not just a Plaid
    # API error.
    test "leaves the claimed timestamp spent (does not restore) when BalanceRefresh returns partial_update" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account_ok = create_account!(plaid_item, %{plaid_account_id: "acc_partial_ok"})
      account_fail = create_account!(plaid_item, %{plaid_account_id: "acc_partial_fail"})
      assert is_nil(plaid_item.last_balance_synced_at)

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      stub_noop_sync(token)

      expect(MockPlaid, :get_balance, fn %{access_token: ^token} ->
        # Destroy after SyncWorker loaded accounts so BalanceRefresh still attempts
        # the update and hits a stale-record failure.
        Ash.destroy!(account_fail, authorize?: false)

        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_partial_ok",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 100.0,
                 available: nil,
                 limit: nil
               }
             },
             %Plaid.Accounts.Account{
               account_id: "acc_partial_fail",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 200.0,
                 available: nil,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_partial"
         }}
      end)

      assert :ok = perform_job(SyncWorker, %{"plaid_item_id" => plaid_item.id})

      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      refute is_nil(reloaded.last_balance_synced_at)

      updated_ok = Ash.get!(FinanceSmith.Banking.Account, account_ok.id, authorize?: false)
      assert updated_ok.current_balance == 10_000
    end

    # Regression test for review finding: SyncWorker's claim, cached apply,
    # and paid fetch are three separate steps, only the first of which is
    # transactional. This exercises a concurrent claim landing while this
    # run's sync loop is still in flight — strictly before this run reaches
    # its own claim_paid_refresh/1 call (the sync_transactions mock is the
    # one deterministic hook available before that point) — simulating a
    # concurrent force: true UI refresh or a second SyncWorker run winning
    # the window first. This run's own claim must then observe :already_fresh
    # and skip both the cached apply and the paid fetch entirely, rather than
    # overwriting the fresher values the other claimant is responsible for.
    test "skips cached and paid updates when a concurrent claim lands before this run's own claim" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item, %{plaid_account_id: "acc_superseded"})
      assert is_nil(plaid_item.last_balance_synced_at)

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      stub(MockPlaid, :sync_transactions, fn %{access_token: ^token} ->
        assert {:claimed, _previous, _claimed_at} =
                 FinanceSmith.Banking.BalanceRefresh.force_claim_paid_refresh(plaid_item.id)

        {:ok,
         %SyncTransactionsResponse{
           added: [],
           modified: [],
           removed: [],
           next_cursor: "cursor_superseded",
           has_more: false,
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_superseded",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 999.0,
                 available: nil,
                 limit: nil
               }
             }
           ]
         }}
      end)

      # get_balance must never be called: by the time this run reaches its
      # own claim_paid_refresh/1 call, the concurrent force claim above has
      # already claimed the window, so this run must observe :already_fresh.
      expect(MockPlaid, :get_balance, 0, fn _ -> :not_called end)

      assert :ok = perform_job(SyncWorker, %{"plaid_item_id" => plaid_item.id})

      # Neither the cached balance from the sync payload (999.0, i.e. 99_900
      # cents) nor a paid balance should have been applied.
      reloaded_account = Ash.get!(FinanceSmith.Banking.Account, account.id, authorize?: false)
      assert is_nil(account.current_balance)
      assert is_nil(reloaded_account.current_balance)
    end
  end
end
