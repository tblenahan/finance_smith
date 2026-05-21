# Seeds the 16 standard Plaid primary category tokens as MetaCategory + CategoryMapping rows
# for every household that exists in the database.
#
# Idempotency is keyed on the CategoryMapping unique identity
# [:household_id, :provider, :source_category_token]. If a mapping already exists for a given
# household + provider + token, the entry is skipped entirely so that any user renames on the
# linked MetaCategory are preserved across re-runs.
#
# Usage:
#   mix run priv/repo/seeds.exs

require Ash.Query

alias FinanceSmith.Banking.{CategoryMapping, MetaCategory}
alias FinanceSmith.Identity.Household

plaid_primary_categories = [
  {"INCOME", "Income"},
  {"TRANSFER_IN", "Transfer In"},
  {"TRANSFER_OUT", "Transfer Out"},
  {"LOAN_PAYMENTS", "Loan Payments"},
  {"BANK_FEES", "Bank Fees"},
  {"ENTERTAINMENT", "Entertainment"},
  {"FOOD_AND_DRINK", "Food & Drink"},
  {"GENERAL_MERCHANDISE", "General Merchandise"},
  {"HOME_IMPROVEMENT", "Home Improvement"},
  {"MEDICAL", "Medical"},
  {"PERSONAL_CARE", "Personal Care"},
  {"GENERAL_SERVICES", "General Services"},
  {"GOVERNMENT_AND_NON_PROFIT", "Government & Non-Profit"},
  {"TRANSPORTATION", "Transportation"},
  {"TRAVEL", "Travel"},
  {"RENT_AND_UTILITIES", "Rent & Utilities"}
]

households = Ash.read!(Household, authorize?: false)

if Enum.empty?(households) do
  IO.puts("No households found. Run seeds after registering at least one user.")
else
  for household <- households do
    IO.puts("\nSeeding categories for household: #{household.name} (#{household.id})")

    for {token, default_name} <- plaid_primary_categories do
      existing =
        CategoryMapping
        |> Ash.Query.filter(
          household_id == ^household.id and
            provider == "plaid" and
            source_category_token == ^token
        )
        |> Ash.read_one!(authorize?: false)

      if is_nil(existing) do
        meta_category =
          MetaCategory
          |> Ash.Changeset.for_create(:create, %{name: default_name})
          |> Ash.Changeset.force_change_attribute(:household_id, household.id)
          |> Ash.create!(authorize?: false)

        CategoryMapping
        |> Ash.Changeset.for_create(:create, %{
          provider: "plaid",
          source_category_token: token,
          household_id: household.id,
          meta_category_id: meta_category.id
        })
        |> Ash.create!(authorize?: false)

        IO.puts("  + created: #{default_name} <- #{token}")
      else
        IO.puts("  ~ skipped (mapping exists): #{token}")
      end
    end
  end

  IO.puts("\nSeeding complete.")
end
