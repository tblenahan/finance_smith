defmodule FinanceSmith.Banking.PoliciesTest do
  use FinanceSmith.DataCase, async: false

  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.{Account, PlaidItem, Transaction}
  alias FinanceSmith.Identity

  require Ash.Query

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  defp upsert_plaid_account!(plaid_item, attrs) do
    unique = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          plaid_account_id: "plaid-account-#{unique}",
          plaid_item_id: plaid_item.id,
          name: "Credit Card",
          mask: "1234",
          type: "credit",
          subtype: "credit card"
        },
        Map.new(attrs)
      )

    Account
    |> Ash.Changeset.for_create(:upsert_from_plaid, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp create_duplicate_account!(plaid_item, canonical_account) do
    account = create_account!(plaid_item)

    account
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:duplicate_of_id, canonical_account.id)
    |> Ash.update!(authorize?: false)
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

    test "read_for_ui excludes soft-linked duplicate accounts" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      canonical_account = create_account!(plaid_item)
      duplicate_account = create_duplicate_account!(plaid_item, canonical_account)

      assert {:ok, %Account{id: id}} =
               Banking.get_account_by_id(canonical_account.id, actor: user)

      assert id == canonical_account.id

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
               Banking.get_account_by_id(duplicate_account.id, actor: user)
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

  describe "Account soft-link duplicate detection" do
    test "marks same-user accounts with the same institution mask and subtype as duplicates" do
      user = register_user!()
      first_item = create_plaid_item!(user, %{institution_name: "Chase"})
      second_item = create_plaid_item!(user, %{institution_name: "Chase"})

      canonical =
        upsert_plaid_account!(first_item,
          plaid_account_id: "canonical-#{System.unique_integer([:positive])}",
          mask: "5189",
          subtype: "credit card"
        )

      duplicate =
        upsert_plaid_account!(second_item,
          plaid_account_id: "duplicate-#{System.unique_integer([:positive])}",
          mask: "5189",
          subtype: "credit card"
        )

      assert duplicate.duplicate_of_id == canonical.id
    end

    test "does not soft-link nil mask different subtype or different user accounts" do
      user = register_user!()
      other_user = register_user!()
      first_item = create_plaid_item!(user, %{institution_name: "Chase"})
      second_item = create_plaid_item!(user, %{institution_name: "Chase"})
      other_item = create_plaid_item!(other_user, %{institution_name: "Chase"})

      _canonical =
        upsert_plaid_account!(first_item,
          plaid_account_id: "canonical-#{System.unique_integer([:positive])}",
          mask: "5189",
          subtype: "credit card"
        )

      nil_mask =
        upsert_plaid_account!(second_item,
          plaid_account_id: "nil-mask-#{System.unique_integer([:positive])}",
          mask: nil,
          subtype: "credit card"
        )

      different_subtype =
        upsert_plaid_account!(second_item,
          plaid_account_id: "different-subtype-#{System.unique_integer([:positive])}",
          mask: "5189",
          subtype: "checking"
        )

      different_user =
        upsert_plaid_account!(other_item,
          plaid_account_id: "different-user-#{System.unique_integer([:positive])}",
          mask: "5189",
          subtype: "credit card"
        )

      assert is_nil(nil_mask.duplicate_of_id)
      assert is_nil(different_subtype.duplicate_of_id)
      assert is_nil(different_user.duplicate_of_id)
    end

    test "does not soft-link when institution names differ" do
      user = register_user!()
      chase_item = create_plaid_item!(user, %{institution_name: "Chase"})
      bofa_item = create_plaid_item!(user, %{institution_name: "Bank of America"})

      _canonical =
        upsert_plaid_account!(chase_item,
          plaid_account_id: "canonical-#{System.unique_integer([:positive])}",
          mask: "5189",
          subtype: "credit card"
        )

      other_institution =
        upsert_plaid_account!(bofa_item,
          plaid_account_id: "other-inst-#{System.unique_integer([:positive])}",
          mask: "5189",
          subtype: "credit card"
        )

      assert is_nil(other_institution.duplicate_of_id)
    end

    test "does not soft-link when plaid item institution_name is nil" do
      user = register_user!()
      named_item = create_plaid_item!(user, %{institution_name: "Chase"})
      nil_institution_item = create_plaid_item!(user, %{institution_name: nil})

      _canonical =
        upsert_plaid_account!(named_item,
          plaid_account_id: "canonical-#{System.unique_integer([:positive])}",
          mask: "5189",
          subtype: "credit card"
        )

      nil_institution_account =
        upsert_plaid_account!(nil_institution_item,
          plaid_account_id: "nil-inst-#{System.unique_integer([:positive])}",
          mask: "5189",
          subtype: "credit card"
        )

      assert is_nil(nil_institution_account.duplicate_of_id)
    end
  end

  describe "duplicate account KPI aggregates" do
    test "user outflow_30d and inflow_30d exclude soft-linked duplicate account transactions" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      canonical_account = create_account!(plaid_item)
      duplicate_account = create_duplicate_account!(plaid_item, canonical_account)
      today = Date.utc_today()

      _canonical_outflow =
        create_transaction!(canonical_account,
          plaid_transaction_id: "canonical-out-#{System.unique_integer([:positive])}",
          amount: 10_000,
          date: today
        )

      _duplicate_outflow =
        create_transaction!(duplicate_account,
          plaid_transaction_id: "duplicate-out-#{System.unique_integer([:positive])}",
          amount: 10_000,
          date: today
        )

      _canonical_inflow =
        create_transaction!(canonical_account,
          plaid_transaction_id: "canonical-in-#{System.unique_integer([:positive])}",
          amount: -5_000,
          date: today
        )

      _duplicate_inflow =
        create_transaction!(duplicate_account,
          plaid_transaction_id: "duplicate-in-#{System.unique_integer([:positive])}",
          amount: -5_000,
          date: today
        )

      user_with_kpis =
        Identity.get_user_with_kpis!(user.id,
          load: [:outflow_30d, :inflow_30d],
          actor: user
        )

      assert user_with_kpis.outflow_30d == 10_000
      assert user_with_kpis.inflow_30d == -5_000
    end

    test "plaid item kpi_outflow_30d and kpi_inflow_30d exclude duplicate account transactions" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      canonical_account = create_account!(plaid_item)
      duplicate_account = create_duplicate_account!(plaid_item, canonical_account)
      today = Date.utc_today()

      _canonical_outflow =
        create_transaction!(canonical_account,
          plaid_transaction_id: "canonical-out-#{System.unique_integer([:positive])}",
          amount: 8_000,
          date: today
        )

      _duplicate_outflow =
        create_transaction!(duplicate_account,
          plaid_transaction_id: "duplicate-out-#{System.unique_integer([:positive])}",
          amount: 8_000,
          date: today
        )

      _canonical_inflow =
        create_transaction!(canonical_account,
          plaid_transaction_id: "canonical-in-#{System.unique_integer([:positive])}",
          amount: -3_000,
          date: today
        )

      _duplicate_inflow =
        create_transaction!(duplicate_account,
          plaid_transaction_id: "duplicate-in-#{System.unique_integer([:positive])}",
          amount: -3_000,
          date: today
        )

      item_with_kpis =
        Banking.get_plaid_item_kpis!(plaid_item.id,
          load: [:kpi_outflow_30d, :kpi_inflow_30d],
          actor: user
        )

      assert item_with_kpis.kpi_outflow_30d == 8_000
      assert item_with_kpis.kpi_inflow_30d == -3_000
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

    test "list action excludes transactions on soft-linked duplicate accounts" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      canonical_account = create_account!(plaid_item)
      duplicate_account = create_duplicate_account!(plaid_item, canonical_account)

      _canonical_txn =
        create_transaction!(canonical_account,
          plaid_transaction_id: "canonical-txn-#{System.unique_integer([:positive])}",
          date: ~D[2025-06-01]
        )

      _duplicate_txn =
        create_transaction!(duplicate_account,
          plaid_transaction_id: "duplicate-txn-#{System.unique_integer([:positive])}",
          date: ~D[2025-06-01]
        )

      assert {:ok, %Ash.Page.Keyset{results: results}} =
               Banking.list_transactions(
                 %{date_from: ~D[2025-01-01], date_to: ~D[2025-12-31]},
                 actor: user,
                 page: [limit: 25]
               )

      assert length(results) == 1
      assert hd(results).account_id == canonical_account.id
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
