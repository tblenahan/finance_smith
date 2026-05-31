defmodule FinanceSmithWeb.TransactionLiveHelpersTest do
  use FinanceSmith.DataCase, async: false

  alias FinanceSmith.Banking.{Account, MetaCategory, PlaidItem, Transaction}
  alias FinanceSmith.Identity
  alias FinanceSmithWeb.TransactionLiveHelpers

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  defp seed_meta_category!(household_id, name) do
    MetaCategory
    |> Ash.Changeset.for_create(:create_system, %{name: name, household_id: household_id})
    |> Ash.create!(authorize?: false)
  end

  defp seed_transaction!(user, opts \\ []) do
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

    attrs =
      %{
        plaid_transaction_id: "txn-#{unique}",
        amount: Keyword.get(opts, :amount, 500),
        date: Keyword.get(opts, :date, Date.utc_today()),
        merchant_name: "Seed Merchant",
        account_id: account.id
      }
      |> maybe_put(:meta_category_id, Keyword.get(opts, :meta_category_id))

    Transaction
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  describe "fetch_transactions/3" do
    test "returns {:ok, %Ash.Page.Keyset{}} on success" do
      user = register_user!()
      _txn = seed_transaction!(user)

      params = TransactionLiveHelpers.default_tx_params()

      assert {:ok, %Ash.Page.Keyset{results: [_ | _]}} =
               TransactionLiveHelpers.fetch_transactions(user, params)
    end

    test "filters by meta_category_id when provided" do
      user = register_user!()
      cat = seed_meta_category!(user.household_id, "Entertainment")
      _txn_with = seed_transaction!(user, meta_category_id: cat.id)
      _txn_without = seed_transaction!(user)

      params = %{TransactionLiveHelpers.default_tx_params() | meta_category_id: cat.id}

      assert {:ok, %Ash.Page.Keyset{results: results}} =
               TransactionLiveHelpers.fetch_transactions(user, params)

      assert length(results) == 1
      assert hd(results).meta_category_id == cat.id
    end

    test "returns {:error, _} when inputs are invalid" do
      user = register_user!()

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

    test "meta_category_id defaults to nil" do
      params = TransactionLiveHelpers.default_tx_params()
      assert is_nil(params.meta_category_id)
    end
  end

  describe "parse_tx_params/1" do
    test "maps 'category' URL param to meta_category_id for valid UUID" do
      uuid = Ash.UUIDv7.generate()
      params = TransactionLiveHelpers.parse_tx_params(%{"category" => uuid})
      assert params.meta_category_id == uuid
    end

    test "rejects non-UUID category param" do
      params = TransactionLiveHelpers.parse_tx_params(%{"category" => "FOOD_AND_DRINK"})
      assert is_nil(params.meta_category_id)
    end

    test "preserves sort_by=category as a valid sort field" do
      params = TransactionLiveHelpers.parse_tx_params(%{"sort_by" => "category"})
      assert params.sort_by == "category"
    end

    test "falls back to 'date' for an unknown sort_by value" do
      params = TransactionLiveHelpers.parse_tx_params(%{"sort_by" => "invalid_field"})
      assert params.sort_by == "date"
    end
  end

  describe "fetch_transactions/3 with sort_by=category" do
    test "accepts sort_by=category and returns results without error" do
      user = register_user!()
      cat = seed_meta_category!(user.household_id, "Groceries")
      _txn = seed_transaction!(user, meta_category_id: cat.id)

      params = %{TransactionLiveHelpers.default_tx_params() | sort_by: "category"}

      assert {:ok, %Ash.Page.Keyset{}} =
               TransactionLiveHelpers.fetch_transactions(user, params)
    end

    test "sorts asc with nil meta_category_id without error and places nulls last" do
      user = register_user!()
      cat = seed_meta_category!(user.household_id, "Alpha")

      _with_category = seed_transaction!(user, meta_category_id: cat.id)
      _without_category = seed_transaction!(user)

      params = %{
        TransactionLiveHelpers.default_tx_params()
        | sort_by: "category",
          sort_dir: "asc"
      }

      assert {:ok, %Ash.Page.Keyset{results: [first | _] = results}} =
               TransactionLiveHelpers.fetch_transactions(user, params)

      assert length(results) == 2
      # The categorized row ("Alpha") sorts before nil in ascending order.
      assert first.meta_category_id != nil
    end

    test "sorts desc with nil meta_category_id without error and places nulls first" do
      user = register_user!()
      cat = seed_meta_category!(user.household_id, "Zebra")

      _with_category = seed_transaction!(user, meta_category_id: cat.id)
      _without_category = seed_transaction!(user)

      params = %{
        TransactionLiveHelpers.default_tx_params()
        | sort_by: "category",
          sort_dir: "desc"
      }

      assert {:ok, %Ash.Page.Keyset{results: [first | _] = results}} =
               TransactionLiveHelpers.fetch_transactions(user, params)

      assert length(results) == 2
      # In descending order, nil sorts before any named category (nils_first for desc).
      assert is_nil(first.meta_category_id)
    end
  end

  describe "list_categories/2" do
    test "returns MetaCategory structs for the user's household" do
      user = register_user!()
      _cat1 = seed_meta_category!(user.household_id, "Food & Drink")
      _cat2 = seed_meta_category!(user.household_id, "Transportation")

      categories = TransactionLiveHelpers.list_categories(user)

      names = Enum.map(categories, & &1.name)
      assert "Food & Drink" in names
      assert "Transportation" in names
      assert length(categories) == 2
    end

    test "returns empty list for a user with no meta-categories" do
      user = register_user!()
      assert TransactionLiveHelpers.list_categories(user) == []
    end

    test "does not return categories from another household" do
      user1 = register_user!()
      user2 = register_user!()
      _cat = seed_meta_category!(user1.household_id, "Private Category")

      categories = TransactionLiveHelpers.list_categories(user2)
      assert categories == []
    end
  end
end
