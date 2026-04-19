defmodule FinanceSmith.Identity.User.Changes.RegisterAndJoin do
  @moduledoc """
  Hashes the new user's password and attaches them to an existing household
  by verifying an existing member's credentials as an inline authorization gate.

  This change deliberately does NOT route through `verify_sign_in/2` so that
  a form typo does not increment the existing member's lockout counter.
  Bcrypt primitives are used directly, matching the same verification logic.
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
          if Bcrypt.verify_pass(existing_password, existing_user.password_hash) do
            hash_and_join(cs, existing_user)
          else
            Ash.Changeset.add_error(cs,
              field: :existing_member_password,
              message: "Invalid credentials."
            )
          end

        :not_found ->
          # Constant-time guard — do not reveal whether the email exists.
          Bcrypt.no_user_verify()

          Ash.Changeset.add_error(cs,
            field: :existing_member_password,
            message: "Invalid credentials."
          )
      end
    end)
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
    |> Ash.Changeset.change_attribute(:password_hash, hashed)
    |> Ash.Changeset.manage_relationship(:household, existing_user.household,
      type: :append_and_remove
    )
  end
end
