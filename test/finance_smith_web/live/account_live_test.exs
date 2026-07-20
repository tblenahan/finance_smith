defmodule FinanceSmithWeb.AccountLiveTest do
  use FinanceSmithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias FinanceSmith.Banking.{Account, PlaidItem}
  alias FinanceSmith.BankingFixtures
  alias FinanceSmith.Identity

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

  defp live_account(conn, account_id) do
    live(conn, "/accounts/#{account_id}")
  end

  describe "balance refresh" do
    test "shows Refresh Balance when account has a linked Plaid item", %{conn: conn} do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)
      account = BankingFixtures.create_account!(plaid_item)

      {:ok, _view, html} = conn |> log_in_user(user) |> live_account(account.id)

      assert html =~ "Refresh Balance"
    end

    test "shows cost advisory when balances are fresh without calling Plaid", %{conn: conn} do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)
      account = BankingFixtures.create_account!(plaid_item)

      _fresh_item =
        plaid_item
        |> Ash.Changeset.for_update(:update_balance_timestamp, %{}, authorize?: false)
        |> Ash.update!(authorize?: false)

      {:ok, view, _html} = conn |> log_in_user(user) |> live_account(account.id)

      html = view |> element("button", "Refresh Balance") |> render_click()

      assert html =~ "Cost advisory"
      assert html =~ "Proceed"
    end

    test "refreshes stale balances asynchronously", %{conn: conn} do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)

      account =
        BankingFixtures.create_account!(plaid_item, %{plaid_account_id: "acc_live_refresh"})

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_live_refresh",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 2222.0,
                 available: 2000.0,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_live_refresh"
         }}
      end)

      {:ok, view, _html} = conn |> log_in_user(user) |> live_account(account.id)

      view |> element("button", "Refresh Balance") |> render_click()

      html = render_async(view)
      assert html =~ "Sync complete. Inevitable."

      updated = Ash.get!(Account, account.id, authorize?: false)
      assert updated.current_balance == 222_200
      assert updated.available_balance == 200_000
    end

    test "confirm_balance_refresh proceeds with force when balances are fresh", %{conn: conn} do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)

      account =
        BankingFixtures.create_account!(plaid_item, %{plaid_account_id: "acc_live_force"})

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
               account_id: "acc_live_force",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 3333.0,
                 available: 3000.0,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_live_force"
         }}
      end)

      {:ok, view, _html} = conn |> log_in_user(user) |> live_account(account.id)

      view |> element("button", "Refresh Balance") |> render_click()
      view |> element("button", "Proceed") |> render_click()

      html = render_async(view)
      assert html =~ "Sync complete. Inevitable."

      reloaded_item = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      refute is_nil(reloaded_item.last_balance_synced_at)
    end

    test "shows error flash when async refresh fails", %{conn: conn} do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)
      account = BankingFixtures.create_account!(plaid_item)
      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:error, %Plaid.Error{error_code: "ITEM_LOGIN_REQUIRED"}}
      end)

      {:ok, view, _html} = conn |> log_in_user(user) |> live_account(account.id)

      view |> element("button", "Refresh Balance") |> render_click()

      html = render_async(view)
      assert html =~ "We have a... discrepancy. The real-time balance fetch failed."
      refute html =~ "pc-button--disabled"
    end

    # Regression test: the async error handler used to flash the same generic
    # string for every failure cause. It now surfaces the Ash-level message
    # via AshErrorHTML.format_for_user/1, so a partial persistence failure
    # must read differently from a plain Plaid API failure (asserted above).
    test "shows a distinct flash for a partial balance persistence failure", %{conn: conn} do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)

      account =
        BankingFixtures.create_account!(plaid_item, %{plaid_account_id: "acc_live_partial_ok"})

      account_fail =
        BankingFixtures.create_account!(plaid_item, %{
          plaid_account_id: "acc_live_partial_fail"
        })

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        # Destroying inside the mock (rather than before it) is deliberate:
        # BalanceRefresh.run/1 builds its account_lookup from the accounts
        # already loaded on the PlaidItem *before* calling Plaid, so this
        # simulates the account disappearing mid-flight (a genuine matched
        # update failure) rather than "unknown account" (which would be
        # silently skipped, not counted as a failure).
        Ash.destroy!(account_fail, authorize?: false)

        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_live_partial_ok",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 100.0,
                 available: nil,
                 limit: nil
               }
             },
             %Plaid.Accounts.Account{
               account_id: "acc_live_partial_fail",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 200.0,
                 available: nil,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_live_partial"
         }}
      end)

      {:ok, view, _html} = conn |> log_in_user(user) |> live_account(account.id)

      view |> element("button", "Refresh Balance") |> render_click()

      html = render_async(view)
      assert html =~ "We have a... discrepancy. Some balances could not be persisted."
      refute html =~ "The real-time balance fetch failed."
    end
  end
end
