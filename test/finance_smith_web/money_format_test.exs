defmodule FinanceSmithWeb.MoneyFormatTest do
  use ExUnit.Case, async: true

  alias FinanceSmithWeb.MoneyFormat

  describe "format/2 with :accounting (default)" do
    test "zero renders as $0.00" do
      assert MoneyFormat.format(0) == "$0.00"
    end

    test "positive cents render with $ and no sign" do
      assert MoneyFormat.format(12_345) == "$123.45"
    end

    test "negative cents render with leading -" do
      assert MoneyFormat.format(-12_345) == "-$123.45"
    end

    test "thousands separators for large amounts" do
      assert MoneyFormat.format(1_234_567_89) == "$1,234,567.89"
    end

    test "nil defaults to em dash" do
      assert MoneyFormat.format(nil) == "—"
    end

    test "nil can be overridden per-caller" do
      assert MoneyFormat.format(nil, nil_display: "$0.00") == "$0.00"
    end
  end

  describe "format/2 with :signed" do
    test "Plaid negative cents (inflow) render with +" do
      assert MoneyFormat.format(-500, style: :signed) == "+$5.00"
    end

    test "Plaid positive cents (outflow) render with -" do
      assert MoneyFormat.format(500, style: :signed) == "-$5.00"
    end
  end
end
