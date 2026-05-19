defmodule FinanceSmithWeb.ErrorPageTest do
  use FinanceSmithWeb.ConnCase, async: true

  describe "404 — unknown route" do
    test "returns 404 status for an unauthenticated request to an unknown path", %{conn: conn} do
      conn = get(conn, "/this-route-does-not-exist-at-all")
      assert conn.status == 404
    end

    test "404 response body includes Agent Smith copy", %{conn: conn} do
      conn = get(conn, "/this-route-does-not-exist-at-all")
      assert conn.status == 404
      assert response_content_type(conn, :html) =~ "text/html"
      body = response(conn, 404)
      assert body =~ "anomaly"
    end
  end
end
