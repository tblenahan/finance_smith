defmodule FinanceSmithWeb.BudgetComponents do
  @moduledoc """
  Domain UI for the budgets workspace: velocity pacing indicators and the
  card-and-drilldown summary pattern.

  Pacing is velocity-based: the tier compares `projected_spend` (spend
  extrapolated across the window from elapsed days) against `scaled_target`
  (the target pro-rated onto the window), so a category can be under its
  raw dollar limit yet still read as "Tight" when spend is moving too fast.
  """

  use Phoenix.Component

  import PetalComponents.Badge

  alias FinanceSmithWeb.MoneyFormat

  @type tier :: :cruising | :on_pace | :tight | :over | :no_target

  @doc """
  Classifies window pacing from projected spend vs the scaled target.

    * `:cruising` - projected below 85% of the scaled target
    * `:on_pace`  - projected between 85% and 100%
    * `:tight`    - projected between 100% and 115%
    * `:over`     - projected beyond 115%
    * `:no_target` - the scaled target is zero (nothing to pace against)
  """
  @spec pace_tier(integer(), integer()) :: tier()
  def pace_tier(_projected, scaled_target) when scaled_target <= 0, do: :no_target

  def pace_tier(projected, scaled_target) do
    ratio = projected / scaled_target

    cond do
      ratio < 0.85 -> :cruising
      ratio <= 1.0 -> :on_pace
      ratio <= 1.15 -> :tight
      true -> :over
    end
  end

  @spec tier_label(tier()) :: String.t()
  def tier_label(:cruising), do: "Cruising"
  def tier_label(:on_pace), do: "On Pace"
  def tier_label(:tight), do: "Tight"
  def tier_label(:over), do: "Over"
  def tier_label(:no_target), do: "No Target"

  @doc """
  Percent of the scaled target consumed by actual spend, rounded to an
  integer. Returns `nil` when there is no target to measure against.
  """
  @spec percent_of_limit(integer(), integer()) :: non_neg_integer() | nil
  def percent_of_limit(_actual, scaled_target) when scaled_target <= 0, do: nil
  def percent_of_limit(actual, scaled_target), do: round(actual * 100 / scaled_target)

  attr(:projected, :integer, required: true)
  attr(:scaled_target, :integer, required: true)
  attr(:class, :string, default: nil)

  def velocity_badge(assigns) do
    assigns = assign(assigns, :tier, pace_tier(assigns.projected, assigns.scaled_target))

    ~H"""
    <.badge
      variant="outline"
      label={tier_label(@tier)}
      class={[
        "font-mono text-[10px] uppercase tracking-widest rounded px-1.5 py-0.5",
        tier_badge_classes(@tier),
        @class
      ]}
    />
    """
  end

  attr(:actual, :integer, required: true)
  attr(:scaled_target, :integer, required: true)
  attr(:projected, :integer, required: true)

  attr(:elapsed_fraction, :float,
    required: true,
    doc: "fraction of the window elapsed (0.0..1.0), rendered as a tick marker"
  )

  def pacing_bar(assigns) do
    tier = pace_tier(assigns.projected, assigns.scaled_target)

    fill_pct =
      case assigns.scaled_target do
        st when st <= 0 -> 0.0
        st -> min(assigns.actual * 100 / st, 100.0)
      end

    assigns =
      assigns
      |> assign(:tier, tier)
      |> assign(:fill_pct, fill_pct)
      |> assign(:marker_pct, Float.round(min(max(assigns.elapsed_fraction, 0.0), 1.0) * 100, 1))

    ~H"""
    <div class="relative h-1.5 w-full rounded-full bg-gray-800 overflow-hidden">
      <div
        class={["absolute inset-y-0 left-0 rounded-full", tier_fill_classes(@tier)]}
        style={"width: #{Float.round(@fill_pct, 1)}%"}
      >
      </div>
      <div
        :if={@tier != :no_target}
        class="absolute inset-y-0 w-px bg-gray-400/80"
        style={"left: #{@marker_pct}%"}
        title="Window elapsed"
      >
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:period_type, :atom, required: true)
  attr(:amount, :integer, required: true, doc: "raw target for its own period, in cents")
  attr(:actual, :integer, required: true)
  attr(:scaled_target, :integer, required: true)
  attr(:projected, :integer, required: true)
  attr(:elapsed_fraction, :float, required: true)
  attr(:selected, :boolean, default: false)
  attr(:rest, :global, include: ~w(phx-click phx-value-id))

  def budget_card(assigns) do
    assigns =
      assign(assigns, :pct, percent_of_limit(assigns.actual, assigns.scaled_target))

    ~H"""
    <article
      id={@id}
      class={[
        "group cursor-pointer rounded-lg border bg-gray-950 p-4 space-y-3 transition-colors",
        (@selected && "border-emerald-500/60") || "border-gray-800 hover:border-gray-600"
      ]}
      {@rest}
    >
      <div class="flex items-start justify-between gap-2">
        <div class="min-w-0">
          <p class="truncate text-sm font-medium text-gray-100">{@name}</p>
          <p class="mt-0.5 font-mono text-[10px] uppercase tracking-widest text-gray-500">
            {period_label(@period_type)} · {MoneyFormat.format(@amount)}
          </p>
        </div>
        <.velocity_badge projected={@projected} scaled_target={@scaled_target} class="shrink-0" />
      </div>

      <div class="flex items-baseline gap-1.5">
        <span class="font-mono text-xl tracking-tight text-gray-100">
          {MoneyFormat.format(@actual)}
        </span>
        <span class="font-mono text-xs text-gray-500">
          of {MoneyFormat.format(@scaled_target)}
        </span>
      </div>

      <.pacing_bar
        actual={@actual}
        scaled_target={@scaled_target}
        projected={@projected}
        elapsed_fraction={@elapsed_fraction}
      />

      <div class="flex items-center justify-between font-mono text-[10px] uppercase tracking-widest text-gray-500">
        <span :if={@pct}>{@pct}% of limit</span>
        <span :if={is_nil(@pct)}>No limit set</span>
        <span>Projected {MoneyFormat.format(@projected)}</span>
      </div>
    </article>
    """
  end

  @spec period_label(atom()) :: String.t()
  def period_label(:weekly), do: "Weekly"
  def period_label(:monthly), do: "Monthly"
  def period_label(:quarterly), do: "Quarterly"
  def period_label(:yearly), do: "Yearly"

  defp tier_badge_classes(:cruising),
    do: "border-emerald-500/40 bg-emerald-500/10 text-emerald-400"

  defp tier_badge_classes(:on_pace), do: "border-gray-700 bg-gray-800/60 text-gray-300"
  defp tier_badge_classes(:tight), do: "border-amber-500/40 bg-amber-500/10 text-amber-400"
  defp tier_badge_classes(:over), do: "border-red-500/40 bg-red-500/10 text-red-400"
  defp tier_badge_classes(:no_target), do: "border-gray-800 bg-gray-900 text-gray-500"

  defp tier_fill_classes(:cruising), do: "bg-gradient-to-r from-emerald-600 to-emerald-400"
  defp tier_fill_classes(:on_pace), do: "bg-gradient-to-r from-gray-500 to-gray-300"
  defp tier_fill_classes(:tight), do: "bg-gradient-to-r from-amber-600 to-amber-400"
  defp tier_fill_classes(:over), do: "bg-gradient-to-r from-red-600 to-red-400"
  defp tier_fill_classes(:no_target), do: "bg-gray-800"
end
