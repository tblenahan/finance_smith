defmodule FinanceSmith.Banking.BalanceRefreshTest do
  use FinanceSmith.DataCase, async: false

  import Mox
  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking.{Account, BalanceRefresh, PlaidItem}
  alias FinanceSmith.Identity

  require Ash.Query

  setup :verify_on_exit!

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  defp load_item_with_token_and_accounts!(plaid_item) do
    plaid_item
    |> Ash.load!([:access_token, :accounts], authorize?: false)
  end

  describe "run/1" do
    test "updates current_balance, available_balance, and credit_limit for non-duplicate accounts" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item, %{plaid_account_id: "acc_refresh_1"})
      item = load_item_with_token_and_accounts!(plaid_item)
      token = item.access_token

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_refresh_1",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 1500.50,
                 available: 1200.00,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_refresh"
         }}
      end)

      assert :ok = BalanceRefresh.run(item)

      updated = Ash.get!(Account, account.id, authorize?: false)
      assert updated.current_balance == 150_050
      assert updated.available_balance == 120_000
      assert is_nil(updated.credit_limit)
    end

    test "stores nil available_balance when Plaid returns nil (unsupported account type)" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item, %{plaid_account_id: "acc_no_avail"})
      item = load_item_with_token_and_accounts!(plaid_item)
      token = item.access_token

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_no_avail",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 5000.0,
                 available: nil,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_no_avail"
         }}
      end)

      assert :ok = BalanceRefresh.run(item)

      updated = Ash.get!(Account, account.id, authorize?: false)
      assert updated.current_balance == 500_000
      assert is_nil(updated.available_balance)
    end

    test "skips duplicate accounts without updating them" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      original = create_account!(plaid_item, %{plaid_account_id: "acc_orig"})

      duplicate =
        Account
        |> Ash.Changeset.for_create(
          :create,
          %{
            plaid_account_id: "acc_dup",
            name: "Dup",
            type: "depository",
            subtype: "checking",
            plaid_item_id: plaid_item.id
          }
        )
        |> Ash.Changeset.force_change_attribute(:duplicate_of_id, original.id)
        |> Ash.create!(authorize?: false)

      item = load_item_with_token_and_accounts!(plaid_item)
      token = item.access_token

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_dup",
               balances: %Plaid.Accounts.Account.Balance{current: 9999.0}
             }
           ],
           item: nil,
           request_id: "req_dup"
         }}
      end)

      assert :ok = BalanceRefresh.run(item)

      # Duplicate account balance must not be changed
      unchanged = Ash.get!(Account, duplicate.id, authorize?: false)
      assert is_nil(unchanged.current_balance)
    end

    test "returns {:error, reason} when Plaid API call fails" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      item = load_item_with_token_and_accounts!(plaid_item)
      token = item.access_token

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:error, %Plaid.Error{error_code: "ITEM_LOGIN_REQUIRED"}}
      end)

      assert {:error, %Plaid.Error{error_code: "ITEM_LOGIN_REQUIRED"}} = BalanceRefresh.run(item)
    end

    test "skips unknown plaid_account_id without raising" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      _account = create_account!(plaid_item, %{plaid_account_id: "acc_known"})
      item = load_item_with_token_and_accounts!(plaid_item)
      token = item.access_token

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_unknown_xyz",
               balances: %Plaid.Accounts.Account.Balance{current: 100.0}
             }
           ],
           item: nil,
           request_id: "req_unknown"
         }}
      end)

      assert :ok = BalanceRefresh.run(item)
    end

    test "returns {:error, :partial_update} when a matched account update fails, with the failing account last" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account_ok = create_account!(plaid_item, %{plaid_account_id: "acc_ok"})
      account_fail = create_account!(plaid_item, %{plaid_account_id: "acc_fail"})
      item = load_item_with_token_and_accounts!(plaid_item)
      token = item.access_token

      Ash.destroy!(account_fail, authorize?: false)

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_ok",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 100.0,
                 available: 90.0,
                 limit: nil
               }
             },
             %Plaid.Accounts.Account{
               account_id: "acc_fail",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 200.0,
                 available: 180.0,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_partial"
         }}
      end)

      assert {:error, :partial_update} = BalanceRefresh.run(item)

      updated = Ash.get!(Account, account_ok.id, authorize?: false)
      assert updated.current_balance == 10_000
      assert updated.available_balance == 9000
    end

    # Regression test for a bug where Enum.any?/2 was used to drive the
    # per-account update side effects: it short-circuits on the first :error,
    # so any account listed *after* a failing one was silently never updated.
    # Here the failing account is deliberately placed FIRST so this test only
    # passes if every account in the response is actually attempted.
    test "returns {:error, :partial_update} but still updates accounts listed after the failing one" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account_fail = create_account!(plaid_item, %{plaid_account_id: "acc_fail_first"})
      account_ok = create_account!(plaid_item, %{plaid_account_id: "acc_ok_second"})
      item = load_item_with_token_and_accounts!(plaid_item)
      token = item.access_token

      Ash.destroy!(account_fail, authorize?: false)

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_fail_first",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 200.0,
                 available: 180.0,
                 limit: nil
               }
             },
             %Plaid.Accounts.Account{
               account_id: "acc_ok_second",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 300.0,
                 available: 270.0,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_partial_fail_first"
         }}
      end)

      assert {:error, :partial_update} = BalanceRefresh.run(item)

      updated = Ash.get!(Account, account_ok.id, authorize?: false)
      assert updated.current_balance == 30_000
      assert updated.available_balance == 27_000
    end
  end

  describe "claim_paid_refresh/1 and restore_balance_timestamp/3" do
    test "claims when never synced and returns {:claimed, nil, claimed_at}" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      assert is_nil(plaid_item.last_balance_synced_at)

      assert {:claimed, nil, claimed_at} = BalanceRefresh.claim_paid_refresh(plaid_item.id)
      refute is_nil(claimed_at)

      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      refute is_nil(reloaded.last_balance_synced_at)
      assert BalanceRefresh.fresh?(reloaded.last_balance_synced_at)
      assert DateTime.diff(reloaded.last_balance_synced_at, claimed_at, :second) == 0
    end

    test "claims when stale and returns the previous timestamp" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      stale_ts = DateTime.add(DateTime.utc_now(), -(25 * 60 * 60), :second)

      plaid_item
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:last_balance_synced_at, stale_ts)
      |> Ash.update!(authorize?: false)

      assert {:claimed, previous, claimed_at} = BalanceRefresh.claim_paid_refresh(plaid_item.id)
      assert DateTime.diff(previous, stale_ts, :second) == 0
      refute is_nil(claimed_at)

      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      assert BalanceRefresh.fresh?(reloaded.last_balance_synced_at)
    end

    test "returns :already_fresh and does not mutate the row when within the window" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      fresh_item =
        plaid_item
        |> Ash.Changeset.for_update(:update_balance_timestamp, %{}, authorize?: false)
        |> Ash.update!(authorize?: false)

      assert :already_fresh = BalanceRefresh.claim_paid_refresh(plaid_item.id)

      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)

      assert DateTime.compare(
               reloaded.last_balance_synced_at,
               fresh_item.last_balance_synced_at
             ) == :eq
    end

    # Regression test for review finding: an empty RETURNING set was
    # previously indistinguishable from "not stale" and both mapped to
    # :already_fresh. A missing PlaidItem (e.g. deleted concurrently) must be
    # reported as :not_found instead, since no window was ever held for it.
    test "returns :not_found for a plaid_item_id that does not exist" do
      assert :not_found = BalanceRefresh.claim_paid_refresh(Ecto.UUID.generate())
    end

    test "returns :not_found for a plaid_item that has been deleted" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      Ash.destroy!(plaid_item, authorize?: false)

      assert :not_found = BalanceRefresh.claim_paid_refresh(plaid_item.id)
    end

    # Regression test for the check-then-act race that claim_paid_refresh/1
    # closes: a second claim attempt after the first has already committed
    # must observe the winner's freshly-committed timestamp and back off,
    # rather than re-reading a stale in-memory snapshot from before the first
    # claim.
    test "a second claim attempt after the first commits observes freshness and backs off" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      assert {:claimed, nil, _claimed_at} = BalanceRefresh.claim_paid_refresh(plaid_item.id)
      assert :already_fresh = BalanceRefresh.claim_paid_refresh(plaid_item.id)
    end

    # Regression test for the FOR UPDATE fix (review finding #1): the previous
    # implementation evaluated staleness against a plain (unlocked) CTE
    # snapshot, so a second claimant blocked on the UPDATE's implicit lock
    # could still observe the pre-lock-wait "stale" snapshot once unblocked and
    # incorrectly succeed too. Locking the row with FOR UPDATE inside the CTE
    # forces the second claimant to re-fetch the just-committed row on
    # unblock, so exactly one of two truly concurrent claims must win.
    test "exactly one of two concurrent claims on the same never-synced item wins" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      parent = self()

      claim = fn ->
        fn ->
          Ecto.Adapters.SQL.Sandbox.allow(FinanceSmith.Repo, parent, self())
          BalanceRefresh.claim_paid_refresh(plaid_item.id)
        end
      end

      task1 = Task.async(claim.())
      task2 = Task.async(claim.())

      results = [Task.await(task1), Task.await(task2)]

      assert Enum.count(results, &match?({:claimed, nil, _claimed_at}, &1)) == 1
      assert Enum.count(results, &(&1 == :already_fresh)) == 1
    end

    test "restore_balance_timestamp/3 writes back a nil previous value" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      assert {:claimed, nil, claimed_at} = BalanceRefresh.claim_paid_refresh(plaid_item.id)
      assert :ok = BalanceRefresh.restore_balance_timestamp(plaid_item.id, nil, claimed_at)

      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      assert is_nil(reloaded.last_balance_synced_at)
      # The window must be open again for a legitimate retry.
      assert {:claimed, nil, _claimed_at} = BalanceRefresh.claim_paid_refresh(plaid_item.id)
    end

    test "restore_balance_timestamp/3 writes back a non-nil previous value" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      stale_ts = DateTime.add(DateTime.utc_now(), -(25 * 60 * 60), :second)

      plaid_item
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:last_balance_synced_at, stale_ts)
      |> Ash.update!(authorize?: false)

      assert {:claimed, previous, claimed_at} = BalanceRefresh.claim_paid_refresh(plaid_item.id)
      assert :ok = BalanceRefresh.restore_balance_timestamp(plaid_item.id, previous, claimed_at)

      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      assert DateTime.diff(reloaded.last_balance_synced_at, stale_ts, :second) == 0
    end

    # Regression test for review finding #2: an unconditional restore could
    # erase a concurrent successful refresh's timestamp. The
    # compare-and-swap in restore_balance_timestamp/3 must be a no-op once
    # last_balance_synced_at no longer equals the claimed_at it was given.
    test "restore_balance_timestamp/3 is a no-op once a newer write has advanced the timestamp" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      assert {:claimed, nil, claimed_at} = BalanceRefresh.claim_paid_refresh(plaid_item.id)

      # Simulate a concurrent force-refresh succeeding after this claim, which
      # advances last_balance_synced_at again to a newer value.
      newer =
        plaid_item
        |> Ash.Changeset.for_update(:update_balance_timestamp, %{}, authorize?: false)
        |> Ash.update!(authorize?: false)

      refute DateTime.compare(newer.last_balance_synced_at, claimed_at) == :eq

      # Restoring against the stale claimed_at must not clobber the newer value.
      assert :ok = BalanceRefresh.restore_balance_timestamp(plaid_item.id, nil, claimed_at)

      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)

      assert DateTime.compare(reloaded.last_balance_synced_at, newer.last_balance_synced_at) ==
               :eq
    end
  end

  describe "force_claim_paid_refresh/1" do
    # Regression test for review finding: force_claim_paid_refresh/1 must
    # bypass the 24h staleness gate and advance the timestamp even when the
    # window is already fresh — this is what lets a force: true refresh
    # stamp before calling Plaid instead of only after persisting balances.
    test "claims and advances the timestamp even when already fresh" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      fresh_item =
        plaid_item
        |> Ash.Changeset.for_update(:update_balance_timestamp, %{}, authorize?: false)
        |> Ash.update!(authorize?: false)

      assert {:claimed, previous, claimed_at} =
               BalanceRefresh.force_claim_paid_refresh(plaid_item.id)

      assert DateTime.compare(previous, fresh_item.last_balance_synced_at) == :eq
      refute is_nil(claimed_at)

      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      assert DateTime.diff(reloaded.last_balance_synced_at, claimed_at, :second) == 0
    end

    test "claims when never synced and returns {:claimed, nil, claimed_at}" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      assert is_nil(plaid_item.last_balance_synced_at)

      assert {:claimed, nil, claimed_at} =
               BalanceRefresh.force_claim_paid_refresh(plaid_item.id)

      refute is_nil(claimed_at)
    end

    test "returns :not_found for a plaid_item_id that does not exist" do
      assert :not_found = BalanceRefresh.force_claim_paid_refresh(Ecto.UUID.generate())
    end

    test "returns :not_found for a plaid_item that has been deleted" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      Ash.destroy!(plaid_item, authorize?: false)

      assert :not_found = BalanceRefresh.force_claim_paid_refresh(plaid_item.id)
    end

    # Regression test for review finding: previously, force: true only
    # stamped last_balance_synced_at via an Ash attribute write *after*
    # BalanceRefresh.run/1 completed, so a concurrent claim_paid_refresh/1
    # (e.g. from SyncWorker) could still observe a stale/nil timestamp for
    # the full duration of the force call's Plaid round-trip. Now that the
    # force claim stamps atomically before Plaid is ever called, a
    # concurrent non-force claim must immediately see the window as fresh.
    test "a concurrent claim_paid_refresh/1 after a force claim observes freshness and backs off" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      assert {:claimed, nil, _claimed_at} = BalanceRefresh.force_claim_paid_refresh(plaid_item.id)
      assert :already_fresh = BalanceRefresh.claim_paid_refresh(plaid_item.id)
    end

    test "restore_balance_timestamp/3 re-opens the window after a force claim" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      assert {:claimed, nil, claimed_at} =
               BalanceRefresh.force_claim_paid_refresh(plaid_item.id)

      assert :ok = BalanceRefresh.restore_balance_timestamp(plaid_item.id, nil, claimed_at)

      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      assert is_nil(reloaded.last_balance_synced_at)
    end
  end

  describe "stale?/1 and fresh?/1" do
    test "stale?/1 is true for nil and timestamps older than 24 hours" do
      assert BalanceRefresh.stale?(nil)

      stale_ts = DateTime.add(DateTime.utc_now(), -(25 * 60 * 60), :second)
      assert BalanceRefresh.stale?(stale_ts)
    end

    test "stale?/1 is false for timestamps within 24 hours" do
      fresh_ts = DateTime.add(DateTime.utc_now(), -(1 * 60 * 60), :second)
      refute BalanceRefresh.stale?(fresh_ts)
    end

    test "fresh?/1 is false for nil and true for recent timestamps" do
      refute BalanceRefresh.fresh?(nil)

      fresh_ts = DateTime.add(DateTime.utc_now(), -(1 * 60 * 60), :second)
      assert BalanceRefresh.fresh?(fresh_ts)
    end

    test "refresh_interval_hours/0 returns 24" do
      assert BalanceRefresh.refresh_interval_hours() == 24
    end
  end
end
