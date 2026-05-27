defmodule FinanceSmith.Banking.CategoryResolutionTest do
  use FinanceSmith.DataCase, async: false

  alias FinanceSmith.Banking.{CategoryMapping, CategoryResolution, MetaCategory}
  alias FinanceSmith.Identity

  require Ash.Query

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  defp seed_meta_category!(household_id, name) do
    MetaCategory
    |> Ash.Changeset.for_create(:create_system, %{name: name, household_id: household_id})
    |> Ash.create!(authorize?: false)
  end

  defp seed_mapping!(household_id, meta_category_id, token) do
    CategoryMapping
    |> Ash.Changeset.for_create(:create_system, %{
      household_id: household_id,
      meta_category_id: meta_category_id,
      provider: "plaid",
      source_category_token: token,
      unreviewed: false
    })
    |> Ash.create!(authorize?: false)
  end

  describe "ensure_fallback_meta_category!/1" do
    test "creates Uncategorized category on first call" do
      user = register_user!()

      result = CategoryResolution.ensure_fallback_meta_category!(user.household_id)

      assert result.name == "Uncategorized"
      assert result.household_id == user.household_id
    end

    test "is idempotent — second call returns the same record" do
      user = register_user!()

      first = CategoryResolution.ensure_fallback_meta_category!(user.household_id)
      second = CategoryResolution.ensure_fallback_meta_category!(user.household_id)

      assert first.id == second.id
    end

    test "is scoped per household" do
      user_a = register_user!()
      user_b = register_user!()

      cat_a = CategoryResolution.ensure_fallback_meta_category!(user_a.household_id)
      cat_b = CategoryResolution.ensure_fallback_meta_category!(user_b.household_id)

      assert cat_a.id != cat_b.id
    end
  end

  describe "resolve_tokens!/2 — empty input" do
    test "returns empty map for empty token list" do
      user = register_user!()

      assert %{} == CategoryResolution.resolve_tokens!([], user.household_id)
    end
  end

  describe "resolve_tokens!/2 — prefix matching" do
    test "detailed token inherits primary MetaCategory when a primary mapping exists" do
      user = register_user!()
      food_cat = seed_meta_category!(user.household_id, "Food & Drink")
      seed_mapping!(user.household_id, food_cat.id, "FOOD_AND_DRINK")

      lookup = CategoryResolution.resolve_tokens!(["FOOD_AND_DRINK_GROCERIES"], user.household_id)

      assert lookup["FOOD_AND_DRINK_GROCERIES"] == food_cat.id
    end

    test "creates a CategoryMapping row for the resolved detailed token" do
      user = register_user!()
      food_cat = seed_meta_category!(user.household_id, "Food & Drink")
      seed_mapping!(user.household_id, food_cat.id, "FOOD_AND_DRINK")

      CategoryResolution.resolve_tokens!(["FOOD_AND_DRINK_RESTAURANTS"], user.household_id)

      mapping =
        CategoryMapping
        |> Ash.Query.filter(
          household_id == ^user.household_id and
            source_category_token == "FOOD_AND_DRINK_RESTAURANTS"
        )
        |> Ash.read_one!(authorize?: false)

      assert mapping.meta_category_id == food_cat.id
      assert mapping.unreviewed == true
    end
  end

  describe "resolve_tokens!/2 — unknown tokens fall back to Uncategorized" do
    test "unknown token resolves to the fallback and creates its mapping" do
      user = register_user!()

      lookup =
        CategoryResolution.resolve_tokens!(
          ["TOTALLY_UNKNOWN_TOKEN"],
          user.household_id
        )

      fallback =
        MetaCategory
        |> Ash.Query.filter(household_id == ^user.household_id and name == "Uncategorized")
        |> Ash.read_one!(authorize?: false)

      assert fallback != nil
      assert lookup["TOTALLY_UNKNOWN_TOKEN"] == fallback.id
    end
  end

  describe "resolve_tokens!/2 — re-reads after upsert (race-safe)" do
    test "returns the DB-resident meta_category_id, not the in-memory plan" do
      user = register_user!()

      original_cat = seed_meta_category!(user.household_id, "Original")
      manual_cat = seed_meta_category!(user.household_id, "Manual Remap")

      # Pre-seed a mapping with original_cat; simulates a manual remap already
      # present when a second worker arrives.
      seed_mapping!(user.household_id, manual_cat.id, "FOOD_AND_DRINK_GROCERIES")

      # This call would *plan* to write food_cat (from prefix), but the token
      # already has a row. After bulk-upsert (no-op on conflict), the re-read
      # should return manual_cat.id — the DB winner.
      food_cat = seed_meta_category!(user.household_id, "Food & Drink")
      seed_mapping!(user.household_id, food_cat.id, "FOOD_AND_DRINK")

      lookup = CategoryResolution.resolve_tokens!(["FOOD_AND_DRINK_GROCERIES"], user.household_id)

      assert lookup["FOOD_AND_DRINK_GROCERIES"] == manual_cat.id

      # Silence unused-variable warning in older checks
      _ = original_cat
    end
  end

  describe "resolve_tokens!/2 — household isolation" do
    test "tokens for household A do not see household B mappings" do
      user_a = register_user!()
      user_b = register_user!()

      cat_a = seed_meta_category!(user_a.household_id, "Cat A")
      seed_mapping!(user_a.household_id, cat_a.id, "INCOME_WAGES")

      # household B resolves the same token independently
      lookup_b = CategoryResolution.resolve_tokens!(["INCOME_WAGES"], user_b.household_id)

      # B should NOT see A's mapping — it falls back or creates its own
      refute lookup_b["INCOME_WAGES"] == cat_a.id
    end
  end

  describe "find_primary_prefix/2" do
    test "matches a detailed token to its primary prefix" do
      lookup = %{"FOOD_AND_DRINK" => "uuid-1"}

      assert CategoryResolution.find_primary_prefix("FOOD_AND_DRINK_GROCERIES", lookup) ==
               "uuid-1"
    end

    test "returns nil when no prefix matches" do
      lookup = %{"FOOD_AND_DRINK" => "uuid-1"}
      assert CategoryResolution.find_primary_prefix("UNKNOWN_TOKEN", lookup) == nil
    end

    test "does not match a token that equals the prefix (no trailing underscore)" do
      lookup = %{"FOOD_AND_DRINK" => "uuid-1"}
      assert CategoryResolution.find_primary_prefix("FOOD_AND_DRINK", lookup) == nil
    end
  end

  describe "load_primary_mappings/1" do
    test "only returns rows for the 16 primary tokens" do
      user = register_user!()
      cat = seed_meta_category!(user.household_id, "Income")
      seed_mapping!(user.household_id, cat.id, "INCOME")
      seed_mapping!(user.household_id, cat.id, "INCOME_WAGES")

      result = CategoryResolution.load_primary_mappings(user.household_id)

      assert Map.has_key?(result, "INCOME")
      refute Map.has_key?(result, "INCOME_WAGES")
    end
  end
end
