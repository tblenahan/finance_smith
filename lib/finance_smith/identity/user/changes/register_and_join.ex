defmodule FinanceSmith.Identity.User.Changes.RegisterAndJoin do
  @moduledoc """
  Hashes the new user's password and attaches them to an existing household
  by verifying an existing member's credentials as an inline authorization gate.

  This change deliberately does NOT route through `verify_sign_in/2` so that
  a form typo does not increment the existing member's lockout counter.
  Bcrypt primitives are used directly, matching the same verification logic.

  A sponsor whose account is currently locked (`locked_until` in the future)
  cannot authorize a join. The error is the same generic "Invalid credentials."
  as a wrong password to avoid leaking lockout state to unauthenticated callers.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      existing_email = Ash.Changeset.get_argument(cs, :existing_member_email)
      existing_password = Ash.Changeset.get_argument(cs, :existing_member_password)

      case look_up_existing_member(existing_email) do
        {:ok, existing_user} ->
          cond do
            locked_out?(existing_user) ->
              add_invalid_credentials_error(cs)

            Bcrypt.verify_pass(existing_password, existing_user.password_hash) ->
              hash_and_join(cs, existing_user)

            true ->
              add_invalid_credentials_error(cs)
          end

        :not_found ->
          # Constant-time guard — do not reveal whether the email exists.
          Bcrypt.no_user_verify()
          add_invalid_credentials_error(cs)
      end
    end)
  end

  defp locked_out?(%{locked_until: nil}), do: false

  defp locked_out?(%{locked_until: %DateTime{} = locked_until}) do
    DateTime.compare(locked_until, DateTime.utc_now()) == :gt
  end

  defp add_invalid_credentials_error(cs) do
    Ash.Changeset.add_error(cs,
      field: :existing_member_password,
      message: "Invalid credentials."
    )
  end

  defp look_up_existing_member(email) do
    # authorize?: false: internal credential-gate lookup during registration,
    # where no actor exists. Result is consumed only by Bcrypt.verify_pass/2
    # and never returned to the caller.
    FinanceSmith.Identity.User
    |> Ash.Query.filter(email == ^email)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(:household)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [user | _]} -> {:ok, user}
      _ -> :not_found
    end
  end

  defp hash_and_join(cs, existing_user) do
    password = Ash.Changeset.get_argument(cs, :password)
    hashed = Bcrypt.hash_pwd_salt(password)

    cs
    |> Ash.Changeset.force_change_attribute(:password_hash, hashed)
    |> Ash.Changeset.manage_relationship(:household, existing_user.household,
      type: :append_and_remove
    )
  end
end
