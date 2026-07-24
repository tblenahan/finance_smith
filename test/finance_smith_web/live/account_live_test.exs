defmodule FinanceSmithWeb.AccountLiveTest do
  use FinanceSmithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.{Account, BalanceRefresh, PlaidItem}
  alias FinanceSmith.BankingFixtures
  alias FinanceSmith.Identity
  alias FinanceSmithWeb.AccountLive

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

    # Regression test: request_balance_refresh used to have no guard against
    # a second click while balance_refresh_loading was already true. Since
    # Phoenix.LiveViewTest dispatches the click event directly (bypassing the
    # rendered `disabled` attribute), this reliably exercises the same
    # overlap a fast double-click or a cancelled/replaced async task could
    # cause. Mox's default `expect` (exactly once) fails the test if the
    # second click starts a second Plaid call.
    test "ignores a second refresh click while a refresh is already in flight", %{conn: conn} do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)

      account =
        BankingFixtures.create_account!(plaid_item, %{plaid_account_id: "acc_live_overlap"})

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:ok,
         %Plaid.Accounts{
           accounts: [
             %Plaid.Accounts.Account{
               account_id: "acc_live_overlap",
               balances: %Plaid.Accounts.Account.Balance{
                 current: 111.0,
                 available: nil,
                 limit: nil
               }
             }
           ],
           item: nil,
           request_id: "req_live_overlap"
         }}
      end)

      {:ok, view, _html} = conn |> log_in_user(user) |> live_account(account.id)

      view |> element("button", "Refresh Balance") |> render_click()

      # The rendered button is now `disabled`, which Phoenix.LiveViewTest's
      # element-based render_click/1 itself refuses to click — dispatching the
      # event directly instead simulates a stale/replayed client event (or a
      # race between two rapid clicks before the disabled attribute reaches
      # the DOM) landing on the server while still loading.
      render_click(view, "request_balance_refresh", %{})

      html = render_async(view)
      assert html =~ "Sync complete. Inevitable."

      updated = Ash.get!(Account, account.id, authorize?: false)
      assert updated.current_balance == 11_100
    end

    # Regression test: confirm_balance_refresh used to run unconditionally,
    # so a stray or replayed "confirm_balance_refresh" event (without the
    # cost advisory ever being shown) would bypass the advisory and force a
    # paid refresh. No Plaid mock is stubbed here, so Mox would raise if the
    # event incorrectly triggered a call.
    test "confirm_balance_refresh is a no-op when the cost advisory is not shown", %{conn: conn} do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)

      account =
        BankingFixtures.create_account!(plaid_item, %{plaid_account_id: "acc_live_confirm_noop"})

      {:ok, view, _html} = conn |> log_in_user(user) |> live_account(account.id)

      html = render_click(view, "confirm_balance_refresh", %{})

      refute html =~ "Cost advisory"

      reloaded_item = Ash.get!(PlaidItem, plaid_item.id, authorize?: false)
      assert is_nil(reloaded_item.last_balance_synced_at)
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

    # Regression test for review finding: request_balance_refresh used to
    # decide freshness from the socket's own (potentially stale) plaid_item
    # assign. If a concurrent refresh (a background SyncWorker run, another
    # tab, or another request in flight) claims the 24h window *after* this
    # socket last loaded plaid_item but *before* the async
    # fetch_realtime_balances call's own claim runs, the async call
    # legitimately fails with :already_fresh even though this socket's own
    # click-time reload saw the item as stale. handle_async/3 must reload
    # plaid_item and, finding it now fresh, show the cost advisory instead
    # of flashing the "already fresh" error — otherwise every retry would
    # repeat the same rejected force: false request forever.
    #
    # The race itself isn't reproduced with real timing; instead the real
    # :already_fresh error is obtained directly (by claiming the window out
    # of band before calling fetch_realtime_balances/3) and fed into
    # handle_async/3 with a socket holding the stale pre-claim plaid_item,
    # exercising the exact reload-and-reclassify path deterministically.
    test "async :already_fresh error reloads plaid_item and shows the cost advisory instead of an error flash" do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)
      account = BankingFixtures.create_account!(plaid_item, %{plaid_account_id: "acc_live_race"})

      stale_plaid_item = Banking.get_plaid_item_summary_by_id!(plaid_item.id, actor: user)
      refute BalanceRefresh.fresh?(stale_plaid_item.last_balance_synced_at)

      assert {:claimed, _previous, _claimed_at} = BalanceRefresh.claim_paid_refresh(plaid_item.id)

      assert {:error, reason} =
               Banking.fetch_realtime_balances(plaid_item.id, %{force: false}, actor: user)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_user: user,
          account_id: account.id,
          account: account,
          plaid_item: stale_plaid_item,
          balance_refresh_loading: true,
          balance_refresh_force: false,
          show_balance_warning: false
        }
      }

      assert {:noreply, updated_socket} =
               AccountLive.handle_async(:balance_refresh, {:ok, {:error, reason}}, socket)

      assert updated_socket.assigns.show_balance_warning
      refute updated_socket.assigns.balance_refresh_loading
      refute updated_socket.assigns.balance_refresh_force
      assert BalanceRefresh.fresh?(updated_socket.assigns.plaid_item.last_balance_synced_at)
      refute Map.has_key?(updated_socket.assigns.flash, "error")
    end

    # Regression test for review finding: after a cost-advisory Proceed
    # (force: true), a Plaid failure restores the previous fresh stamp via
    # CAS. handle_async/3 must flash the real error — not reopen the
    # advisory — otherwise users loop on Proceed without seeing the failure.
    test "force: true Plaid failure flashes the error instead of reopening the cost advisory", %{
      conn: conn
    } do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)

      account =
        BankingFixtures.create_account!(plaid_item, %{plaid_account_id: "acc_live_force_fail"})

      token = Ash.load!(plaid_item, :access_token, authorize?: false).access_token

      _fresh_item =
        plaid_item
        |> Ash.Changeset.for_update(:update_balance_timestamp, %{}, authorize?: false)
        |> Ash.update!(authorize?: false)

      expect(FinanceSmith.Banking.MockPlaid, :get_balance, fn %{access_token: ^token} ->
        {:error, %Plaid.Error{error_code: "ITEM_LOGIN_REQUIRED"}}
      end)

      {:ok, view, _html} = conn |> log_in_user(user) |> live_account(account.id)

      view |> element("button", "Refresh Balance") |> render_click()
      view |> element("button", "Proceed") |> render_click()

      html = render_async(view)
      assert html =~ "We have a... discrepancy. The real-time balance fetch failed."
      refute html =~ "Cost advisory"
    end
  end
end
