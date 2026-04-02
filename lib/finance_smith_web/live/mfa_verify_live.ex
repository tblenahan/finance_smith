defmodule FinanceSmithWeb.MfaVerifyLive do
  use FinanceSmithWeb, :live_view

  alias FinanceSmith.Identity

  @max_attempts 5
  @lockout_seconds 60

  def mount(_params, session, socket) do
    mfa_pending_user = FinanceSmithWeb.Plugs.LiveAuth.get_mfa_pending_user_from_session(session)

    socket =
      socket
      |> assign(:page_title, "Verify identity")
      |> assign(:mfa_pending_user, mfa_pending_user)
      |> assign(:code, "")
      |> assign(:use_recovery, false)
      |> assign(:error, nil)
      |> assign(:attempts, 0)
      |> assign(:locked_until, nil)

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

          <%= if locked?(@locked_until) do %>
            <.alert color="danger" class="mt-6 text-xs font-mono text-left" with_icon>
              Quarantine protocol engaged. Try again in <%= remaining_seconds(@locked_until) %>s.
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
              <.alert :if={@error} color="danger" class="text-xs font-mono" with_icon label="Anomaly detected. The code is invalid." />
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

  defp locked?(nil), do: false
  defp locked?(until_ts), do: System.system_time(:second) < until_ts

  defp remaining_seconds(until_ts) do
    max(0, until_ts - System.system_time(:second))
  end

  def handle_event("toggle_recovery", _params, socket) do
    {:noreply,
     socket
     |> assign(:use_recovery, !socket.assigns.use_recovery)
     |> assign(:code, "")
     |> assign(:error, nil)}
  end

  def handle_event("verify", %{"form" => %{"code" => code}}, socket) do
    if locked?(socket.assigns.locked_until) do
      {:noreply, socket}
    else
      user = socket.assigns.mfa_pending_user
      code = String.trim(code)

      case Identity.verify_mfa_login(user, code, authorize?: false) do
        {:ok, _} ->
          token =
            Phoenix.Token.sign(
              FinanceSmithWeb.Endpoint,
              "user session",
              %{user_id: user.id, mfa_enabled: false},
              max_age: 300
            )

          {:noreply,
           socket
           |> put_flash(:info, "Sync complete. Inevitable.")
           |> redirect(to: "/users/session?token=#{token}")}

        {:error, _} ->
          attempts = (socket.assigns.attempts || 0) + 1

          locked_until =
            if attempts >= @max_attempts,
              do: System.system_time(:second) + @lockout_seconds,
              else: nil

          {:noreply,
           socket
           |> assign(:attempts, if(locked_until, do: 0, else: attempts))
           |> assign(:locked_until, locked_until)
           |> assign(:error, "invalid")
           |> assign(:code, "")}
      end
    end
  end
end
