defmodule FinanceSmithWeb.PlugsTest do
  use FinanceSmithWeb.ConnCase, async: true

  alias FinanceSmith.Identity
  alias FinanceSmithWeb.UserAuth
  alias FinanceSmithWeb.Plugs.RequireAuthenticated
  alias FinanceSmithWeb.Plugs.RequireMfaVerified
  alias FinanceSmithWeb.Plugs.RequireMfaPending

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp create_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # UserAuth plug
  # ---------------------------------------------------------------------------

  describe "UserAuth.fetch_current_user/2" do
    test "assigns current_user when user_id is in the session", %{conn: conn} do
      user = create_user!()

      conn =
        conn
        |> init_test_session(%{user_id: user.id})
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user.id == user.id
    end

    test "assigns mfa_pending_user when mfa_pending_user_id is in the session", %{conn: conn} do
      user = create_user!()

      conn =
        conn
        |> init_test_session(%{mfa_pending_user_id: user.id})
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
      assert conn.assigns.mfa_pending_user.id == user.id
    end

    test "assigns nil for both when no relevant session keys are present", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
      assert conn.assigns.mfa_pending_user == nil
    end

    test "assigns nil when session user_id refers to a non-existent user", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{user_id: "00000000-0000-0000-0000-000000000000"})
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
    end
  end

  # ---------------------------------------------------------------------------
  # RequireAuthenticated plug
  # ---------------------------------------------------------------------------

  describe "RequireAuthenticated.call/2" do
    test "passes through when current_user is assigned", %{conn: conn} do
      user = create_user!()

      conn =
        conn
        |> init_test_session(%{})
        |> fetch_flash()
        |> assign(:current_user, user)
        |> assign(:mfa_pending_user, nil)
        |> RequireAuthenticated.call([])

      refute conn.halted
    end

    test "passes through when mfa_pending_user is assigned", %{conn: conn} do
      user = create_user!()

      conn =
        conn
        |> init_test_session(%{})
        |> fetch_flash()
        |> assign(:current_user, nil)
        |> assign(:mfa_pending_user, user)
        |> RequireAuthenticated.call([])

      refute conn.halted
    end

    test "halts and redirects to /users/log_in when neither user is assigned", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_flash()
        |> assign(:current_user, nil)
        |> assign(:mfa_pending_user, nil)
        |> RequireAuthenticated.call([])

      assert conn.halted
      assert redirected_to(conn) == "/users/log_in"
    end
  end

  # ---------------------------------------------------------------------------
  # RequireMfaVerified plug
  # ---------------------------------------------------------------------------

  describe "RequireMfaVerified.call/2" do
    test "passes through when current_user is assigned", %{conn: conn} do
      user = create_user!()

      conn =
        conn
        |> init_test_session(%{})
        |> fetch_flash()
        |> assign(:current_user, user)
        |> RequireMfaVerified.call([])

      refute conn.halted
    end

    test "halts and redirects to /users/mfa when only mfa_pending_user is present", %{conn: conn} do
      user = create_user!()

      conn =
        conn
        |> init_test_session(%{})
        |> fetch_flash()
        |> assign(:current_user, nil)
        |> assign(:mfa_pending_user, user)
        |> RequireMfaVerified.call([])

      assert conn.halted
      assert redirected_to(conn) == "/users/mfa"
    end

    test "halts and redirects to /users/mfa when no user is assigned", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_flash()
        |> assign(:current_user, nil)
        |> RequireMfaVerified.call([])

      assert conn.halted
      assert redirected_to(conn) == "/users/mfa"
    end
  end

  # ---------------------------------------------------------------------------
  # RequireMfaPending plug
  # ---------------------------------------------------------------------------

  describe "RequireMfaPending.call/2" do
    test "passes through when mfa_pending_user is assigned", %{conn: conn} do
      user = create_user!()

      conn =
        conn
        |> init_test_session(%{})
        |> fetch_flash()
        |> assign(:current_user, nil)
        |> assign(:mfa_pending_user, user)
        |> RequireMfaPending.call([])

      refute conn.halted
    end

    test "redirects to /dashboard when current_user is already set", %{conn: conn} do
      user = create_user!()

      conn =
        conn
        |> init_test_session(%{})
        |> fetch_flash()
        |> assign(:current_user, user)
        |> assign(:mfa_pending_user, nil)
        |> RequireMfaPending.call([])

      assert conn.halted
      assert redirected_to(conn) == "/dashboard"
    end

    test "redirects to /users/log_in when neither user is present", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> fetch_flash()
        |> assign(:current_user, nil)
        |> assign(:mfa_pending_user, nil)
        |> RequireMfaPending.call([])

      assert conn.halted
      assert redirected_to(conn) == "/users/log_in"
    end
  end
end
