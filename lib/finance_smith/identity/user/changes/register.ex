defmodule FinanceSmith.Identity.User.Changes.Register do
  @moduledoc """
  Hashes the password and creates a household for the new user.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    password = Ash.Changeset.get_argument(changeset, :password)
    household_name = Ash.Changeset.get_argument(changeset, :household_name) || "My Household"

    hashed = Bcrypt.hash_pwd_salt(password)

    changeset
    |> Ash.Changeset.change_attribute(:password_hash, hashed)
    |> Ash.Changeset.before_action(fn cs ->
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
