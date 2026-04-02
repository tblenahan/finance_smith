defmodule FinanceSmith.Identity.User.Changes.VerifyMfaLogin do
  @moduledoc """
  Validates the given code as either a TOTP code or a recovery code.
  If a recovery code is used, it is consumed (removed from the list).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    code = Ash.Changeset.get_argument(changeset, :code)
    code = String.trim(code)
    base32_secret = Ash.Changeset.get_attribute(changeset, :mfa_secret)
    recovery_codes_json = Ash.Changeset.get_attribute(changeset, :recovery_codes)

    cond do
      is_nil(base32_secret) || base32_secret == "" ->
        Ash.Changeset.add_error(changeset, "MFA is not enabled")

      true ->
        raw_secret = decode_secret(base32_secret)

        cond do
          # Try TOTP first
          NimbleTOTP.valid?(raw_secret, code) ->
            changeset

          # Then try recovery code
          recovery_code_valid?(recovery_codes_json, code) ->
            new_codes = remove_recovery_code(recovery_codes_json, code)
            Ash.Changeset.change_attribute(changeset, :recovery_codes, new_codes)

          true ->
            Ash.Changeset.add_error(changeset, "Invalid code")
        end
    end
  end

  defp decode_secret(base32) do
    Base.decode32!(base32, padding: false)
  end

  defp recovery_code_valid?(nil, _code), do: false
  defp recovery_code_valid?("", _code), do: false

  defp recovery_code_valid?(json, code) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> code in list
      _ -> false
    end
  end

  defp remove_recovery_code(json, used_code) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        list
        |> List.delete(used_code)
        |> Jason.encode!()

      _ ->
        json
    end
  end
end
