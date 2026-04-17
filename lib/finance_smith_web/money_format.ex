defmodule FinanceSmithWeb.MoneyFormat do
  @moduledoc """
  Money display helpers. The ledger stores amounts as integer cents.

  Two sign conventions are supported:

    * `:accounting` (default) - render with `$` and a leading `-` for negative,
      used for balances and aggregates (net worth, 30-day outflow, account
      balance).

    * `:signed` - render with an explicit `+`/`-`, used for transaction rows
      where inflow vs outflow must be unambiguous at a glance. Plaid reports
      outflow as positive cents and inflow as negative, so the sign is flipped
      from the raw value.

  A `:nil_display` option controls the placeholder for `nil` amounts; defaults
  to an em dash (`"—"`) for transactions and `"$0.00"` for aggregate tiles.
  """

  @type opts :: [
          style: :accounting | :signed,
          nil_display: String.t()
        ]

  @spec format(integer() | nil, opts()) :: String.t()
  def format(cents, opts \\ [])

  def format(nil, opts), do: Keyword.get(opts, :nil_display, "—")

  def format(cents, opts) when is_integer(cents) do
    style = Keyword.get(opts, :style, :accounting)
    format_cents(style, cents)
  end

  defp format_cents(:accounting, 0), do: "$0.00"

  defp format_cents(:accounting, cents) do
    {sign, abs_cents} = if cents < 0, do: {"-", abs(cents)}, else: {"", cents}
    "#{sign}$#{format_dollars(abs_cents)}"
  end

  defp format_cents(:signed, cents) when cents < 0 do
    "+$#{format_dollars(abs(cents))}"
  end

  defp format_cents(:signed, cents) do
    "-$#{format_dollars(cents)}"
  end

  defp format_dollars(abs_cents) when is_integer(abs_cents) and abs_cents >= 0 do
    dollars = div(abs_cents, 100)
    remainder = rem(abs_cents, 100)

    "#{format_thousands(dollars)}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
  end

  defp format_thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end
end
