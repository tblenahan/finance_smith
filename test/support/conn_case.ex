defmodule FinanceSmithWeb.ConnCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's web endpoints.

  It imports helpers from `Phoenix.ConnTest` and provides
  a utility to put a fully-authenticated user into the session.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest

      @endpoint FinanceSmithWeb.Endpoint

      import FinanceSmithWeb.ConnCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(FinanceSmith.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Puts a fully-authenticated user into the conn session.
  """
  def log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{user_id: user.id})
  end

  @doc """
  Puts an MFA-pending user into the conn session.
  """
  def put_mfa_pending(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{mfa_pending_user_id: user.id})
  end
end
