defmodule FinanceSmith.Banking.PoliciesTest do
  use FinanceSmith.DataCase, async: false

  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.{Account, PlaidItem, Transaction}
  alias FinanceSmith.Identity

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  describe "PlaidItem.read policy" do
    test "owner can read their PlaidItem" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      assert {:ok, %PlaidItem{id: id}} =
               Banking.get_plaid_item_by_id(plaid_item.id, actor: user)

      assert id == plaid_item.id
    end

    test "non-owner cannot read another user's PlaidItem" do
      owner = register_user!()
      stranger = register_user!()
      plaid_item = create_plaid_item!(owner)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
               Banking.get_plaid_item_by_id(plaid_item.id, actor: stranger)
    end
  end

  describe "PlaidItem.read_for_ui (summary read)" do
    test "owner can read their PlaidItem summary" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      assert {:ok, %PlaidItem{id: id} = summary} =
               Banking.get_plaid_item_summary_by_id(plaid_item.id, actor: user)

      assert id == plaid_item.id
    end

    test "access_token is not loaded by the summary read" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      assert {:ok, summary} =
               Banking.get_plaid_item_summary_by_id(plaid_item.id, actor: user)

      refute Ash.Resource.loaded?(summary, :access_token)
      assert %Ash.NotLoaded{} = summary.access_token
    end

    test "non-owner cannot read another user's PlaidItem summary" do
      owner = register_user!()
      stranger = register_user!()
      plaid_item = create_plaid_item!(owner)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
               Banking.get_plaid_item_summary_by_id(plaid_item.id, actor: stranger)
    end
  end

  describe "PlaidItem.create_from_public_token policy" do
    test "forbidden without an actor" do
      refute Ash.can?({PlaidItem, :create_from_public_token, %{public_token: "pub"}}, nil)
    end

    test "allowed when actor is present" do
      user = register_user!()
      assert Ash.can?({PlaidItem, :create_from_public_token, %{public_token: "pub"}}, user)
    end
  end

  describe "PlaidItem write policies" do
    test "regular user cannot destroy a PlaidItem" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      assert {:error, %Ash.Error.Forbidden{}} =
               plaid_item |> Ash.Changeset.for_destroy(:destroy) |> Ash.destroy(actor: user)
    end

    test "regular user cannot run complete_sync" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      refute Ash.can?({plaid_item, :complete_sync, %{}}, user)
    end
  end

  describe "Account.read policy" do
    test "owner can read an account through plaid_item.user_id" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)

      assert {:ok, %Account{id: id}} = Banking.get_account_by_id(account.id, actor: user)
      assert id == account.id
    end

    test "non-owner cannot read another user's account" do
      owner = register_user!()
      stranger = register_user!()
      plaid_item = create_plaid_item!(owner)
      account = create_account!(plaid_item)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
               Banking.get_account_by_id(account.id, actor: stranger)
    end
  end

  describe "Account write policies" do
    test "regular user cannot create an account" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)

      assert {:error, %Ash.Error.Forbidden{}} =
               Account
               |> Ash.Changeset.for_create(:create, %{
                 plaid_account_id: "acc-forbidden",
                 name: "Attempt",
                 plaid_item_id: plaid_item.id
               })
               |> Ash.create(actor: user)
    end

    test "regular user cannot destroy an account" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)

      assert {:error, %Ash.Error.Forbidden{}} =
               account |> Ash.Changeset.for_destroy(:destroy) |> Ash.destroy(actor: user)
    end
  end

  describe "Transaction.read policy" do
    test "owner can read transactions through account.plaid_item.user_id" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)
      _txn = create_transaction!(account)

      assert {:ok, %Ash.Page.Keyset{results: results}} =
               Banking.list_transactions(
                 %{date_from: ~D[2024-01-01], date_to: ~D[2025-12-31]},
                 actor: user,
                 page: [limit: 25]
               )

      assert length(results) == 1
    end

    test "non-owner cannot read another user's transactions" do
      owner = register_user!()
      stranger = register_user!()
      plaid_item = create_plaid_item!(owner)
      account = create_account!(plaid_item)
      _txn = create_transaction!(account)

      assert {:ok, %Ash.Page.Keyset{results: []}} =
               Banking.list_transactions(
                 %{date_from: ~D[2024-01-01], date_to: ~D[2025-12-31]},
                 actor: stranger,
                 page: [limit: 25]
               )
    end
  end

  describe "Transaction write policies" do
    test "regular user cannot create a transaction" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)

      assert {:error, %Ash.Error.Forbidden{}} =
               Transaction
               |> Ash.Changeset.for_create(:create, %{
                 plaid_transaction_id: "txn-forbidden",
                 amount: 100,
                 date: ~D[2025-01-01],
                 account_id: account.id
               })
               |> Ash.create(actor: user)
    end

    test "regular user cannot destroy a transaction" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)
      txn = create_transaction!(account)

      assert {:error, %Ash.Error.Forbidden{}} =
               txn |> Ash.Changeset.for_destroy(:destroy) |> Ash.destroy(actor: user)
    end
  end

  describe "Transaction list action search" do
    test "merchant_name search is case-insensitive" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)
      _txn = create_transaction!(account, merchant_name: "STARBUCKS Coffee")

      assert {:ok, %Ash.Page.Keyset{results: [%Transaction{merchant_name: "STARBUCKS Coffee"}]}} =
               Banking.list_transactions(
                 %{
                   search: "starbucks",
                   date_from: ~D[2024-01-01],
                   date_to: ~D[2025-12-31]
                 },
                 actor: user,
                 page: [limit: 25]
               )
    end
  end
end
