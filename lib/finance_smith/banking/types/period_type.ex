defmodule FinanceSmith.Banking.Types.PeriodType do
  use Ash.Type.Enum, values: [:weekly, :monthly, :quarterly, :yearly]
end
