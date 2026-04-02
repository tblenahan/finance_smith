defmodule FinanceSmith.Identity.User.Changes.VerifyMfaLogin do
  @moduledoc """
  Validates the given code as either a TOTP code or a recovery code.
  If a recovery code is used, it is consumed (removed from the list).

  Loads the decrypted mfa_secret and recovery_codes inside a before_action hook
  so callers do not need to pre-load AshCloak calculations. Writes updated
  recovery_codes via AshCloak.encrypt_and_set/3.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    raw_code = Ash.Changeset.get_argument(changeset, :code)
    code = if raw_code, do: String.trim(raw_code), else: raw_code

    Ash.Changeset.before_action(changeset, fn cs ->
      loaded = Ash.load!(cs.data, [:mfa_secret, :recovery_codes], authorize?: false)
      base32_secret = loaded.mfa_secret
      recovery_codes_json = loaded.recovery_codes

      cond do
        is_nil(base32_secret) || base32_secret == "" ->
          Ash.Changeset.add_error(cs, "MFA is not enabled")

        true ->
          raw_secret = Base.decode32!(base32_secret, padding: false)

          cond do
            NimbleTOTP.valid?(raw_secret, code) ->
              cs

            recovery_code_valid?(recovery_codes_json, code) ->
              new_codes = remove_recovery_code(recovery_codes_json, code)
              AshCloak.encrypt_and_set(cs, :recovery_codes, new_codes)

            true ->
              Ash.Changeset.add_error(cs, "Invalid code")
          end
      end
    end)
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
