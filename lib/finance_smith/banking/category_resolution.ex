defmodule FinanceSmith.Banking.CategoryResolution do
  @moduledoc """
  Shared helpers for resolving and persisting Plaid category mappings.

  Used by both the live `TransactionProcessor` (Oban job path) and the
  one-shot backfill/alignment scripts so that the logic lives in one place
  and both paths stay in sync.
  """

  alias FinanceSmith.Banking.{CategoryMapping, MetaCategory}

  require Ash.Query

  @doc """
  Returns the household's `"Uncategorized"` `MetaCategory`, creating it if it
  does not yet exist. Uses an upsert to be safe under concurrent Oban workers.
  """
  @spec ensure_fallback_meta_category!(Ash.UUID.t()) :: MetaCategory.t()
  def ensure_fallback_meta_category!(household_id) do
    existing =
      MetaCategory
      |> Ash.Query.filter(household_id == ^household_id and name == "Uncategorized")
      |> Ash.read_one!(authorize?: false)

    case existing do
      nil ->
        MetaCategory
        |> Ash.Changeset.for_create(:create_system, %{
          name: "Uncategorized",
          household_id: household_id
        })
        |> Ash.create!(
          authorize?: false,
          upsert?: true,
          upsert_identity: :unique_name_per_household
        )

      meta_category ->
        meta_category
    end
  end

  @doc """
  Bulk-creates `CategoryMapping` rows for `tokens` under the given
  `household_id` and `meta_category_id`. On conflict (two concurrent workers
  racing on the same token) only `:updated_at` is touched to avoid
  overwriting any manual remapping done between the pre-load check and this write.

  Raises on bulk failure.
  """
  @spec bulk_create_mappings!([String.t()], Ash.UUID.t(), Ash.UUID.t()) :: :ok
  def bulk_create_mappings!(tokens, household_id, meta_category_id) do
    rows =
      Enum.map(tokens, fn token ->
        %{
          household_id: household_id,
          meta_category_id: meta_category_id,
          provider: "plaid",
          source_category_token: token,
          unreviewed: true
        }
      end)

    %Ash.BulkResult{status: status} =
      Ash.bulk_create(rows, CategoryMapping, :create_system,
        authorize?: false,
        upsert?: true,
        upsert_identity: :unique_mapping_per_household,
        upsert_fields: [:updated_at]
      )

    if status == :error do
      raise "[CategoryResolution] Failed to bulk create category mappings for household=#{household_id}"
    end

    :ok
  end
end
