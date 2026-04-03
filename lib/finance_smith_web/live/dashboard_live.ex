defmodule FinanceSmithWeb.DashboardLive do
  use FinanceSmithWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "The Ledger")
     |> assign(:current_nav, :dashboard)}
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex items-end justify-between border-b border-gray-800 pb-4">
        <div>
          <.h1 color_class="text-gray-100" no_margin>The Ledger</.h1>
          <.p class="text-sm text-gray-500 mt-1" no_margin>
            Your financial data, consolidated. Inevitable.
          </.p>
        </div>
        <.button size="sm" color="gray" variant="outline" class="font-mono text-xs border-gray-800 text-emerald-500 hover:border-emerald-500/50">
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
              <tr>
                <td colspan="5" class="px-4 py-16 text-center">
                  <p class="font-mono text-sm text-gray-500">There is no data here. Only an anomaly.</p>
                  <p class="mt-2 text-xs font-mono text-gray-600">Initialize a Plaid connection to populate the ledger.</p>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end
end
