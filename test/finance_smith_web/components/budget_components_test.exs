defmodule FinanceSmithWeb.BudgetComponentsTest do
  use ExUnit.Case, async: true

  alias FinanceSmithWeb.BudgetComponents

  describe "pace_tier/2" do
    test "returns :no_target when the scaled target is zero or negative" do
      assert BudgetComponents.pace_tier(1_000, 0) == :no_target
      assert BudgetComponents.pace_tier(1_000, -100) == :no_target
    end

    test "returns :cruising below 85% of the scaled target" do
      assert BudgetComponents.pace_tier(84, 100) == :cruising
      assert BudgetComponents.pace_tier(0, 100) == :cruising
    end

    test "returns :on_pace from 85% through 100%" do
      assert BudgetComponents.pace_tier(85, 100) == :on_pace
      assert BudgetComponents.pace_tier(100, 100) == :on_pace
    end

    test "returns :tight just over 100% through 115%" do
      assert BudgetComponents.pace_tier(101, 100) == :tight
      assert BudgetComponents.pace_tier(115, 100) == :tight
    end

    test "returns :over above 115%" do
      assert BudgetComponents.pace_tier(116, 100) == :over
      assert BudgetComponents.pace_tier(200, 100) == :over
    end
  end

  describe "percent_of_limit/2" do
    test "returns nil when there is no scaled target" do
      assert BudgetComponents.percent_of_limit(50, 0) == nil
      assert BudgetComponents.percent_of_limit(50, -1) == nil
    end

    test "rounds actual spend as a percent of the scaled target" do
      assert BudgetComponents.percent_of_limit(50, 100) == 50
      assert BudgetComponents.percent_of_limit(1, 3) == 33
      assert BudgetComponents.percent_of_limit(2, 3) == 67
    end
  end
end
