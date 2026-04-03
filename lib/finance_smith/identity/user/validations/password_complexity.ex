defmodule FinanceSmith.Identity.User.Validations.PasswordComplexity do
  @moduledoc """
  Validates that a password argument is not all-whitespace and contains
  at least one letter and one digit.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    password = Ash.Changeset.get_argument(changeset, :password)

    cond do
      is_nil(password) ->
        :ok

      String.trim(password) == "" ->
        {:error, field: :password, message: "cannot be blank or whitespace only"}

      not Regex.match?(~r/[a-zA-Z]/, password) ->
        {:error, field: :password, message: "must contain at least one letter"}

      not Regex.match?(~r/[0-9]/, password) ->
        {:error, field: :password, message: "must contain at least one number"}

      true ->
        :ok
    end
  end
end
