defmodule FinanceSmith.Banking.Changes.SetActorContext do
  @moduledoc """
  Stamps `household_id` and `created_by_id` from the actor on create.

  Both MetaCategory and CategoryMapping are household-owned resources created
  by an authenticated user. This change derives the two FK values directly from
  the actor so neither field needs to be accepted in the action's `accept` list
  (which would allow callers to forge ownership).

  When `authorize?: false` is used in tests without an actor, the changeset is
  returned unchanged — the caller must supply the attributes manually or pass a
  test actor.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: nil}), do: changeset

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    changeset
    |> Ash.Changeset.force_change_attribute(:household_id, actor.household_id)
    |> Ash.Changeset.force_change_attribute(:created_by_id, actor.id)
  end
end
