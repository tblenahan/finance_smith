defmodule FinanceSmithWeb.MfaSetupLive do
  use FinanceSmithWeb, :live_view

  alias FinanceSmith.Identity
  alias EQRCode

  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user]
    user = user && Ash.load!(user, :mfa_secret, actor: user)
    has_secret = user && user.mfa_secret && user.mfa_secret != ""

    socket =
      socket
      |> assign(:page_title, "MFA Setup")
      |> assign(:current_user, user)
      |> assign(:user, user)
      |> assign(:step, if(has_secret, do: :verify, else: :generate))
      |> assign(:code, "")
      |> assign(:recovery_codes, nil)
      |> assign(:error, nil)
      |> assign(:current_nav, :settings)

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-md pt-8">
      <.h2 color_class="text-gray-100" class="text-xl">Authentication Protocol</.h2>

      <.card variant="outline" class="mt-4">
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
                <.alert color="danger" with_icon heading="Your recovery codes">
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

                  <.alert color="warning" class="mt-4 text-xs font-mono">
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
                    <.alert :if={@error} color="danger" label={@error} />
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

  defp qr_code_svg(user) do
    raw_secret = Base.decode32!(user.mfa_secret, padding: false)

    uri =
      NimbleTOTP.otpauth_uri("Finance Smith:#{user.email}", raw_secret, issuer: "Finance Smith")

    uri |> EQRCode.encode() |> EQRCode.svg()
  end

  def handle_event("generate_secret", _params, socket) do
    user = socket.assigns.user

    case Identity.generate_mfa_secret(user, actor: user) do
      {:ok, updated} ->
        updated = Ash.load!(updated, :mfa_secret, actor: user)

        {:noreply,
         socket
         |> assign(:user, updated)
         |> assign(:step, :verify)
         |> assign(:error, nil)}

      {:error, _} ->
        {:noreply, assign(socket, :error, "Failed to generate secret.")}
    end
  end

  def handle_event("verify", %{"form" => %{"code" => code}}, socket) do
    user = socket.assigns.user
    code = String.trim(code)

    case Identity.enable_mfa(user, code, actor: user) do
      {:ok, updated} ->
        updated = Ash.load!(updated, :recovery_codes, actor: user)
        codes = Jason.decode!(updated.recovery_codes)

        {:noreply,
         socket
         |> assign(:recovery_codes, codes)
         |> assign(:user, updated)
         |> assign(:error, nil)}

      {:error, error} ->
        msg = format_ash_error(error)

        {:noreply,
         socket
         |> assign(:error, msg)
         |> assign(:code, "")}
    end
  end

  defp format_ash_error(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    errors
    |> Enum.map(fn err ->
      case Map.get(err, :message) do
        nil -> Exception.message(err)
        msg when is_binary(msg) -> msg
        other -> inspect(other)
      end
    end)
    |> Enum.join(", ")
  end

  defp format_ash_error(error) when is_struct(error), do: Exception.message(error)
  defp format_ash_error(_), do: "Invalid code."
end
