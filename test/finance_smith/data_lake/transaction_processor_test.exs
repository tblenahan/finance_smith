defmodule FinanceSmith.DataLake.TransactionProcessorTest do
  use FinanceSmith.DataCase, async: false

  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking.{Account, CategoryMapping, MetaCategory, Transaction}
  alias FinanceSmith.DataLake.TransactionProcessor
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

  defp build_plaid_item_with_account(user) do
    plaid_item =
      create_plaid_item!(user)
      |> Ash.load!([:accounts, user: :household], authorize?: false)

    account = create_account!(plaid_item)

    plaid_item =
      plaid_item
      |> Ash.load!([:accounts, user: :household], authorize?: false)

    {plaid_item, account}
  end

  defp txn_payload(plaid_account_id, txn_id, token) do
    base = %{
      "transaction_id" => txn_id,
      "account_id" => plaid_account_id,
      "amount" => 12.50,
      "date" => "2026-05-01",
      "merchant_name" => "Test Merchant",
      "pending" => false
    }

    if token do
      Map.put(base, "personal_finance_category", %{"detailed" => token})
    else
      base
    end
  end

  defp create_duplicate_account!(plaid_item, canonical_account) do
    unique = System.unique_integer([:positive])

    Account
    |> Ash.Changeset.for_create(:create, %{
      plaid_account_id: "dup-acc-#{unique}",
      name: canonical_account.name,
      type: canonical_account.type,
      subtype: canonical_account.subtype,
      plaid_item_id: plaid_item.id
    })
    |> Ash.Changeset.force_change_attribute(:duplicate_of_id, canonical_account.id)
    |> Ash.create!(authorize?: false)
  end

  describe "process/2 — category mapping stamping" do
    test "transaction with prefix-matched token gets the primary MetaCategory" do
      user = register_user!()
      {plaid_item, account} = build_plaid_item_with_account(user)

      food_cat = seed_meta_category!(user.household_id, "Food & Drink")
      seed_mapping!(user.household_id, food_cat.id, "FOOD_AND_DRINK")

      txn_id = "txn-prefix-#{System.unique_integer([:positive])}"

      payload = %{
        "added" => [txn_payload(account.plaid_account_id, txn_id, "FOOD_AND_DRINK_GROCERIES")],
        "modified" => [],
        "removed" => []
      }

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      txn =
        Transaction
        |> Ash.Query.filter(plaid_transaction_id == ^txn_id)
        |> Ash.read_one!(authorize?: false)

      assert txn.meta_category_id == food_cat.id
    end

    test "transaction with unknown token gets Uncategorized and mapping is created as unreviewed" do
      user = register_user!()
      {plaid_item, account} = build_plaid_item_with_account(user)

      txn_id = "txn-unknown-#{System.unique_integer([:positive])}"
      unknown_token = "TOTALLY_UNKNOWN_#{System.unique_integer([:positive])}"

      payload = %{
        "added" => [txn_payload(account.plaid_account_id, txn_id, unknown_token)],
        "modified" => [],
        "removed" => []
      }

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      txn =
        Transaction
        |> Ash.Query.filter(plaid_transaction_id == ^txn_id)
        |> Ash.read_one!(authorize?: false)

      fallback =
        MetaCategory
        |> Ash.Query.filter(household_id == ^user.household_id and name == "Uncategorized")
        |> Ash.read_one!(authorize?: false)

      assert fallback != nil
      assert txn.meta_category_id == fallback.id

      mapping =
        CategoryMapping
        |> Ash.Query.filter(
          household_id == ^user.household_id and
            source_category_token == ^unknown_token
        )
        |> Ash.read_one!(authorize?: false)

      assert mapping != nil
      assert mapping.unreviewed == true
    end

    test "transaction with no category token gets nil meta_category_id" do
      user = register_user!()
      {plaid_item, account} = build_plaid_item_with_account(user)

      txn_id = "txn-nocat-#{System.unique_integer([:positive])}"

      payload = %{
        "added" => [txn_payload(account.plaid_account_id, txn_id, nil)],
        "modified" => [],
        "removed" => []
      }

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      txn =
        Transaction
        |> Ash.Query.filter(plaid_transaction_id == ^txn_id)
        |> Ash.read_one!(authorize?: false)

      assert txn.meta_category_id == nil
    end
  end

  describe "process/2 — pending transaction resolution" do
    test "promotes an existing pending transaction to the posted transaction and skips removed cleanup" do
      user = register_user!()
      {plaid_item, account} = build_plaid_item_with_account(user)

      pending_id = "txn-pending-#{System.unique_integer([:positive])}"
      posted_id = "txn-posted-#{System.unique_integer([:positive])}"

      pending =
        create_transaction!(account,
          plaid_transaction_id: pending_id,
          amount: 1250,
          date: ~D[2026-05-01],
          merchant_name: "Pending Merchant",
          is_pending: true
        )

      posted_payload =
        account.plaid_account_id
        |> txn_payload(posted_id, nil)
        |> Map.merge(%{
          "amount" => 12.75,
          "date" => "2026-05-02",
          "merchant_name" => "Posted Merchant",
          "pending_transaction_id" => pending_id
        })

      payload = %{
        "added" => [posted_payload],
        "modified" => [],
        "removed" => [%{"transaction_id" => pending_id}]
      }

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      assert nil ==
               Transaction
               |> Ash.Query.filter(plaid_transaction_id == ^pending_id)
               |> Ash.read_one!(authorize?: false)

      resolved =
        Transaction
        |> Ash.Query.filter(plaid_transaction_id == ^posted_id)
        |> Ash.read_one!(authorize?: false)

      assert resolved.id == pending.id
      assert resolved.amount == 1275
      assert resolved.date == ~D[2026-05-02]
      assert resolved.merchant_name == "Posted Merchant"
      assert resolved.is_pending == false
      assert resolved.pending_transaction_id == pending_id
    end

    test "resolves pending transactions from modified payloads too" do
      user = register_user!()
      {plaid_item, account} = build_plaid_item_with_account(user)

      pending_id = "txn-modified-pending-#{System.unique_integer([:positive])}"
      posted_id = "txn-modified-posted-#{System.unique_integer([:positive])}"

      pending =
        create_transaction!(account,
          plaid_transaction_id: pending_id,
          is_pending: true
        )

      posted_payload =
        account.plaid_account_id
        |> txn_payload(posted_id, nil)
        |> Map.put("pending_transaction_id", pending_id)

      payload = %{
        "added" => [],
        "modified" => [posted_payload],
        "removed" => [%{"transaction_id" => pending_id}]
      }

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      resolved =
        Transaction
        |> Ash.Query.filter(plaid_transaction_id == ^posted_id)
        |> Ash.read_one!(authorize?: false)

      assert resolved.id == pending.id
      assert resolved.is_pending == false
      assert resolved.pending_transaction_id == pending_id
    end

    test "falls back to standard upsert when pending_transaction_id has no matching row" do
      user = register_user!()
      {plaid_item, account} = build_plaid_item_with_account(user)

      missing_pending_id = "txn-missing-pending-#{System.unique_integer([:positive])}"
      posted_id = "txn-fallback-posted-#{System.unique_integer([:positive])}"

      posted_payload =
        account.plaid_account_id
        |> txn_payload(posted_id, nil)
        |> Map.put("pending_transaction_id", missing_pending_id)

      payload = %{
        "added" => [posted_payload],
        "modified" => [],
        "removed" => []
      }

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      txn =
        Transaction
        |> Ash.Query.filter(plaid_transaction_id == ^posted_id)
        |> Ash.read_one!(authorize?: false)

      assert txn.pending_transaction_id == missing_pending_id
      refute Map.has_key?(txn.metadata, "pending_transaction_id")
    end

    test "destroys stale pending transaction when posted transaction already exists" do
      user = register_user!()
      {plaid_item, account} = build_plaid_item_with_account(user)

      pending_id = "txn-stale-pending-#{System.unique_integer([:positive])}"
      posted_id = "txn-existing-posted-#{System.unique_integer([:positive])}"

      create_transaction!(account,
        plaid_transaction_id: pending_id,
        is_pending: true
      )

      posted =
        create_transaction!(account,
          plaid_transaction_id: posted_id,
          amount: 1250,
          is_pending: false
        )

      posted_payload =
        account.plaid_account_id
        |> txn_payload(posted_id, nil)
        |> Map.merge(%{
          "amount" => 18.50,
          "pending_transaction_id" => pending_id
        })

      payload = %{
        "added" => [posted_payload],
        "modified" => [],
        "removed" => []
      }

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      assert nil ==
               Transaction
               |> Ash.Query.filter(plaid_transaction_id == ^pending_id)
               |> Ash.read_one!(authorize?: false)

      updated_posted =
        Transaction
        |> Ash.Query.filter(plaid_transaction_id == ^posted_id)
        |> Ash.read_one!(authorize?: false)

      assert updated_posted.id == posted.id
      assert updated_posted.amount == 1850
      assert updated_posted.pending_transaction_id == pending_id

      remaining =
        Transaction
        |> Ash.Query.filter(plaid_transaction_id in ^[pending_id, posted_id])
        |> Ash.read!(authorize?: false)

      assert length(remaining) == 1
    end
  end

  describe "process/2 — duplicate account guard" do
    test "skips transactions for soft-linked duplicate accounts" do
      user = register_user!()
      {plaid_item, canonical_account} = build_plaid_item_with_account(user)
      duplicate_account = create_duplicate_account!(plaid_item, canonical_account)

      plaid_item =
        plaid_item
        |> Ash.load!([:accounts, user: :household], authorize?: false)

      canonical_txn_id = "txn-canonical-#{System.unique_integer([:positive])}"
      duplicate_txn_id = "txn-duplicate-#{System.unique_integer([:positive])}"

      payload = %{
        "added" => [
          txn_payload(canonical_account.plaid_account_id, canonical_txn_id, nil),
          txn_payload(duplicate_account.plaid_account_id, duplicate_txn_id, nil)
        ],
        "modified" => [],
        "removed" => []
      }

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      assert %Transaction{} =
               Transaction
               |> Ash.Query.filter(plaid_transaction_id == ^canonical_txn_id)
               |> Ash.read_one!(authorize?: false)

      assert nil ==
               Transaction
               |> Ash.Query.filter(plaid_transaction_id == ^duplicate_txn_id)
               |> Ash.read_one!(authorize?: false)
    end
  end

  describe "process/2 — PubSub notifications" do
    test "broadcasts transaction:created after inserting transactions" do
      user = register_user!()
      {plaid_item, account} = build_plaid_item_with_account(user)

      FinanceSmithWeb.Endpoint.subscribe("transaction:created")

      txn_id = "txn-pubsub-#{System.unique_integer([:positive])}"

      payload = %{
        "added" => [txn_payload(account.plaid_account_id, txn_id, nil)],
        "modified" => [],
        "removed" => []
      }

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      assert_receive %{topic: "transaction:created", payload: %Ash.Notifier.Notification{}},
                     1_000
    end

    test "broadcasts transaction:updated after resolving a pending transaction" do
      user = register_user!()
      {plaid_item, account} = build_plaid_item_with_account(user)

      FinanceSmithWeb.Endpoint.subscribe("transaction:updated")

      pending_id = "txn-update-pending-#{System.unique_integer([:positive])}"
      posted_id = "txn-update-posted-#{System.unique_integer([:positive])}"

      create_transaction!(account, plaid_transaction_id: pending_id, is_pending: true)

      posted_payload =
        account.plaid_account_id
        |> txn_payload(posted_id, nil)
        |> Map.put("pending_transaction_id", pending_id)

      payload = %{
        "added" => [posted_payload],
        "modified" => [],
        "removed" => []
      }

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      assert_receive %{topic: "transaction:updated", payload: %Ash.Notifier.Notification{}},
                     1_000
    end
  end
end
