defmodule FinanceSmith.Identity.User.Changes.RecordFailedLogin do
  @moduledoc """
  Increments failed_auth_attempts on the user record.
  If the count reaches @lockout_threshold, sets locked_until to 15 minutes
  in the future and resets the counter.

  Used by the :record_failed_login action, called by verify_sign_in/2 on
  password mismatch.
  """
  use Ash.Resource.Change

  @lockout_threshold 5
  @lockout_minutes 15

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      new_attempts = (cs.data.failed_auth_attempts || 0) + 1

      if new_attempts >= @lockout_threshold do
        cs
        |> Ash.Changeset.force_change_attribute(:failed_auth_attempts, 0)
        |> Ash.Changeset.force_change_attribute(
          :locked_until,
          DateTime.add(DateTime.utc_now(), @lockout_minutes * 60, :second)
        )
      else
        Ash.Changeset.force_change_attribute(cs, :failed_auth_attempts, new_attempts)
      end
    end)
  end
end
