defmodule FinanceSmith.Banking.Plaid.SyncTransactionsResponse do
  @moduledoc """
  App-owned decode target for Plaid `/transactions/sync` responses.

  Mirrors `Plaid.Transactions.Sync` but includes `accounts` with cached
  balances — a field the upstream `plaid_elixir` struct omits.
  """

  @derive Jason.Encoder
  defstruct [
    :added,
    :modified,
    :removed,
    :next_cursor,
    :has_more,
    :request_id,
    accounts: []
  ]

  @type t :: %__MODULE__{
          added: [Plaid.Transactions.Transaction.t()],
          modified: [Plaid.Transactions.Transaction.t()],
          removed: [Plaid.Transactions.RemovedTransaction.t()],
          next_cursor: String.t() | nil,
          has_more: boolean() | nil,
          request_id: String.t() | nil,
          accounts: [Plaid.Accounts.Account.t()]
        }
end
