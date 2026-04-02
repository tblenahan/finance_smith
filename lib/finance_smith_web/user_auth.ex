defmodule FinanceSmithWeb.UserAuth do
  @moduledoc """
  Plug and helpers for user authentication and session handling.
  Supports two-stage session: full auth (user_id) or MFA-pending (mfa_pending_user_id).
  """
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, opts) do
    fetch_current_user(conn, opts)
  end

  @doc """
  Plug: loads the current user from the session if present.
  Assigns:
  - :current_user when fully authenticated (user_id in session)
  - :mfa_pending_user when credentials accepted but MFA not yet verified (mfa_pending_user_id in session)
  """
  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, :user_id)
    mfa_pending_id = get_session(conn, :mfa_pending_user_id)

    cond do
      user_id ->
        user =
          FinanceSmith.Identity.User
          |> Ash.get(user_id, authorize?: false)
          |> case do
            {:ok, u} -> Ash.load!(u, :household)
            _ -> nil
          end

        assign(conn, :current_user, user)

      mfa_pending_id ->
        user =
          FinanceSmith.Identity.User
          |> Ash.get(mfa_pending_id, authorize?: false)
          |> case do
            {:ok, u} -> u
            _ -> nil
          end

        conn
        |> assign(:current_user, nil)
        |> assign(:mfa_pending_user, user)

      true ->
        assign(conn, :current_user, nil) |> assign(:mfa_pending_user, nil)
    end
  end

  @doc """
  Callback for DELETE /users/log_out. Logs the user out and redirects.
  """
  def delete(conn, _opts) do
    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Disconnected.")
    |> redirect(to: "/")
  end

  def log_in_user(conn, user) do
    if user.mfa_enabled do
      conn
      |> put_session(:mfa_pending_user_id, user.id)
      |> delete_session(:user_id)
      |> put_flash(:info, "Credentials accepted. Identity unverified.")
      |> redirect(to: "/users/mfa")
    else
      conn
      |> put_session(:user_id, user.id)
      |> delete_session(:mfa_pending_user_id)
      |> put_flash(:info, "Sync complete. Inevitable.")
      |> redirect(to: "/dashboard")
    end
  end

  def verify_mfa_and_log_in(conn, user) do
    conn
    |> put_session(:user_id, user.id)
    |> delete_session(:mfa_pending_user_id)
    |> put_flash(:info, "Sync complete. Inevitable.")
    |> redirect(to: "/dashboard")
  end
end
