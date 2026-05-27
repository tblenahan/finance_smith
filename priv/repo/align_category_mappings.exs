# Realigns CategoryMapping records and Transaction.meta_category_id values that
# were incorrectly mapped to "Uncategorized" due to the detailed-token vs
# primary-token mismatch. For each household:
#
# 1. Finds all CategoryMapping rows pointing at "Uncategorized".
# 2. If the source_category_token starts with a known primary token prefix,
#    updates that mapping's meta_category_id to the primary MetaCategory's id.
# 3. Re-stamps Transaction.meta_category_id for any transactions that were
#    stamped with "Uncategorized" but whose token now has a correct primary match.
#
# Idempotent: only touches CategoryMapping rows still pointing at "Uncategorized"
# and Transaction rows still stamped with the "Uncategorized" meta_category_id.
# A second pass finds nothing to change.
#
# Usage:
#   mix run priv/repo/align_category_mappings.exs

defmodule Align.CategoryMappings do
  @moduledoc false

  require Ash.Query

  alias FinanceSmith.Banking.{CategoryMapping, CategoryResolution, MetaCategory, Transaction}
  alias FinanceSmith.Identity.Household

  def run do
    households = Ash.read!(Household, authorize?: false)

    if Enum.empty?(households) do
      IO.puts("No households found. Nothing to align.")
    else
      {total_mappings_aligned, total_txns_restamped} =
        Enum.reduce(households, {0, 0}, fn household, {map_acc, txn_acc} ->
          {mapped, stamped} = align_household(household)
          {map_acc + mapped, txn_acc + stamped}
        end)

      IO.puts(
        "\nAlignment complete. Mappings aligned: #{total_mappings_aligned} | Transactions re-stamped: #{total_txns_restamped}"
      )
    end
  end

  defp align_household(household) do
    uncategorized =
      MetaCategory
      |> Ash.Query.filter(household_id == ^household.id and name == "Uncategorized")
      |> Ash.read_one!(authorize?: false)

    if is_nil(uncategorized) do
      {0, 0}
    else
      IO.puts("\nAligning household: #{household.name} (#{household.id})")

      primary_lookup = CategoryResolution.load_primary_mappings(household.id)

      uncategorized_mappings =
        CategoryMapping
        |> Ash.Query.filter(
          household_id == ^household.id and
            meta_category_id == ^uncategorized.id
        )
        |> Ash.read!(authorize?: false)

      {to_align, no_match} =
        Enum.split_with(uncategorized_mappings, fn mapping ->
          not is_nil(
            CategoryResolution.find_primary_prefix(mapping.source_category_token, primary_lookup)
          )
        end)

      corrected_token_lookup =
        Map.new(to_align, fn mapping ->
          new_meta_category_id =
            CategoryResolution.find_primary_prefix(
              mapping.source_category_token,
              primary_lookup
            )

          mapping
          |> Ash.Changeset.for_update(:update, %{meta_category_id: new_meta_category_id},
            authorize?: false
          )
          |> Ash.update!(authorize?: false)

          {mapping.source_category_token, new_meta_category_id}
        end)

      mappings_aligned = map_size(corrected_token_lookup)

      IO.puts(
        "  mappings checked: #{length(uncategorized_mappings)} | aligned: #{mappings_aligned} | still uncategorized: #{length(no_match)}"
      )

      txns_restamped = restamp_transactions(household, uncategorized, corrected_token_lookup)
      IO.puts("  transactions re-stamped: #{txns_restamped}")

      {mappings_aligned, txns_restamped}
    end
  end

  defp restamp_transactions(_household, _uncategorized, corrected_token_lookup)
       when map_size(corrected_token_lookup) == 0,
       do: 0

  defp restamp_transactions(household, uncategorized, corrected_token_lookup) do
    candidates =
      Transaction
      |> Ash.Query.filter(
        meta_category_id == ^uncategorized.id and
          not is_nil(personal_finance_category) and
          account.plaid_item.user.household_id == ^household.id
      )
      |> Ash.Query.select([:id, :personal_finance_category])
      |> Ash.read!(authorize?: false)

    candidates
    |> Enum.group_by(& &1.personal_finance_category)
    |> Enum.reduce(0, fn {token, txns}, acc ->
      case Map.fetch(corrected_token_lookup, token) do
        {:ok, new_meta_category_id} ->
          ids = Enum.map(txns, & &1.id)

          %Ash.BulkResult{status: status} =
            Transaction
            |> Ash.Query.filter(id in ^ids)
            |> Ash.bulk_update(:update, %{meta_category_id: new_meta_category_id},
              authorize?: false,
              authorize_query?: false
            )

          if status == :error do
            raise "[Align] bulk_update failed for household=#{household.id} token=#{token}"
          end

          acc + length(txns)

        :error ->
          acc
      end
    end)
  end

end

Align.CategoryMappings.run()
