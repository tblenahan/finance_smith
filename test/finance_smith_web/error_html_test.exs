defmodule FinanceSmithWeb.ErrorHTMLTest do
  use ExUnit.Case, async: true

  alias FinanceSmithWeb.ErrorHTML

  describe "render/2 — 404" do
    test "returns HTML containing the 404 status label" do
      html = Phoenix.Template.render_to_string(ErrorHTML, "404", "html", %{})
      assert html =~ "404"
    end

    test "contains Agent Smith empty-state copy" do
      html = Phoenix.Template.render_to_string(ErrorHTML, "404", "html", %{})
      assert html =~ "anomaly"
    end

    test "does not expose exception or message placeholders" do
      html = Phoenix.Template.render_to_string(ErrorHTML, "404", "html", %{})
      refute html =~ "@exception"
      refute html =~ "exception.message"
    end

    test "includes a home link" do
      html = Phoenix.Template.render_to_string(ErrorHTML, "404", "html", %{})
      assert html =~ ~s(href="/")
    end
  end

  describe "render/2 — 500" do
    test "returns HTML containing the 500 status label" do
      html = Phoenix.Template.render_to_string(ErrorHTML, "500", "html", %{})
      assert html =~ "500"
    end

    test "contains Agent Smith error copy" do
      html = Phoenix.Template.render_to_string(ErrorHTML, "500", "html", %{})
      assert html =~ "discrepancy"
    end

    test "does not expose exception or message placeholders" do
      html = Phoenix.Template.render_to_string(ErrorHTML, "500", "html", %{})
      refute html =~ "@exception"
      refute html =~ "exception.message"
    end

    test "does not claim the system was notified" do
      html = Phoenix.Template.render_to_string(ErrorHTML, "500", "html", %{})
      refute html =~ "notified"
    end

    test "includes a home link" do
      html = Phoenix.Template.render_to_string(ErrorHTML, "500", "html", %{})
      assert html =~ ~s(href="/")
    end
  end

  describe "render/2 — catch-all" do
    test "returns plain status text for unknown status codes" do
      result = ErrorHTML.render("418.html", %{})
      assert result == "I'm a teapot"
    end
  end
end
