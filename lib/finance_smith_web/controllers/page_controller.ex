defmodule FinanceSmithWeb.PageController do
  use FinanceSmithWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: "/dashboard")
    else
      redirect(conn, to: "/users/log_in")
    end
  end
end
