defmodule FinanceSmithWeb.AccountLive do
  use FinanceSmithWeb, :live_view

  require Logger

  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.BalanceRefresh
  alias FinanceSmithWeb.AshErrorHTML
  alias FinanceSmithWeb.MoneyFormat
  alias FinanceSmithWeb.TransactionLiveHelpers
  alias FinanceSmithWeb.TransactionTableComponent

  @balance_fresh_hours BalanceRefresh.refresh_interval_hours()

  def mount(%{"account_id" => account_id}, _session, socket) do
    if connected?(socket) do
      FinanceSmithWeb.Endpoint.subscribe("transaction:created")
      FinanceSmithWeb.Endpoint.subscribe("transaction:updated")
    end

    user = socket.assigns.current_user
    account = load_account(user, account_id)
    plaid_item = load_plaid_item_summary(user, account)

    socket =
      socket
      |> assign(:page_title, account_title(account))
      |> assign(:current_nav, :dashboard)
      |> assign(:account_id, account_id)
      |> assign(:account, account)
      |> assign(:plaid_item, plaid_item)
      |> assign(:show_balance_warning, false)
      |> assign(:balance_refresh_loading, false)
      |> assign(:balance_fresh_hours, @balance_fresh_hours)
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

  # --- Balance refresh events -----------------------------------------------

  def handle_event("request_balance_refresh", _params, socket) do
    # Reloads the plaid_item summary before checking freshness — the socket's
    # copy can be stale (e.g. a background SyncWorker run advanced
    # last_balance_synced_at while this page was open), which would otherwise
    # send a force: false request straight into an :already_fresh error
    # instead of surfacing the cost advisory.
    user = socket.assigns.current_user
    account = socket.assigns.account
    plaid_item = load_plaid_item_summary(user, account)
    socket = assign(socket, :plaid_item, plaid_item)

    cond do
      socket.assigns.balance_refresh_loading ->
        {:noreply, socket}

      is_nil(plaid_item) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "We have a... discrepancy. No connection found for this account."
         )}

      BalanceRefresh.fresh?(plaid_item.last_balance_synced_at) ->
        {:noreply, assign(socket, :show_balance_warning, true)}

      true ->
        {:noreply, perform_balance_refresh(socket, force: false)}
    end
  end

  def handle_event("confirm_balance_refresh", _params, socket) do
    if socket.assigns.balance_refresh_loading or not socket.assigns.show_balance_warning or
         is_nil(socket.assigns.plaid_item) do
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:show_balance_warning, false)
        |> perform_balance_refresh(force: true)

      {:noreply, socket}
    end
  end

  def handle_event("cancel_balance_refresh", _params, socket) do
    if socket.assigns.balance_refresh_loading do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :show_balance_warning, false)}
    end
  end

  # --- Transaction PubSub ----------------------------------------------------

  def handle_info(%{topic: "transaction:created", payload: %Ash.Notifier.Notification{}}, socket) do
    {:noreply, refresh_view(socket)}
  end

  def handle_info(%{topic: "transaction:updated", payload: %Ash.Notifier.Notification{}}, socket) do
    {:noreply, refresh_view(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def handle_async(:balance_refresh, {:ok, {:ok, _updated_item}}, socket) do
    user = socket.assigns.current_user
    account_id = socket.assigns.account_id
    updated_account = load_account(user, account_id)
    updated_plaid_item = load_plaid_item_summary(user, updated_account)

    socket =
      socket
      |> assign(:balance_refresh_loading, false)
      |> assign(:account, updated_account)
      |> assign(:plaid_item, updated_plaid_item)
      |> put_flash(:info, "Sync complete. Inevitable.")

    {:noreply, socket}
  end

  def handle_async(:balance_refresh, {:ok, {:error, reason}}, socket) do
    Logger.error(
      "[AccountLive] fetch_realtime_balances failed for plaid_item=#{socket.assigns.plaid_item.id}: #{inspect(reason)}"
    )

    user = socket.assigns.current_user
    account_id = socket.assigns.account_id
    updated_account = load_account(user, account_id)
    updated_plaid_item = load_plaid_item_summary(user, updated_account)

    socket =
      socket
      |> assign(:balance_refresh_loading, false)
      |> assign(:account, updated_account)
      |> assign(:plaid_item, updated_plaid_item)

    if updated_plaid_item && BalanceRefresh.fresh?(updated_plaid_item.last_balance_synced_at) do
      # The freshly-reloaded item is within the window — this was a stale
      # force: false request racing a concurrent refresh (e.g. a background
      # SyncWorker run) that already claimed it, not a real failure. Show
      # the cost advisory instead of an "already fresh" error so the user
      # isn't stuck retrying the same rejected request.
      {:noreply, assign(socket, :show_balance_warning, true)}
    else
      # Surface the Ash-level cause (item missing, partial persist, or Plaid
      # API failure) instead of a single generic message, so users and tests
      # can distinguish these outcomes rather than seeing them collapsed into
      # one indistinguishable flash.
      {:noreply, put_flash(socket, :error, AshErrorHTML.format_for_user(reason))}
    end
  end

  def handle_async(:balance_refresh, {:exit, reason}, socket) do
    Logger.error(
      "[AccountLive] balance refresh task exited for plaid_item=#{socket.assigns.plaid_item.id}: #{inspect(reason)}"
    )

    # A process crash carries no Ash error to format, so this keeps the
    # generic fallback message.
    socket =
      socket
      |> assign(:balance_refresh_loading, false)
      |> put_flash(
        :error,
        "We have a... discrepancy. The real-time balance fetch failed."
      )

    {:noreply, socket}
  end

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

        <%= if @account && @plaid_item do %>
          <div class="flex flex-col items-end gap-2">
            <.button
              phx-click="request_balance_refresh"
              phx-disable-with="Fetching..."
              size="sm"
              color="gray"
              variant="outline"
              class="font-mono text-xs border-gray-800 text-gray-400 hover:border-emerald-500/50 hover:text-emerald-400 disabled:opacity-50"
              disabled={@balance_refresh_loading}
            >
              Refresh Balance
            </.button>
            <%= if @plaid_item.last_balance_synced_at do %>
              <p class="font-mono text-[10px] text-gray-600 uppercase tracking-widest">
                Last real-time fetch: {format_datetime(@plaid_item.last_balance_synced_at)}
              </p>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- 24h cost warning confirmation panel --%>
      <%= if @show_balance_warning do %>
        <div class="border border-amber-800/50 bg-amber-950/30 rounded-lg p-4 space-y-3">
          <p class="font-mono text-xs text-amber-400 uppercase tracking-widest">
            Cost advisory
          </p>
          <p class="text-sm text-gray-300">
            Balances were updated less than {@balance_fresh_hours} hours ago. Requesting a real-time
            update now will incur additional API charges. Proceed?
          </p>
          <div class="flex items-center gap-3">
            <.button
              phx-click="confirm_balance_refresh"
              phx-disable-with="Fetching..."
              size="sm"
              color="gray"
              variant="outline"
              class="font-mono text-xs border-amber-800/50 text-amber-400 hover:border-amber-600 hover:text-amber-300 disabled:opacity-50"
              disabled={@balance_refresh_loading}
            >
              Proceed
            </.button>
            <.button
              phx-click="cancel_balance_refresh"
              size="sm"
              color="gray"
              variant="outline"
              class="font-mono text-xs border-gray-800 text-gray-500 hover:border-gray-600 hover:text-gray-300 disabled:opacity-50"
              disabled={@balance_refresh_loading}
            >
              Cancel
            </.button>
          </div>
        </div>
      <% end %>

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

  defp perform_balance_refresh(socket, opts) do
    force? = Keyword.get(opts, :force, false)
    user = socket.assigns.current_user
    plaid_item = socket.assigns.plaid_item

    socket
    |> assign(:balance_refresh_loading, true)
    |> start_async(:balance_refresh, fn ->
      Banking.fetch_realtime_balances(plaid_item.id, %{force: force?}, actor: user)
    end)
  end

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

  # Loads the parent PlaidItem summary (token-free, :read_for_ui) for the
  # account's connection. Returns nil if the account is nil or the item is
  # inaccessible. last_balance_synced_at is included in :read_for_ui.
  defp load_plaid_item_summary(_user, nil), do: nil

  defp load_plaid_item_summary(user, account) do
    case Banking.get_plaid_item_summary_by_id(account.plaid_item_id, actor: user) do
      {:ok, plaid_item} ->
        plaid_item

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        nil

      {:error, reason} ->
        Logger.warning("[AccountLive] get_plaid_item_summary_by_id failed",
          error: inspect(reason)
        )

        nil
    end
  end

  defp account_title(nil), do: "Account"
  defp account_title(%{name: name, mask: nil}), do: name
  defp account_title(%{name: name, mask: mask}), do: "#{name} ···#{mask}"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
