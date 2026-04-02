defmodule FinanceSmith.Identity do
  use Ash.Domain

  resources do
    resource FinanceSmith.Identity.Household

    resource FinanceSmith.Identity.User do
      define :register, action: :register, args: [:email, :password]
      define :sign_in, action: :sign_in, args: [:email, :password]
      define :generate_mfa_secret, action: :generate_mfa_secret
      define :enable_mfa, action: :enable_mfa, args: [:code]
      define :verify_mfa_login, action: :verify_mfa_login, args: [:code]
    end
  end

  @doc """
  Verifies email and password; returns {:ok, user} or {:error, :invalid_credentials}.
  """
  def verify_sign_in(email, password) do
    case sign_in(email, password, authorize?: false) do
      {:ok, [user | _]} ->
        if Bcrypt.verify_pass(password, user.password_hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end

      _ ->
        {:error, :invalid_credentials}
    end
  end
end
