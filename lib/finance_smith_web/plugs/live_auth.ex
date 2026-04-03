defmodule FinanceSmithWeb.Plugs.LiveAuth do
  @moduledoc """
  On-mount hooks that assign :current_user or :mfa_pending_user from session,
  and also set :actor on the socket for use with Ash authorization.
  """
  import Phoenix.Component, only: [assign: 2]

  def on_mount(:default, _params, session, socket) do
    user = get_user_from_session(session)

    {:cont,
     socket
     |> assign(current_user: user)
     |> assign(actor: user)}
  end

  def on_mount(:mfa_pending, _params, session, socket) do
    user = get_mfa_pending_user_from_session(session)
    {:cont, assign(socket, mfa_pending_user: user)}
  end

  def get_mfa_pending_user_from_session(session) when is_map(session) do
    user_id = session["mfa_pending_user_id"] || session[:mfa_pending_user_id]
    get_user_by_id(user_id)
  end

  def get_user_from_session(session) when is_map(session) do
    user_id = session["user_id"] || session[:user_id]
    get_user_by_id(user_id)
  end

  defp get_user_by_id(user_id) when is_binary(user_id) do
    FinanceSmith.Identity.User
    |> Ash.get(user_id, authorize?: false)
    |> case do
      {:ok, user} -> Ash.load!(user, :household)
      _ -> nil
    end
  end

  defp get_user_by_id(_), do: nil
end
