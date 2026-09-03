defmodule FinanceSmithWeb.BudgetsLive do
  @moduledoc """
  The budgeting workspace: a dense matrix (or card grid) of budget targets
  with velocity-based pacing, household/personal scope switching, an
  inline target editor, and a Smart Sheet slide-over for bulk adjustments.

  Drill-down state lives in the URL (`?category=&date_from=&date_to=`) so
  the embedded transaction table's patch-based filters and pagination work
  unchanged, and an inspected category survives reloads.
  """

  use FinanceSmithWeb, :live_view

  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.BudgetTarget
  alias FinanceSmith.Banking.DatePeriod
  alias FinanceSmithWeb.MoneyFormat
  alias FinanceSmithWeb.TransactionLiveHelpers
  alias FinanceSmithWeb.TransactionTableComponent
  alias FinanceSmithWeb.ViewScope

  import FinanceSmithWeb.BudgetComponents

  @windows [weekly: "Week", monthly: "Month", quarterly: "Quarter", yearly: "Year"]
  @default_window :monthly
  @period_options [
    {"Weekly", "weekly"},
    {"Monthly", "monthly"},
    {"Quarterly", "quarterly"},
    {"Yearly", "yearly"}
  ]

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    view_scope = ViewScope.default_scope(user)
    scope = ViewScope.parse_scope(view_scope)

    if connected?(socket) do
      FinanceSmithWeb.Endpoint.subscribe("transaction:created")
      FinanceSmithWeb.Endpoint.subscribe("transaction:updated")
    end

    socket =
      socket
      |> assign(:page_title, "Budgets")
      |> assign(:current_nav, :budgets)
      |> assign(:current_user, user)
      |> assign(:windows, @windows)
      |> assign(:view_scope, view_scope)
      |> assign(:scope, scope)
      |> assign(:view_mode, :matrix)
      |> assign(:edit_target_id, nil)
      |> assign(:edit_form, nil)
      |> assign(:sheet_open?, false)
      |> assign(:sheet_rows, [])
      |> assign(:categories, TransactionLiveHelpers.list_categories(user))
      |> assign(:drill_category, nil)
      |> assign(:tx_page, nil)
      |> assign(:tx_params, TransactionLiveHelpers.default_tx_params())
      |> apply_window(@default_window)

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    tx_params = TransactionLiveHelpers.parse_tx_params(params)

    drill_category =
      Enum.find(socket.assigns.categories, &(&1.id == tx_params.meta_category_id))

    socket =
      socket
      |> assign(:tx_params, tx_params)
      |> assign(:drill_category, drill_category)
      |> fetch_drill_transactions()

    {:noreply, socket}
  end

  # --- Events -----------------------------------------------------------------

  def handle_event("set_window", %{"window" => raw_window}, socket) do
    case parse_window(raw_window) do
      {:ok, window} ->
        socket = apply_window(socket, window)

        # Keep an open drill-down aligned with the new window's date range.
        socket =
          if socket.assigns.drill_category do
            push_patch(socket, to: drill_url(socket, socket.assigns.drill_category.id))
          else
            socket
          end

        {:noreply, socket}

      :error ->
        {:noreply, put_flash(socket, :error, "We have a... discrepancy. The window is invalid.")}
    end
  end

  def handle_event("change_view_scope", %{"scope" => raw_scope}, socket)
      when is_binary(raw_scope) do
    case ViewScope.validate_scope(raw_scope) do
      {:ok, view_scope} ->
        socket =
          socket
          |> assign(:view_scope, view_scope)
          |> assign(:scope, ViewScope.parse_scope(view_scope))
          |> apply_window(socket.assigns.window)
          |> fetch_drill_transactions()

        {:noreply, socket}

      :error ->
        {:noreply, put_flash(socket, :error, "We have a... discrepancy. The scope is invalid.")}
    end
  end

  def handle_event("set_view_mode", %{"mode" => mode}, socket) when mode in ~w(matrix cards) do
    {:noreply, assign(socket, :view_mode, String.to_existing_atom(mode))}
  end

  def handle_event("open_drill", %{"id" => meta_category_id}, socket) do
    {:noreply, push_patch(socket, to: drill_url(socket, meta_category_id))}
  end

  # --- Inline editing ---------------------------------------------------------

  def handle_event("begin_edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.targets, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      target ->
        form =
          target
          |> AshPhoenix.Form.for_update(:update,
            as: "edit_target",
            id: "edit-target-form",
            actor: socket.assigns.current_user,
            transform_params: &transform_amount_params/2
          )
          |> AshPhoenix.Form.validate(%{"amount" => cents_to_dollars(target.amount)},
            errors: false
          )
          |> to_form()

        {:noreply, assign(socket, edit_target_id: id, edit_form: form)}
    end
  end

  def handle_event("validate_edit", %{"edit_target" => params}, socket) do
    {:noreply,
     assign(socket, :edit_form, AshPhoenix.Form.validate(socket.assigns.edit_form, params))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, edit_target_id: nil, edit_form: nil)}
  end

  def handle_event("save_edit", %{"edit_target" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_form, params: params) do
      {:ok, _target} ->
        {:noreply,
         socket
         |> assign(edit_target_id: nil, edit_form: nil)
         |> apply_window(socket.assigns.window)
         |> put_flash(:info, "Target updated. The ledger has fulfilled its purpose.")}

      {:error, form} ->
        {:noreply, assign(socket, :edit_form, form)}
    end
  end

  # --- Smart Sheet ------------------------------------------------------------

  def handle_event("open_sheet", _params, socket) do
    {:noreply,
     socket
     |> assign(:sheet_rows, build_sheet_rows(socket))
     |> assign(:sheet_open?, true)}
  end

  # Pushed by the Petal slide_over close button / escape / click-away.
  def handle_event("close_slide_over", _params, socket) do
    {:noreply, assign(socket, sheet_open?: false, sheet_rows: [])}
  end

  def handle_event("validate_sheet", params, socket) do
    case params |> Map.keys() |> Enum.find(&String.starts_with?(&1, "row_")) do
      nil ->
        {:noreply, socket}

      row_key ->
        rows =
          Enum.map(socket.assigns.sheet_rows, fn row ->
            if row.form.name == row_key do
              %{row | form: AshPhoenix.Form.validate(row.form, params[row_key], errors: false)}
            else
              row
            end
          end)

        {:noreply, assign(socket, :sheet_rows, rows)}
    end
  end

  # Two-phase apply: every dirty row is validated first, and nothing is
  # submitted unless all of them pass, so a bad row cannot cause a partial
  # apply. Submit-time failures (e.g. a concurrent unique-period conflict)
  # are still surfaced per row on the reopened sheet.
  def handle_event("apply_sheet", _params, socket) do
    {dirty_rows, clean_rows} = Enum.split_with(socket.assigns.sheet_rows, &sheet_row_dirty?/1)

    validated =
      Enum.map(dirty_rows, fn row ->
        %{row | form: AshPhoenix.Form.validate(row.form, row.form.source.raw_params)}
      end)

    cond do
      validated == [] ->
        {:noreply, put_flash(socket, :info, "No changes to apply.")}

      Enum.any?(validated, &(not &1.form.source.valid?)) ->
        rows = Enum.sort_by(validated ++ clean_rows, & &1.category_name)

        {:noreply,
         socket
         |> assign(:sheet_rows, rows)
         |> put_flash(:error, "We have a... discrepancy. Review the highlighted targets.")}

      true ->
        submitted =
          Enum.map(validated, fn row ->
            case AshPhoenix.Form.submit(row.form) do
              {:ok, _record} -> {:ok, row}
              {:error, form} -> {:error, %{row | form: form}}
            end
          end)

        socket = apply_window(socket, socket.assigns.window)

        if Enum.any?(submitted, &match?({:error, _}, &1)) do
          rows =
            (Enum.map(submitted, fn {_status, row} -> row end) ++ clean_rows)
            |> Enum.sort_by(& &1.category_name)

          {:noreply,
           socket
           |> assign(:sheet_rows, rows)
           |> put_flash(:error, "We have a... discrepancy. Review the highlighted targets.")}
        else
          {:noreply,
           socket
           |> assign(sheet_open?: false, sheet_rows: [])
           |> put_flash(:info, "Targets updated. Inevitable.")}
        end
    end
  end

  def handle_event("remove_target", %{"id" => id}, socket) do
    with %BudgetTarget{} = target <- Enum.find(socket.assigns.targets, &(&1.id == id)),
         :ok <- Banking.destroy_budget_target(target, actor: socket.assigns.current_user) do
      socket = apply_window(socket, socket.assigns.window)

      {:noreply,
       socket
       |> assign(:sheet_rows, build_sheet_rows(socket))
       |> put_flash(:info, "Target removed. It no longer serves a purpose.")}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, "We have a... discrepancy. The target was not removed.")}
    end
  end

  # --- PubSub -----------------------------------------------------------------

  def handle_info(%{topic: "transaction:" <> _, payload: %Ash.Notifier.Notification{}}, socket) do
    {:noreply,
     socket
     |> apply_window(socket.assigns.window)
     |> fetch_drill_transactions()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Render -----------------------------------------------------------------

  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex flex-wrap items-end justify-between gap-4 border-b border-gray-800 pb-4">
        <div>
          <.h1 color_class="text-gray-100" no_margin>Budgets</.h1>
          <.p class="text-sm text-gray-500 mt-1" no_margin>
            Targets against actuals. The outcome is already decided.
          </.p>
        </div>

        <div class="flex flex-wrap items-center gap-3">
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

          <div
            role="tablist"
            aria-label="Budget window"
            class="flex items-center gap-1 font-mono text-[10px] uppercase tracking-widest"
          >
            <%= for {window, label} <- @windows do %>
              <button
                type="button"
                role="tab"
                aria-selected={@window == window}
                phx-click="set_window"
                phx-value-window={window}
                class={[
                  "px-3 py-1.5 border transition-colors",
                  (@window == window &&
                     "border-emerald-500 bg-emerald-500/10 text-emerald-400") ||
                    "border-gray-800 text-gray-500 hover:border-gray-700 hover:text-gray-300"
                ]}
              >
                {label}
              </button>
            <% end %>
          </div>

          <div
            role="tablist"
            aria-label="View mode"
            class="flex items-center gap-1 font-mono text-[10px] uppercase tracking-widest"
          >
            <%= for {mode, label} <- [matrix: "Matrix", cards: "Cards"] do %>
              <button
                type="button"
                role="tab"
                aria-selected={@view_mode == mode}
                phx-click="set_view_mode"
                phx-value-mode={mode}
                class={[
                  "px-3 py-1.5 border transition-colors",
                  (@view_mode == mode &&
                     "border-gray-600 bg-gray-800/60 text-gray-200") ||
                    "border-gray-800 text-gray-500 hover:border-gray-700 hover:text-gray-300"
                ]}
              >
                {label}
              </button>
            <% end %>
          </div>

          <.button
            phx-click="open_sheet"
            size="sm"
            color="gray"
            variant="outline"
            class="font-mono text-xs border-gray-800 text-emerald-500 hover:border-emerald-500/50"
          >
            Adjust Targets
          </.button>
        </div>
      </div>

      <section class={[
        "space-y-4 rounded-lg",
        @scope == :personal && "border border-sky-500/40 p-4"
      ]}>
        <div class="flex items-center justify-between">
          <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">
            {window_range_label(@start_date, @end_date)}
          </p>
          <p
            :if={@scope == :personal}
            class="font-mono text-[10px] uppercase tracking-widest text-sky-400"
          >
            Personal lens · your transactions only
          </p>
        </div>

        <%= if @targets == [] do %>
          <div class="border border-gray-800 rounded-lg bg-gray-950/50 px-5 py-10 text-center">
            <p class="text-sm text-gray-500">
              There is no data here. Only an anomaly.
            </p>
            <p class="text-xs text-gray-600 mt-1 mb-4">
              Define a target to begin measuring the household against it.
            </p>
            <.button
              phx-click="open_sheet"
              size="sm"
              color="gray"
              variant="outline"
              class="font-mono text-xs border-gray-800 text-emerald-500 hover:border-emerald-500/50"
            >
              Define Targets
            </.button>
          </div>
        <% else %>
          <%= if @view_mode == :matrix do %>
            {render_matrix(assigns)}
          <% else %>
            {render_cards(assigns)}
          <% end %>
        <% end %>
      </section>

      <section :if={@drill_category} id="budget-drilldown" class="space-y-3">
        <div class="flex items-center justify-between">
          <p class="text-[10px] font-mono text-gray-500 uppercase tracking-widest">
            Inspecting · <span class="text-gray-300">{@drill_category.name}</span>
          </p>
          <.link
            patch={~p"/budgets"}
            class="font-mono text-[10px] uppercase tracking-widest text-gray-600 hover:text-gray-400 transition-colors"
          >
            Close inspection
          </.link>
        </div>

        <.live_component
          module={TransactionTableComponent}
          id="budget-txn-table"
          page={@tx_page}
          params={@tx_params}
          base_url={~p"/budgets"}
          scope={:global}
          categories={@categories}
        />
      </section>

      {render_sheet(assigns)}
    </div>
    """
  end

  defp render_matrix(assigns) do
    ~H"""
    <div class="border border-gray-800 rounded-lg bg-gray-950/50 overflow-x-auto">
      <table class="w-full text-left whitespace-nowrap">
        <thead class="sticky top-0 bg-gray-950">
          <tr class="border-b border-gray-800">
            <th class="px-4 py-3 text-[10px] font-mono text-gray-500 uppercase tracking-widest">
              Category
            </th>
            <th class="px-4 py-3 text-[10px] font-mono text-gray-500 uppercase tracking-widest">
              Period
            </th>
            <th class="px-4 py-3 text-[10px] font-mono text-gray-500 uppercase tracking-widest text-right">
              Target
            </th>
            <th class="px-4 py-3 text-[10px] font-mono text-gray-500 uppercase tracking-widest text-right">
              Window Target
            </th>
            <th class="px-4 py-3 text-[10px] font-mono text-gray-500 uppercase tracking-widest text-right">
              Actual
            </th>
            <th class="px-4 py-3 text-[10px] font-mono text-gray-500 uppercase tracking-widest text-right">
              Of Limit
            </th>
            <th class="px-4 py-3 text-[10px] font-mono text-gray-500 uppercase tracking-widest text-right">
              Projected
            </th>
            <th class="px-4 py-3 text-[10px] font-mono text-gray-500 uppercase tracking-widest">
              Pace
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-800">
          <tr
            :for={target <- @targets}
            class={[
              "transition-colors hover:bg-gray-900/50",
              @drill_category && @drill_category.id == target.meta_category_id &&
                "bg-emerald-500/5"
            ]}
          >
            <td class="px-4 py-3 text-sm">
              <.link
                patch={drill_url_from(@start_date, @end_date, target.meta_category_id)}
                class="text-gray-100 hover:text-emerald-400 transition-colors"
              >
                {target.meta_category.name}
              </.link>
            </td>
            <td class="px-4 py-3 font-mono text-[10px] uppercase tracking-widest text-gray-500">
              {period_label(target.period_type)}
            </td>
            <td class="px-4 py-2 text-right">
              <%= if @edit_target_id == target.id do %>
                <.form
                  for={@edit_form}
                  id="edit-target-form"
                  phx-submit="save_edit"
                  phx-change="validate_edit"
                  class="inline-block"
                >
                  <.input
                    field={@edit_form[:amount]}
                    type="text"
                    inputmode="decimal"
                    autofocus
                    phx-keydown="cancel_edit"
                    phx-key="escape"
                    class="w-28 bg-gray-900 border border-emerald-500/50 rounded font-mono text-sm text-right text-gray-100 px-2 py-1 focus:outline-none focus:border-emerald-500"
                  />
                  <p
                    :for={msg <- field_errors(@edit_form[:amount])}
                    class="mt-1 font-mono text-[10px] text-red-400 text-right"
                  >
                    {msg}
                  </p>
                </.form>
              <% else %>
                <button
                  type="button"
                  id={"target-amount-#{target.id}"}
                  phx-hook="BudgetDblClick"
                  data-target-id={target.id}
                  title="Double-click to adjust"
                  class="font-mono text-sm text-gray-100 hover:text-emerald-400 transition-colors cursor-text"
                >
                  {MoneyFormat.format(target.amount)}
                </button>
              <% end %>
            </td>
            <td class="px-4 py-3 font-mono text-sm text-gray-300 text-right">
              {MoneyFormat.format(target.scaled_target)}
            </td>
            <td class="px-4 py-3 font-mono text-sm text-gray-100 text-right">
              {MoneyFormat.format(target.actual_spend)}
            </td>
            <td class="px-4 py-3 font-mono text-xs text-gray-400 text-right">
              {limit_label(target)}
            </td>
            <td class="px-4 py-3 font-mono text-sm text-gray-300 text-right">
              {MoneyFormat.format(target.projected_spend)}
            </td>
            <td class="px-4 py-3">
              <div class="flex items-center gap-3 min-w-40">
                <div class="w-24">
                  <.pacing_bar
                    actual={target.actual_spend}
                    scaled_target={target.scaled_target}
                    projected={target.projected_spend}
                    elapsed_fraction={@elapsed_fraction}
                  />
                </div>
                <.velocity_badge
                  projected={target.projected_spend}
                  scaled_target={target.scaled_target}
                />
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp render_cards(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-4">
      <.budget_card
        :for={target <- @targets}
        id={"budget-card-#{target.id}"}
        name={target.meta_category.name}
        period_type={target.period_type}
        amount={target.amount}
        actual={target.actual_spend}
        scaled_target={target.scaled_target}
        projected={target.projected_spend}
        elapsed_fraction={@elapsed_fraction}
        selected={@drill_category != nil and @drill_category.id == target.meta_category_id}
        phx-click="open_drill"
        phx-value-id={target.meta_category_id}
      />
    </div>
    """
  end

  defp render_sheet(assigns) do
    ~H"""
    <.slide_over
      :if={@sheet_open?}
      id="budget-sheet"
      origin="right"
      max_width="lg"
      title="Adjust Targets"
      class="!bg-gray-950 border-l border-gray-800"
    >
      <div class="space-y-1">
        <p class="font-mono text-[10px] uppercase tracking-widest text-gray-500">
          Smart Sheet
        </p>
        <p class="text-xs text-gray-500 pb-2">
          Set amounts in dollars per period. Blank rows are ignored. Changes apply together.
        </p>

        <%= if @sheet_rows == [] do %>
          <div class="border border-gray-800 rounded-lg bg-gray-950/50 px-4 py-8 text-center">
            <p class="text-sm text-gray-500">There are no categories to budget. Only an anomaly.</p>
            <p class="text-xs text-gray-600 mt-1">
              Categories appear here once transactions have been classified.
            </p>
          </div>
        <% else %>
          <div class="divide-y divide-gray-800 border-y border-gray-800">
            <.form
              :for={row <- @sheet_rows}
              for={row.form}
              id={row.form.id}
              phx-change="validate_sheet"
              class="flex items-start gap-2 py-2.5"
            >
              <div class="flex-1 min-w-0 pt-1.5">
                <p class="truncate text-sm text-gray-100">{row.category_name}</p>
                <p
                  :if={row.kind == :create}
                  class="font-mono text-[10px] uppercase tracking-widest text-gray-600"
                >
                  No target
                </p>
              </div>

              <div class="w-28 shrink-0">
                <.input
                  field={row.form[:amount]}
                  type="text"
                  inputmode="decimal"
                  placeholder="0.00"
                  class="w-full bg-gray-900 border border-gray-800 rounded font-mono text-sm text-right text-gray-100 px-2 py-1.5 placeholder-gray-600 focus:outline-none focus:border-gray-600"
                />
                <p
                  :for={msg <- field_errors(row.form[:amount])}
                  class="mt-1 font-mono text-[10px] text-red-400 text-right"
                >
                  {msg}
                </p>
              </div>

              <div class="w-28 shrink-0">
                <.input
                  field={row.form[:period_type]}
                  type="select"
                  options={period_options()}
                  class="w-full bg-gray-900 border border-gray-800 rounded text-gray-400 font-mono text-[10px] uppercase tracking-wider px-2 py-2 focus:outline-none focus:border-gray-600 cursor-pointer"
                />
                <p
                  :for={msg <- field_errors(row.form[:period_type])}
                  class="mt-1 font-mono text-[10px] text-red-400"
                >
                  {msg}
                </p>
              </div>

              <button
                :if={row.kind == :update}
                type="button"
                phx-click="remove_target"
                phx-value-id={row.id}
                title="Remove target"
                class="pt-2 px-1 font-mono text-xs text-gray-600 hover:text-red-400 transition-colors"
              >
                ✕
              </button>
              <span :if={row.kind == :create} class="w-[22px]"></span>
            </.form>
          </div>

          <div class="flex items-center justify-end gap-2 pt-4">
            <.button
              phx-click="apply_sheet"
              phx-disable-with="Applying..."
              size="sm"
              color="gray"
              variant="outline"
              class="font-mono text-xs border-gray-800 text-emerald-500 hover:border-emerald-500/50"
            >
              Apply Changes
            </.button>
          </div>
        <% end %>
      </div>
    </.slide_over>
    """
  end

  # --- Data helpers -----------------------------------------------------------

  defp apply_window(socket, window) do
    user = socket.assigns.current_user
    {start_date, end_date} = DatePeriod.to_range(window)
    today = Date.utc_today()

    elapsed_fraction =
      DatePeriod.elapsed_days(start_date, end_date, today) /
        DatePeriod.day_count(start_date, end_date)

    targets =
      Banking.list_budget_targets_for_window!(
        %{
          start_date: start_date,
          end_date: end_date,
          user_id: spend_user_id(socket.assigns.scope, user)
        },
        actor: user,
        load: [:meta_category]
      )
      |> Enum.sort_by(& &1.meta_category.name)

    socket
    |> assign(:window, window)
    |> assign(:start_date, start_date)
    |> assign(:end_date, end_date)
    |> assign(:elapsed_fraction, elapsed_fraction)
    |> assign(:targets, targets)
  end

  defp fetch_drill_transactions(%{assigns: %{drill_category: nil}} = socket) do
    assign(socket, :tx_page, nil)
  end

  defp fetch_drill_transactions(socket) do
    user = socket.assigns.current_user
    filters = scope_filters(socket.assigns.scope, user)

    case TransactionLiveHelpers.fetch_transactions(user, socket.assigns.tx_params, filters) do
      {:ok, page} ->
        assign(socket, :tx_page, page)

      {:error, _reason} ->
        socket
        |> assign(:tx_page, nil)
        |> put_flash(:error, "We have a... discrepancy. The ledger refused to open.")
    end
  end

  defp spend_user_id(:personal, user), do: user.id
  defp spend_user_id(:household, _user), do: nil

  defp scope_filters(:personal, user), do: %{user_id: user.id}
  defp scope_filters(:household, _user), do: %{}

  defp drill_url(socket, meta_category_id) do
    drill_url_from(socket.assigns.start_date, socket.assigns.end_date, meta_category_id)
  end

  defp drill_url_from(start_date, end_date, meta_category_id) do
    params = %{
      TransactionLiveHelpers.default_tx_params()
      | meta_category_id: meta_category_id,
        date_from: start_date,
        date_to: end_date
    }

    TransactionTableComponent.build_url(~p"/budgets", params)
  end

  # --- Sheet helpers ----------------------------------------------------------

  defp build_sheet_rows(socket) do
    user = socket.assigns.current_user

    target_rows =
      Enum.map(socket.assigns.targets, fn target ->
        form =
          target
          |> AshPhoenix.Form.for_update(:update,
            as: "row_#{target.id}",
            id: "sheet-row-#{target.id}",
            actor: user,
            transform_params: &transform_amount_params/2
          )
          |> AshPhoenix.Form.validate(
            %{
              "amount" => cents_to_dollars(target.amount),
              "period_type" => to_string(target.period_type)
            },
            errors: false
          )
          |> to_form()

        %{
          id: target.id,
          kind: :update,
          category_name: target.meta_category.name,
          target: target,
          form: form
        }
      end)

    covered = MapSet.new(socket.assigns.targets, & &1.meta_category_id)

    create_rows =
      socket.assigns.categories
      |> Enum.reject(&MapSet.member?(covered, &1.id))
      |> Enum.map(fn category ->
        form =
          BudgetTarget
          |> AshPhoenix.Form.for_create(:create,
            as: "row_new_#{category.id}",
            id: "sheet-row-new-#{category.id}",
            actor: user,
            transform_params: fn params, type ->
              params
              |> transform_amount_params(type)
              |> Map.put("meta_category_id", category.id)
            end
          )
          |> AshPhoenix.Form.validate(%{"period_type" => "monthly"}, errors: false)
          |> to_form()

        %{id: "new_#{category.id}", kind: :create, category_name: category.name, form: form}
      end)

    Enum.sort_by(target_rows ++ create_rows, & &1.category_name)
  end

  # A create row only submits once an amount has been entered; an update row
  # only submits when its values differ from the persisted target. The field
  # value is integer cents when transform_params succeeded, or the raw string
  # when the input is blank/invalid (invalid input still submits so the cast
  # error surfaces on the row).
  defp sheet_row_dirty?(%{kind: :create, form: form}) do
    case form[:amount].value do
      cents when is_integer(cents) -> true
      raw when is_binary(raw) -> String.trim(raw) != ""
      _ -> false
    end
  end

  defp sheet_row_dirty?(%{kind: :update, form: form, target: target}) do
    amount_cents =
      case form[:amount].value do
        cents when is_integer(cents) -> cents
        raw when is_binary(raw) -> dollars_to_cents(raw)
        _ -> nil
      end

    period = form[:period_type].value |> to_string()

    amount_cents != target.amount or period != to_string(target.period_type)
  end

  # --- Money conversion -------------------------------------------------------

  # Inputs work in dollars; the action stores integer cents. Invalid input is
  # passed through untouched so Ash surfaces the cast error on the field.
  defp transform_amount_params(params, _type) do
    case Map.fetch(params, "amount") do
      {:ok, raw} when is_binary(raw) ->
        case dollars_to_cents(raw) do
          nil -> params
          cents -> Map.put(params, "amount", cents)
        end

      _ ->
        params
    end
  end

  defp dollars_to_cents(raw) when is_binary(raw) do
    cleaned = raw |> String.trim() |> String.replace(["$", ","], "")

    case Decimal.parse(cleaned) do
      {decimal, ""} ->
        decimal
        |> Decimal.mult(100)
        |> Decimal.round(0, :half_up)
        |> Decimal.to_integer()

      _ ->
        nil
    end
  end

  defp dollars_to_cents(_), do: nil

  defp cents_to_dollars(cents) when is_integer(cents) do
    cents
    |> Decimal.new()
    |> Decimal.div(100)
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
  end

  # --- Display helpers --------------------------------------------------------

  defp field_errors(field) do
    Enum.map(field.errors, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp limit_label(target) do
    case percent_of_limit(target.actual_spend, target.scaled_target) do
      nil -> "—"
      pct -> "#{pct}% of limit"
    end
  end

  defp window_range_label(start_date, end_date) do
    "#{Calendar.strftime(start_date, "%b %d")} – #{Calendar.strftime(end_date, "%b %d, %Y")}"
  end

  defp period_options, do: @period_options

  for {window, _label} <- @windows do
    defp parse_window(unquote(to_string(window))), do: {:ok, unquote(window)}
  end

  defp parse_window(_), do: :error
end
