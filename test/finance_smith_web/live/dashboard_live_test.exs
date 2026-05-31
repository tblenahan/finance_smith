defmodule FinanceSmithWeb.DashboardLiveTest do
  use FinanceSmithWeb.ConnCase, async: false
  use Oban.Testing, repo: FinanceSmith.Repo, prefix: "machine"

  import Phoenix.LiveViewTest
  import Mox

  alias FinanceSmith.Banking.{MetaCategory, PlaidItem, Transaction}
  alias FinanceSmith.BankingFixtures
  alias FinanceSmith.Identity
  alias FinanceSmith.Test.PlaidTestHelpers

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

  defp live_dashboard(conn) do
    live(conn, "/dashboard")
  end

  defp create_meta_category!(household_id, name) do
    MetaCategory
    |> Ash.Changeset.for_create(:create_system, %{name: name, household_id: household_id})
    |> Ash.create!(authorize?: false)
  end

  defp create_chart_transaction!(account, attrs) do
    unique = System.unique_integer([:positive])

    attrs =
      %{
        plaid_transaction_id: "chart-txn-#{unique}",
        amount: attrs.amount,
        date: Map.get(attrs, :date, Date.utc_today()),
        merchant_name: Map.get(attrs, :merchant_name, "Chart Merchant"),
        account_id: account.id,
        is_pending: false
      }
      |> maybe_put(:meta_category_id, Map.get(attrs, :meta_category_id))

    Transaction
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  describe "mount" do
    test "redirects unauthenticated requests to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, "/dashboard")
    end

    test "renders Plaid hook and connect control for authenticated user", %{conn: conn} do
      user = register_user!()

      {:ok, _view, html} = conn |> log_in_user(user) |> live_dashboard()

      assert html =~ ~s(id="plaid-link-hook")
      assert html =~ ~s(phx-hook="PlaidLink")
      assert html =~ ~s(phx-click="request_link_token")
      assert html =~ "+ Add Integration"
    end

    test "does not request a link token on mount", %{conn: conn} do
      user = register_user!()

      stub(FinanceSmith.Banking.MockPlaid, :create_link_token, fn _ ->
        flunk("create_link_token must not run on mount")
      end)

      assert {:ok, _view, _html} = conn |> log_in_user(user) |> live_dashboard()
    end
  end

  describe "request_link_token" do
    test "calls Plaid with redirect_uri and pushes open_plaid_link to the client", %{conn: conn} do
      user = register_user!()

      expect(FinanceSmith.Banking.MockPlaid, :create_link_token, fn params ->
        assert params.client_name == "Finance Smith"
        assert params.redirect_uri =~ "/oauth/callback/plaid"
        assert params.user.client_user_id == user.id
        {:ok, %{link_token: "link-dash-test"}}
      end)

      {:ok, view, _html} = conn |> log_in_user(user) |> live_dashboard()

      render_click(view, "request_link_token", %{})

      assert_push_event(view, "open_plaid_link", %{link_token: "link-dash-test"})
    end

    test "shows error flash when link token creation fails", %{conn: conn} do
      user = register_user!()

      stub(FinanceSmith.Banking.MockPlaid, :create_link_token, fn _ ->
        {:error, :timeout}
      end)

      {:ok, view, _html} = conn |> log_in_user(user) |> live_dashboard()

      html = render_click(view, "request_link_token", %{})

      assert html =~ "Could not reach the data broker"
    end
  end

  describe "plaid_link_success" do
    setup %{conn: conn} do
      user = register_user!()
      {:ok, view, _html} = conn |> log_in_user(user) |> live_dashboard()
      %{view: view, user: user}
    end

    test "puts flash when institution_name is missing", %{view: view} do
      html = render_hook(view, "plaid_link_success", %{"public_token" => "public-only"})

      assert html =~ "Incomplete handshake data received"
    end

    test "redirects to dashboard on successful token exchange", %{view: view, user: user} do
      item_id = "item_dash_#{System.unique_integer([:positive])}"
      access = "access-dash-#{System.unique_integer([:positive])}"

      expect(FinanceSmith.Banking.MockPlaid, :exchange_public_token, fn %{
                                                                          public_token:
                                                                            "public-ok"
                                                                        } ->
        {:ok, %{access_token: access, item_id: item_id, request_id: "r1"}}
      end)

      expect(FinanceSmith.Banking.MockPlaid, :get_accounts, fn %{access_token: ^access} ->
        {:ok, PlaidTestHelpers.mock_accounts_response()}
      end)

      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               render_hook(view, "plaid_link_success", %{
                 "public_token" => "public-ok",
                 "institution_name" => "Dashboard Test Bank"
               })

      plaid_item =
        PlaidItem
        |> Ash.Query.filter(plaid_item_id == ^item_id)
        |> Ash.read_one!(authorize?: false)

      assert plaid_item.user_id == user.id
      assert plaid_item.institution_name == "Dashboard Test Bank"

      assert_enqueued(
        worker: FinanceSmith.DataLake.SyncWorker,
        args: %{"plaid_item_id" => plaid_item.id}
      )
    end

    test "shows error flash when Plaid exchange fails", %{view: view} do
      expect(FinanceSmith.Banking.MockPlaid, :exchange_public_token, fn _ ->
        {:error, %Plaid.Error{error_code: "INVALID_INPUT"}}
      end)

      html =
        render_hook(view, "plaid_link_success", %{
          "public_token" => "public-bad",
          "institution_name" => "X"
        })

      assert html =~ "The connection could not be established"
    end
  end

  describe "transaction table pagination" do
    # Seeds 30 transactions (more than the default page size of 25) and verifies
    # that the Next/Previous links carry distinct per-record keyset cursors rather
    # than the stale request cursors stored on the page struct.
    test "Next link advances to page 2 with distinct rows, Previous returns to page 1", %{
      conn: conn
    } do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)
      account = BankingFixtures.create_account!(plaid_item)

      # Spread across 30 distinct past dates so the default sort is stable and
      # rows fall outside the 30-day default window — we clear the filter below.
      for i <- 1..30 do
        BankingFixtures.create_transaction!(account, %{
          date: Date.add(Date.utc_today(), -(i + 30)),
          amount: i * 100,
          merchant_name: "Merchant #{i}"
        })
      end

      # Clear the date filter so all 30 rows are visible.
      base_conn = log_in_user(conn, user)

      {:ok, view, html} = live(base_conn, "/dashboard?date_from=2000-01-01")

      # Page 1: verify we got 25 rows and a working Next link.
      assert html =~ "Merchant"

      next_href =
        Regex.run(~r/href="([^"]*after=[^"]*)"[^>]*>[\s\S]*?Next/, html)
        |> case do
          [_, href] -> String.replace(href, "&amp;", "&")
          _ -> nil
        end

      assert is_binary(next_href),
             "Expected a Next link with an `after=` cursor on page 1."

      # Count page 1 rows via the tr count in tbody.
      page1_row_count = length(Regex.scan(~r/<tr[^>]*class="hover:bg-gray-900/, html))
      assert page1_row_count == 25, "Expected 25 rows on page 1, got #{page1_row_count}"

      # Navigate to page 2 via the keyset cursor.
      {:ok, _view2, html2} = live(base_conn, next_href)

      page2_row_count = length(Regex.scan(~r/<tr[^>]*class="hover:bg-gray-900/, html2))
      assert page2_row_count == 5, "Expected 5 remaining rows on page 2, got #{page2_row_count}"

      # Page 2 rows must not overlap with page 1 rows.
      page1_merchants = Regex.scan(~r/Merchant \d+/, html) |> List.flatten() |> MapSet.new()
      page2_merchants = Regex.scan(~r/Merchant \d+/, html2) |> List.flatten() |> MapSet.new()

      overlap = MapSet.intersection(page1_merchants, page2_merchants)

      assert MapSet.size(overlap) == 0,
             "Pages 1 and 2 must not share rows. Overlap: #{inspect(overlap)}"

      # Page 2 must expose a Previous link with a `before=` cursor.
      prev_href =
        Regex.run(~r/href="([^"]*before=[^"]*)"[^>]*>[\s\S]*?Previous/, html2)
        |> case do
          [_, href] -> String.replace(href, "&amp;", "&")
          _ -> nil
        end

      assert is_binary(prev_href),
             "Expected a Previous link with a `before=` cursor on page 2"

      # Following Previous must return a full page of 25 rows.
      {:ok, _view3, html3} = live(base_conn, prev_href)

      page1_return_row_count = length(Regex.scan(~r/<tr[^>]*class="hover:bg-gray-900/, html3))

      assert page1_return_row_count == 25,
             "Following Previous from page 2 must return 25 rows, got #{page1_return_row_count}"

      _ = view
    end
  end

  describe "chart data" do
    test "cashflow line chart hides symbols on zero days but keeps line continuity", %{
      conn: conn
    } do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)
      account = BankingFixtures.create_account!(plaid_item)

      create_chart_transaction!(account, %{
        amount: 5000,
        date: Date.utc_today(),
        merchant_name: "Today Outflow"
      })

      create_chart_transaction!(account, %{
        amount: -3000,
        date: Date.add(Date.utc_today(), -1),
        merchant_name: "Yesterday Inflow"
      })

      {:ok, view, _html} = conn |> log_in_user(user) |> live_dashboard()

      assert_push_event(view, "update-chart-cashflow-line-chart", %{
        series: [%{data: inflow_data}, %{data: outflow_data}]
      })

      hidden = %{value: 0.0, symbol: "none", symbolSize: 0}

      assert Enum.count(inflow_data, &(&1 == hidden)) == length(inflow_data) - 1
      assert Enum.count(outflow_data, &(&1 == hidden)) == length(outflow_data) - 1
      assert 30.0 in inflow_data
      assert 50.0 in outflow_data
    end

    test "outflow pie chart separates named, uncategorized, and no-category transactions", %{
      conn: conn
    } do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)
      account = BankingFixtures.create_account!(plaid_item)

      groceries = create_meta_category!(user.household_id, "Groceries")
      uncategorized = create_meta_category!(user.household_id, "Uncategorized")

      create_chart_transaction!(account, %{
        amount: 4200,
        merchant_name: "Market",
        meta_category_id: groceries.id
      })

      create_chart_transaction!(account, %{
        amount: 2100,
        merchant_name: "Mystery Merchant",
        meta_category_id: uncategorized.id
      })

      create_chart_transaction!(account, %{
        amount: 900,
        merchant_name: "No Token"
      })

      {:ok, view, _html} = conn |> log_in_user(user) |> live_dashboard()

      assert_push_event(view, "update-chart-outflow-pie-chart", %{
        series: [%{data: pie_data}]
      })

      values_by_name = Map.new(pie_data, &{&1.name, &1.value})

      assert values_by_name["Groceries"] == 42.0
      assert values_by_name["Uncategorized"] == 21.0
      assert values_by_name["—"] == 9.0
    end
  end

  describe "plaid_link_error" do
    setup %{conn: conn} do
      user = register_user!()
      {:ok, view, _html} = conn |> log_in_user(user) |> live_dashboard()
      %{view: view}
    end

    test "shows error flash when error_code is present", %{view: view} do
      html =
        render_hook(view, "plaid_link_error", %{
          "error_type" => "OAUTH",
          "error_code" => "OAUTH_ERROR",
          "display_message" => "failed"
        })

      assert html =~ "The link was not completed"
    end
  end

  describe "transaction:updated broadcast" do
    test "refreshes view to show resolved transaction without a duplicate", %{conn: conn} do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)
      account = BankingFixtures.create_account!(plaid_item)

      pending_id = "pending-lv-#{System.unique_integer([:positive])}"
      posted_id = "posted-lv-#{System.unique_integer([:positive])}"

      pending_txn =
        BankingFixtures.create_transaction!(account, %{
          plaid_transaction_id: pending_id,
          is_pending: true,
          merchant_name: "Pending Coffee",
          date: Date.utc_today(),
          amount: 450
        })

      # Clear date filter so the transaction is visible.
      {:ok, view, html} = conn |> log_in_user(user) |> live("/dashboard?date_from=2000-01-01")

      assert html =~ "Pending Coffee"
      assert html =~ "pending"

      # Resolve the transaction in the DB (as the processor would), then broadcast.
      resolved_txn =
        pending_txn
        |> Ash.Changeset.for_update(:resolve_pending, %{
          plaid_transaction_id: posted_id,
          amount: 450,
          date: Date.utc_today(),
          pending_transaction_id: pending_id
        })
        |> Ash.update!(authorize?: false)

      notification = %Ash.Notifier.Notification{
        resource: FinanceSmith.Banking.Transaction,
        action: %{name: :resolve_pending},
        data: resolved_txn
      }

      send(view.pid, %{topic: "transaction:updated", payload: notification})

      html = render(view)

      # The posted row is still rendered.
      assert html =~ "Pending Coffee"

      # The "pending" badge is gone.
      pending_badge_count =
        html
        |> String.split("Pending Coffee")
        |> Enum.drop(1)
        |> List.first("")
        |> then(&Regex.scan(~r/pending/, &1))
        |> length()

      assert pending_badge_count == 0,
             "Expected no 'pending' badge after resolve, but found one"

      # Exactly one row for this merchant — no duplicate.
      row_count = length(Regex.scan(~r/Pending Coffee/, html))
      assert row_count == 1, "Expected exactly 1 row for 'Pending Coffee', got #{row_count}"
    end
  end
end
