defmodule FinanceSmith.DataLake.Uploader do
  @moduledoc """
  Uploads raw Plaid transaction sync responses to Backblaze B2.

  Called immediately after a successful `FinanceSmith.Banking.Plaid.sync_transactions/1`
  call. The response struct is serialized to JSON before upload so the B2 object
  contains the complete Plaid payload in a portable format.

  The struct is converted to a JSON-safe map tree before encoding to avoid
  any dependency on Plaid's choice of JSON library. Date and DateTime values
  are converted to ISO 8601 strings.
  """

  alias FinanceSmith.DataLake.{B2, KeyBuilder}
  alias FinanceSmith.Banking.PlaidItem

  require Ash.Query

  @doc """
  Converts a Plaid sync response struct into a string-keyed map suitable for
  both B2 archival (via `Jason.encode!/1`) and direct processing by
  `TransactionProcessor`.

  Handles nested structs, `Date`, `DateTime`, atoms, and lists recursively.
  """
  @spec to_sync_payload(term()) :: map()
  def to_sync_payload(sync_response), do: to_encodable(sync_response)

  @doc """
  Serializes `sync_response` and uploads it to B2 under the time-partitioned key.

  `plaid_item` must have `user` and `user.household` loaded, or they will be
  loaded automatically.

  Returns `{:ok, object_key}` on success or `{:error, reason}` on failure.
  """
  @spec upload_sync_response(PlaidItem.t(), term()) :: {:ok, String.t()} | {:error, term()}
  def upload_sync_response(%PlaidItem{} = plaid_item, sync_response) do
    with {:ok, loaded_item} <- ensure_household_loaded(plaid_item),
         {:ok, json} <- encode(sync_response),
         object_key = KeyBuilder.build(loaded_item, DateTime.utc_now()),
         {:ok, _file_id} <- B2.upload_file(object_key, json) do
      {:ok, object_key}
    end
  end

  # --- Private helpers ------------------------------------------------------

  defp ensure_household_loaded(%PlaidItem{user: %Ash.NotLoaded{}} = item) do
    case Ash.load(item, user: :household) do
      {:ok, loaded} -> {:ok, loaded}
      {:error, reason} -> {:error, {:household_load_failed, reason}}
    end
  end

  defp ensure_household_loaded(%PlaidItem{user: user} = item)
       when not is_nil(user) do
    case user do
      %{household: %Ash.NotLoaded{}} ->
        case Ash.load(item, user: :household) do
          {:ok, loaded} -> {:ok, loaded}
          {:error, reason} -> {:error, {:household_load_failed, reason}}
        end

      _ ->
        {:ok, item}
    end
  end

  defp encode(sync_response) do
    json = sync_response |> to_encodable() |> Jason.encode!()
    {:ok, json}
  rescue
    e -> {:error, {:json_encode_failed, Exception.message(e)}}
  end

  # Recursively converts any Elixir struct/map/list to a JSON-safe
  # representation without relying on the struct's Jason.Encoder implementation.
  defp to_encodable(%Date{} = d), do: Date.to_iso8601(d)
  defp to_encodable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_encodable(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)

  defp to_encodable(value) when is_struct(value) do
    value |> Map.from_struct() |> to_encodable()
  end

  defp to_encodable(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), to_encodable(v)} end)
  end

  defp to_encodable(value) when is_list(value) do
    Enum.map(value, &to_encodable/1)
  end

  defp to_encodable(value) when is_atom(value) and not is_nil(value) and not is_boolean(value) do
    to_string(value)
  end

  defp to_encodable(value), do: value
end
