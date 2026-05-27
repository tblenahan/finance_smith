# Backfills meta_category_id on historical transactions whose personal_finance_category
# token is populated but meta_category_id is nil.
#
# Idempotent: only touches rows where meta_category_id IS NULL and
# personal_finance_category IS NOT NULL. A second pass finds zero candidates
# and exits cleanly.
#
# The category mapping resolution logic is an inline copy of the private helpers
# in TransactionProcessor so that the ingestion module is not modified.
#
# Usage:
#   mix run priv/repo/backfill_plaid_transaction_categories.exs

defmodule Backfill.CategoryResolver do
  @moduledoc false

  require Ash.Query

  alias FinanceSmith.Banking.{CategoryMapping, MetaCategory}

  @doc """
  Returns `{%{token => meta_category_id}, mappings_created_count}` for the given
  unique `tokens` list scoped to `household_id`. Missing tokens are lazily
  registered as unreviewed mappings pointing to "Uncategorized".
  """
  def resolve_mappings!(tokens, household_id) do
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

    {created_by_token, created_count} =
      if Enum.empty?(missing_tokens) do
        {%{}, 0}
      else
        fallback = ensure_fallback_meta_category!(household_id)
        bulk_create_mappings!(missing_tokens, household_id, fallback.id)
        {Map.new(missing_tokens, &{&1, fallback.id}), length(missing_tokens)}
      end

    {Map.merge(existing_by_token, created_by_token), created_count}
  end

  defp ensure_fallback_meta_category!(household_id) do
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

  defp bulk_create_mappings!(tokens, household_id, meta_category_id) do
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
      raise "[Backfill] Failed to bulk create category mappings for household=#{household_id}"
    end

    :ok
  end
end

require Ash.Query

alias Backfill.CategoryResolver
alias FinanceSmith.Banking.Transaction
alias FinanceSmith.Identity.Household

households = Ash.read!(Household, authorize?: false)

if Enum.empty?(households) do
  IO.puts("No households found. Nothing to backfill.")
else
  total_updated =
    Enum.reduce(households, 0, fn household, total_acc ->
      candidates =
        Transaction
        |> Ash.Query.filter(
          is_nil(meta_category_id) and
            not is_nil(personal_finance_category) and
            account.plaid_item.user.household_id == ^household.id
        )
        |> Ash.Query.select([:id, :personal_finance_category])
        |> Ash.read!(authorize?: false)

      if Enum.empty?(candidates) do
        total_acc
      else
        IO.puts("\nBackfilling household: #{household.name} (#{household.id})")

        tokens =
          candidates
          |> Enum.map(& &1.personal_finance_category)
          |> Enum.uniq()

        {lookup, mappings_created} = CategoryResolver.resolve_mappings!(tokens, household.id)

        updated =
          candidates
          |> Enum.group_by(& &1.personal_finance_category)
          |> Enum.reduce(0, fn {token, txns}, acc ->
            meta_category_id = Map.fetch!(lookup, token)
            ids = Enum.map(txns, & &1.id)

            %Ash.BulkResult{status: status} =
              Transaction
              |> Ash.Query.filter(id in ^ids)
              |> Ash.bulk_update(:update, %{meta_category_id: meta_category_id},
                authorize?: false,
                authorize_query?: false
              )

            if status == :error do
              raise "[Backfill] bulk_update failed for household=#{household.id} token=#{token}"
            end

            acc + length(txns)
          end)

        IO.puts(
          "  candidates: #{length(candidates)} | unique tokens: #{length(tokens)} | mappings created: #{mappings_created} | transactions updated: #{updated}"
        )

        total_acc + updated
      end
    end)

  IO.puts("\nBackfill complete. Total transactions updated: #{total_updated}")
end
