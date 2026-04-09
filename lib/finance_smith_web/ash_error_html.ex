defmodule FinanceSmithWeb.AshErrorHTML do
  @moduledoc """
  Safe, user-facing formatter for Ash validation errors.

  Ash stores constraint violation messages as templates with `%{key}` placeholders
  and keeps the actual values on the exception's `vars` field (matching Splode's
  interpolation contract).  The standard `Exception.message/1` on `InvalidArgument`
  errors appends `inspect(value)`, which would echo sensitive input (e.g. passwords)
  into the UI.  This module builds readable strings without ever revealing raw input
  values.
  """

  @invalid_argument_modules [
    Ash.Error.Action.InvalidArgument,
    Ash.Error.Changes.InvalidArgument
  ]

  # Keys that live on every Splode error struct but are not template vars.
  @meta_keys [
    :field,
    :message,
    :value,
    :path,
    :vars,
    :bread_crumbs,
    :stacktrace,
    :splode,
    :class,
    :fields,
    :has_value?,
    :private_vars
  ]

  @doc """
  Formats an Ash error into a short, human-readable string safe for display in the UI.

  Handles `%Ash.Error.Invalid{}` (the typical wrapper) by collecting and joining
  the individual nested errors.  Falls back gracefully for any other error shape.
  """
  @spec format_for_user(term()) :: String.t()
  def format_for_user(%Ash.Error.Invalid{errors: [_ | _] = errors}) do
    errors
    |> Enum.map(&format_nested/1)
    |> Enum.join(", ")
  end

  def format_for_user(%Ash.Error.Invalid{}) do
    "We have a... discrepancy."
  end

  def format_for_user(error) when is_exception(error) do
    generic_safe_message(error)
  end

  def format_for_user(_), do: "We have a... discrepancy."

  # -- Private helpers -------------------------------------------------------

  # Handle InvalidArgument errors (both action and changeset variants) specially:
  # interpolate the template but never append inspect(value).
  defp format_nested(%module{} = err) when module in @invalid_argument_modules do
    template = Map.get(err, :message) || ""
    vars = normalise_vars(Map.get(err, :vars, []))
    field = Map.get(err, :field)

    interpolated = interpolate(template, vars)

    friendly_message(field, interpolated, vars)
  end

  defp format_nested(err) when is_exception(err) do
    generic_safe_message(err)
  end

  defp format_nested(err) when is_map(err) do
    template = Map.get(err, :message) || ""
    vars = normalise_vars(Map.get(err, :vars, []))
    field = Map.get(err, :field)

    interpolated = interpolate(template, vars)
    friendly_message(field, interpolated, vars)
  end

  defp format_nested(_), do: "We have a... discrepancy."

  # Produce a friendly sentence.  For password min-length violations, the Ash
  # template mentions "length must be greater than or equal to N" which is
  # technically correct but not clear to users.  Rewrite to something actionable.
  defp friendly_message(:password, msg, vars) do
    cond do
      min = vars[:min] ->
        "Password must be at least #{min} characters."

      max = vars[:max] ->
        "Password must be no more than #{max} characters."

      true ->
        cap_sentence(msg)
    end
  end

  defp friendly_message(_field, msg, _vars) do
    cap_sentence(msg)
  end

  # Ensure the message starts with a capital letter and ends with a period.
  defp cap_sentence(msg) when is_binary(msg) do
    case String.trim(msg) do
      "" ->
        "We have a... discrepancy."

      trimmed ->
        first = String.first(trimmed) |> String.upcase()
        rest = String.slice(trimmed, 1..-1//1)
        sentence = first <> rest
        if String.ends_with?(sentence, "."), do: sentence, else: sentence <> "."
    end
  end

  # Replaces %{key} placeholders in `template` with values from `vars`.
  defp interpolate(template, vars) when is_binary(template) do
    Enum.reduce(vars, template, fn {key, value}, acc ->
      placeholder = "%{#{key}}"

      if String.contains?(acc, placeholder) do
        String.replace(acc, placeholder, to_string(value))
      else
        acc
      end
    end)
  end

  defp interpolate(_, _), do: ""

  # Normalise vars to a keyword list of non-meta atoms.
  defp normalise_vars(vars) when is_map(vars) do
    vars
    |> Enum.reject(fn {k, _} -> k in @meta_keys end)
    |> Enum.map(fn {k, v} -> {k, v} end)
  end

  defp normalise_vars(vars) when is_list(vars) do
    vars
    |> Keyword.drop(@meta_keys)
  end

  defp normalise_vars(_), do: []

  # Safe fallback for exceptions that are not InvalidArgument.
  # We avoid calling Exception.message/1 on InvalidArgument because that impl
  # always ends with `inspect(value)`.
  defp generic_safe_message(%module{} = error) when module in @invalid_argument_modules do
    template = Map.get(error, :message) || ""
    vars = normalise_vars(Map.get(error, :vars, []))
    interpolated = interpolate(template, vars)
    cap_sentence(interpolated)
  end

  defp generic_safe_message(error) when is_exception(error) do
    error |> Exception.message() |> String.trim() |> cap_sentence()
  end
end
