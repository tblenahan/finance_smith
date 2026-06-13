defmodule FinanceSmith.DataLake.TransactionProcessorCachedBalancesTest do
  @moduledoc """
  Tests that TransactionProcessor applies cached balances from the
  `accounts` array in the /transactions/sync payload without disturbing the
  transaction upsert/dedup logic.
  """

  use FinanceSmith.DataCase, async: false

  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking.Account
  alias FinanceSmith.DataLake.TransactionProcessor
  alias FinanceSmith.Identity

  require Ash.Query

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  defp build_plaid_item_with_account(user) do
    plaid_item =
      create_plaid_item!(user)
      |> Ash.load!([:accounts, user: :household], authorize?: false)

    account = create_account!(plaid_item)

    plaid_item = Ash.load!(plaid_item, [:accounts, user: :household], authorize?: false)
    {plaid_item, account}
  end

  # A payload with no transactions but a populated accounts array.
  defp balance_only_payload(plaid_account_id, current, available, limit) do
    %{
      "added" => [],
      "modified" => [],
      "removed" => [],
      "next_cursor" => "cursor_cached",
      "has_more" => false,
      "accounts" => [
        %{
          "account_id" => plaid_account_id,
          "balances" => %{
            "current" => current,
            "available" => available,
            "limit" => limit
          }
        }
      ]
    }
  end

  describe "process/2 cached balance extraction" do
    test "updates current_balance and available_balance from payload accounts" do
      user = register_user!()
      {plaid_item, account} = build_plaid_item_with_account(user)

      payload = balance_only_payload(account.plaid_account_id, 2500.00, 2100.50, nil)

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      updated = Ash.get!(Account, account.id, authorize?: false)
      assert updated.current_balance == 250_000
      assert updated.available_balance == 210_050
      assert is_nil(updated.credit_limit)
    end

    test "stores nil available_balance when payload provides nil (graceful nil handling)" do
      user = register_user!()
      {plaid_item, account} = build_plaid_item_with_account(user)

      payload = balance_only_payload(account.plaid_account_id, 1000.00, nil, nil)

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      updated = Ash.get!(Account, account.id, authorize?: false)
      assert updated.current_balance == 100_000
      assert is_nil(updated.available_balance)
    end

    test "updates credit_limit for credit accounts" do
      user = register_user!()

      plaid_item =
        create_plaid_item!(user) |> Ash.load!([:accounts, user: :household], authorize?: false)

      account =
        create_account!(plaid_item, %{type: "credit", subtype: "credit card"})

      plaid_item = Ash.load!(plaid_item, [:accounts, user: :household], authorize?: false)

      payload = balance_only_payload(account.plaid_account_id, 450.00, nil, 5000.00)

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      updated = Ash.get!(Account, account.id, authorize?: false)
      assert updated.current_balance == 45_000
      assert updated.credit_limit == 500_000
      assert is_nil(updated.available_balance)
    end

    test "does not update duplicate accounts" do
      user = register_user!()

      plaid_item =
        create_plaid_item!(user) |> Ash.load!([:accounts, user: :household], authorize?: false)

      original = create_account!(plaid_item, %{plaid_account_id: "acc_orig_cached"})

      dup_account_id = "acc_dup_cached_#{System.unique_integer([:positive])}"

      Account
      |> Ash.Changeset.for_create(
        :create,
        %{
          plaid_account_id: dup_account_id,
          name: "Dup",
          type: "depository",
          subtype: "checking",
          plaid_item_id: plaid_item.id
        }
      )
      |> Ash.Changeset.force_change_attribute(:duplicate_of_id, original.id)
      |> Ash.create!(authorize?: false)

      plaid_item = Ash.load!(plaid_item, [:accounts, user: :household], authorize?: false)

      payload = balance_only_payload(dup_account_id, 9999.00, nil, nil)

      assert :ok = TransactionProcessor.process(plaid_item, payload)

      # Duplicate account balance must remain unchanged (nil)
      dup =
        Account
        |> Ash.Query.filter(plaid_account_id == ^dup_account_id)
        |> Ash.read_one!(authorize?: false)

      assert is_nil(dup.current_balance)
    end

    test "processes without error when payload has no accounts key" do
      user = register_user!()
      {plaid_item, _account} = build_plaid_item_with_account(user)

      payload = %{
        "added" => [],
        "modified" => [],
        "removed" => [],
        "next_cursor" => "cursor_no_acc",
        "has_more" => false
      }

      assert :ok = TransactionProcessor.process(plaid_item, payload)
    end
  end
end
