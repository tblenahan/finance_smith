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

    test "regular user cannot invoke :resolve_pending" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)
      txn = create_transaction!(account, %{is_pending: true})

      assert {:error, %Ash.Error.Forbidden{}} =
               txn
               |> Ash.Changeset.for_update(:resolve_pending, %{
                 plaid_transaction_id: "posted-#{System.unique_integer([:positive])}",
                 amount: txn.amount,
                 date: txn.date
               })
               |> Ash.update(actor: user)
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

  # ────────────────────────────────────────────────────────────────────────────
  # Household isolation
  #
  # Finance Smith allows household members to read each other's banking data.
  # These tests verify:
  #   (a) same-household actor can read another member's data
  #   (b) different-household actor is denied
  #   (c) actor with no shared household is denied
  # ────────────────────────────────────────────────────────────────────────────

  defp share_household!(user1, user2) do
    # Move user2 into user1's household so they share it. household_id is not
    # a public input on the default :update action, so force_change_attribute/3
    # is used (test-only helper; mirrors other authorize?: false test setup).
    user2
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:household_id, user1.household_id)
    |> Ash.update!(authorize?: false)
  end

  describe "Household isolation — PlaidItem reads" do
    test "same-household member can read another member's PlaidItem" do
      owner = register_user!()
      member = register_user!()
      _member = share_household!(owner, member)
      # Reload member so it carries owner's household_id
      member = Ash.get!(FinanceSmith.Identity.User, member.id, authorize?: false)

      plaid_item = create_plaid_item!(owner)

      assert {:ok, %PlaidItem{id: id}} =
               Banking.get_plaid_item_by_id(plaid_item.id, actor: member)

      assert id == plaid_item.id
    end

    test "different-household actor cannot read another user's PlaidItem" do
      owner = register_user!()
      outsider = register_user!()
      plaid_item = create_plaid_item!(owner)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
               Banking.get_plaid_item_by_id(plaid_item.id, actor: outsider)
    end
  end

  describe "Household isolation — Account reads" do
    test "same-household member can read another member's Account" do
      owner = register_user!()
      member = register_user!()
      _member = share_household!(owner, member)
      member = Ash.get!(FinanceSmith.Identity.User, member.id, authorize?: false)

      plaid_item = create_plaid_item!(owner)
      account = create_account!(plaid_item)

      assert {:ok, %Account{id: id}} = Banking.get_account_by_id(account.id, actor: member)
      assert id == account.id
    end

    test "different-household actor cannot read another user's Account" do
      owner = register_user!()
      outsider = register_user!()
      plaid_item = create_plaid_item!(owner)
      account = create_account!(plaid_item)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
               Banking.get_account_by_id(account.id, actor: outsider)
    end
  end

  describe "Household isolation — Transaction reads" do
    test "same-household member can read another member's transactions" do
      owner = register_user!()
      member = register_user!()
      _member = share_household!(owner, member)
      member = Ash.get!(FinanceSmith.Identity.User, member.id, authorize?: false)

      plaid_item = create_plaid_item!(owner)
      account = create_account!(plaid_item)
      _txn = create_transaction!(account)

      assert {:ok, %Ash.Page.Keyset{results: [%Transaction{}]}} =
               Banking.list_transactions(
                 %{date_from: ~D[2024-01-01], date_to: ~D[2026-12-31]},
                 actor: member,
                 page: [limit: 25]
               )
    end

    test "different-household actor cannot read another user's transactions" do
      owner = register_user!()
      outsider = register_user!()
      plaid_item = create_plaid_item!(owner)
      account = create_account!(plaid_item)
      _txn = create_transaction!(account)

      assert {:ok, %Ash.Page.Keyset{results: []}} =
               Banking.list_transactions(
                 %{date_from: ~D[2024-01-01], date_to: ~D[2026-12-31]},
                 actor: outsider,
                 page: [limit: 25]
               )
    end
  end

  describe "Household policy — reads and writes" do
    test "user can read their own household" do
      user = register_user!()

      assert {:ok, %FinanceSmith.Identity.Household{}} =
               Identity.get_household_with_kpis(user.household_id, actor: user)
    end

    test "user from a different household cannot read another household" do
      owner = register_user!()
      stranger = register_user!()

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
               Identity.get_household_with_kpis(owner.household_id, actor: stranger)
    end
  end
end
