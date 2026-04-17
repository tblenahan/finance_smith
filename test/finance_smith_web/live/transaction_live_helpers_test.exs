defmodule FinanceSmithWeb.TransactionLiveHelpersTest do
  use FinanceSmith.DataCase, async: false

  alias FinanceSmith.Banking.{Account, PlaidItem, Transaction}
  alias FinanceSmith.Identity
  alias FinanceSmithWeb.TransactionLiveHelpers

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  defp seed_transaction!(user) do
    unique = System.unique_integer([:positive])

    plaid_item =
      PlaidItem
      |> Ash.Changeset.for_create(:create, %{status: :active})
      |> Ash.Changeset.force_change_attribute(:plaid_item_id, "item-#{unique}")
      |> AshCloak.encrypt_and_set(:access_token, "access-#{unique}")
      |> Ash.Changeset.force_change_attribute(:institution_name, "Seed Bank")
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.create!(authorize?: false)

    account =
      Account
      |> Ash.Changeset.for_create(:create, %{
        plaid_account_id: "acc-#{unique}",
        name: "Seed Checking",
        plaid_item_id: plaid_item.id
      })
      |> Ash.create!(authorize?: false)

    Transaction
    |> Ash.Changeset.for_create(:create, %{
      plaid_transaction_id: "txn-#{unique}",
      amount: 500,
      date: Date.utc_today(),
      merchant_name: "Seed Merchant",
      account_id: account.id
    })
    |> Ash.create!(authorize?: false)
  end

  describe "fetch_transactions/3" do
    test "returns {:ok, %Ash.Page.Keyset{}} on success" do
      user = register_user!()
      _txn = seed_transaction!(user)

      params = TransactionLiveHelpers.default_tx_params()

      assert {:ok, %Ash.Page.Keyset{results: [_ | _]}} =
               TransactionLiveHelpers.fetch_transactions(user, params)
    end

    test "returns {:error, _} when inputs are invalid" do
      user = register_user!()

      # Pass an invalid UUID for scope_filters — the action argument is typed as :uuid,
      # so casting fails and Ash returns {:error, _}.
      params = TransactionLiveHelpers.default_tx_params()

      assert {:error, _} =
               TransactionLiveHelpers.fetch_transactions(user, params, %{
                 account_id: "not-a-uuid"
               })
    end
  end

  describe "default_tx_params/0" do
    test "30-day default window" do
      params = TransactionLiveHelpers.default_tx_params()
      assert %Date{} = params.date_from
      assert Date.diff(Date.utc_today(), params.date_from) == 30
    end
  end

  describe "list_categories/2" do
    test "returns distinct category strings for the user's transactions" do
      user = register_user!()
      _txn1 = seed_transaction_with_category!(user, "FOOD_AND_DRINK_RESTAURANTS")
      _txn2 = seed_transaction_with_category!(user, "FOOD_AND_DRINK_RESTAURANTS")
      _txn3 = seed_transaction_with_category!(user, "TRANSPORTATION_GAS")

      categories = TransactionLiveHelpers.list_categories(user)

      assert "FOOD_AND_DRINK_RESTAURANTS" in categories
      assert "TRANSPORTATION_GAS" in categories
      assert length(categories) == 2
    end

    test "returns empty list for a user with no transactions" do
      user = register_user!()
      assert TransactionLiveHelpers.list_categories(user) == []
    end

    test "returns empty list on invalid scope_filters rather than raising" do
      user = register_user!()
      assert TransactionLiveHelpers.list_categories(user, %{account_id: "not-a-uuid"}) == []
    end
  end

  defp seed_transaction_with_category!(user, category) do
    unique = System.unique_integer([:positive])

    plaid_item =
      FinanceSmith.Banking.PlaidItem
      |> Ash.Changeset.for_create(:create, %{status: :active})
      |> Ash.Changeset.force_change_attribute(:plaid_item_id, "item-#{unique}")
      |> AshCloak.encrypt_and_set(:access_token, "access-#{unique}")
      |> Ash.Changeset.force_change_attribute(:institution_name, "Cat Bank")
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.create!(authorize?: false)

    account =
      FinanceSmith.Banking.Account
      |> Ash.Changeset.for_create(:create, %{
        plaid_account_id: "acc-#{unique}",
        name: "Cat Checking",
        plaid_item_id: plaid_item.id
      })
      |> Ash.create!(authorize?: false)

    FinanceSmith.Banking.Transaction
    |> Ash.Changeset.for_create(:create, %{
      plaid_transaction_id: "txn-#{unique}",
      amount: 100,
      date: Date.utc_today(),
      merchant_name: "Cat Merchant",
      personal_finance_category: category,
      account_id: account.id
    })
    |> Ash.create!(authorize?: false)
  end
end
