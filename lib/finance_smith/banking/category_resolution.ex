defmodule FinanceSmith.Banking.CategoryResolution do
  @moduledoc """
  Shared helpers for resolving and persisting Plaid category mappings.

  Used by the live `TransactionProcessor` (Oban job path) and the
  one-shot backfill/alignment scripts so that the logic lives in one place
  and both paths stay in sync.

  ## Resolution order for unknown tokens

  1. If the detailed token starts with a known Plaid primary token prefix
     (e.g. `FOOD_AND_DRINK_GROCERIES` → `FOOD_AND_DRINK`), it inherits that
     primary's `MetaCategory`.
  2. Otherwise it falls back to the household's `"Uncategorized"` `MetaCategory`,
     which is created on first use.

  All new mappings are persisted as `unreviewed: true` and can be manually
  remapped by the household later.
  """

  alias FinanceSmith.Banking.{CategoryMapping, MetaCategory}

  require Ash.Query

  @plaid_primary_tokens ~w(
    INCOME TRANSFER_IN TRANSFER_OUT LOAN_PAYMENTS BANK_FEES
    ENTERTAINMENT FOOD_AND_DRINK GENERAL_MERCHANDISE HOME_IMPROVEMENT
    MEDICAL PERSONAL_CARE GENERAL_SERVICES GOVERNMENT_AND_NON_PROFIT
    TRANSPORTATION TRAVEL RENT_AND_UTILITIES
  )

  @doc "Returns the list of the 16 known Plaid primary category tokens."
  @spec primary_tokens() :: [String.t()]
  def primary_tokens, do: @plaid_primary_tokens

  @doc """
  Resolves `tokens` to a `%{token => meta_category_id}` map for the given
  `household_id`, lazily creating `CategoryMapping` rows for any tokens that
  do not yet have one.

  ## Race safety

  After bulk-creating missing mappings (upsert with `upsert_fields: [:updated_at]`),
  the rows are re-read from the DB. The returned map therefore reflects whichever
  `meta_category_id` won the upsert, not the in-memory plan — preventing a
  concurrent worker from stamping transactions with a stale ID.
  """
  @spec resolve_tokens!([String.t()], Ash.UUID.t()) :: %{String.t() => Ash.UUID.t()}
  def resolve_tokens!(tokens, _household_id) when tokens == [], do: %{}

  def resolve_tokens!(tokens, household_id) do
    existing =
      CategoryMapping
      |> Ash.Query.filter(
        household_id == ^household_id and
          provider == "plaid" and
          source_category_token in ^tokens
      )
      |> Ash.read!(authorize?: false)

    existing_by_token = Map.new(existing, &{&1.source_category_token, &1.meta_category_id})
    missing_tokens = Enum.reject(tokens, &Map.has_key?(existing_by_token, &1))

    if Enum.empty?(missing_tokens) do
      existing_by_token
    else
      primary_lookup = load_primary_mappings(household_id)
      fallback = ensure_fallback_meta_category!(household_id)

      missing_tokens
      |> Enum.group_by(fn token ->
        case find_primary_prefix(token, primary_lookup) do
          nil -> fallback.id
          meta_category_id -> meta_category_id
        end
      end)
      |> Enum.each(fn {meta_category_id, group_tokens} ->
        bulk_create_mappings!(group_tokens, household_id, meta_category_id)
      end)

      # Re-read DB rows so the returned map reflects the upsert winner,
      # not our in-memory plan (race-safe).
      freshly_created =
        CategoryMapping
        |> Ash.Query.filter(
          household_id == ^household_id and
            provider == "plaid" and
            source_category_token in ^missing_tokens
        )
        |> Ash.read!(authorize?: false)
        |> Map.new(&{&1.source_category_token, &1.meta_category_id})

      Map.merge(existing_by_token, freshly_created)
    end
  end

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

  @doc """
  Loads the household's existing `CategoryMapping` rows for the 16 known Plaid
  primary tokens in a single query. Returns `%{primary_token => meta_category_id}`.
  """
  @spec load_primary_mappings(Ash.UUID.t()) :: %{String.t() => Ash.UUID.t()}
  def load_primary_mappings(household_id) do
    CategoryMapping
    |> Ash.Query.filter(
      household_id == ^household_id and
        provider == "plaid" and
        source_category_token in ^@plaid_primary_tokens
    )
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.source_category_token, &1.meta_category_id})
  end

  @doc """
  Returns the `meta_category_id` of the primary token whose prefix (plus `"_"`)
  matches the given detailed token, or `nil` if no primary matches.

  Example: `"FOOD_AND_DRINK_GROCERIES"` matches the `"FOOD_AND_DRINK"` prefix.
  """
  @spec find_primary_prefix(String.t(), %{String.t() => Ash.UUID.t()}) ::
          Ash.UUID.t() | nil
  def find_primary_prefix(token, primary_lookup) do
    Enum.find_value(primary_lookup, fn {prefix, meta_category_id} ->
      if String.starts_with?(token, prefix <> "_"), do: meta_category_id
    end)
  end
end
