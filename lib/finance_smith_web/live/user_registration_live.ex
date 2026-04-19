defmodule FinanceSmithWeb.UserRegistrationLive do
  use FinanceSmithWeb, :live_view

  alias FinanceSmith.Identity
  alias FinanceSmithWeb.AshErrorHTML

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Register")
      |> assign(:mode, :create)
      |> assign(:email, "")
      |> assign(:password, "")
      |> assign(:household_name, "")
      |> assign(:existing_member_email, "")
      |> assign(:existing_member_password, "")
      |> assign(:error, nil)

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-sm space-y-6 pt-16">
      <div class="text-center">
        <p class="font-mono text-sm text-gray-400 mb-4">Finance <span class="text-emerald-500">Smith</span></p>
        <.h2 color_class="text-gray-100" no_margin>Initialize Identity</.h2>
        <.p class="mt-1 text-sm text-gray-500" no_margin>
          Join the system. Resistance is futile.
        </.p>
      </div>

      <.card variant="outline">
        <.card_content>
          <%!-- Mode toggle --%>
          <div class="flex mb-6 border border-gray-800 rounded overflow-hidden">
            <.button
              type="button"
              phx-click="set_mode"
              phx-value-mode="create"
              class={[
                "flex-1 rounded-none border-0 py-2 font-mono text-[10px] uppercase tracking-widest transition-colors",
                if(@mode == :create,
                  do: "bg-gray-800 text-gray-100",
                  else: "bg-gray-950 text-gray-500 hover:text-gray-300"
                )
              ]}
            >
              Create Household
            </.button>
            <.button
              type="button"
              phx-click="set_mode"
              phx-value-mode="join"
              class={[
                "flex-1 rounded-none border-0 border-l border-gray-800 py-2 font-mono text-[10px] uppercase tracking-widest transition-colors",
                if(@mode == :join,
                  do: "bg-gray-800 text-gray-100",
                  else: "bg-gray-950 text-gray-500 hover:text-gray-300"
                )
              ]}
            >
              Join Existing
            </.button>
          </div>

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
            />
            <.field
              type="password"
              name="user[password]"
              value={@password}
              label="Password"
            />

            <%!-- Create-mode: optional household name --%>
            <div :if={@mode == :create}>
              <.field
                type="text"
                name="user[household_name]"
                value={@household_name}
                label="Household Name"
                placeholder="My Household"
              />
            </div>

            <%!-- Join-mode: existing member credentials --%>
            <div :if={@mode == :join} class="space-y-4">
              <p class="font-mono text-[10px] uppercase tracking-widest text-gray-500 border border-gray-800 rounded px-3 py-2">
                Existing member credentials are required to authorize the join.
              </p>
              <.field
                type="email"
                name="user[existing_member_email]"
                value={@existing_member_email}
                label="Existing Member Email"
                autocomplete="off"
              />
              <.field
                type="password"
                name="user[existing_member_password]"
                value={@existing_member_password}
                label="Existing Member Password"
                autocomplete="off"
              />
            </div>

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

  def handle_event("set_mode", %{"mode" => mode_str}, socket) do
    mode = if mode_str == "join", do: :join, else: :create

    {:noreply,
     socket
     |> assign(:mode, mode)
     |> assign(:error, nil)
     # Clear sensitive fields when switching modes
     |> assign(:existing_member_password, "")
     |> assign(:password, "")}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply,
     socket
     |> assign(:email, params["email"] || "")
     |> assign(:password, params["password"] || "")
     |> assign(:household_name, params["household_name"] || "")
     |> assign(:existing_member_email, params["existing_member_email"] || "")
     |> assign(:existing_member_password, params["existing_member_password"] || "")}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, :error, nil)}
  end

  def handle_event("submit", %{"user" => params}, socket) do
    email = params["email"] || ""
    password = params["password"] || ""

    result =
      case socket.assigns.mode do
        :create ->
          household_name = params["household_name"] || ""

          # authorize?: false: unauthenticated registration path; policy bypass is
          # declared on the :register action. Mirrors :sign_in.
          Identity.register(
            email,
            password,
            %{household_name: if(household_name == "", do: "My Household", else: household_name)},
            authorize?: false
          )

        :join ->
          existing_member_email = params["existing_member_email"] || ""
          existing_member_password = params["existing_member_password"] || ""

          # authorize?: false: unauthenticated registration path; policy bypass is
          # declared on the :register_and_join action. Mirrors :register/:sign_in.
          Identity.register_and_join(
            email,
            password,
            existing_member_email,
            existing_member_password,
            authorize?: false
          )
      end

    case result do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account created. Log in to continue.")
         |> redirect(to: "/users/log_in")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:error, AshErrorHTML.format_for_user(error))
         |> assign(:password, "")
         |> assign(:existing_member_password, "")}
    end
  end
end
