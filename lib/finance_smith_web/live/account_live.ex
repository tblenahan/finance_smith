defmodule FinanceSmithWeb.AccountLive do
  use FinanceSmithWeb, :live_view

  require Logger

  alias FinanceSmith.Banking
  alias FinanceSmithWeb.MoneyFormat
  alias FinanceSmithWeb.TransactionLiveHelpers
  alias FinanceSmithWeb.TransactionTableComponent

  def mount(%{"account_id" => account_id}, _session, socket) do
    if connected?(socket) do
      FinanceSmithWeb.Endpoint.subscribe("transaction:created")
      FinanceSmithWeb.Endpoint.subscribe("transaction:updated")
    end

    account = load_account(socket.assigns.current_user, account_id)
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:page_title, account_title(account))
      |> assign(:current_nav, :dashboard)
      |> assign(:account_id, account_id)
      |> assign(:account, account)
      |> assign(:page, nil)
      |> assign(:tx_params, TransactionLiveHelpers.default_tx_params())
      |> assign(
        :categories,
        TransactionLiveHelpers.list_categories(user, %{account_id: account_id})
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
          <%= if @account do %>
            <.h1 color_class="text-gray-100" no_margin>
              {@account.name}
              <%= if @account.mask do %>
                <span class="text-gray-500">···{@account.mask}</span>
              <% end %>
            </.h1>
            <.p class="text-sm text-gray-500 mt-1" no_margin>
              <span class="font-mono text-[10px] uppercase tracking-widest">{@account.type}</span>
              <%= if @account.subtype do %>
                <span class="text-gray-600">/ {@account.subtype}</span>
              <% end %>
              — Balance:
              <span class="font-mono text-gray-300">{MoneyFormat.format(@account.current_balance)}</span>
            </.p>
          <% else %>
            <.h1 color_class="text-gray-100" no_margin>Account</.h1>
            <.p class="text-sm text-gray-500 mt-1" no_margin>
              Account not found.
            </.p>
          <% end %>
        </div>
      </div>

      <.live_component
        module={TransactionTableComponent}
        id="txn-table"
        page={@page}
        params={@tx_params}
        base_url={~p"/accounts/#{@account_id}"}
        scope={:account}
        categories={@categories}
      />
    </div>
    """
  end

  # --- Helpers ----------------------------------------------------------------

  defp refresh_view(socket) do
    user = socket.assigns.current_user
    account_id = socket.assigns.account_id

    socket
    |> assign(
      :categories,
      TransactionLiveHelpers.list_categories(user, %{account_id: account_id})
    )
    |> apply_transactions(socket.assigns.tx_params)
  end

  defp apply_transactions(socket, tx_params) do
    case TransactionLiveHelpers.fetch_transactions(
           socket.assigns.current_user,
           tx_params,
           %{account_id: socket.assigns.account_id}
         ) do
      {:ok, page} ->
        assign(socket, :page, page)

      {:error, _reason} ->
        put_flash(socket, :error, "We have a... discrepancy. The ledger refused to open.")
    end
  end

  defp load_account(user, account_id) do
    case Banking.get_account_by_id(account_id, actor: user) do
      {:ok, account} ->
        account

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        nil

      {:error, reason} ->
        Logger.warning("[AccountLive] get_account_by_id failed", error: inspect(reason))
        nil
    end
  end

  defp account_title(nil), do: "Account"
  defp account_title(%{name: name, mask: nil}), do: name
  defp account_title(%{name: name, mask: mask}), do: "#{name} ···#{mask}"
end
