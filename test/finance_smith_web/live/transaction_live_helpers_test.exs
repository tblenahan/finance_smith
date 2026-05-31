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

  # --- Helpers for apply_resolved_transaction/4 unit tests --------------------

  defp fake_account(name \\ "Checking") do
    %{id: Ash.UUID.generate(), name: name, mask: "1234"}
  end

  defp fake_meta_category(id \\ nil, name \\ "Groceries") do
    id = id || Ash.UUID.generate()
    %{id: id, name: name}
  end

  defp fake_txn(overrides) do
    base = %Transaction{
      id: Ash.UUID.generate(),
      plaid_transaction_id: "posted-#{System.unique_integer([:positive])}",
      pending_transaction_id: nil,
      amount: 1000,
      date: ~D[2026-05-15],
      merchant_name: "Test Merchant",
      is_pending: false,
      meta_category_id: nil,
      account_id: Ash.UUID.generate(),
      account: %Ash.NotLoaded{field: :account, type: :relationship},
      meta_category: %Ash.NotLoaded{field: :meta_category, type: :relationship}
    }

    Map.merge(base, overrides)
  end

  defp fake_page(results, count \\ nil) do
    %Ash.Page.Keyset{
      results: results,
      count: count || length(results),
      more?: false,
      before: nil,
      after: nil,
      limit: 25
    }
  end

  defp default_tx_params(overrides \\ %{}) do
    base = %{
      sort_by: "date",
      sort_dir: "desc",
      after_cursor: nil,
      before_cursor: nil,
      date_from: ~D[2026-04-15],
      date_to: nil,
      meta_category_id: nil,
      search: nil
    }

    Map.merge(base, overrides)
  end

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

  describe "apply_resolved_transaction/4" do
    test "returns nil page unchanged" do
      updated_txn = fake_txn(%{pending_transaction_id: "old-pending-id"})

      assert nil ==
               TransactionLiveHelpers.apply_resolved_transaction(
                 nil,
                 updated_txn,
                 default_tx_params(),
                 []
               )
    end

    test "returns page unchanged when updated_txn has nil pending_transaction_id" do
      pending_row = fake_txn(%{plaid_transaction_id: "pending-123", is_pending: true})
      page = fake_page([pending_row])
      updated_txn = fake_txn(%{pending_transaction_id: nil})

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          updated_txn,
          default_tx_params(),
          []
        )

      assert result.results == [pending_row]
    end

    test "returns page unchanged when updated_txn has empty string pending_transaction_id" do
      pending_row = fake_txn(%{plaid_transaction_id: "pending-abc", is_pending: true})
      page = fake_page([pending_row])
      updated_txn = fake_txn(%{pending_transaction_id: ""})

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          updated_txn,
          default_tx_params(),
          []
        )

      assert result.results == [pending_row]
    end

    test "returns page unchanged when no row matches pending_transaction_id" do
      row = fake_txn(%{plaid_transaction_id: "some-other-txn"})
      page = fake_page([row])
      updated_txn = fake_txn(%{pending_transaction_id: "no-match-id"})

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          updated_txn,
          default_tx_params(),
          []
        )

      assert result.results == [row]
    end

    test "swaps the pending row with the rebuilt posted struct" do
      account = fake_account()

      pending_row =
        fake_txn(%{
          plaid_transaction_id: "pending-txn-1",
          is_pending: true,
          amount: 1500,
          merchant_name: "Coffee Shop",
          account: account,
          meta_category: nil,
          meta_category_id: nil
        })

      page = fake_page([pending_row])

      updated_txn =
        fake_txn(%{
          plaid_transaction_id: "posted-txn-1",
          pending_transaction_id: "pending-txn-1",
          is_pending: false,
          amount: 1500,
          merchant_name: "Coffee Shop",
          meta_category_id: nil
        })

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          updated_txn,
          default_tx_params(),
          []
        )

      assert length(result.results) == 1
      [swapped] = result.results

      # The posted txn's own fields are used
      assert swapped.plaid_transaction_id == "posted-txn-1"
      assert swapped.is_pending == false

      # The old row's loaded account is reused (no NotLoaded crash)
      assert swapped.account == account
    end

    test "reuses the old row's loaded account regardless of NotLoaded on updated_txn" do
      account = fake_account("Savings Account")

      pending_row =
        fake_txn(%{
          plaid_transaction_id: "pending-assoc-test",
          is_pending: true,
          account: account
        })

      page = fake_page([pending_row])

      updated_txn =
        fake_txn(%{
          pending_transaction_id: "pending-assoc-test",
          account: %Ash.NotLoaded{field: :account, type: :relationship}
        })

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          updated_txn,
          default_tx_params(),
          []
        )

      [swapped] = result.results
      assert swapped.account == account
      refute match?(%Ash.NotLoaded{}, swapped.account)
    end

    test "looks up meta_category from categories list by id" do
      cat_id = Ash.UUID.generate()
      category = fake_meta_category(cat_id, "Dining")
      categories = [fake_meta_category(), category, fake_meta_category()]

      account = fake_account()

      pending_row =
        fake_txn(%{
          plaid_transaction_id: "pending-cat-test",
          is_pending: true,
          account: account
        })

      page = fake_page([pending_row])

      updated_txn =
        fake_txn(%{
          pending_transaction_id: "pending-cat-test",
          meta_category_id: cat_id,
          meta_category: %Ash.NotLoaded{field: :meta_category, type: :relationship}
        })

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          updated_txn,
          default_tx_params(),
          categories
        )

      [swapped] = result.results
      assert swapped.meta_category == category
      assert swapped.meta_category.name == "Dining"
    end

    test "uses nil for meta_category when id not found in categories" do
      account = fake_account()

      pending_row =
        fake_txn(%{
          plaid_transaction_id: "pending-nocat",
          is_pending: true,
          account: account
        })

      page = fake_page([pending_row])

      updated_txn =
        fake_txn(%{
          pending_transaction_id: "pending-nocat",
          meta_category_id: Ash.UUID.generate()
        })

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          updated_txn,
          default_tx_params(),
          []
        )

      [swapped] = result.results
      assert is_nil(swapped.meta_category)
    end

    test "drops swapped row when it no longer matches date_from filter" do
      account = fake_account()

      pending_row =
        fake_txn(%{
          plaid_transaction_id: "pending-datefilter",
          is_pending: true,
          date: ~D[2026-05-01],
          account: account
        })

      page = fake_page([pending_row])

      # Posted transaction lands on an old date outside the filter window
      updated_txn =
        fake_txn(%{
          pending_transaction_id: "pending-datefilter",
          date: ~D[2026-03-01]
        })

      tx_params = default_tx_params(%{date_from: ~D[2026-04-15]})

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          updated_txn,
          tx_params,
          []
        )

      assert result.results == []
      assert result.count == 0
    end

    test "drops swapped row when it no longer matches category filter" do
      cat_id = Ash.UUID.generate()
      account = fake_account()

      pending_row =
        fake_txn(%{
          plaid_transaction_id: "pending-catfilter",
          is_pending: true,
          meta_category_id: cat_id,
          account: account
        })

      page = fake_page([pending_row])

      # Posted transaction resolved to a different category
      different_cat_id = Ash.UUID.generate()

      updated_txn =
        fake_txn(%{
          pending_transaction_id: "pending-catfilter",
          meta_category_id: different_cat_id
        })

      tx_params = default_tx_params(%{meta_category_id: cat_id})

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          updated_txn,
          tx_params,
          []
        )

      assert result.results == []
      assert result.count == 0
    end

    test "drops swapped row when merchant name no longer matches search filter" do
      account = fake_account()

      pending_row =
        fake_txn(%{
          plaid_transaction_id: "pending-search",
          is_pending: true,
          merchant_name: "Coffee Shop",
          account: account
        })

      page = fake_page([pending_row])

      updated_txn =
        fake_txn(%{
          pending_transaction_id: "pending-search",
          merchant_name: "Gas Station"
        })

      tx_params = default_tx_params(%{search: "coffee"})

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          updated_txn,
          tx_params,
          []
        )

      assert result.results == []
      assert result.count == 0
    end

    test "keeps swapped row when merchant name matches search case-insensitively" do
      account = fake_account()

      pending_row =
        fake_txn(%{
          plaid_transaction_id: "pending-case",
          is_pending: true,
          merchant_name: "Coffee Shop",
          account: account
        })

      page = fake_page([pending_row])

      updated_txn =
        fake_txn(%{
          pending_transaction_id: "pending-case",
          merchant_name: "COFFEE SHOP"
        })

      tx_params = default_tx_params(%{search: "coffee"})

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          updated_txn,
          tx_params,
          []
        )

      assert length(result.results) == 1
    end

    test "preserves other rows untouched when one row is swapped" do
      account = fake_account()

      pending_row =
        fake_txn(%{
          plaid_transaction_id: "pending-multi",
          is_pending: true,
          account: account
        })

      other_row_1 = fake_txn(%{plaid_transaction_id: "other-1"})
      other_row_2 = fake_txn(%{plaid_transaction_id: "other-2"})

      page = fake_page([other_row_1, pending_row, other_row_2])

      updated_txn =
        fake_txn(%{
          plaid_transaction_id: "posted-multi",
          pending_transaction_id: "pending-multi"
        })

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          updated_txn,
          default_tx_params(),
          []
        )

      assert length(result.results) == 3
      ids = Enum.map(result.results, & &1.plaid_transaction_id)
      assert "other-1" in ids
      assert "other-2" in ids
      assert "posted-multi" in ids
      refute "pending-multi" in ids
    end

    test "preserves page struct fields (count, more?, cursors)" do
      account = fake_account()

      pending_row =
        fake_txn(%{
          plaid_transaction_id: "pending-struct",
          is_pending: true,
          account: account
        })

      page = %Ash.Page.Keyset{
        results: [pending_row],
        count: 42,
        more?: true,
        before: "some-cursor",
        after: nil,
        limit: 25
      }

      updated_txn =
        fake_txn(%{
          pending_transaction_id: "pending-struct"
        })

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          updated_txn,
          default_tx_params(),
          []
        )

      assert result.count == 42
      assert result.more? == true
      assert result.before == "some-cursor"
      assert result.limit == 25
    end

    test "decrements count by 1 when resolved row is dropped; leaves count unchanged when row is kept" do
      account = fake_account()

      pending_row =
        fake_txn(%{
          plaid_transaction_id: "pending-countcheck",
          is_pending: true,
          date: ~D[2026-05-01],
          account: account
        })

      other_row = fake_txn(%{plaid_transaction_id: "other-row", date: ~D[2026-05-10]})

      # 2 rows on the page, total count reported as 50
      page = %Ash.Page.Keyset{
        results: [other_row, pending_row],
        count: 50,
        more?: true,
        before: nil,
        after: nil,
        limit: 25
      }

      # Posted transaction resolves to a date outside the active filter window
      dropped_txn =
        fake_txn(%{
          pending_transaction_id: "pending-countcheck",
          date: ~D[2026-01-01]
        })

      tx_params = default_tx_params(%{date_from: ~D[2026-04-15]})

      result =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          dropped_txn,
          tx_params,
          []
        )

      # The pending row is dropped; count decrements by 1
      assert length(result.results) == 1
      assert result.count == 49

      # Now verify a kept swap leaves count unchanged
      kept_txn =
        fake_txn(%{
          pending_transaction_id: "pending-countcheck",
          date: ~D[2026-05-15]
        })

      result2 =
        TransactionLiveHelpers.apply_resolved_transaction(
          page,
          kept_txn,
          tx_params,
          []
        )

      assert length(result2.results) == 2
      assert result2.count == 50
    end
  end
end
