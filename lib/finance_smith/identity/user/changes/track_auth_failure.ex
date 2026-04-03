defmodule FinanceSmith.Identity.User.Changes.TrackAuthFailure do
  @moduledoc """
  After-transaction hook that persists brute-force lockout state on the User
  record.

  On failure: increments failed_auth_attempts. If the new total meets or
  exceeds @lockout_threshold, sets locked_until to 15 minutes in the future
  and resets the counter.

  On success: resets failed_auth_attempts to 0 and clears locked_until.

  Uses a direct Ash update with authorize?: false because this runs in an
  after_transaction callback — outside the original transaction and before a
  user actor is reliably available.
  """
  use Ash.Resource.Change

  @lockout_threshold 5
  @lockout_minutes 15

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn cs, result ->
      user = cs.data

      case result do
        {:ok, _} ->
          reset_lockout(user)
          result

        {:error, _} ->
          record_failure(user)
          result
      end
    end)
  end

  defp record_failure(user) do
    new_attempts = (user.failed_auth_attempts || 0) + 1

    attrs =
      if new_attempts >= @lockout_threshold do
        %{
          failed_auth_attempts: 0,
          locked_until: DateTime.add(DateTime.utc_now(), @lockout_minutes * 60, :second)
        }
      else
        %{failed_auth_attempts: new_attempts}
      end

    user
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(authorize?: false)
  end

  defp reset_lockout(user) do
    user
    |> Ash.Changeset.for_update(:update, %{failed_auth_attempts: 0, locked_until: nil})
    |> Ash.update(authorize?: false)
  end
end
