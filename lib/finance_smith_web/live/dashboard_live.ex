defmodule FinanceSmithWeb.DashboardLive do
  use FinanceSmithWeb, :live_view

  alias FinanceSmith.Banking

  require Logger

  def mount(_params, _session, socket) do
    if connected?(socket) do
      FinanceSmithWeb.Endpoint.subscribe(
        "plaid_item:sync_complete:#{socket.assigns.current_user.id}"
      )
    end

    socket =
      socket
      |> assign(:page_title, "The Ledger")
      |> assign(:current_nav, :dashboard)
      |> AshPhoenix.LiveView.keep_live(
        :transactions,
        fn socket ->
          Banking.list_recent_transactions!(actor: socket.assigns.current_user)
        end,
        subscribe: "transaction:created"
      )

    {:ok, socket}
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
    {:noreply,
     socket
     |> put_flash(:info, "Sync complete. Inevitable.")
     |> AshPhoenix.LiveView.handle_live(:refetch, :transactions)}
  end

  def handle_info(%{topic: topic, payload: %Ash.Notifier.Notification{}}, socket) do
    {:noreply, AshPhoenix.LiveView.handle_live(socket, topic, :transactions)}
  end

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
            <.badge color="gray" variant="outline" size="sm" class="font-mono text-[9px] border-gray-800 text-gray-600">Uncalculated</.badge>
          </div>
          <p class="mt-2 text-3xl font-mono text-gray-100 tracking-tight">$0.00</p>
        </div>

        <div class="p-5 border-b md:border-b-0 md:border-r border-gray-800">
          <div class="flex items-center justify-between">
            <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">30-Day Outflow</p>
            <.badge color="gray" variant="outline" size="sm" class="font-mono text-[9px] border-gray-800 text-gray-600">Uncalculated</.badge>
          </div>
          <p class="mt-2 text-3xl font-mono text-gray-100 tracking-tight">$0.00</p>
        </div>

        <div class="p-5">
          <div class="flex items-center justify-between">
            <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">Active Data Streams</p>
            <.badge color="danger" variant="outline" size="sm" class="font-mono text-[9px] border-red-900/30 text-red-500">Severed</.badge>
          </div>
          <p class="mt-2 text-3xl font-mono text-gray-100 tracking-tight">0</p>
        </div>
      </div>

      <div class="border border-gray-800 rounded-lg bg-gray-950 overflow-hidden">
        <div class="border-b border-gray-800 px-4 py-3 bg-black">
          <.h3 color_class="text-gray-300" class="text-sm font-mono tracking-wide" no_margin>Recent Entries</.h3>
        </div>

        <div class="w-full overflow-x-auto">
          <table class="w-full text-left text-sm whitespace-nowrap">
            <thead class="bg-gray-900/50 font-mono text-[10px] uppercase tracking-wider text-gray-500 border-b border-gray-800">
              <tr>
                <th scope="col" class="px-4 py-3">Date</th>
                <th scope="col" class="px-4 py-3">Merchant</th>
                <th scope="col" class="px-4 py-3">Category</th>
                <th scope="col" class="px-4 py-3">Account</th>
                <th scope="col" class="px-4 py-3 text-right">Amount</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-800/50">
              <%= if @transactions == [] do %>
                <tr>
                  <td colspan="5" class="px-4 py-16 text-center">
                    <p class="font-mono text-sm text-gray-500">There is no data here. Only an anomaly.</p>
                    <p class="mt-2 text-xs font-mono text-gray-600">Initialize a Plaid connection to populate the ledger.</p>
                  </td>
                </tr>
              <% else %>
                <%= for transaction <- @transactions do %>
                  <tr class="hover:bg-gray-900/30 transition-colors">
                    <td class="px-4 py-3 font-mono text-xs text-gray-400">
                      <%= Calendar.strftime(transaction.date, "%Y-%m-%d") %>
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-200">
                      <%= transaction.merchant_name || "—" %>
                    </td>
                    <td class="px-4 py-3 font-mono text-[10px] uppercase tracking-wider text-gray-500">
                      <%= format_category(transaction.category) %>
                    </td>
                    <td class="px-4 py-3 text-xs text-gray-400">
                      <%= transaction.account.name %>
                    </td>
                    <td class={"px-4 py-3 font-mono text-sm text-right #{amount_class(transaction.amount)}"}>
                      <%= format_amount(transaction.amount) %>
                    </td>
                  </tr>
                <% end %>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ----------------------------------------------------------------

  defp format_amount(nil), do: "—"

  defp format_amount(cents) when cents < 0 do
    dollars = abs(cents) / 100
    "+$#{:erlang.float_to_binary(dollars, [{:decimals, 2}])}"
  end

  defp format_amount(cents) do
    dollars = cents / 100
    "-$#{:erlang.float_to_binary(dollars, [{:decimals, 2}])}"
  end

  defp amount_class(nil), do: "text-gray-400"
  defp amount_class(cents) when cents < 0, do: "text-emerald-500"
  defp amount_class(_), do: "text-gray-200"

  defp format_category(nil), do: "—"
  defp format_category([]), do: "—"
  defp format_category(categories), do: List.last(categories)

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
