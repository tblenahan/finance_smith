defmodule FinanceSmithWeb.DashboardLiveTest do
  use FinanceSmithWeb.ConnCase, async: false
  use Oban.Testing, repo: FinanceSmith.Repo

  import Phoenix.LiveViewTest
  import Mox

  alias FinanceSmith.Banking.PlaidItem
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
end
