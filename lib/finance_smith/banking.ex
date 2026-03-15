defmodule FinanceSmith.Banking do
  use Ash.Domain

  resources do
    resource FinanceSmith.Banking.PlaidItem
    resource FinanceSmith.Banking.Account
    resource FinanceSmith.Banking.Transaction
  end
end
