defmodule FinanceSmithWeb.UserSettingsLive do
  use FinanceSmithWeb, :live_view

  def mount(_params, _session, socket) do
    mfa_enabled = socket.assigns[:current_user] && socket.assigns.current_user.mfa_enabled

    {:ok,
     socket
     |> assign(:page_title, "System Parameters")
     |> assign(:mfa_enabled, mfa_enabled)
     |> assign(:current_nav, :settings)}
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6 max-w-3xl">
      <div class="border-b border-gray-800 pb-4">
        <.h1 color_class="text-gray-100" no_margin>System Parameters</.h1>
        <.p class="text-sm text-gray-500 mt-1" no_margin>
          Configure your account. The ledger awaits your directives.
        </.p>
      </div>

      <.card variant="outline">
        <.card_content>
          <.h3 color_class="text-gray-100" no_margin>Security Protocols</.h3>
          <div class="mt-4 flex items-center justify-between border-t border-gray-800/50 pt-4">
            <div class="space-y-1">
              <div class="flex items-center gap-2">
                <p class="font-mono text-sm text-gray-300">Multi-Factor Authentication</p>
                <%= if @mfa_enabled do %>
                  <.badge color="success" variant="outline" size="sm" class="font-mono text-[10px] uppercase tracking-wider border-emerald-500/30 text-emerald-500">Enforced</.badge>
                <% else %>
                  <.badge color="gray" variant="outline" size="sm" class="font-mono text-[10px] uppercase tracking-wider border-gray-700 text-gray-500">Bypassed</.badge>
                <% end %>
              </div>
              <.p class="text-gray-500 text-xs" no_margin>
                <%= if @mfa_enabled do %>
                  Your identity is verified on each login. The system is secure.
                <% else %>
                  What good is a login if you cannot verify your identity?
                <% end %>
              </.p>
            </div>
            <.link navigate={~p"/users/settings/mfa"}>
              <.button variant="outline" color="gray" size="sm" class="font-mono text-xs border-gray-700 hover:border-gray-500 hover:text-gray-100">
                <%= if @mfa_enabled, do: "Reconfigure", else: "Enforce" %>
              </.button>
            </.link>
          </div>
        </.card_content>
      </.card>
    </div>
    """
  end
end
