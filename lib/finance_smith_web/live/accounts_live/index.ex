defmodule FinanceSmithWeb.AccountsLive.Index do
  use FinanceSmithWeb, :live_view

  import Ash.Expr

  alias FinanceSmith.Banking
  alias FinanceSmith.Identity
  alias FinanceSmithWeb.MoneyFormat
  alias FinanceSmithWeb.ViewScope

  require Logger

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    view_scope = ViewScope.default_scope(user)
    scope = ViewScope.parse_scope(view_scope)

    if connected?(socket) do
      FinanceSmithWeb.Endpoint.subscribe("plaid_item:sync_complete:#{user.id}")
    end

    kpis = fetch_scoped_kpis(scope, user)
    accounts = fetch_accounts(scope, user)

    socket =
      socket
      |> assign(:page_title, "Accounts")
      |> assign(:current_nav, :accounts)
      |> assign(:current_user, user)
      |> assign(:view_scope, view_scope)
      |> assign(:scope, scope)
      |> assign(:accounts, accounts)
      |> assign(kpis)

    {:ok, socket}
  end

  def handle_event("change_view_scope", %{"scope" => raw_scope}, socket)
      when is_binary(raw_scope) do
    case ViewScope.validate_scope(raw_scope) do
      {:ok, view_scope} ->
        {:noreply, refresh_scope_data(socket, view_scope)}

      :error ->
        {:noreply, put_flash(socket, :error, "We have a... discrepancy. The scope is invalid.")}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "complete_sync"}, socket) do
    socket =
      socket
      |> refresh_scope_data(socket.assigns.view_scope)
      |> put_flash(:info, "Sync complete. Inevitable.")

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex items-end justify-between border-b border-gray-800 pb-4">
        <div>
          <.h1 color_class="text-gray-100" no_margin>Accounts</.h1>
          <.p class="text-sm text-gray-500 mt-1" no_margin>
            Financial position. Every variable accounted for.
          </.p>
        </div>
        <form phx-change="change_view_scope" class="flex items-center">
          <.input
            type="select"
            name="scope"
            id="accounts-scope-select"
            value={@view_scope}
            options={ViewScope.scope_options(@current_user)}
            class="bg-gray-900 border border-gray-800 rounded text-gray-400 font-mono text-[10px] uppercase tracking-wider px-2 py-1.5 focus:outline-none focus:border-gray-600 cursor-pointer"
          />
        </form>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 border border-gray-800 rounded-lg overflow-hidden bg-gray-950/50">
        <div class="p-5 border-b sm:border-b lg:border-b-0 lg:border-r border-gray-800">
          <div class="flex items-center justify-between mb-2">
            <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">
              30-Day Inflow
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
          <p class="text-3xl font-mono text-gray-100 tracking-tight">
            {MoneyFormat.format(@scope_inflow_30d, style: :signed, nil_display: "$0.00")}
          </p>
        </div>

        <div class="p-5 border-b sm:border-b lg:border-b-0 lg:border-r border-gray-800">
          <div class="flex items-center justify-between mb-2">
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
          <p class="text-3xl font-mono text-gray-100 tracking-tight">
            {MoneyFormat.format(@scope_outflow_30d, nil_display: "$0.00")}
          </p>
        </div>

        <div class="p-5 border-b sm:border-b lg:border-b-0 lg:border-r border-gray-800">
          <div class="flex items-center justify-between mb-2">
            <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">
              Active Data Streams
            </p>
            <%= if @scope_streams_count > 0 do %>
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
          <p class="text-3xl font-mono text-gray-100 tracking-tight">
            {@scope_streams_count}
          </p>
        </div>

        <div class="p-5 border-b sm:border-r lg:border-b-0 lg:border-r border-gray-800">
          <div class="flex items-center justify-between mb-2">
            <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">
              Total Credit
            </p>
            <%= if @scope_total_credit > 0 do %>
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
          <p class="text-3xl font-mono text-gray-100 tracking-tight">
            {MoneyFormat.format(@scope_total_credit, nil_display: "$0.00")}
          </p>
        </div>

        <div class="p-5">
          <div class="flex items-center justify-between mb-2">
            <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">
              Available Credit
            </p>
            <%= if @scope_available_credit > 0 do %>
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
          <p class={"text-3xl font-mono tracking-tight #{if @scope_available_credit > 0, do: "text-emerald-500", else: "text-gray-100"}"}>
            {MoneyFormat.format(@scope_available_credit, nil_display: "$0.00")}
          </p>
        </div>
      </div>

      <section class="space-y-4">
        <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">
          Connected Accounts
        </p>

        <%= if @accounts == [] do %>
          <p class="text-sm text-gray-500 border border-gray-800 rounded-lg bg-gray-950/50 px-5 py-8 text-center">
            There is no data here. Only an anomaly.
          </p>
        <% else %>
          <ul class="border border-gray-800 rounded-lg overflow-hidden bg-gray-950/50 divide-y divide-gray-800">
            <%= for account <- @accounts do %>
              <li>
                <.link
                  navigate={~p"/accounts/#{account.id}"}
                  class="flex items-center justify-between gap-4 px-5 py-4 hover:bg-gray-900/50 transition-colors group"
                >
                  <div class="min-w-0">
                    <p class="text-gray-100 group-hover:text-emerald-400 transition-colors truncate">
                      {account.name}
                      <%= if account.mask do %>
                        <span class="text-gray-500">···{account.mask}</span>
                      <% end %>
                    </p>
                    <p class="font-mono text-[10px] uppercase tracking-widest text-gray-600 mt-0.5">
                      {account.type}<%= if account.subtype do %>
                        <span class="text-gray-700"> / {account.subtype}</span>
                      <% end %>
                    </p>
                  </div>
                  <div class="flex items-center gap-4 shrink-0">
                    <span class="font-mono text-sm text-gray-300">
                      {MoneyFormat.format(account.current_balance)}
                    </span>
                    <span class="font-mono text-[10px] uppercase tracking-widest text-gray-600 group-hover:text-gray-400 transition-colors">
                      View →
                    </span>
                  </div>
                </.link>
              </li>
            <% end %>
          </ul>
        <% end %>
      </section>
    </div>
    """
  end

  # --- Scoped KPIs -------------------------------------------------------

  defp fetch_scoped_kpis(:personal, user) do
    u =
      Identity.get_user_with_kpis!(user.id,
        load: [
          :outflow_30d,
          :inflow_30d,
          :active_streams_count,
          :total_credit,
          :total_available_credit
        ],
        actor: user
      )

    %{
      scope_outflow_30d: u.outflow_30d,
      scope_inflow_30d: u.inflow_30d,
      scope_streams_count: u.active_streams_count,
      scope_total_credit: u.total_credit,
      scope_available_credit: u.total_available_credit
    }
  end

  defp fetch_scoped_kpis(:household, user) do
    h =
      Identity.get_household_with_kpis!(user.household_id,
        load: [
          :outflow_30d,
          :inflow_30d,
          :active_streams_count,
          :total_credit,
          :total_available_credit
        ],
        actor: user
      )

    %{
      scope_outflow_30d: h.outflow_30d,
      scope_inflow_30d: h.inflow_30d,
      scope_streams_count: h.active_streams_count,
      scope_total_credit: h.total_credit,
      scope_available_credit: h.total_available_credit
    }
  end

  defp refresh_scope_data(socket, view_scope) do
    scope = ViewScope.parse_scope(view_scope)
    user = socket.assigns.current_user
    kpis = fetch_scoped_kpis(scope, user)
    accounts = fetch_accounts(scope, user)

    socket
    |> assign(:view_scope, view_scope)
    |> assign(:scope, scope)
    |> assign(:accounts, accounts)
    |> assign(kpis)
  end

  defp fetch_accounts(:personal, user) do
    case Banking.list_accounts(
           actor: user,
           query: [
             filter: expr(status == :active and plaid_item.user_id == ^user.id),
             sort: [name: :asc]
           ]
         ) do
      {:ok, accounts} ->
        accounts

      {:error, reason} ->
        Logger.warning("[AccountsLive.Index] list_accounts failed", error: inspect(reason))
        []
    end
  end

  defp fetch_accounts(:household, user) do
    case Banking.list_accounts(
           actor: user,
           query: [
             filter: [status: :active],
             sort: [name: :asc]
           ]
         ) do
      {:ok, accounts} ->
        accounts

      {:error, reason} ->
        Logger.warning("[AccountsLive.Index] list_accounts failed", error: inspect(reason))
        []
    end
  end
end
