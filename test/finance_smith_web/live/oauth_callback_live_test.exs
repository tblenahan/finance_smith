defmodule FinanceSmithWeb.OAuthCallbackLiveTest do
  use FinanceSmithWeb.ConnCase, async: false
  use Oban.Testing, repo: FinanceSmith.Repo, prefix: "machine"

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

  defp live_oauth(conn, query_string \\ "oauth_state_id=test-state-123") do
    live(conn, "/oauth/callback/plaid?" <> query_string)
  end

  describe "mount" do
    test "redirects unauthenticated requests to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} =
               live(conn, "/oauth/callback/plaid?oauth_state_id=x")
    end

    test "redirects to dashboard when oauth_state_id is missing", %{conn: conn} do
      user = register_user!()

      stub(FinanceSmith.Banking.MockPlaid, :create_link_token, fn _ ->
        flunk("create_link_token should not run without oauth_state_id")
      end)

      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               conn |> log_in_user(user) |> live("/oauth/callback/plaid")
    end

    test "redirects to dashboard when oauth_state_id is empty", %{conn: conn} do
      user = register_user!()

      stub(FinanceSmith.Banking.MockPlaid, :create_link_token, fn _ ->
        flunk("create_link_token should not run with empty oauth_state_id")
      end)

      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               conn |> log_in_user(user) |> live("/oauth/callback/plaid?oauth_state_id=")
    end

    test "redirects to dashboard when Plaid link token creation fails", %{conn: conn} do
      user = register_user!()

      stub(FinanceSmith.Banking.MockPlaid, :create_link_token, fn _ ->
        {:error, :timeout}
      end)

      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               conn |> log_in_user(user) |> live_oauth()
    end

    test "renders Plaid hook container with link token and redirect URI", %{conn: conn} do
      user = register_user!()

      stub(FinanceSmith.Banking.MockPlaid, :create_link_token, fn params ->
        assert params.client_name == "Finance Smith"
        assert params.redirect_uri =~ "/oauth/callback/plaid"
        assert params.user.client_user_id == user.id
        {:ok, %{link_token: "link-sandbox-test-token"}}
      end)

      {:ok, _view, html} =
        conn |> log_in_user(user) |> live_oauth("oauth_state_id=state-abc")

      assert html =~ "id=\"plaid-link-container\""
      assert html =~ "data-link-token=\"link-sandbox-test-token\""
      assert html =~ "data-received-redirect-uri="
      assert html =~ "state-abc"
      assert html =~ "Completing Connection"
    end
  end

  describe "plaid_link_error" do
    setup %{conn: conn} do
      user = register_user!()

      stub(FinanceSmith.Banking.MockPlaid, :create_link_token, fn _ ->
        {:ok, %{link_token: "link-for-error-tests"}}
      end)

      {:ok, view, _html} = conn |> log_in_user(user) |> live_oauth()
      %{view: view, user: user}
    end

    test "renders error UI when error_code is present", %{view: view} do
      html =
        render_hook(view, "plaid_link_error", %{
          "error_type" => "OAUTH",
          "error_code" => "OAUTH_ERROR",
          "error_message" => "oauth handshake failed",
          "display_message" => "failed",
          "request_id" => "req_oauth_123",
          "institution_id" => "ins_123",
          "institution_name" => "American Express",
          "link_session_id" => "session_123",
          "link_status" => "requires_credentials"
        })

      assert html =~ "We have a... discrepancy."
      assert html =~ "Return to The Ledger"
    end

    test "logs structured metadata on plaid_link_error", %{view: view, user: user} do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          render_hook(view, "plaid_link_error", %{
            "error_type" => "INSTITUTION_ERROR",
            "error_code" => "INSTITUTION_REGISTRATION_REQUIRED",
            "request_id" => "req_oauth_log",
            "institution_name" => "American Express"
          })
        end)

      assert log =~ "[OAuthCallbackLive] Plaid Link exited"
      assert log =~ user.id
      assert log =~ "INSTITUTION_REGISTRATION_REQUIRED"
    end

    test "renders error UI when params are empty", %{view: view} do
      html = render_hook(view, "plaid_link_error", %{})

      assert html =~ "We have a... discrepancy."
      assert html =~ "Return to The Ledger"
    end
  end

  describe "plaid_link_success" do
    setup %{conn: conn} do
      user = register_user!()

      stub(FinanceSmith.Banking.MockPlaid, :create_link_token, fn _ ->
        {:ok, %{link_token: "link-for-success-tests"}}
      end)

      {:ok, view, _html} = conn |> log_in_user(user) |> live_oauth()
      %{view: view, user: user}
    end

    test "renders error state when institution_name is missing", %{view: view} do
      html = render_hook(view, "plaid_link_success", %{"public_token" => "public-only"})

      assert html =~ "We have a... discrepancy."
      assert html =~ "The connection could not be completed."
    end

    test "redirects to dashboard on successful token exchange", %{
      view: view,
      user: user
    } do
      item_id = "item_lv_#{System.unique_integer([:positive])}"
      access = "access-lv-#{System.unique_integer([:positive])}"

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
                 "institution_name" => "OAuth Test Bank"
               })

      plaid_item =
        PlaidItem
        |> Ash.Query.filter(plaid_item_id == ^item_id)
        |> Ash.read_one!(authorize?: false)

      assert plaid_item.user_id == user.id
      assert plaid_item.institution_name == "OAuth Test Bank"

      assert_enqueued(
        worker: FinanceSmith.DataLake.SyncWorker,
        args: %{"plaid_item_id" => plaid_item.id}
      )
    end

    test "renders error UI when Plaid exchange fails", %{view: view} do
      expect(FinanceSmith.Banking.MockPlaid, :exchange_public_token, fn _ ->
        {:error, %Plaid.Error{error_code: "INVALID_INPUT"}}
      end)

      html =
        render_hook(view, "plaid_link_success", %{
          "public_token" => "public-bad",
          "institution_name" => "X"
        })

      assert html =~ "We have a... discrepancy."
      assert html =~ "Return to The Ledger"
    end
  end
end
