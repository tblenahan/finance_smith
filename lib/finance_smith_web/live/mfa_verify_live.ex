defmodule FinanceSmithWeb.MfaVerifyLive do
  use FinanceSmithWeb, :live_view

  alias FinanceSmith.Identity
  alias FinanceSmithWeb.AshErrorHTML

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Verify identity")
      |> assign(:code, "")
      |> assign(:use_recovery, false)
      |> assign(:error, nil)
      |> assign(:token, nil)
      |> assign(:trigger_action, false)

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm pt-24">
      <.card variant="outline">
        <.card_content class="text-center p-6">
          <.h3 color_class="text-gray-100" class="font-mono text-sm tracking-wide" no_margin>
            Credentials accepted.
          </.h3>
          <.p class="text-gray-500 text-xs font-mono mt-1" no_margin>
            Identity unverified.
          </.p>

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
            <.alert :if={@error} color="danger" class="text-xs font-mono" with_icon label={@error} />
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
        </.card_content>
      </.card>

      <.form
        :if={@token}
        for={%{}}
        as={:session}
        action={~p"/users/session"}
        method="post"
        phx-trigger-action={@trigger_action}
      >
        <input type="hidden" name="token" value={@token} />
      </.form>
    </div>
    """
  end

  def handle_event("toggle_recovery", _params, socket) do
    {:noreply,
     socket
     |> assign(:use_recovery, !socket.assigns.use_recovery)
     |> assign(:code, "")
     |> assign(:error, nil)}
  end

  def handle_event("verify", %{"form" => %{"code" => code}}, socket) do
    user = socket.assigns[:mfa_pending_user]
    code = String.trim(code)

    case Identity.verify_mfa_login(user, code, actor: user) do
      {:ok, _} ->
        token =
          Phoenix.Token.sign(
            FinanceSmithWeb.Endpoint,
            "user session",
            %{user_id: user.id, mfa_verified: true},
            max_age: 300
          )

        {:noreply,
         socket
         |> assign(:token, token)
         |> assign(:trigger_action, true)}

      {:error, %Ash.Error.Invalid{} = error} ->
        {:noreply,
         socket
         |> assign(:error, AshErrorHTML.format_for_user(error))
         |> assign(:code, "")}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:error, "Anomaly detected. The code is invalid.")
         |> assign(:code, "")}
    end
  end
end
