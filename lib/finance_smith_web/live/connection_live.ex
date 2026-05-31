defmodule FinanceSmithWeb.ConnectionLive do
  use FinanceSmithWeb, :live_view

  require Logger

  alias FinanceSmith.Banking
  alias FinanceSmithWeb.TransactionLiveHelpers
  alias FinanceSmithWeb.TransactionTableComponent

  def mount(%{"plaid_item_id" => plaid_item_id}, _session, socket) do
    if connected?(socket) do
      FinanceSmithWeb.Endpoint.subscribe("transaction:created")
      FinanceSmithWeb.Endpoint.subscribe("transaction:updated")
    end

    plaid_item = load_plaid_item(socket.assigns.current_user, plaid_item_id)
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:page_title, page_title(plaid_item))
      |> assign(:current_nav, :dashboard)
      |> assign(:plaid_item_id, plaid_item_id)
      |> assign(:plaid_item, plaid_item)
      |> assign(:page, nil)
      |> assign(:tx_params, TransactionLiveHelpers.default_tx_params())
      |> assign(
        :categories,
        TransactionLiveHelpers.list_categories(user, %{plaid_item_id: plaid_item_id})
      )

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

  def handle_info(%{topic: "transaction:created", payload: %Ash.Notifier.Notification{}}, socket) do
    {:noreply, refresh_view(socket)}
  end

  def handle_info(
        %{topic: "transaction:updated", payload: %Ash.Notifier.Notification{data: updated_txn}},
        socket
      ) do
    page =
      TransactionLiveHelpers.apply_resolved_transaction(
        socket.assigns.page,
        updated_txn,
        socket.assigns.tx_params,
        socket.assigns.categories
      )

    {:noreply, assign(socket, :page, page)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex items-end justify-between border-b border-gray-800 pb-4">
        <div>
          <div class="flex items-center gap-2 mb-1">
            <.link
              navigate={~p"/dashboard"}
              class="font-mono text-[10px] uppercase tracking-widest text-gray-600 hover:text-gray-400 transition-colors"
            >
              ← The Ledger
            </.link>
          </div>
          <%= if @plaid_item do %>
            <.h1 color_class="text-gray-100" no_margin>
              {@plaid_item.institution_name || "Connection"}
            </.h1>
            <.p class="text-sm text-gray-500 mt-1" no_margin>
              Connection status:
              <%= if @plaid_item.status == :active do %>
                <.badge
                  color="success"
                  variant="outline"
                  size="sm"
                  class="font-mono text-[9px] border-emerald-900/30 text-emerald-500"
                >
                  {Atom.to_string(@plaid_item.status)}
                </.badge>
              <% else %>
                <.badge
                  color="danger"
                  variant="outline"
                  size="sm"
                  class="font-mono text-[9px] border-red-900/30 text-red-500"
                >
                  {Atom.to_string(@plaid_item.status)}
                </.badge>
              <% end %>
              <%= if @plaid_item.last_synced_at do %>
                — Last sync: <span class="text-gray-400">{format_datetime(@plaid_item.last_synced_at)}</span>
              <% end %>
            </.p>
          <% else %>
            <.h1 color_class="text-gray-100" no_margin>Connection</.h1>
            <.p class="text-sm text-gray-500 mt-1" no_margin>
              Connection not found.
            </.p>
          <% end %>
        </div>
      </div>

      <.live_component
        module={TransactionTableComponent}
        id="txn-table"
        page={@page}
        params={@tx_params}
        base_url={~p"/connections/#{@plaid_item_id}"}
        scope={:connection}
        categories={@categories}
      />
    </div>
    """
  end

  # --- Helpers ----------------------------------------------------------------

  defp refresh_view(socket) do
    user = socket.assigns.current_user
    plaid_item_id = socket.assigns.plaid_item_id

    socket
    |> assign(
      :categories,
      TransactionLiveHelpers.list_categories(user, %{plaid_item_id: plaid_item_id})
    )
    |> apply_transactions(socket.assigns.tx_params)
  end

  defp apply_transactions(socket, tx_params) do
    case TransactionLiveHelpers.fetch_transactions(
           socket.assigns.current_user,
           tx_params,
           %{plaid_item_id: socket.assigns.plaid_item_id}
         ) do
      {:ok, page} ->
        assign(socket, :page, page)

      {:error, _reason} ->
        put_flash(socket, :error, "We have a... discrepancy. The ledger refused to open.")
    end
  end

  defp load_plaid_item(user, plaid_item_id) do
    case Banking.get_plaid_item_summary_by_id(plaid_item_id, actor: user) do
      {:ok, plaid_item} ->
        plaid_item

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        nil

      {:error, reason} ->
        Logger.warning("[ConnectionLive] get_plaid_item_summary_by_id failed",
          error: inspect(reason)
        )

        nil
    end
  end

  defp page_title(nil), do: "Connection"
  defp page_title(%{institution_name: nil}), do: "Connection"
  defp page_title(%{institution_name: name}), do: name

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
