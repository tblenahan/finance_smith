defmodule FinanceSmith.Banking.BalanceRefreshTest do
  use FinanceSmith.DataCase, async: false

  import Mox
  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking.{Account, BalanceRefresh}
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
        create_account!(plaid_item, %{
          plaid_account_id: "acc_dup",
          duplicate_of_id: original.id
        })

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
  end
end
