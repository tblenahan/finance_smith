defmodule FinanceSmithWeb.UserSessionControllerTest do
  use FinanceSmithWeb.ConnCase, async: true

  alias FinanceSmith.Identity

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp create_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  defp sign_token(payload) do
    Phoenix.Token.sign(FinanceSmithWeb.Endpoint, "user session", payload)
  end

  # Signs a token backdated 400s so it fails the controller's 300s max_age check.
  defp expired_token(user_id) do
    Phoenix.Token.sign(
      FinanceSmithWeb.Endpoint,
      "user session",
      %{user_id: user_id, mfa_enabled: false},
      signed_at: System.system_time(:second) - 400
    )
  end

  # ---------------------------------------------------------------------------
  # Non-MFA user flow
  # ---------------------------------------------------------------------------

  describe "GET /users/session (non-MFA user)" do
    test "sets user_id in session and redirects to /dashboard", %{conn: conn} do
      user = create_user!()
      token = sign_token(%{user_id: user.id, mfa_enabled: false})

      conn = get(conn, "/users/session?token=#{token}")

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :user_id) == user.id
      assert get_session(conn, :mfa_pending_user_id) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # MFA user flow
  # ---------------------------------------------------------------------------

  describe "GET /users/session (MFA-enabled user)" do
    test "sets mfa_pending_user_id in session and redirects to /users/mfa", %{conn: conn} do
      user = create_user!()
      token = sign_token(%{user_id: user.id, mfa_enabled: true})

      conn = get(conn, "/users/session?token=#{token}")

      assert redirected_to(conn) == "/users/mfa"
      assert get_session(conn, :mfa_pending_user_id) == user.id
      assert get_session(conn, :user_id) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Invalid / expired token
  # ---------------------------------------------------------------------------

  describe "GET /users/session (bad token)" do
    test "redirects to /users/log_in for an invalid token", %{conn: conn} do
      conn = get(conn, "/users/session?token=totally_invalid_token")

      assert redirected_to(conn) == "/users/log_in"
    end

    test "redirects to /users/log_in for an expired token", %{conn: conn} do
      user = create_user!()
      token = expired_token(user.id)

      conn = get(conn, "/users/session?token=#{token}")

      assert redirected_to(conn) == "/users/log_in"
    end

    test "redirects to /users/log_in when token parameter is absent", %{conn: conn} do
      conn = get(conn, "/users/session")

      assert redirected_to(conn) == "/users/log_in"
    end
  end
end
