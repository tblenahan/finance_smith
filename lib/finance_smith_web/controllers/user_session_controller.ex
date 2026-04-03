defmodule FinanceSmithWeb.UserSessionController do
  use FinanceSmithWeb, :controller

  def create(conn, %{"token" => token}) when is_binary(token) do
    case Phoenix.Token.verify(
           FinanceSmithWeb.Endpoint,
           "user session",
           token,
           max_age: 300
         ) do
      # Token from UserLoginLive — mfa_enabled indicates whether MFA step is needed.
      {:ok, %{user_id: user_id, mfa_enabled: mfa_enabled}} ->
        if mfa_enabled do
          conn
          |> put_session(:mfa_pending_user_id, user_id)
          |> delete_session(:user_id)
          |> put_flash(:info, "Credentials accepted. Identity unverified.")
          |> redirect(to: "/users/mfa")
        else
          conn
          |> put_session(:user_id, user_id)
          |> delete_session(:mfa_pending_user_id)
          |> put_flash(:info, "Sync complete. Inevitable.")
          |> redirect(to: "/dashboard")
        end

      # Token from MfaVerifyLive — mfa_verified means full auth is complete.
      {:ok, %{user_id: user_id, mfa_verified: true}} ->
        conn
        |> put_session(:user_id, user_id)
        |> delete_session(:mfa_pending_user_id)
        |> put_flash(:info, "Sync complete. Inevitable.")
        |> redirect(to: "/dashboard")

      _ ->
        conn
        |> put_flash(:error, "Invalid or expired link.")
        |> redirect(to: "/users/log_in")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Invalid or expired link.")
    |> redirect(to: "/users/log_in")
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Disconnected.")
    |> redirect(to: "/users/log_in")
  end
end
