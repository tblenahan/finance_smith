defmodule FinanceSmith.Identity.User.Changes.GenerateMfaSecret do
  @moduledoc """
  Generates a new TOTP secret and assigns it to the user.
  Resets mfa_enabled and recovery_codes so MFA must be re-enabled with the new secret.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    raw_secret = NimbleTOTP.secret()
    base32_secret = Base.encode32(raw_secret, padding: false)

    changeset
    |> Ash.Changeset.change_attribute(:mfa_secret, base32_secret)
    |> Ash.Changeset.change_attribute(:mfa_enabled, false)
    |> Ash.Changeset.change_attribute(:recovery_codes, nil)
  end
end
