defmodule FinanceSmith.Banking.Types.AccountStatus do
  use Ash.Type.Enum, values: [:active, :quarantined, :hidden]
end
