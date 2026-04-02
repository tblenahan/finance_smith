defmodule FinanceSmith.Identity.User.Changes.GenerateMfaSecret do
  @moduledoc """
  Generates a new TOTP secret and assigns it to the user.
  Resets mfa_enabled and recovery_codes so MFA must be re-enabled with the new secret.

  Uses AshCloak.encrypt_and_set/3 to write the encrypted attribute correctly,
  and force_change_attribute to NULL-out the encrypted_recovery_codes column.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    raw_secret = NimbleTOTP.secret()
    base32_secret = Base.encode32(raw_secret, padding: false)

    changeset
    |> AshCloak.encrypt_and_set(:mfa_secret, base32_secret)
    |> Ash.Changeset.change_attribute(:mfa_enabled, false)
    |> Ash.Changeset.force_change_attribute(:encrypted_recovery_codes, nil)
  end
end
