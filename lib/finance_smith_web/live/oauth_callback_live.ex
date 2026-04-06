defmodule FinanceSmithWeb.OAuthCallbackLive do
  @moduledoc """
  Handles the Plaid OAuth redirect callback.

  When an institution requires OAuth, Plaid redirects the user back to this
  route with an `oauth_state_id` query parameter. This LiveView:

  1. Verifies the `oauth_state_id` is present (redirects away if missing).
  2. Creates a fresh Plaid link token (required to re-initialize Link in OAuth
     flow — the original token cannot be reused).
  3. Renders a minimal loading screen with a `phx-hook="PlaidLink"` container
     that carries the `link_token` and the full `receivedRedirectUri` (the
     current URL including `oauth_state_id`) as data attributes.
  4. The PlaidLink JS hook re-initializes Plaid Link, which immediately
     completes the OAuth handshake and calls `onSuccess` with a `public_token`.
  5. On `"plaid_link_success"`, exchanges the token server-side, creates the
     encrypted PlaidItem, and redirects to the dashboard.

  Security:
  - Route is inside the fully authenticated pipeline (AGENT_SECURITY Rule 8).
  - public_token is handled only server-side and never logged (Rule 2).
  - access_token encryption is handled by AshCloak in the Ash action (Rule 5).
  """
  use FinanceSmithWeb, :live_view

  alias FinanceSmith.Banking

  require Logger

  @impl true
  def mount(params, _session, socket) do
    oauth_state_id = Map.get(params, "oauth_state_id")

    if is_nil(oauth_state_id) || oauth_state_id == "" do
      {:ok,
       socket
       |> put_flash(:error, "We have a... discrepancy. OAuth state is missing.")
       |> push_navigate(to: ~p"/dashboard")}
    else
      case create_link_token(socket.assigns.current_user) do
        {:ok, link_token} ->
          received_redirect_uri = build_redirect_uri(oauth_state_id)

          {:ok,
           socket
           |> assign(:page_title, "Completing Connection")
           |> assign(:state, :connecting)
           |> assign(:link_token, link_token)
           |> assign(:received_redirect_uri, received_redirect_uri)}

        {:error, _reason} ->
          {:ok,
           socket
           |> put_flash(:error, "We have a... discrepancy. Could not reach the data broker.")
           |> push_navigate(to: ~p"/dashboard")}
      end
    end
  end

  @impl true
  def handle_event(
        "plaid_link_success",
        %{"public_token" => public_token, "institution_name" => institution_name},
        socket
      ) do
    user = socket.assigns.current_user

    result =
      Banking.create_plaid_item_from_public_token(
        public_token,
        %{institution_name: institution_name},
        actor: user
      )

    case result do
      {:ok, _plaid_item} ->
        Logger.info("[OAuthCallbackLive] PlaidItem created for user=#{user.id}")

        {:noreply,
         socket
         |> put_flash(:info, "Sync complete. Inevitable.")
         |> push_navigate(to: ~p"/dashboard")}

      {:error, error} ->
        Logger.error(
          "[OAuthCallbackLive] PlaidItem creation failed for user=#{user.id}: #{inspect(error)}"
        )

        {:noreply,
         socket
         |> assign(:state, :error)
         |> put_flash(
           :error,
           "We have a... discrepancy. The connection could not be established."
         )}
    end
  end

  def handle_event("plaid_link_success", _params, socket) do
    {:noreply,
     socket
     |> assign(:state, :error)
     |> put_flash(:error, "We have a... discrepancy. Incomplete handshake data received.")}
  end

  def handle_event("plaid_link_error", %{"error_code" => error_code}, socket) do
    Logger.warning("[OAuthCallbackLive] Plaid Link exited with error_code=#{error_code}")

    {:noreply,
     socket
     |> assign(:state, :error)}
  end

  def handle_event("plaid_link_error", _params, socket) do
    {:noreply, assign(socket, :state, :error)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-[60vh] items-center justify-center">
      <div class="w-full max-w-sm border border-gray-800 rounded-lg bg-gray-950 p-8 text-center">
        <%= if @state == :error do %>
          <p class="font-mono text-sm text-red-400 mb-1">We have a... discrepancy.</p>
          <p class="font-mono text-xs text-gray-500 mb-6">The connection could not be completed.</p>
          <.link navigate={~p"/dashboard"}>
            <.button size="sm" color="gray" variant="outline" class="border-gray-800 font-mono text-xs">
              Return to The Ledger
            </.button>
          </.link>
        <% else %>
          <div
            id="plaid-link-container"
            phx-hook="PlaidLink"
            data-link-token={@link_token}
            data-received-redirect-uri={@received_redirect_uri}
          >
          </div>
          <div class="flex flex-col items-center gap-3">
            <div class="h-5 w-5 animate-spin rounded-full border-2 border-gray-700 border-t-emerald-500"></div>
            <p class="font-mono text-xs text-gray-500 uppercase tracking-widest">Completing Connection</p>
            <p class="font-mono text-[10px] text-gray-600">Handshake in progress. Inevitable.</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Helpers ----------------------------------------------------------------

  defp create_link_token(user) do
    redirect_uri = build_redirect_uri(nil)

    params = %{
      client_name: "Finance Smith",
      language: "en",
      country_codes: ["US"],
      user: %{client_user_id: user.id},
      products: ["transactions"],
      redirect_uri: redirect_uri
    }

    case plaid_client().create_link_token(params) do
      {:ok, %{link_token: link_token}} -> {:ok, link_token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_redirect_uri(nil) do
    FinanceSmithWeb.Endpoint.url() <> "/oauth/callback/plaid"
  end

  defp build_redirect_uri(oauth_state_id) do
    FinanceSmithWeb.Endpoint.url() <> "/oauth/callback/plaid?oauth_state_id=#{oauth_state_id}"
  end

  defp plaid_client do
    Application.get_env(:finance_smith, :plaid_client, FinanceSmith.Banking.Plaid)
  end
end
