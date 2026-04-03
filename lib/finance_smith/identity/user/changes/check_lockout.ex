defmodule FinanceSmith.Identity.User.Changes.CheckLockout do
  @moduledoc """
  Reusable Ash change that blocks an action if the user's locked_until
  timestamp is still in the future.

  Add this change to any action that should be rate-limited (e.g.
  :verify_mfa_login). It runs as a before_action hook so that a locked user
  never reaches the main action body.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      locked_until = cs.data.locked_until

      if locked_until && DateTime.compare(locked_until, DateTime.utc_now()) == :gt do
        remaining =
          locked_until
          |> DateTime.diff(DateTime.utc_now(), :second)
          |> max(1)

        Ash.Changeset.add_error(cs,
          message: "Account locked. Try again in #{remaining} seconds.",
          field: :code
        )
      else
        cs
      end
    end)
  end
end
