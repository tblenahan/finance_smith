defmodule FinanceSmithWeb.ConnectionLive do
  use FinanceSmithWeb, :live_view

  alias FinanceSmith.Banking
  alias FinanceSmithWeb.{TransactionLiveHelpers, TransactionTableComponent}

  require Ash.Query
  require Logger

  def mount(%{"institution_name" => institution_name}, _session, socket) do
    if connected?(socket) do
      FinanceSmithWeb.Endpoint.subscribe("transaction:created")
    end

    plaid_item = load_plaid_item(socket.assigns.current_user, institution_name)

    socket =
      socket
      |> assign(:page_title, institution_name)
      |> assign(:current_nav, :dashboard)
      |> assign(:institution_name, institution_name)
      |> assign(:plaid_item, plaid_item)
      |> assign(:page, nil)
      |> assign(:tx_params, TransactionLiveHelpers.default_tx_params())

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    tx_params = TransactionLiveHelpers.parse_tx_params(params)

    page =
      TransactionLiveHelpers.fetch_transactions(
        socket.assigns.current_user,
        tx_params,
        %{institution_name: socket.assigns.institution_name}
      )

    {:noreply,
     socket
     |> assign(:tx_params, tx_params)
     |> assign(:page, page)}
  end

  def handle_info(%{topic: "transaction:created", payload: %Ash.Notifier.Notification{}}, socket) do
    page =
      TransactionLiveHelpers.fetch_transactions(
        socket.assigns.current_user,
        socket.assigns.tx_params,
        %{institution_name: socket.assigns.institution_name}
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
          <.h1 color_class="text-gray-100" no_margin>{@institution_name}</.h1>
          <.p class="text-sm text-gray-500 mt-1" no_margin>
            <%= if @plaid_item do %>
              Connection status:
              <span class={if @plaid_item.status == :active, do: "text-emerald-500", else: "text-red-500"}>
                {Atom.to_string(@plaid_item.status)}
              </span>
              <%= if @plaid_item.last_synced_at do %>
                — Last sync: <span class="text-gray-400">{format_datetime(@plaid_item.last_synced_at)}</span>
              <% end %>
            <% else %>
              Connection not found.
            <% end %>
          </.p>
        </div>
      </div>

      <.live_component
        module={TransactionTableComponent}
        id="txn-table"
        page={@page}
        params={@tx_params}
        base_url={~p"/connections/#{@institution_name}"}
        scope={:connection}
      />
    </div>
    """
  end

  # --- Helpers ----------------------------------------------------------------

  defp load_plaid_item(user, institution_name) do
    Banking.PlaidItem
    |> Ash.Query.filter(user_id == ^user.id and institution_name == ^institution_name)
    |> Ash.read_one(actor: user)
    |> case do
      {:ok, item} -> item
      _ -> nil
    end
  end

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
