defmodule FinanceSmith.Banking.TransactionCategoriesTest do
  use FinanceSmith.DataCase, async: false

  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking
  alias FinanceSmith.Identity

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  describe ":categories read action" do
    test "returns distinct non-nil categories sorted alphabetically" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)

      create_transaction!(account, personal_finance_category: "FOOD_AND_DRINK_RESTAURANTS")
      create_transaction!(account, personal_finance_category: "FOOD_AND_DRINK_RESTAURANTS")
      create_transaction!(account, personal_finance_category: "TRANSPORTATION_GAS")
      create_transaction!(account, personal_finance_category: nil)

      assert {:ok, records} = Banking.list_transaction_categories(%{}, actor: user)

      categories = Enum.map(records, & &1.personal_finance_category)

      assert "FOOD_AND_DRINK_RESTAURANTS" in categories
      assert "TRANSPORTATION_GAS" in categories
      refute nil in categories
      assert length(categories) == 2
      assert categories == Enum.sort(categories)
    end

    test "excludes categories from other users" do
      owner = register_user!()
      stranger = register_user!()

      owner_item = create_plaid_item!(owner)
      owner_account = create_account!(owner_item)
      create_transaction!(owner_account, personal_finance_category: "INCOME_WAGES")

      stranger_item = create_plaid_item!(stranger)
      stranger_account = create_account!(stranger_item)
      create_transaction!(stranger_account, personal_finance_category: "SHOPPING_CLOTHING")

      assert {:ok, stranger_records} = Banking.list_transaction_categories(%{}, actor: stranger)
      stranger_cats = Enum.map(stranger_records, & &1.personal_finance_category)

      refute "INCOME_WAGES" in stranger_cats
      assert "SHOPPING_CLOTHING" in stranger_cats
    end

    test "filters by account_id when supplied" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account_a = create_account!(plaid_item)
      account_b = create_account!(plaid_item)

      create_transaction!(account_a, personal_finance_category: "FOOD_AND_DRINK_RESTAURANTS")
      create_transaction!(account_b, personal_finance_category: "TRANSPORTATION_GAS")

      assert {:ok, records} =
               Banking.list_transaction_categories(%{account_id: account_a.id}, actor: user)

      categories = Enum.map(records, & &1.personal_finance_category)

      assert categories == ["FOOD_AND_DRINK_RESTAURANTS"]
    end

    test "filters by plaid_item_id when supplied" do
      user = register_user!()
      item_a = create_plaid_item!(user)
      item_b = create_plaid_item!(user)

      account_a = create_account!(item_a)
      account_b = create_account!(item_b)

      create_transaction!(account_a, personal_finance_category: "ENTERTAINMENT_STREAMING")
      create_transaction!(account_b, personal_finance_category: "MEDICAL_HEALTHCARE")

      assert {:ok, records} =
               Banking.list_transaction_categories(%{plaid_item_id: item_b.id}, actor: user)

      categories = Enum.map(records, & &1.personal_finance_category)

      assert categories == ["MEDICAL_HEALTHCARE"]
    end

    test "returns empty list when actor has no transactions" do
      user = register_user!()

      assert {:ok, []} = Banking.list_transaction_categories(%{}, actor: user)
    end
  end
end
