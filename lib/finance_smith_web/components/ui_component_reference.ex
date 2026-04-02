defmodule FinanceSmithWeb.UIComponentReference do
  @moduledoc false
  use FinanceSmithWeb, :html
  import FinanceSmithWeb.CoreComponents

  # ---------------------------------------------------------------------------
  # Layouts — root
  # ---------------------------------------------------------------------------
  def root_layout(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="dark bg-gray-950 text-gray-100">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>Finance Smith</title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}></script>
      </head>
      <body class="antialiased font-sans selection:bg-emerald-500/30">
        <%= @inner_content %>
      </body>
    </html>
    """
  end

  # ---------------------------------------------------------------------------
  # Layouts — app (nav + main)
  # ---------------------------------------------------------------------------
  def app_layout(assigns) do
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
              <div class="flex items-center gap-4">
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

  defp user_email(assigns) do
    cond do
      assigns[:current_user] -> assigns.current_user.email
      assigns[:mfa_pending_user] -> assigns.mfa_pending_user.email
      true -> ""
    end
  end

  # ---------------------------------------------------------------------------
  # ErrorHTML
  # ---------------------------------------------------------------------------
  def error_html(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Error · Finance Smith</title>
      </head>
      <body class="bg-black text-gray-100 min-h-screen flex items-center justify-center">
        <main class="text-center max-w-md border border-gray-800 bg-gray-950 p-8 rounded-lg shadow-2xl">
          <h1 class="text-lg font-mono text-emerald-500">We have a... discrepancy.</h1>
          <p class="mt-4 text-sm text-gray-400 font-mono"><%= @exception.message %></p>
        </main>
      </body>
    </html>
    """
  end

  # ---------------------------------------------------------------------------
  # UserRegistrationLive
  # ---------------------------------------------------------------------------
  def user_registration(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm space-y-6 pt-16">
      <div class="text-center">
        <.h2 color_class="text-gray-100" no_margin>Initialize Identity</.h2>
        <.p class="mt-1 text-sm text-gray-500" no_margin>
          Join the system. Resistance is futile.
        </.p>
      </div>

      <.card variant="outline" class="bg-gray-950 border-gray-800">
        <.card_content>
          <.form
            for={%{}}
            as={:user}
            id="register_form"
            phx-submit="submit"
            phx-change="validate"
            class="space-y-4"
          >
            <.field
              type="email"
              name="user[email]"
              value={@email}
              label="Email"
              class="font-mono text-sm"
            />
            <.field
              type="password"
              name="user[password]"
              value={@password}
              label="Password"
            />
            <.alert :if={@error} color="danger" label={@error} class="text-xs font-mono" />
            <.button type="submit" class="w-full font-mono uppercase tracking-wider text-xs">
              Compile Record
            </.button>
          </.form>
        </.card_content>
      </.card>

      <p class="text-center text-xs font-mono text-gray-600">
        Already in the system?
        <.link href={~p"/users/log_in"} class="text-emerald-500 hover:text-emerald-400">
          Authenticate
        </.link>
      </p>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # UserLoginLive
  # ---------------------------------------------------------------------------
  def user_login(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm space-y-6 pt-16">
      <div class="text-center">
        <.h2 color_class="text-gray-100" no_margin>Authenticate</.h2>
        <.p class="mt-1 text-sm text-gray-500" no_margin>
          Provide your credentials. The system awaits.
        </.p>
      </div>

      <.card variant="outline" class="bg-gray-950 border-gray-800">
        <.card_content>
          <.form
            for={%{}}
            as={:user}
            id="login_form"
            phx-submit="submit"
            phx-change="validate"
            class="space-y-4"
          >
            <.field
              type="email"
              name="user[email]"
              value={@email}
              label="Email"
              class="font-mono text-sm"
            />
            <.field
              type="password"
              name="user[password]"
              value={@password}
              label="Password"
            />
            <.alert :if={@error} color="danger" label={@error} class="text-xs font-mono" />
            <.button type="submit" class="w-full font-mono uppercase tracking-wider text-xs">
              Establish Connection
            </.button>
          </.form>
        </.card_content>
      </.card>

      <p class="text-center text-xs font-mono text-gray-600">
        No credentials on file?
        <.link href={~p"/users/register"} class="text-emerald-500 hover:text-emerald-400">
          Initialize
        </.link>
      </p>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # UserSettingsLive
  # ---------------------------------------------------------------------------
  def user_settings(assigns) do
    ~H"""
    <div class="space-y-6 max-w-3xl">
      <div class="border-b border-gray-800 pb-4">
        <.h1 color_class="text-gray-100" no_margin>System Parameters</.h1>
        <.p class="text-sm text-gray-500 mt-1" no_margin>
          Configure your account. The ledger awaits your directives.
        </.p>
      </div>

      <.card variant="outline" class="bg-gray-950 border-gray-800">
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

  # ---------------------------------------------------------------------------
  # DashboardLive
  # ---------------------------------------------------------------------------
  def dashboard(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex items-end justify-between border-b border-gray-800 pb-4">
        <div>
          <.h1 color_class="text-gray-100" no_margin>The Ledger</.h1>
          <.p class="text-sm text-gray-500 mt-1" no_margin>
            Your financial data, consolidated. Inevitable.
          </.p>
        </div>
        <.button size="sm" color="gray" variant="outline" class="font-mono text-xs border-gray-800 text-emerald-500 hover:border-emerald-500/50">
          + Add Integration
        </.button>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-3 border border-gray-800 rounded-lg overflow-hidden bg-gray-950/50">
        <div class="p-5 border-b md:border-b-0 md:border-r border-gray-800">
          <div class="flex items-center justify-between">
            <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">Net Worth</p>
            <.badge color="gray" variant="outline" size="sm" class="font-mono text-[9px] border-gray-800 text-gray-600">Uncalculated</.badge>
          </div>
          <p class="mt-2 text-3xl font-mono text-gray-100 tracking-tight">$0.00</p>
        </div>

        <div class="p-5 border-b md:border-b-0 md:border-r border-gray-800">
          <div class="flex items-center justify-between">
            <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">30-Day Outflow</p>
            <.badge color="gray" variant="outline" size="sm" class="font-mono text-[9px] border-gray-800 text-gray-600">Uncalculated</.badge>
          </div>
          <p class="mt-2 text-3xl font-mono text-gray-100 tracking-tight">$0.00</p>
        </div>

        <div class="p-5">
          <div class="flex items-center justify-between">
            <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">Active Data Streams</p>
            <.badge color="danger" variant="outline" size="sm" class="font-mono text-[9px] border-red-900/30 text-red-500">Severed</.badge>
          </div>
          <p class="mt-2 text-3xl font-mono text-gray-100 tracking-tight">0</p>
        </div>
      </div>

      <div class="border border-gray-800 rounded-lg bg-gray-950 overflow-hidden">
        <div class="border-b border-gray-800 px-4 py-3 bg-black">
          <.h3 color_class="text-gray-300" class="text-sm font-mono tracking-wide" no_margin>Recent Entries</.h3>
        </div>

        <div class="w-full overflow-x-auto">
          <table class="w-full text-left text-sm whitespace-nowrap">
            <thead class="bg-gray-900/50 font-mono text-[10px] uppercase tracking-wider text-gray-500 border-b border-gray-800">
              <tr>
                <th scope="col" class="px-4 py-3">Date</th>
                <th scope="col" class="px-4 py-3">Merchant</th>
                <th scope="col" class="px-4 py-3">Category</th>
                <th scope="col" class="px-4 py-3">Account</th>
                <th scope="col" class="px-4 py-3 text-right">Amount</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-800/50">
              <tr>
                <td colspan="5" class="px-4 py-16 text-center">
                  <p class="font-mono text-sm text-gray-500">There is no data here. Only an anomaly.</p>
                  <p class="mt-2 text-xs font-mono text-gray-600">Initialize a Plaid connection to populate the ledger.</p>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # MfaSetupLive
  # ---------------------------------------------------------------------------
  def mfa_setup(assigns) do
    ~H"""
    <div class="mx-auto max-w-md pt-8">
      <.h2 color_class="text-gray-100" class="text-xl">Authentication Protocol</.h2>

      <.card variant="outline" class="mt-4 bg-gray-950 border-gray-800">
        <.card_content>
          <%= if @step == :generate do %>
            <div class="space-y-6">
              <.p class="text-sm text-gray-400">
                Generate a cryptographic secret and synchronize it with your authenticator device.
              </.p>
              <.button phx-click="generate_secret" class="w-full font-mono text-xs tracking-widest uppercase">
                Initialize Secret
              </.button>
            </div>
          <% else %>
            <%= if @recovery_codes do %>
              <div class="space-y-6">
                <.alert color="danger" with_icon class="border-red-900/50 bg-red-950/20 text-red-400 font-mono text-xs">
                  Save these offline. Without them, you will be permanently unplugged from your ledger.
                </.alert>
                <div class="grid grid-cols-2 gap-3 p-4 bg-black border border-gray-800 rounded-md">
                  <%= for code <- @recovery_codes do %>
                    <div class="font-mono text-sm text-gray-300 text-center tracking-widest select-all"><%= code %></div>
                  <% end %>
                </div>
                <.link navigate={~p"/users/settings"}>
                  <.button class="w-full font-mono text-xs tracking-widest uppercase">Acknowledge & Finalize</.button>
                </.link>
              </div>
            <% else %>
              <div class="space-y-6">
                <div :if={@user.mfa_secret}>
                  <.p class="text-xs font-mono text-gray-500 uppercase tracking-widest">Optical Sync:</.p>
                  <div class="inline-block p-4 bg-gray-200 rounded-md mt-2 w-full flex justify-center">
                    <%= Phoenix.HTML.raw(qr_code_svg(@user)) %>
                  </div>

                  <.alert color="warning" class="mt-4 text-xs font-mono border-yellow-900/30 bg-yellow-900/10 text-yellow-600">
                    Scan the code. Or use the manual key. The choice is an illusion, but the security is mandatory.
                  </.alert>

                  <div class="mt-4 rounded border border-gray-800 bg-black px-3 py-2">
                    <p class="text-[10px] font-mono text-gray-600 uppercase tracking-widest mb-1">Manual Base32 Key</p>
                    <p class="font-mono text-sm text-emerald-500 break-all select-all tracking-widest text-center py-1"><%= @user.mfa_secret %></p>
                  </div>
                </div>

                <div class="border-t border-gray-800/50 pt-6">
                  <.form for={%{}} as={:form} id="verify_mfa" phx-submit="verify" class="space-y-4">
                    <.field
                      type="text"
                      name="form[code]"
                      value={@code}
                      label="6-Digit Token"
                      maxlength="6"
                      class="font-mono text-center tracking-[0.5em] text-lg"
                      placeholder="000000"
                    />
                    <.alert :if={@error} color="danger" label={@error} class="text-xs font-mono" />
                    <.button type="submit" class="w-full font-mono text-xs tracking-widest uppercase">
                      Verify & Enforce
                    </.button>
                  </.form>
                </div>
              </div>
            <% end %>
          <% end %>
        </.card_content>
      </.card>
    </div>
    """
  end

  defp qr_code_svg(_user), do: ""

  # ---------------------------------------------------------------------------
  # MfaVerifyLive
  # ---------------------------------------------------------------------------
  def mfa_verify(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm pt-24">
      <.card variant="outline" class="bg-gray-950 border-gray-800 shadow-2xl">
        <.card_content class="text-center p-6">
          <.h3 color_class="text-gray-100" class="font-mono text-sm tracking-wide" no_margin>
            Credentials accepted.
          </.h3>
          <.p class="text-gray-500 text-xs font-mono mt-1" no_margin>
            Identity unverified.
          </.p>

          <%= if locked?(@locked_until) do %>
            <.alert color="danger" class="mt-6 text-xs font-mono text-left border-red-900/50 bg-red-950/20" with_icon>
              Quarantine protocol engaged. <br/> Try again in <%= remaining_seconds(@locked_until) %>s.
            </.alert>
          <% else %>
            <.form for={%{}} as={:form} id="mfa_verify" phx-submit="verify" class="mt-8 space-y-4 text-left">
              <%= if @use_recovery do %>
                <.field
                  type="text"
                  name="form[code]"
                  value={@code}
                  label="Recovery Sequence"
                  class="font-mono text-center tracking-widest"
                  placeholder="XXXX-XXXX-XXXX"
                />
              <% else %>
                <.field
                  type="text"
                  name="form[code]"
                  value={@code}
                  label="Authentication Token"
                  maxlength="6"
                  class="font-mono text-center tracking-[0.5em] text-lg"
                  placeholder="------"
                  autofocus
                />
              <% end %>

              <.alert :if={@error} color="danger" class="text-xs font-mono border-red-900/30 bg-red-900/10 text-red-500" with_icon label="Anomaly detected. The code is invalid." />

              <div class="flex flex-col gap-3 pt-2">
                <.button type="submit" class="w-full font-mono text-xs tracking-widest uppercase">
                  Transmit
                </.button>
                <.button
                  type="button"
                  variant="ghost"
                  color="gray"
                  phx-click="toggle_recovery"
                  class="w-full font-mono text-[10px] uppercase tracking-widest text-gray-500 hover:text-gray-300"
                >
                  <%= if @use_recovery, do: "Return to Token Input", else: "I require a recovery code." %>
                </.button>
              </div>
            </.form>
          <% end %>
        </.card_content>
      </.card>
    </div>
    """
  end

  defp locked?(_), do: false
  defp remaining_seconds(_), do: 0
end
