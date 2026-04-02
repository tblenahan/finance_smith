defmodule FinanceSmith.Identity.User.Changes.EnableMfa do
  @moduledoc """
  Validates the 6-digit TOTP code against the stored secret.
  On success: sets mfa_enabled to true and generates 10 recovery codes.
  On failure: adds a validation error.
  """
  use Ash.Resource.Change

  @recovery_code_count 10
  @recovery_code_length 8

  @impl true
  def change(changeset, _opts, _context) do
    code = Ash.Changeset.get_argument(changeset, :code)
    base32_secret = Ash.Changeset.get_attribute(changeset, :mfa_secret)

    if is_nil(base32_secret) || base32_secret == "" do
      Ash.Changeset.add_error(changeset, "No MFA secret found. Generate a secret first.")
    else
      raw_secret = decode_secret(base32_secret)

      if NimbleTOTP.valid?(raw_secret, code) do
        recovery_codes = generate_recovery_codes(@recovery_code_count)
        json_codes = Jason.encode!(recovery_codes)

        changeset
        |> Ash.Changeset.change_attribute(:mfa_enabled, true)
        |> Ash.Changeset.change_attribute(:recovery_codes, json_codes)
      else
        Ash.Changeset.add_error(changeset, "Invalid verification code")
      end
    end
  end

  defp decode_secret(base32) do
    # Base.encode32 with padding: false may produce strings without padding; decode32! accepts both
    Base.decode32!(base32, padding: false)
  end

  defp generate_recovery_codes(count) do
    # 8-character alphanumeric codes (A-Z, 0-9); use crypto RNG
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
