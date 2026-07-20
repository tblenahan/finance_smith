defmodule FinanceSmith.Banking.PlaidItemBalanceTest do
  @moduledoc """
  Tests for the hybrid balance fetch actions on PlaidItem:
  :update_balance_timestamp and :fetch_realtime_balances.
  """

  use FinanceSmith.DataCase, async: false

  import Mox
  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.{BalanceRefresh, PlaidItem}
  alias FinanceSmith.Identity
  alias FinanceSmithWeb.AshErrorHTML

  require Ash.Query

  setup :verify_on_exit!

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  # -------------------------------------------------------------------------
  # :update_balance_timestamp
  # -------------------------------------------------------------------------

  describe ":update_balance_timestamp" do
    test "sets last_balance_synced_at to current UTC time" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      assert is_nil(plaid_item.last_balance_synced_at)

      updated =
        plaid_item
        |> Ash.Changeset.for_update(:update_balance_timestamp, %{}, authorize?: false)
        |> Ash.update!(authorize?: false)

      refute is_nil(updated.last_balance_synced_at)
      # Timestamp should be within the last 5 seconds
      diff = DateTime.diff(DateTime.utc_now(), updated.last_balance_synced_at, :second)
      assert diff >= 0 and diff < 5
    end

    test "can be called multiple times, advancing the timestamp each time" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      first =
        plaid_item
        |> Ash.Changeset.for_update(:update_balance_timestamp, %{}, authorize?: false)
        |> Ash.update!(authorize?: false)

      # Small delay to ensure timestamp advances
      Process.sleep(10)

      second =
        first
        |> Ash.Changeset.for_update(:update_balance_timestamp, %{}, authorize?: false)
        |> Ash.update!(authorize?: false)

      assert DateTime.compare(second.last_balance_synced_at, first.last_balance_synced_at) in [
               :gt,
               :eq
             ]
    end
  end

  # -------------------------------------------------------------------------
  # Account :update_cached_balances
  # -------------------------------------------------------------------------

  describe "Account :update_cached_balances" do
    test "persists current_balance, available_balance, and credit_limit" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)

      assert is_nil(account.available_balance)

      updated =
        account
        |> Ash.Changeset.for_update(
          :update_cached_balances,
          %{current_balance: 100_000, available_balance: 80_000, credit_limit: nil},
          authorize?: false
        )
        |> Ash.update!(authorize?: false)

      assert updated.current_balance == 100_000
      assert updated.available_balance == 80_000
      assert is_nil(updated.credit_limit)
    end

    test "accepts nil available_balance gracefully" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)

      updated =
        account
        |> Ash.Changeset.for_update(
          :update_cached_balances,
          %{current_balance: 50_000, available_balance: nil, credit_limit: nil},
          authorize?: false
        )
        |> Ash.update!(authorize?: false)

      assert updated.current_balance == 50_000
      assert is_nil(updated.available_balance)
    end
  end

  # -------------------------------------------------------------------------
  # :fetch_realtime_balances — authorization
  # -------------------------------------------------------------------------

  describe ":fetch_realtime_balances authorization" do
    test "is authorized for the item owner" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      _account = create_account!(plaid_item, %{plaid_account_id: "acc_owner_test"})
      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_owner_test",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 1000.0,
                 available: nil,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_owner"
         }}
      end)

      assert {:ok, updated_item} = Banking.fetch_realtime_balances(plaid_item.id, actor: user)
      refute is_nil(updated_item.last_balance_synced_at)
    end

    test "is forbidden for an unrelated user" do
      owner = register_user!()
      other = register_user!()
      plaid_item = create_plaid_item!(owner)

      assert_raise Ash.Error.Forbidden, fn ->
        Banking.fetch_realtime_balances(plaid_item.id, actor: other)
      end
    end

    test "is authorized for a same-household member" do
      owner = register_user!()
      member = register_user!()

      member =
        member
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:household_id, owner.household_id)
        |> Ash.update!(authorize?: false)

      plaid_item = create_plaid_item!(owner)
      _account = create_account!(plaid_item, %{plaid_account_id: "acc_household_test"})
      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_household_test",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 500.0,
                 available: nil,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_household"
         }}
      end)

      assert {:ok, updated_item} =
               Banking.fetch_realtime_balances(plaid_item.id, actor: member)

      refute is_nil(updated_item.last_balance_synced_at)
    end

    test "does not advance timestamp when Plaid fetch fails" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      _account = create_account!(plaid_item)
      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:error, %Plaid.Error{error_code: "ITEM_LOGIN_REQUIRED"}}
      end)

      assert {:error, error} = Banking.fetch_realtime_balances(plaid_item.id, actor: user)

      assert AshErrorHTML.format_for_user(error) ==
               "We have a... discrepancy. The real-time balance fetch failed."

      # Timestamp must remain nil — the atomic claim taken before the Plaid
      # call must have been rolled back via restore_balance_timestamp/3.
      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      assert is_nil(reloaded.last_balance_synced_at)
    end

    test "does not advance timestamp when BalanceRefresh returns partial_update" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      _account_ok = create_account!(plaid_item, %{plaid_account_id: "acc_action_partial_ok"})
      account_fail = create_account!(plaid_item, %{plaid_account_id: "acc_action_partial_fail"})
      assert is_nil(plaid_item.last_balance_synced_at)

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        Ash.destroy!(account_fail, authorize?: false)

        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_action_partial_ok",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 100.0,
                 available: nil,
                 limit: nil
               }
             },
             %Plaid.Accounts.Account{
               account_id: "acc_action_partial_fail",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 200.0,
                 available: nil,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_action_partial"
         }}
      end)

      assert {:error, error} = Banking.fetch_realtime_balances(plaid_item.id, actor: user)

      assert AshErrorHTML.format_for_user(error) ==
               "We have a... discrepancy. Some balances could not be persisted."

      # Timestamp must remain nil — restore_balance_timestamp/3 must have
      # reverted the claim taken before the (partially-failing) Plaid call.
      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      assert is_nil(reloaded.last_balance_synced_at)
    end

    # Regression test for review finding: claim_paid_refresh/1 used to fold a
    # missing PlaidItem into :already_fresh. Bypassing the code interface's
    # get_by read (which would otherwise surface a different, generic
    # not-found error before our change ever runs) lets this exercise the
    # :not_found branch inside FetchRealtimeBalances directly.
    test "surfaces not-found messaging when the item is deleted before the atomic claim runs" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      Ash.destroy!(plaid_item, authorize?: false)

      assert {:error, error} =
               plaid_item
               |> Ash.Changeset.for_update(:fetch_realtime_balances, %{}, authorize?: false)
               |> Ash.update(authorize?: false)

      assert AshErrorHTML.format_for_user(error) =~
               "We have a... discrepancy. The item could not be located."
    end

    test "rejects refresh when balances are fresh and force is false" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      _account = create_account!(plaid_item, %{plaid_account_id: "acc_fresh_gate"})

      fresh_item =
        plaid_item
        |> Ash.Changeset.for_update(:update_balance_timestamp, %{}, authorize?: false)
        |> Ash.update!(authorize?: false)

      assert BalanceRefresh.fresh?(fresh_item.last_balance_synced_at)

      assert {:error, error} =
               Banking.fetch_realtime_balances(plaid_item.id, %{force: false}, actor: user)

      assert AshErrorHTML.format_for_user(error) =~
               "Balances were updated less than #{BalanceRefresh.refresh_interval_hours()} hours ago."

      # Rejected as :already_fresh — no claim should have been taken, so the
      # row must be untouched (not just restored to the same value).
      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)

      assert DateTime.compare(reloaded.last_balance_synced_at, fresh_item.last_balance_synced_at) ==
               :eq
    end

    test "allows refresh when balances are fresh and force is true" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      _account = create_account!(plaid_item, %{plaid_account_id: "acc_force_refresh"})
      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      _fresh_item =
        plaid_item
        |> Ash.Changeset.for_update(:update_balance_timestamp, %{}, authorize?: false)
        |> Ash.update!(authorize?: false)

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_force_refresh",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 750.0,
                 available: 700.0,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_force"
         }}
      end)

      assert {:ok, updated_item} =
               Banking.fetch_realtime_balances(plaid_item.id, %{force: true}, actor: user)

      refute is_nil(updated_item.last_balance_synced_at)
    end
  end

  # -------------------------------------------------------------------------
  # read_for_ui includes last_balance_synced_at
  # -------------------------------------------------------------------------

  describe ":read_for_ui" do
    test "includes last_balance_synced_at in the selected fields" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      # Set the timestamp via system action
      updated =
        plaid_item
        |> Ash.Changeset.for_update(:update_balance_timestamp, %{}, authorize?: false)
        |> Ash.update!(authorize?: false)

      {:ok, summary} = Banking.get_plaid_item_summary_by_id(updated.id, actor: user)
      refute is_nil(summary.last_balance_synced_at)
    end

    test "does not include access_token in the selected fields" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      {:ok, summary} = Banking.get_plaid_item_summary_by_id(plaid_item.id, actor: user)

      assert %Ash.NotLoaded{} = summary.access_token
    end
  end
end
