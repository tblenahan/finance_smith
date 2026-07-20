defmodule FinanceSmith.DataLake.SyncWorkerCachedBalanceOrderingTest do
  @moduledoc """
  Regression tests for cached vs paid balance ordering.

  Ensures async ProcessWorker jobs cannot overwrite fresher paid balances and
  that SyncWorker applies paid fetches after cached sync values.
  """

  use FinanceSmith.DataCase, async: false
  use Oban.Testing, repo: FinanceSmith.Repo, prefix: "machine"

  import Mox
  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking.{Account, BalanceRefresh, MockPlaid, PlaidItem}
  alias FinanceSmith.Banking.Plaid.SyncTransactionsResponse
  alias FinanceSmith.DataLake.{SyncWorker, TransactionProcessor}
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

  defp balance_only_payload(plaid_account_id, current) do
    %{
      "added" => [],
      "modified" => [],
      "removed" => [],
      "next_cursor" => "cursor_ordering",
      "has_more" => false,
      "accounts" => [
        %{
          "account_id" => plaid_account_id,
          "balances" => %{"current" => current, "available" => nil, "limit" => nil}
        }
      ]
    }
  end

  defp set_account_balance!(account, cents) do
    account
    |> Ash.Changeset.for_update(
      :update_cached_balances,
      %{current_balance: cents, available_balance: nil, credit_limit: nil},
      authorize?: false
    )
    |> Ash.update!(authorize?: false)
  end

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

  describe "process/2 apply_cached_balances? option" do
    test "does not overwrite balances when apply_cached_balances? is false" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item, %{plaid_account_id: "acc_skip_cached"})

      plaid_item =
        plaid_item |> Ash.load!([:accounts, user: :household], authorize?: false)

      set_account_balance!(account, 200_000)

      payload = balance_only_payload(account.plaid_account_id, 1000.00)

      assert :ok =
               TransactionProcessor.process(plaid_item, payload, apply_cached_balances?: false)

      updated = Ash.get!(Account, account.id, authorize?: false)
      assert updated.current_balance == 200_000
    end

    test "still applies cached balances by default" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item, %{plaid_account_id: "acc_apply_cached"})

      plaid_item =
        plaid_item |> Ash.load!([:accounts, user: :household], authorize?: false)

      set_account_balance!(account, 200_000)

      payload = balance_only_payload(account.plaid_account_id, 1000.00)

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      updated = Ash.get!(Account, account.id, authorize?: false)
      assert updated.current_balance == 100_000
    end
  end

  describe "paid vs cached ordering" do
    test "late ProcessWorker path cannot overwrite a fresher paid balance" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item, %{plaid_account_id: "acc_race"})

      item =
        plaid_item
        |> Ash.load!([:access_token, :accounts, user: :household], authorize?: false)

      token = item.access_token

      expect(MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_race",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 2000.0,
                 available: nil,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_paid_first"
         }}
      end)

      assert :ok = BalanceRefresh.run(item)

      updated = Ash.get!(Account, account.id, authorize?: false)
      assert updated.current_balance == 200_000

      payload = balance_only_payload("acc_race", 1000.00)

      assert :ok =
               TransactionProcessor.process(item, payload, apply_cached_balances?: false)

      reloaded = Ash.get!(Account, account.id, authorize?: false)
      assert reloaded.current_balance == 200_000
    end

    test "SyncWorker paid fetch wins when balance is stale" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item, %{plaid_account_id: "acc_sync_paid"})

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      stub_noop_sync(token)

      expect(MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: account.plaid_account_id,
               balances: %Plaid.Accounts.Account.Balance{
                 current: 2000.0,
                 available: nil,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_sync_paid"
         }}
      end)

      assert :ok = perform_job(SyncWorker, %{"plaid_item_id" => plaid_item.id})

      updated = Ash.get!(Account, account.id, authorize?: false)
      assert updated.current_balance == 200_000

      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      refute is_nil(reloaded.last_balance_synced_at)
    end
  end

  defp stub_sync_with_accounts(token, plaid_account_id, current) do
    stub(MockPlaid, :sync_transactions, fn %{access_token: ^token} ->
      {:ok,
       %SyncTransactionsResponse{
         added: [],
         modified: [],
         removed: [],
         next_cursor: "cursor_#{System.unique_integer([:positive])}",
         has_more: false,
         accounts: [
           %Plaid.Accounts.Account{
             account_id: plaid_account_id,
             balances: %Plaid.Accounts.Account.Balance{
               current: current,
               available: nil,
               limit: nil
             }
           }
         ]
       }}
    end)
  end

  describe "sync response accounts end-to-end" do
    test "applies cached balances from sync response accounts when paid fetch fails" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item, %{plaid_account_id: "acc_sync_cached"})
      assert is_nil(plaid_item.last_balance_synced_at)

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      stub_sync_with_accounts(token, account.plaid_account_id, 1500.0)

      expect(MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:error, %Plaid.Error{error_code: "INSTITUTION_DOWN"}}
      end)

      assert :ok = perform_job(SyncWorker, %{"plaid_item_id" => plaid_item.id})

      updated = Ash.get!(Account, account.id, authorize?: false)
      assert updated.current_balance == 150_000
    end

    test "does not apply cached balances when paid refresh is fresh" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item, %{plaid_account_id: "acc_fresh_gate_cached"})

      item =
        plaid_item
        |> Ash.load!([:access_token, :accounts, user: :household], authorize?: false)

      token = item.access_token

      expect(MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: account.plaid_account_id,
               balances: %Plaid.Accounts.Account.Balance{
                 current: 2000.0,
                 available: nil,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_fresh_paid"
         }}
      end)

      assert :ok = BalanceRefresh.run(item)

      updated = Ash.get!(Account, account.id, authorize?: false)
      assert updated.current_balance == 200_000

      fresh_ts = DateTime.add(DateTime.utc_now(), -(1 * 60 * 60), :second)

      plaid_item
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:last_balance_synced_at, fresh_ts)
      |> Ash.update!(authorize?: false)

      stub_sync_with_accounts(token, account.plaid_account_id, 1000.0)
      expect(MockPlaid, :get_balance, 0, fn _ -> :not_called end)

      assert :ok = perform_job(SyncWorker, %{"plaid_item_id" => plaid_item.id})

      reloaded = Ash.get!(Account, account.id, authorize?: false)
      assert reloaded.current_balance == 200_000
    end

    # Regression test for review finding: SyncWorker used to apply free
    # cached sync-payload balances via a *separate* staleness check from the
    # paid-fetch claim, so cached balances could still be applied even after
    # a concurrent force refresh had already claimed the window and
    # persisted a fresher paid balance. SyncWorker now claims the window
    # first and only applies cached balances (and attempts a paid fetch) when
    # it wins that same claim — modeling a concurrent force refresh that
    # already claimed the window and persisted its paid balance before
    # SyncWorker's own sync run reaches the balance step.
    test "cached sync balances are skipped once a concurrent claim has already won the window" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item, %{plaid_account_id: "acc_concurrent_claim"})
      assert is_nil(plaid_item.last_balance_synced_at)

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      assert {:claimed, nil, _claimed_at} = BalanceRefresh.claim_paid_refresh(plaid_item.id)
      set_account_balance!(account, 900_000)

      stub_sync_with_accounts(token, account.plaid_account_id, 1234.0)
      expect(MockPlaid, :get_balance, 0, fn _ -> :not_called end)

      assert :ok = perform_job(SyncWorker, %{"plaid_item_id" => plaid_item.id})

      reloaded = Ash.get!(Account, account.id, authorize?: false)
      assert reloaded.current_balance == 900_000
    end
  end
end
