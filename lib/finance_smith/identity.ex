defmodule FinanceSmith.Identity do
  use Ash.Domain

  resources do
    resource FinanceSmith.Identity.Household do
      # Used by the dashboard to load household-level KPI aggregates.
      define :get_household_with_kpis, action: :read, get_by: [:id]
    end

    resource FinanceSmith.Identity.User do
      define :register, action: :register, args: [:email, :password]
      define :sign_in, action: :sign_in, args: [:email, :password]
      define :generate_mfa_secret, action: :generate_mfa_secret
      define :enable_mfa, action: :enable_mfa, args: [:code]
      define :verify_mfa_login, action: :verify_mfa_login, args: [:code]
      define :record_failed_login, action: :record_failed_login
      define :clear_auth_lockout, action: :clear_auth_lockout

      # Used by the dashboard to load user-level KPI aggregates.
      define :get_user_with_kpis, action: :read, get_by: [:id]
    end
  end

  @doc """
  Verifies email and password; returns {:ok, user} or {:error, reason}.

  Enforces persistent brute-force lockout: if the user's locked_until is in
  the future, returns {:error, {:locked, remaining_seconds}}. On password
  failure, increments failed_auth_attempts and locks after 5 consecutive
  failures. On success, resets the counter.
  """
  def verify_sign_in(email, password) do
    case sign_in(email, password, authorize?: false) do
      {:ok, [user | _]} ->
        if user.locked_until && DateTime.compare(user.locked_until, DateTime.utc_now()) == :gt do
          remaining =
            DateTime.diff(user.locked_until, DateTime.utc_now(), :second) |> Kernel.max(1)

          {:error, {:locked, remaining}}
        else
          if Bcrypt.verify_pass(password, user.password_hash) do
            clear_auth_lockout(user, authorize?: false)
            {:ok, user}
          else
            record_failed_login(user, authorize?: false)
            {:error, :invalid_credentials}
          end
        end

      _ ->
        # Don't reveal whether the email exists; still constant-time.
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
    end
  end
end
