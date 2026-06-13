defmodule FinanceSmith.Banking.PlaidItemBalanceTest do
  @moduledoc """
  Tests for the hybrid balance fetch actions on PlaidItem:
  :update_balance_timestamp and :fetch_realtime_balances.
  """

  use FinanceSmith.DataCase, async: false

  import Mox
  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.PlaidItem
  alias FinanceSmith.Identity

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

      assert {:error, _} = Banking.fetch_realtime_balances(plaid_item.id, actor: user)

      # Timestamp must remain nil
      reloaded = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      assert is_nil(reloaded.last_balance_synced_at)
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
