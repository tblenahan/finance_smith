defmodule FinanceSmithWeb.Plugs.RequireMfaVerified do
  @moduledoc """
  Ensures :current_user is set (full auth). If user has MFA enabled but only
  mfa_pending_user_id is in session, redirects to /users/mfa.
  """
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Credentials accepted. Identity unverified.")
      |> redirect(to: "/users/mfa")
      |> halt()
    end
  end
end
