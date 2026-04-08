defmodule FinanceSmith.Identity.User.Changes.EnableMfa do
  @moduledoc """
  Validates the 6-digit TOTP code against the stored secret.
  On success: sets mfa_enabled to true and generates 10 recovery codes.
  On failure: adds a validation error.

  Loads the decrypted mfa_secret inside a before_action hook so callers do not
  need to pre-load the AshCloak calculation. Writes recovery_codes via
  AshCloak.encrypt_and_set/3.
  """
  use Ash.Resource.Change

  @recovery_code_count 10
  @recovery_code_length 8

  @impl true
  def change(changeset, _opts, _context) do
    code = Ash.Changeset.get_argument(changeset, :code)

    Ash.Changeset.before_action(changeset, fn cs ->
      # authorize?: false is correct here — this load is internal to the action's
      # own transaction. The action-level policy is the authorization boundary.
      case Ash.load(cs.data, :mfa_secret, authorize?: false) do
        {:ok, loaded} ->
          base32_secret = loaded.mfa_secret

          if is_nil(base32_secret) || base32_secret == "" do
            Ash.Changeset.add_error(cs, "No MFA secret found. Generate a secret first.")
          else
            raw_secret = Base.decode32!(base32_secret, padding: false)

            if NimbleTOTP.valid?(raw_secret, code) do
              recovery_codes = generate_recovery_codes(@recovery_code_count)
              json_codes = Jason.encode!(recovery_codes)

              cs
              |> Ash.Changeset.force_change_attribute(:mfa_enabled, true)
              |> AshCloak.encrypt_and_set(:recovery_codes, json_codes)
            else
              Ash.Changeset.add_error(cs, "Invalid verification code")
            end
          end

        {:error, _} ->
          Ash.Changeset.add_error(
            cs,
            "MFA configuration error. Generate a new secret and try again."
          )
      end
    end)
  end

  defp generate_recovery_codes(count) do
    alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    base = length(alphabet)

    for _ <- 1..count do
      bytes = :crypto.strong_rand_bytes(@recovery_code_length)

      bytes
      |> :binary.bin_to_list()
      |> Enum.map(&rem(&1, base))
      |> Enum.map(&(alphabet |> Enum.at(&1) |> List.wrap() |> List.to_string()))
      |> Enum.join()
    end
  end
end
