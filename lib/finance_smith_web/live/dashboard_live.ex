defmodule FinanceSmithWeb.DashboardLive do
  use FinanceSmithWeb, :live_view

  alias FinanceSmith.Banking
  alias FinanceSmithWeb.MoneyFormat
  alias FinanceSmithWeb.TransactionLiveHelpers
  alias FinanceSmithWeb.TransactionTableComponent

  require Logger

  @aggregate_fields [:total_net_worth, :outflow_30d, :inflow_30d, :active_streams_count]

  def mount(_params, _session, socket) do
    if connected?(socket) do
      FinanceSmithWeb.Endpoint.subscribe(
        "plaid_item:sync_complete:#{socket.assigns.current_user.id}"
      )

      FinanceSmithWeb.Endpoint.subscribe("transaction:created")
    end

    user = load_user_aggregates(socket.assigns.current_user)

    socket =
      socket
      |> assign(:page_title, "The Ledger")
      |> assign(:current_nav, :dashboard)
      |> assign(:current_user, user)
      |> assign(:page, nil)
      |> assign(:tx_params, TransactionLiveHelpers.default_tx_params())
      |> assign(:categories, TransactionLiveHelpers.list_categories(user))

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    tx_params = TransactionLiveHelpers.parse_tx_params(params)

    socket =
      socket
      |> assign(:tx_params, tx_params)
      |> apply_transactions(tx_params)

    {:noreply, socket}
  end

  def handle_event("request_link_token", _params, socket) do
    case create_link_token(socket.assigns.current_user) do
      {:ok, link_token} ->
        {:noreply, push_event(socket, "open_plaid_link", %{link_token: link_token})}

      {:error, reason} ->
        Logger.error("[DashboardLive] create_link_token failed: #{inspect(reason)}")

        {:noreply,
         put_flash(socket, :error, "We have a... discrepancy. Could not reach the data broker.")}
    end
  end

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
        Logger.info("[DashboardLive] PlaidItem created for user=#{user.id}")

        {:noreply,
         socket
         |> put_flash(:info, "Connection established. Synchronization initiated.")
         |> push_navigate(to: ~p"/dashboard")}

      {:error, error} ->
        Logger.error(
          "[DashboardLive] PlaidItem creation failed for user=#{user.id}: #{inspect(error)}"
        )

        {:noreply,
         put_flash(
           socket,
           :error,
           "We have a... discrepancy. The connection could not be established."
         )}
    end
  end

  def handle_event("plaid_link_success", _params, socket) do
    {:noreply,
     put_flash(socket, :error, "We have a... discrepancy. Incomplete handshake data received.")}
  end

  def handle_event("plaid_link_error", %{"error_code" => error_code}, socket) do
    Logger.warning("[DashboardLive] Plaid Link exited with error_code=#{error_code}")
    {:noreply, put_flash(socket, :error, "We have a... discrepancy. The link was not completed.")}
  end

  def handle_event("plaid_link_error", _params, socket) do
    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "complete_sync"}, socket) do
    user = load_user_aggregates(socket.assigns.current_user)

    socket =
      socket
      |> assign(:current_user, user)
      |> apply_transactions(socket.assigns.tx_params)
      |> put_flash(:info, "Sync complete. Inevitable.")

    {:noreply, socket}
  end

  def handle_info(%{topic: "transaction:created", payload: %Ash.Notifier.Notification{}}, socket) do
    {:noreply, apply_transactions(socket, socket.assigns.tx_params)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div id="plaid-link-hook" phx-hook="PlaidLink"></div>

      <div class="flex items-end justify-between border-b border-gray-800 pb-4">
        <div>
          <.h1 color_class="text-gray-100" no_margin>The Ledger</.h1>
          <.p class="text-sm text-gray-500 mt-1" no_margin>
            Your financial data, consolidated. Inevitable.
          </.p>
        </div>
        <.button
          phx-click="request_link_token"
          size="sm"
          color="gray"
          variant="outline"
          class="font-mono text-xs border-gray-800 text-emerald-500 hover:border-emerald-500/50"
        >
          + Add Integration
        </.button>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-3 border border-gray-800 rounded-lg overflow-hidden bg-gray-950/50">
        <div class="p-5 border-b md:border-b-0 md:border-r border-gray-800">
          <div class="flex items-center justify-between">
            <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">Net Worth</p>
            <%= if @current_user.active_streams_count > 0 do %>
              <.badge
                color="success"
                variant="outline"
                size="sm"
                class="font-mono text-[9px] border-emerald-900/30 text-emerald-500"
              >
                Calculated
              </.badge>
            <% else %>
              <.badge
                color="gray"
                variant="outline"
                size="sm"
                class="font-mono text-[9px] border-gray-800 text-gray-600"
              >
                Uncalculated
              </.badge>
            <% end %>
          </div>
          <p class="mt-2 text-3xl font-mono text-gray-100 tracking-tight">
            {MoneyFormat.format(@current_user.total_net_worth, nil_display: "$0.00")}
          </p>
        </div>

        <div class="p-5 border-b md:border-b-0 md:border-r border-gray-800">
          <div class="flex items-center justify-between">
            <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">
              30-Day Outflow
            </p>
            <.badge
              color="gray"
              variant="outline"
              size="sm"
              class="font-mono text-[9px] border-gray-800 text-gray-600"
            >
              30d
            </.badge>
          </div>
          <p class="mt-2 text-3xl font-mono text-gray-100 tracking-tight">
            {MoneyFormat.format(@current_user.outflow_30d, nil_display: "$0.00")}
          </p>
        </div>

        <div class="p-5">
          <div class="flex items-center justify-between">
            <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">
              Active Data Streams
            </p>
            <%= if @current_user.active_streams_count > 0 do %>
              <.badge
                color="success"
                variant="outline"
                size="sm"
                class="font-mono text-[9px] border-emerald-900/30 text-emerald-500"
              >
                Connected
              </.badge>
            <% else %>
              <.badge
                color="danger"
                variant="outline"
                size="sm"
                class="font-mono text-[9px] border-red-900/30 text-red-500"
              >
                Severed
              </.badge>
            <% end %>
          </div>
          <p class="mt-2 text-3xl font-mono text-gray-100 tracking-tight">
            {@current_user.active_streams_count}
          </p>
        </div>
      </div>

      <.live_component
        module={TransactionTableComponent}
        id="txn-table"
        page={@page}
        params={@tx_params}
        base_url={~p"/dashboard"}
        scope={:global}
        categories={@categories}
      />
    </div>
    """
  end

  # --- Helpers ----------------------------------------------------------------

  defp apply_transactions(socket, tx_params) do
    case TransactionLiveHelpers.fetch_transactions(socket.assigns.current_user, tx_params) do
      {:ok, page} ->
        assign(socket, :page, page)

      {:error, _reason} ->
        put_flash(socket, :error, "We have a... discrepancy. The ledger refused to open.")
    end
  end

  defp load_user_aggregates(user) do
    Ash.load!(user, @aggregate_fields, actor: user)
  end

  defp create_link_token(user) do
    redirect_uri = FinanceSmithWeb.Endpoint.url() <> "/oauth/callback/plaid"

    plaid_env =
      if Application.get_env(:plaid, :root_uri) =~ "sandbox", do: "sandbox", else: "production"

    Logger.debug(
      "[DashboardLive] Plaid link token request — env=#{plaid_env} redirect_uri=#{redirect_uri}"
    )

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

  defp plaid_client do
    Application.get_env(:finance_smith, :plaid_client, FinanceSmith.Banking.Plaid)
  end
end
