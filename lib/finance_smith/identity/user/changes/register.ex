defmodule FinanceSmith.Identity.User.Changes.Register do
  @moduledoc """
  Hashes the password and creates a household for the new user.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    household_name = Ash.Changeset.get_argument(changeset, :household_name) || "My Household"

    # Hash password and create household inside before_action so that Ash
    # argument validations (min_length, complexity) run first. If validation
    # fails the hook never executes, preventing Bcrypt from receiving nil.
    Ash.Changeset.before_action(changeset, fn cs ->
      password = Ash.Changeset.get_argument(cs, :password)
      hashed = Bcrypt.hash_pwd_salt(password)
      cs = Ash.Changeset.change_attribute(cs, :password_hash, hashed)

      household_result =
        FinanceSmith.Identity.Household
        |> Ash.Changeset.for_create(:create, %{name: household_name})
        |> Ash.create(authorize?: false)

      case household_result do
        {:ok, household} ->
          Ash.Changeset.manage_relationship(cs, :household, household, type: :append_and_remove)

        {:error, _} ->
          Ash.Changeset.add_error(cs, "Could not create household")
      end
    end)
  end
end
