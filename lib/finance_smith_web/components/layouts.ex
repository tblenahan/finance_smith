defmodule FinanceSmithWeb.Layouts do
  use FinanceSmithWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="dark bg-gray-950 text-gray-100">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>Finance Smith</title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css" <> static_asset_query()} />
        <script src="https://cdn.plaid.com/link/v2/stable/link-initialize.js"></script>
        <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js" <> static_asset_query()}></script>
      </head>
      <body class="antialiased font-sans selection:bg-emerald-500/30">
        <%= @inner_content %>
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950">
      <%= if assigns[:current_user] || assigns[:mfa_pending_user] do %>
        <nav class="sticky top-0 z-50 border-b border-gray-800 bg-black/80 backdrop-blur-md">
          <.container max_width="xl">
            <div class="flex h-12 items-center justify-between">
              <div class="flex items-center gap-6">
                <span class="font-mono text-sm text-gray-300">Finance <span class="text-emerald-500">Smith</span></span>
                <%= if assigns[:current_user] do %>
                  <.link
                    navigate={~p"/dashboard"}
                    class={["rounded px-2 py-1 font-mono text-sm transition-colors", (assigns[:current_nav] == :dashboard && "text-emerald-400") || "text-gray-300 hover:text-emerald-400"]}
                  >
                    The Ledger
                  </.link>
                  <.link
                    navigate={~p"/users/settings"}
                    class={["rounded px-2 py-1 font-mono text-sm transition-colors", (assigns[:current_nav] == :settings && "text-emerald-400") || "text-gray-500 hover:text-emerald-400"]}
                  >
                    System Parameters
                  </.link>
                <% end %>
              </div>
              <div class="flex items-center gap-3">
                <span class="text-xs text-gray-600 font-mono hidden sm:block">
                  <%= user_email(assigns) %>
                </span>
                <.link href={~p"/users/log_out"} method="delete">
                  <.button size="xs" color="gray" variant="outline" class="border-gray-800 hover:border-gray-600 hover:text-gray-100">
                    Disconnect
                  </.button>
                </.link>
              </div>
            </div>
          </.container>
        </nav>
      <% end %>
      <main>
        <.container max_width="xl" class="py-8">
          <.flash_group flash={@flash} />
          <%= @inner_content %>
        </.container>
      </main>
    </div>
    """
  end

  defp static_asset_query do
    if Mix.env() == :dev do
      path = Application.app_dir(:finance_smith, "priv/static/assets/app.css")

      case File.stat(path) do
        {:ok, %{mtime: mtime}} ->
          "?t=#{:calendar.datetime_to_gregorian_seconds(mtime)}"

        _ ->
          ""
      end
    else
      ""
    end
  end

  defp user_email(assigns) do
    cond do
      assigns[:current_user] -> assigns.current_user.email
      assigns[:mfa_pending_user] -> assigns.mfa_pending_user.email
      true -> ""
    end
  end
end
