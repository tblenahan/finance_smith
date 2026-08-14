defmodule FinanceSmith.Banking.BudgetTarget.Changes.SetHouseholdFromActor do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %{household_id: household_id}})
      when not is_nil(household_id) do
    Ash.Changeset.force_change_attribute(changeset, :household_id, household_id)
  end

  # System calls (authorize?: false, no actor) must set household_id via
  # force_change_attribute on the changeset before calling Ash.create!/2.
  def change(changeset, _opts, _context), do: changeset
end
