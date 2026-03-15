defmodule FinanceSmith.Identity do
  use Ash.Domain

  resources do
    resource FinanceSmith.Identity.Household
    resource FinanceSmith.Identity.User
  end
end
