defmodule FinanceSmithWeb.UserSessionController do
  use FinanceSmithWeb, :controller

  def create(conn, %{"token" => token}) do
    case Phoenix.Token.verify(
           FinanceSmithWeb.Endpoint,
           "user session",
           token,
           max_age: 300
         ) do
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

      _ ->
        conn
        |> put_flash(:error, "Invalid or expired link.")
        |> redirect(to: "/users/log_in")
    end
  end
end
