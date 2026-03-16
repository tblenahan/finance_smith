defmodule FinanceSmith.DataLake.KeyBuilder do
  @moduledoc """
  Generates time-partitioned B2 object keys for raw Plaid sync responses.

  Key format (FR-1.2):
      plaid_sync/{household_id}/{plaid_item_id}/{YYYY}/{MM}/{timestamp}.json

  - `household_id`  — UUID of the household owning the PlaidItem (requires
    `plaid_item.user.household` to be loaded before calling `build/2`).
  - `plaid_item_id` — Plaid's own item ID string (not our internal UUID).
  - `YYYY/MM`       — Year and zero-padded month derived from the provided UTC DateTime.
  - `timestamp`     — ISO 8601 UTC timestamp with microseconds, with colons
    replaced by dashes to ensure filesystem safety.
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
    plaid_item_id = plaid_item.plaid_item_id
    year = executed_at.year |> Integer.to_string()
    month = executed_at.month |> Integer.to_string() |> String.pad_leading(2, "0")
    timestamp = DateTime.to_iso8601(executed_at) |> String.replace(":", "-")

    "plaid_sync/#{household_id}/#{plaid_item_id}/#{year}/#{month}/#{timestamp}.json"
  end

  @doc """
  Extracts the Plaid item ID from an object key produced by `build/2`.

  Returns `{:ok, plaid_item_id}` or `:error` if the key does not match the
  expected format.
  """
  @spec extract_plaid_item_id(String.t()) :: {:ok, String.t()} | :error
  def extract_plaid_item_id(object_key) do
    case String.split(object_key, "/") do
      ["plaid_sync", _household_id, plaid_item_id | _rest] when plaid_item_id != "" ->
        {:ok, plaid_item_id}

      _ ->
        :error
    end
  end
end
