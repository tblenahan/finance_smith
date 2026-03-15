defmodule FinanceSmith.Banking.Types.PlaidItemStatus do
  use Ash.Type.Enum, values: [:active, :error, :disconnected]
end
