defmodule FinanceSmithWeb.UserLoginLive do
  use FinanceSmithWeb, :live_view

  alias FinanceSmith.Identity

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Log in")
      |> assign(:email, "")
      |> assign(:password, "")
      |> assign(:error, nil)
      |> assign(:token, nil)
      |> assign(:trigger_action, false)

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm space-y-6 pt-16">
      <div class="text-center">
        <p class="font-mono text-sm text-gray-400 mb-4">Finance <span class="text-emerald-500">Smith</span></p>
        <.h2 color_class="text-gray-100" no_margin>Authenticate</.h2>
        <.p class="mt-1 text-sm text-gray-500" no_margin>
          Provide your credentials. The system awaits.
        </.p>
      </div>

      <.card variant="outline">
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
            />
            <.field
              type="password"
              name="user[password]"
              value={@password}
              label="Password"
            />
            <.alert
              :if={@error}
              color="danger"
              with_icon
              class="text-xs font-mono"
              label={@error}
              close_button_properties={[
                type: "button",
                "phx-click": "dismiss_error"
              ]}
            />
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

  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply,
     socket
     |> assign(:email, params["email"] || "")
     |> assign(:password, params["password"] || "")}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, :error, nil)}
  end

  def handle_event("submit", %{"user" => %{"email" => email, "password" => password}}, socket) do
    case Identity.verify_sign_in(email, password) do
      {:ok, user} ->
        token =
          Phoenix.Token.sign(
            FinanceSmithWeb.Endpoint,
            "user session",
            %{user_id: user.id, mfa_enabled: user.mfa_enabled},
            max_age: 300
          )

        {:noreply,
         socket
         |> assign(:error, nil)
         |> assign(:token, token)
         |> assign(:trigger_action, true)}

      {:error, :invalid_credentials} ->
        {:noreply,
         socket
         |> assign(:error, "We have a... discrepancy. Invalid email or password.")
         |> assign(:password, "")}

      {:error, {:locked, seconds}} ->
        {:noreply,
         socket
         |> assign(:error, "Quarantine protocol engaged. Try again in #{seconds} seconds.")
         |> assign(:password, "")}
    end
  end
end
