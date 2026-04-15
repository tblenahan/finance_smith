defmodule FinanceSmithWeb.AccountLive do
  use FinanceSmithWeb, :live_view

  alias FinanceSmith.Banking
  alias FinanceSmithWeb.{TransactionLiveHelpers, TransactionTableComponent}

  require Ash.Query
  require Logger

  def mount(%{"account_id" => account_id}, _session, socket) do
    if connected?(socket) do
      FinanceSmithWeb.Endpoint.subscribe("transaction:created")
    end

    account = load_account(socket.assigns.current_user, account_id)

    socket =
      socket
      |> assign(:page_title, account_title(account))
      |> assign(:current_nav, :dashboard)
      |> assign(:account_id, account_id)
      |> assign(:account, account)
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
        %{account_id: socket.assigns.account_id}
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
        %{account_id: socket.assigns.account_id}
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
              <span class="font-mono text-gray-300">{format_balance(@account.current_balance)}</span>
            </.p>
          <% else %>
            <.h1 color_class="text-gray-100" no_margin>Account</.h1>
            <.p class="text-sm text-gray-500 mt-1" no_margin>
              The record has fulfilled its purpose. Or was never found.
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
      />
    </div>
    """
  end

  # --- Helpers ----------------------------------------------------------------

  defp load_account(user, account_id) do
    require Ash.Query

    Banking.Account
    |> Ash.Query.filter(id == ^account_id and plaid_item.user_id == ^user.id)
    |> Ash.Query.load(:plaid_item)
    |> Ash.read_one(actor: user, authorize?: false)
    |> case do
      {:ok, account} -> account
      _ -> nil
    end
  end

  defp account_title(nil), do: "Account"
  defp account_title(%{name: name, mask: nil}), do: name
  defp account_title(%{name: name, mask: mask}), do: "#{name} ···#{mask}"

  defp format_balance(nil), do: "—"

  defp format_balance(cents) when is_integer(cents) do
    dollars = abs(cents) / 100
    sign = if cents < 0, do: "-", else: ""
    "#{sign}$#{:erlang.float_to_binary(dollars, [{:decimals, 2}])}"
  end
end
