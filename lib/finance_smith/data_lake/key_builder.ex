defmodule FinanceSmith.DataLake.KeyBuilder do
  @moduledoc """
  Generates time-partitioned B2 object keys for raw Plaid sync responses.

  Key format (FR-1.2):
      plaid_sync/{household_id}/{user_id}/{plaid_item_id}/{YYYY}/{MM}/{timestamp}.json

  - `household_id`  — UUID of the household owning the PlaidItem (requires
    `plaid_item.user.household` to be loaded before calling `build/2`).
  - `user_id`       — UUID of the `Identity.User` that owns the PlaidItem
    (available directly as `plaid_item.user_id`; no extra load required).
  - `plaid_item_id` — Plaid's own item ID string (not our internal UUID).
  - `YYYY/MM`       — Year and zero-padded month derived from the provided UTC DateTime.
  - `timestamp`     — ISO 8601 UTC timestamp with microseconds, with colons
    replaced by dashes to ensure filesystem safety.

  ## Legacy key layout

  A previous layout — `plaid_sync/{household_id}/{plaid_item_id}/{YYYY}/…` — omitted
  the `user_id` segment. Keys in that form are **not** recognized by
  `extract_plaid_item_id/1` and will return `:error`. Any objects archived under the
  old layout must be re-keyed to the current format before they can be replayed by
  `TransactionProcessor`.
  """

  alias FinanceSmith.Banking.PlaidItem

  @doc """
  Builds the B2 object key for a sync response.

  `plaid_item` must have `user` and `user.household` loaded.
  `executed_at` should be the UTC DateTime when the sync job ran.
  """
  @spec build(PlaidItem.t(), DateTime.t()) :: String.t()
  def build(%PlaidItem{} = plaid_item, %DateTime{} = executed_at) do
    household_id = plaid_item.user.household_id
    user_id = plaid_item.user_id
    plaid_item_id = plaid_item.plaid_item_id
    year = executed_at.year |> Integer.to_string()
    month = executed_at.month |> Integer.to_string() |> String.pad_leading(2, "0")
    timestamp = DateTime.to_iso8601(executed_at) |> String.replace(":", "-")

    "plaid_sync/#{household_id}/#{user_id}/#{plaid_item_id}/#{year}/#{month}/#{timestamp}.json"
  end

  @doc """
  Extracts the Plaid item ID from an object key produced by `build/2`.

  Returns `{:ok, plaid_item_id}` or `:error` if the key does not match the
  expected format.
  """
  @spec extract_plaid_item_id(String.t()) :: {:ok, String.t()} | :error
  def extract_plaid_item_id(object_key) do
    case String.split(object_key, "/") do
      ["plaid_sync", _household_id, _user_id, plaid_item_id, year | _rest]
      when plaid_item_id != "" ->
        if numeric_year?(year), do: {:ok, plaid_item_id}, else: :error

      _ ->
        :error
    end
  end

  defp numeric_year?(<<a, b, c, d>>)
       when a in ?0..?9 and b in ?0..?9 and c in ?0..?9 and d in ?0..?9,
       do: true

  defp numeric_year?(_), do: false
end
