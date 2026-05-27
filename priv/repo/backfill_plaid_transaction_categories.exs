# Backfills meta_category_id on historical transactions whose personal_finance_category
# token is populated but meta_category_id is nil.
#
# Idempotent: only touches rows where meta_category_id IS NULL and
# personal_finance_category IS NOT NULL. A second pass finds zero candidates
# and exits cleanly.
#
# Resolution order (matches live sync via CategoryResolution.resolve_tokens!/2):
#   1. Detailed token matching a known Plaid primary prefix → primary MetaCategory.
#   2. No prefix match → "Uncategorized" MetaCategory (created on first use).
#
# Usage:
#   mix run priv/repo/backfill_plaid_transaction_categories.exs

require Ash.Query

alias FinanceSmith.Banking.{CategoryResolution, Transaction}
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

        lookup = CategoryResolution.resolve_tokens!(tokens, household.id)

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
          "  candidates: #{length(candidates)} | unique tokens: #{length(tokens)} | transactions updated: #{updated}"
        )

        total_acc + updated
      end
    end)

  IO.puts("\nBackfill complete. Total transactions updated: #{total_updated}")
end
