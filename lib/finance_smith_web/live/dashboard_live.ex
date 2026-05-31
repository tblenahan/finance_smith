defmodule FinanceSmithWeb.DashboardLive do
  use FinanceSmithWeb, :live_view

  alias FinanceSmith.Banking
  alias FinanceSmith.DataLake.SyncWorker
  alias FinanceSmith.Identity
  alias FinanceSmithWeb.MoneyFormat
  alias FinanceSmithWeb.TransactionLiveHelpers
  alias FinanceSmithWeb.TransactionTableComponent
  alias FinanceSmithWeb.ViewScope

  require Logger

  @timeframes ["1W", "1M", "3M", "6M", "9M", "1Y", "All"]
  @default_timeframe "1M"

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    view_scope = ViewScope.default_scope(user)
    scope = ViewScope.parse_scope(view_scope)

    if connected?(socket) do
      FinanceSmithWeb.Endpoint.subscribe("plaid_item:sync_complete:#{user.id}")
      FinanceSmithWeb.Endpoint.subscribe("transaction:created")
      FinanceSmithWeb.Endpoint.subscribe("transaction:updated")
    end

    kpis = fetch_scoped_kpis(scope, user)

    socket =
      socket
      |> assign(:page_title, "The Ledger")
      |> assign(:current_nav, :dashboard)
      |> assign(:current_user, user)
      |> assign(:page, nil)
      |> assign(:timeframe, @default_timeframe)
      |> assign(:timeframes, @timeframes)
      |> assign(:view_scope, view_scope)
      |> assign(:scope, scope)
      |> assign(kpis)
      |> assign(:tx_params, TransactionLiveHelpers.default_tx_params())
      |> assign(
        :categories,
        TransactionLiveHelpers.list_categories(user, scope_filters(scope, user))
      )

    socket =
      if connected?(socket) do
        push_chart_data(socket, @default_timeframe, scope)
      else
        socket
      end

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

  def handle_event("sync_accounts", _params, socket) do
    user = socket.assigns.current_user
    items = Banking.list_active_plaid_items!(actor: user)

    if items == [] do
      {:noreply, put_flash(socket, :info, "No active integrations. Connect a data source first.")}
    else
      Enum.each(items, fn %{id: id} -> SyncWorker.enqueue(id) end)

      {:noreply,
       put_flash(socket, :info, "Synchronization initiated. The ledger will update shortly.")}
    end
  end

  def handle_event("set_timeframe", %{"range" => range}, socket)
      when range in @timeframes do
    socket =
      socket
      |> assign(:timeframe, range)
      |> push_chart_data(range, socket.assigns.scope)

    {:noreply, socket}
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

  def handle_info(%{topic: "transaction:created", payload: %Ash.Notifier.Notification{}}, socket) do
    {:noreply, refresh_scope_data(socket, socket.assigns.view_scope)}
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
      <div id="plaid-link-hook" phx-hook="PlaidLink"></div>

      <div class="flex items-end justify-between border-b border-gray-800 pb-4">
        <div>
          <.h1 color_class="text-gray-100" no_margin>The Ledger</.h1>
          <.p class="text-sm text-gray-500 mt-1" no_margin>
            Your financial data, consolidated. Inevitable.
          </.p>
        </div>
        <div class="flex items-center gap-2">
          <.button
            phx-click="sync_accounts"
            phx-disable-with="Syncing..."
            size="sm"
            color="gray"
            variant="outline"
            class="font-mono text-xs border-gray-800 text-gray-400 hover:border-gray-600 hover:text-gray-200"
          >
            Sync Accounts
          </.button>

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
      </div>

      <div class="grid grid-cols-1 md:grid-cols-3 border border-gray-800 rounded-lg overflow-hidden bg-gray-950/50">
        <div class="p-5 border-b md:border-b-0 md:border-r border-gray-800">
          <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">Net Worth</p>
          <p class="mt-2 text-3xl font-mono text-gray-100 tracking-tight">
            {MoneyFormat.format(@scope_net_worth, nil_display: "$0.00")}
          </p>
        </div>

        <div class="p-5 border-b md:border-b-0 md:border-r border-gray-800">
          <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">Total Assets</p>
          <p class="mt-2 text-3xl font-mono text-gray-100 tracking-tight">
            {MoneyFormat.format(@scope_total_assets, nil_display: "$0.00")}
          </p>
        </div>

        <div class="p-5">
          <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">
            Total Liabilities
          </p>
          <p class="mt-2 text-3xl font-mono text-gray-100 tracking-tight">
            {MoneyFormat.format(@scope_total_liabilities, nil_display: "$0.00")}
          </p>
        </div>
      </div>

      <section class="space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest shrink-0">
            Cashflow Analysis
          </p>

          <div class="flex flex-wrap items-center gap-3">
            <%!-- Scope selector --%>
            <form phx-change="change_view_scope" class="flex items-center">
              <.input
                type="select"
                name="scope"
                id="view-scope-select"
                value={@view_scope}
                options={ViewScope.scope_options(@current_user)}
                class="bg-gray-900 border border-gray-800 rounded text-gray-400 font-mono text-[10px] uppercase tracking-wider px-2 py-1.5 focus:outline-none focus:border-gray-600 cursor-pointer"
              />
            </form>

            <%!-- Timeframe tabs --%>
            <div
              role="tablist"
              class="flex items-center gap-1 font-mono text-[10px] uppercase tracking-widest"
            >
              <%= for range <- @timeframes do %>
                <button
                  type="button"
                  role="tab"
                  aria-selected={@timeframe == range}
                  phx-click="set_timeframe"
                  phx-value-range={range}
                  class={[
                    "px-3 py-1.5 border transition-colors",
                    (@timeframe == range &&
                       "border-emerald-500 bg-emerald-500/10 text-emerald-400") ||
                      "border-gray-800 text-gray-500 hover:border-gray-700 hover:text-gray-300"
                  ]}
                >
                  {range}
                </button>
              <% end %>
            </div>
          </div>
        </div>

        <div
          id="chart-splitter-container"
          phx-hook="Splitter"
          phx-update="ignore"
          class="flex w-full h-96 relative"
        >
          <div id="left-panel" style="width: 66%;" class="min-w-0 h-full">
            <div class="h-full border border-gray-800 rounded-lg bg-gray-950/50 p-5 flex flex-col">
              <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest mb-3">
                Inflow vs Outflow
              </p>
              <div
                id="cashflow-line-chart"
                phx-hook="Chart"
                phx-update="ignore"
                class="w-full flex-1"
              ></div>
            </div>
          </div>

          <div
            id="resizer"
            role="separator"
            aria-label="Resize panels"
            aria-orientation="vertical"
            tabindex="0"
            class="w-4 cursor-col-resize bg-gray-800 hover:bg-gray-700 flex-shrink-0 transition-colors z-10 mx-1 rounded"
          >
          </div>

          <div id="right-panel" style="width: 34%;" class="min-w-0 h-full">
            <div class="h-full border border-gray-800 rounded-lg bg-gray-950/50 p-5 flex flex-col">
              <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest mb-3">
                Outflow Categories
              </p>
              <div
                id="outflow-pie-chart"
                phx-hook="Chart"
                phx-update="ignore"
                class="w-full flex-1"
              ></div>
            </div>
          </div>
        </div>
      </section>

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
    user = socket.assigns.current_user
    filters = scope_filters(socket.assigns.scope, user)

    case TransactionLiveHelpers.fetch_transactions(user, tx_params, filters) do
      {:ok, page} ->
        assign(socket, :page, page)

      {:error, _reason} ->
        put_flash(socket, :error, "We have a... discrepancy. The ledger refused to open.")
    end
  end

  defp create_link_token(user) do
    redirect_uri = FinanceSmithWeb.Endpoint.url() <> "/oauth/callback/plaid"

    plaid_env =
      if Application.get_env(:plaid, :root_uri) =~ "sandbox", do: "sandbox", else: "production"

    Logger.debug("[DashboardLive] Plaid link token requested",
      plaid_env: plaid_env,
      redirect_uri: redirect_uri
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

  defp scope_filters(:household, _user), do: %{}
  defp scope_filters(:personal, user), do: %{user_id: user.id}

  # --- Scoped KPIs -------------------------------------------------------

  defp fetch_scoped_kpis(:personal, user) do
    u =
      Identity.get_user_with_kpis!(user.id,
        load: [:total_assets, :total_liabilities],
        actor: user
      )

    %{
      scope_net_worth: u.total_assets - u.total_liabilities,
      scope_total_assets: u.total_assets,
      scope_total_liabilities: u.total_liabilities
    }
  end

  defp fetch_scoped_kpis(:household, user) do
    h =
      Identity.get_household_with_kpis!(user.household_id,
        load: [:total_assets, :total_liabilities],
        actor: user
      )

    %{
      scope_net_worth: h.total_assets - h.total_liabilities,
      scope_total_assets: h.total_assets,
      scope_total_liabilities: h.total_liabilities
    }
  end

  defp refresh_scope_data(socket, view_scope) do
    scope = ViewScope.parse_scope(view_scope)
    user = socket.assigns.current_user
    kpis = fetch_scoped_kpis(scope, user)

    socket
    |> assign(:view_scope, view_scope)
    |> assign(:scope, scope)
    |> assign(kpis)
    |> assign(
      :categories,
      TransactionLiveHelpers.list_categories(user, scope_filters(scope, user))
    )
    |> apply_transactions(socket.assigns.tx_params)
    |> push_chart_data(socket.assigns.timeframe, scope)
  end

  # --- Chart data -------------------------------------------------------

  defp start_date_for(timeframe) do
    today = Date.utc_today()

    case timeframe do
      "1W" -> Date.add(today, -6)
      "1M" -> Date.add(today, -29)
      "3M" -> Date.add(today, -89)
      "6M" -> Date.add(today, -179)
      "9M" -> Date.add(today, -269)
      "1Y" -> Date.add(today, -364)
      # "All" passes nil so the chart spans the full transaction history.
      # The 10,000-row cap in Transaction.for_chart bounds memory use.
      "All" -> nil
      _ -> Date.add(today, -29)
    end
  end

  defp fetch_financial_data(timeframe, user, scope) do
    start_date = start_date_for(timeframe)
    today = Date.utc_today()

    chart_filters = scope_filters(scope, user) |> Map.put(:date_from, start_date)

    rows = Banking.list_transactions_for_chart!(chart_filters, actor: user)

    if rows == [] do
      :empty
    else
      %{
        cashflow: build_cashflow_series(rows, start_date || earliest_date(rows, today), today),
        categories: build_outflow_categories(rows)
      }
    end
  end

  defp earliest_date([], today), do: today
  defp earliest_date(rows, _today), do: Enum.min_by(rows, & &1.date, Date).date

  defp build_cashflow_series(rows, start_date, today) do
    buckets =
      Enum.reduce(rows, %{}, fn %{date: d, amount: cents}, acc ->
        {inflow_delta, outflow_delta} =
          cond do
            is_nil(cents) -> {0, 0}
            cents > 0 -> {0, cents}
            cents < 0 -> {-cents, 0}
            true -> {0, 0}
          end

        Map.update(acc, d, {inflow_delta, outflow_delta}, fn {i, o} ->
          {i + inflow_delta, o + outflow_delta}
        end)
      end)

    dates = Date.range(start_date, today) |> Enum.to_list()

    labels = Enum.map(dates, &Calendar.strftime(&1, "%b %d"))

    inflow =
      Enum.map(dates, fn d ->
        {i, _o} = Map.get(buckets, d, {0, 0})
        chart_series_point(i / 100.0)
      end)

    outflow =
      Enum.map(dates, fn d ->
        {_i, o} = Map.get(buckets, d, {0, 0})
        chart_series_point(o / 100.0)
      end)

    %{labels: labels, inflow: inflow, outflow: outflow}
  end

  # ECharts still plots y=0 for quiet days (line continuity) but hides the dot.
  defp chart_series_point(0.0), do: %{value: 0.0, symbol: "none", symbolSize: 0}
  defp chart_series_point(value) when is_float(value), do: value

  defp build_outflow_categories(rows) do
    rows
    |> Stream.filter(fn %{amount: a} -> is_integer(a) and a > 0 end)
    |> Enum.reduce(%{}, fn txn, acc ->
      name = meta_category_label(txn)
      Map.update(acc, name, txn.amount, &(&1 + txn.amount))
    end)
    |> Enum.map(fn {name, cents} ->
      %{name: name, value: cents / 100.0, readable_name: name}
    end)
    |> Enum.sort_by(& &1.value, :desc)
  end

  defp meta_category_label(%{meta_category_name: name}) when is_binary(name), do: name
  defp meta_category_label(%{meta_category_id: nil}), do: "—"
  defp meta_category_label(_), do: "Uncategorized"

  defp push_chart_data(socket, timeframe, scope) do
    case fetch_financial_data(timeframe, socket.assigns.current_user, scope) do
      :empty ->
        socket
        |> push_event("update-chart-cashflow-line-chart", %{empty: true})
        |> push_event("update-chart-outflow-pie-chart", %{empty: true})

      %{cashflow: %{labels: labels, inflow: inflow, outflow: outflow}, categories: pie_data} ->
        line_config = %{
          tooltip: %{
            trigger: "axis",
            backgroundColor: "#030712",
            borderColor: "#1f2937",
            textStyle: %{color: "#e5e7eb", fontFamily: "monospace"}
          },
          legend: %{
            data: ["Inflow", "Outflow"],
            textStyle: %{color: "#9ca3af", fontFamily: "monospace"},
            top: 4
          },
          grid: %{containLabel: true, left: 8, right: 16, top: 36, bottom: 24},
          xAxis: %{
            type: "category",
            data: labels,
            axisLine: %{lineStyle: %{color: "#374151"}},
            axisLabel: %{color: "#6b7280", fontFamily: "monospace"}
          },
          yAxis: %{
            type: "value",
            axisLabel: %{formatter: "${value}", color: "#6b7280", fontFamily: "monospace"},
            splitLine: %{lineStyle: %{color: "#1f2937"}}
          },
          series: [
            %{
              name: "Inflow",
              type: "line",
              smooth: true,
              data: inflow,
              lineStyle: %{color: "#10b981"},
              itemStyle: %{color: "#10b981"},
              areaStyle: %{color: "rgba(16,185,129,0.12)"}
            },
            %{
              name: "Outflow",
              type: "line",
              smooth: true,
              data: outflow,
              lineStyle: %{color: "#f59e0b"},
              itemStyle: %{color: "#f59e0b"},
              areaStyle: %{color: "rgba(245,158,11,0.10)"}
            }
          ]
        }

        pie_config = %{
          tooltip: %{
            trigger: "item",
            backgroundColor: "#030712",
            borderColor: "#1f2937",
            textStyle: %{color: "#e5e7eb", fontFamily: "monospace"}
          },
          series: [
            %{
              name: "Outflow",
              type: "pie",
              radius: ["35%", "60%"],
              center: ["40%", "50%"],
              avoidLabelOverlap: true,
              itemStyle: %{borderColor: "#030712", borderWidth: 2},
              label: %{
                show: true,
                formatter: "{b}",
                color: "#9ca3af",
                fontFamily: "monospace"
              },
              data: pie_data,
              color: ["#10b981", "#f59e0b", "#3b82f6", "#a855f7", "#ef4444", "#6b7280"]
            }
          ]
        }

        socket
        |> push_event("update-chart-cashflow-line-chart", line_config)
        |> push_event("update-chart-outflow-pie-chart", pie_config)
    end
  end
end
