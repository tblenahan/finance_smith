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

  describe "keyset pagination round-trip" do
    test "advancing and retreating pages returns consistent, non-duplicated records" do
      user = register_user!()
      {account, _plaid_item} = seed_account_for_user!(user)

      # Seed 30 transactions all on the same date so the sort on (date, inserted_at)
      # alone would be ambiguous without the :id tiebreaker.
      today = Date.utc_today()

      all_ids =
        for i <- 1..30 do
          unique = System.unique_integer([:positive])

          txn =
            Transaction
            |> Ash.Changeset.for_create(:create, %{
              plaid_transaction_id: "txn-rt-#{unique}",
              amount: i * 100,
              date: today,
              merchant_name: "Round Trip #{i}",
              account_id: account.id
            })
            |> Ash.create!(authorize?: false)

          txn.id
        end

      params = TransactionLiveHelpers.default_tx_params()

      # Page 1: no cursor — expect 25 records with more? true.
      # Note: Ash.Page.Keyset.after/before hold the INPUT cursors (nil on page 1).
      # The cursors for navigation live in record.__metadata__.keyset.
      assert {:ok, page1} = TransactionLiveHelpers.fetch_transactions(user, params)
      assert length(page1.results) == 25
      assert page1.more? == true

      page1_ids = Enum.map(page1.results, & &1.id)

      # Page 2: advance using the last record's keyset as the after cursor.
      after_cursor = List.last(page1.results).__metadata__.keyset
      params_p2 = %{params | after_cursor: after_cursor, before_cursor: nil}

      assert {:ok, page2} = TransactionLiveHelpers.fetch_transactions(user, params_p2)
      assert length(page2.results) == 5

      page2_ids = Enum.map(page2.results, & &1.id)

      # No record should appear on both pages
      assert MapSet.disjoint?(MapSet.new(page1_ids), MapSet.new(page2_ids))

      # All 30 seeded IDs must be present across the two pages — no gaps, no extras
      assert MapSet.equal?(
               MapSet.new(all_ids),
               MapSet.union(MapSet.new(page1_ids), MapSet.new(page2_ids))
             )

      # Navigate back: use page 2's first record's keyset as the before cursor.
      before_cursor = List.first(page2.results).__metadata__.keyset
      params_back = %{params | before_cursor: before_cursor, after_cursor: nil}

      assert {:ok, page_back} = TransactionLiveHelpers.fetch_transactions(user, params_back)
      assert length(page_back.results) == 25

      back_ids = Enum.map(page_back.results, & &1.id)

      # The retreat page must exactly match page 1 — same records, same deterministic order
      assert back_ids == page1_ids
    end
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

  defp seed_account_for_user!(user) do
    unique = System.unique_integer([:positive])

    plaid_item =
      PlaidItem
      |> Ash.Changeset.for_create(:create, %{status: :active})
      |> Ash.Changeset.force_change_attribute(:plaid_item_id, "item-#{unique}")
      |> AshCloak.encrypt_and_set(:access_token, "access-#{unique}")
      |> Ash.Changeset.force_change_attribute(:institution_name, "Round Trip Bank")
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.create!(authorize?: false)

    account =
      Account
      |> Ash.Changeset.for_create(:create, %{
        plaid_account_id: "acc-#{unique}",
        name: "Round Trip Checking",
        plaid_item_id: plaid_item.id
      })
      |> Ash.create!(authorize?: false)

    {account, plaid_item}
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
