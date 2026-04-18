defmodule FinanceSmithWeb.TransactionTableComponent do
  use FinanceSmithWeb, :live_component

  alias FinanceSmith.Banking.PlaidCategories
  alias FinanceSmithWeb.MoneyFormat

  @doc """
  A reusable, paginated, filterable transaction table.

  ## Required assigns

    * `:page`       - An `Ash.Page.Keyset` result (or `nil` when loading).
    * `:params`     - A map of parsed filter/sort state (from the parent's `handle_params`).
    * `:base_url`   - The parent route path used to build patch URLs (e.g. `"/dashboard"`).
    * `:categories` - A list of `personal_finance_category` strings from the DB for the
                      current scope (household, connection, or account).

  ## Optional assigns

    * `:scope`    - Atom describing the scope context: `:global` (default), `:connection`,
                    or `:account`. Used to hide redundant columns (e.g. hide Account column
                    on an account-scoped view).
  """

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:scope, fn -> :global end)
     |> assign_new(:categories, fn -> [] end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="border border-gray-800 rounded-lg bg-gray-950 overflow-hidden">
      <%!-- Filter bar --%>
      <div class="border-b border-gray-800 px-4 py-3 bg-black flex flex-wrap items-center gap-3">
        <p class="font-mono text-[10px] uppercase tracking-widest text-gray-500 shrink-0">
          Transactions
        </p>
        <form
          id={"#{@id}-filters"}
          phx-change="apply_filters"
          phx-target={@myself}
          class="flex flex-wrap items-center gap-2"
        >
          <.input
            type="search"
            name="search"
            value={@params.search}
            placeholder="Search merchant..."
            phx-debounce="400"
            class="bg-gray-900 border border-gray-800 rounded text-gray-200 font-mono text-xs px-2 py-1.5 placeholder-gray-600 focus:outline-none focus:border-gray-600 w-40"
          />

          <.input
            type="date"
            name="date_from"
            value={@params.date_from}
            class="bg-gray-900 border border-gray-800 rounded text-gray-400 font-mono text-xs px-2 py-1.5 focus:outline-none focus:border-gray-600 w-36"
          />
          <span class="font-mono text-[10px] text-gray-600 shrink-0">to</span>
          <.input
            type="date"
            name="date_to"
            value={@params.date_to}
            class="bg-gray-900 border border-gray-800 rounded text-gray-400 font-mono text-xs px-2 py-1.5 focus:outline-none focus:border-gray-600 w-36"
          />

          <.input
            type="select"
            name="category"
            value={@params.category}
            prompt="All Categories"
            options={Enum.map(@categories, &{PlaidCategories.format(&1), &1})}
            class="bg-gray-900 border border-gray-800 rounded text-gray-400 font-mono text-[10px] uppercase tracking-wider px-2 py-1.5 focus:outline-none focus:border-gray-600 w-64 max-w-full"
          />

          <%= if has_active_filters?(@params) do %>
            <.link
              patch={build_url(@base_url, clear_filters_params(@params))}
              class="font-mono text-[10px] uppercase tracking-widest text-gray-600 hover:text-gray-400 transition-colors shrink-0"
            >
              Clear
            </.link>
          <% end %>
        </form>
      </div>

      <%!-- Table --%>
      <div class="w-full overflow-x-auto">
        <table class="w-full text-left text-sm whitespace-nowrap">
          <thead class="bg-gray-900/50 border-b border-gray-800">
            <tr>
              <th scope="col" class="px-4 py-3">
                <.link
                  patch={sort_url(@base_url, @params, "date")}
                  class="flex items-center gap-1 font-mono text-[10px] uppercase tracking-widest text-gray-500 hover:text-gray-300 transition-colors"
                >
                  Date {sort_indicator(@params, "date")}
                </.link>
              </th>
              <th scope="col" class="px-4 py-3">
                <.link
                  patch={sort_url(@base_url, @params, "merchant_name")}
                  class="flex items-center gap-1 font-mono text-[10px] uppercase tracking-widest text-gray-500 hover:text-gray-300 transition-colors"
                >
                  Merchant {sort_indicator(@params, "merchant_name")}
                </.link>
              </th>
              <th scope="col" class="px-4 py-3 font-mono text-[10px] uppercase tracking-widest text-gray-500">
                Category
              </th>
              <%= if @scope != :account do %>
                <th scope="col" class="px-4 py-3 font-mono text-[10px] uppercase tracking-widest text-gray-500">
                  Account
                </th>
              <% end %>
              <th scope="col" class="px-4 py-3 text-right">
                <.link
                  patch={sort_url(@base_url, @params, "amount")}
                  class="flex items-center justify-end gap-1 font-mono text-[10px] uppercase tracking-widest text-gray-500 hover:text-gray-300 transition-colors"
                >
                  Amount {sort_indicator(@params, "amount")}
                </.link>
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-800/50">
            <%= if is_nil(@page) or @page.results == [] do %>
              <tr>
                <td colspan={if @scope == :account, do: 4, else: 5} class="px-4 py-16 text-center">
                  <p class="font-mono text-sm text-gray-500">
                    There is no data here. Only an anomaly.
                  </p>
                  <p class="mt-2 text-xs font-mono text-gray-600">
                    Adjust the filters or initialize a connection to populate the ledger.
                  </p>
                </td>
              </tr>
            <% else %>
              <tr :for={txn <- @page.results} class="hover:bg-gray-900/30 transition-colors">
                <td class="px-4 py-3 font-mono text-xs text-gray-400">
                  {Calendar.strftime(txn.date, "%Y-%m-%d")}
                </td>
                <td class="px-4 py-3 text-sm text-gray-200">
                  {txn.merchant_name || "—"}
                  <%= if txn.is_pending do %>
                    <span class="ml-1.5 font-mono text-[9px] uppercase tracking-widest text-gray-600">
                      pending
                    </span>
                  <% end %>
                </td>
                <td class="px-4 py-3 font-mono text-[10px] uppercase tracking-wider text-gray-500">
                  {PlaidCategories.format(txn.personal_finance_category) || "—"}
                </td>
                <%= if @scope != :account do %>
                  <td class="px-4 py-3 text-xs text-gray-400">
                    {txn.account.name}
                    <%= if txn.account.mask do %>
                      <span class="text-gray-600">···{txn.account.mask}</span>
                    <% end %>
                  </td>
                <% end %>
                <td class={"px-4 py-3 font-mono text-sm text-right #{amount_class(txn.amount)}"}>
                  {MoneyFormat.format(txn.amount, style: :signed)}
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%!-- Keyset pagination bar --%>
      <div class="flex items-center justify-between px-4 py-3 border-t border-gray-800 bg-black">
        <%= if show_previous?(@params, @page) do %>
          <.link
            patch={build_url(@base_url, %{@params | before_cursor: @page.before, after_cursor: nil})}
            class="font-mono text-[10px] uppercase tracking-widest px-3 py-1.5 rounded border border-gray-700 text-gray-400 hover:border-gray-600 hover:text-gray-200 transition-colors"
          >
            ← Previous
          </.link>
        <% else %>
          <span class="font-mono text-[10px] uppercase tracking-widest px-3 py-1.5 rounded border border-gray-800 text-gray-700 cursor-not-allowed">
            ← Previous
          </span>
        <% end %>

        <span class="font-mono text-[10px] text-gray-600">
          <%= if @page && is_integer(@page.count) do %>
            {@page.count} total
          <% end %>
        </span>

        <%= if @page && @page.more? do %>
          <.link
            patch={build_url(@base_url, %{@params | after_cursor: @page.after, before_cursor: nil})}
            class="font-mono text-[10px] uppercase tracking-widest px-3 py-1.5 rounded border border-gray-700 text-gray-400 hover:border-gray-600 hover:text-gray-200 transition-colors"
          >
            Next →
          </.link>
        <% else %>
          <span class="font-mono text-[10px] uppercase tracking-widest px-3 py-1.5 rounded border border-gray-800 text-gray-700 cursor-not-allowed">
            Next →
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("apply_filters", params, socket) do
    new_params = %{
      socket.assigns.params
      | search: nilify(params["search"]),
        date_from: nilify(params["date_from"]),
        date_to: nilify(params["date_to"]),
        category: nilify(params["category"]),
        after_cursor: nil,
        before_cursor: nil
    }

    {:noreply, push_patch(socket, to: build_url(socket.assigns.base_url, new_params))}
  end

  # --- URL helpers ------------------------------------------------------------

  defp sort_url(base_url, params, field) do
    {new_by, new_dir} =
      if params.sort_by == field do
        {field, if(params.sort_dir == "asc", do: "desc", else: "asc")}
      else
        {field, "desc"}
      end

    build_url(base_url, %{
      params
      | sort_by: new_by,
        sort_dir: new_dir,
        after_cursor: nil,
        before_cursor: nil
    })
  end

  defp sort_indicator(%{sort_by: field, sort_dir: dir}, field) when dir == "asc", do: "↑"
  defp sort_indicator(%{sort_by: field, sort_dir: _dir}, field), do: "↓"
  defp sort_indicator(_params, _field), do: ""

  @doc false
  def build_url(base, params) do
    query =
      %{}
      |> maybe_put("sort_by", params.sort_by, "date")
      |> maybe_put("sort_dir", params.sort_dir, "desc")
      |> maybe_put("search", params.search, nil)
      |> maybe_put("date_from", format_date_param(params.date_from), nil)
      |> maybe_put("date_to", format_date_param(params.date_to), nil)
      |> maybe_put("category", params.category, nil)
      |> maybe_put("after", params.after_cursor, nil)
      |> maybe_put("before", params.before_cursor, nil)

    if map_size(query) == 0 do
      base
    else
      base <> "?" <> URI.encode_query(query)
    end
  end

  defp maybe_put(map, _key, nil, _default), do: map
  defp maybe_put(map, _key, value, value), do: map
  defp maybe_put(map, key, value, _default), do: Map.put(map, key, value)

  defp format_date_param(nil), do: nil
  defp format_date_param(%Date{} = d), do: Date.to_iso8601(d)
  defp format_date_param(s) when is_binary(s), do: s

  defp has_active_filters?(params) do
    params.search || params.date_from || params.date_to || params.category
  end

  # Only show "Previous" when the user has actually paged forward or backward,
  # because keyset pages always expose a `before` cursor once results exist.
  defp show_previous?(_params, nil), do: false
  defp show_previous?(_params, %{before: nil}), do: false
  defp show_previous?(%{after_cursor: nil, before_cursor: nil}, _page), do: false
  defp show_previous?(_params, _page), do: true

  # --- Display helpers --------------------------------------------------------

  defp amount_class(nil), do: "text-gray-400"
  defp amount_class(cents) when cents < 0, do: "text-emerald-500"
  defp amount_class(_), do: "text-gray-200"

  defp clear_filters_params(params) do
    %{
      params
      | search: nil,
        date_from: nil,
        date_to: nil,
        category: nil,
        after_cursor: nil,
        before_cursor: nil
    }
  end

  defp nilify(""), do: nil
  defp nilify(v), do: v
end
