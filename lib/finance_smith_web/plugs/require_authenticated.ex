defmodule FinanceSmithWeb.Plugs.RequireAuthenticated do
  @moduledoc """
  Ensures either :current_user (full auth) or :mfa_pending_user is present.
  Used for routes that require the user to have at least passed password auth.
  """
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_user] || conn.assigns[:mfa_pending_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> redirect(to: "/users/log_in")
      |> halt()
    end
  end
end
