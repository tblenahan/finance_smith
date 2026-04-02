defmodule FinanceSmithWeb.Plugs.RequireMfaPending do
  @moduledoc """
  Ensures :mfa_pending_user is set (password verified, MFA not yet).
  Used only for /users/mfa. Redirects to login or dashboard otherwise.
  """
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:mfa_pending_user] do
      conn
    else
      redirect_to =
        if conn.assigns[:current_user] do
          "/dashboard"
        else
          "/users/log_in"
        end

      conn
      |> put_flash(:info, "Log in first.")
      |> redirect(to: redirect_to)
      |> halt()
    end
  end
end
