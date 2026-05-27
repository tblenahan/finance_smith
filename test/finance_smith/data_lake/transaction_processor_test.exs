defmodule FinanceSmith.DataLake.TransactionProcessorTest do
  use FinanceSmith.DataCase, async: false

  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking.{CategoryMapping, MetaCategory, Transaction}
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
  end
end
