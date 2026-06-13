defmodule FinanceSmith.Banking.PlaidErrorLog do
  @moduledoc """
  Normalizes Plaid errors into token-safe metadata for structured logging.
  """

  @max_message_len 300

  @spec from_reason(term()) :: map()
  def from_reason(%Plaid.Error{} = reason) do
    %{
      error_type: reason.error_type,
      error_code: reason.error_code,
      http_code: reason.http_code,
      request_id: reason.request_id,
      display_message: redact(reason.display_message),
      error_message: redact(reason.error_message)
    }
  end

  def from_reason(reason) do
    %{
      reason_class: reason |> classify_reason() |> to_string(),
      reason_message: reason |> inspect(limit: 10, printable_limit: @max_message_len) |> redact()
    }
  end

  @doc """
  Extracts a stable set of Plaid Link exit fields from LiveView event payloads.
  """
  @spec from_link_exit(map()) :: map()
  def from_link_exit(params) when is_map(params) do
    %{
      error_type: fetch(params, "error_type", :error_type),
      error_code: fetch(params, "error_code", :error_code),
      error_message: fetch(params, "error_message", :error_message) |> redact(),
      display_message: fetch(params, "display_message", :display_message) |> redact(),
      request_id: fetch(params, "request_id", :request_id),
      institution_id: fetch(params, "institution_id", :institution_id),
      institution_name: fetch(params, "institution_name", :institution_name),
      link_session_id: fetch(params, "link_session_id", :link_session_id),
      link_status: fetch(params, "link_status", :link_status)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp fetch(map, string_key, atom_key), do: Map.get(map, string_key) || Map.get(map, atom_key)

  defp classify_reason(reason) when is_atom(reason), do: :atom
  defp classify_reason(reason) when is_binary(reason), do: :binary
  defp classify_reason(reason) when is_map(reason), do: :map
  defp classify_reason(reason) when is_list(reason), do: :list
  defp classify_reason(reason) when is_tuple(reason), do: :tuple
  defp classify_reason(_reason), do: :other

  defp redact(nil), do: nil

  defp redact(value) when is_binary(value) do
    value
    |> String.replace(
      ~r/(access|public|link)_token\s*[:=]\s*["']?[^\s"',}]+["']?/i,
      "[REDACTED_TOKEN]"
    )
    |> String.replace(~r/\b(access|public|link)-[A-Za-z0-9\-_]+\b/, "[REDACTED_TOKEN]")
    |> String.slice(0, @max_message_len)
  end

  defp redact(value), do: value
end
