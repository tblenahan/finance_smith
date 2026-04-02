defmodule FinanceSmithWeb.UserRegistrationLive do
  use FinanceSmithWeb, :live_view

  alias FinanceSmith.Identity

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Register")
      |> assign(:email, "")
      |> assign(:password, "")
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
            <.alert :if={@error} color="danger" label={@error} />
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

  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply,
     socket
     |> assign(:email, params["email"] || "")
     |> assign(:password, params["password"] || "")
     |> assign(:error, nil)}
  end

  def handle_event("submit", %{"user" => %{"email" => email, "password" => password}}, socket) do
    case Identity.register(email, password, authorize?: false) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account created. Log in to continue.")
         |> redirect(to: "/users/log_in")}

      {:error, error} ->
        message = format_ash_error(error)

        {:noreply,
         socket
         |> assign(:error, message)
         |> assign(:password, "")}
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
  defp format_ash_error(_), do: "Something went wrong."
end
