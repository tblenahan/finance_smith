defmodule FinanceSmith.Banking.PlaidStrings do
  @moduledoc """
  Normalizes Plaid-provided string fields (type, subtype, etc.) for consistent
  storage and duplicate-account fingerprint matching.
  """

  @spec normalize(nil | atom() | binary()) :: nil | binary()
  def normalize(nil), do: nil
  def normalize(s) when is_atom(s), do: s |> Atom.to_string() |> String.downcase()
  def normalize(s) when is_binary(s), do: String.downcase(s)
end
