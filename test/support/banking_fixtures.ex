defmodule FinanceSmith.BankingFixtures do
  @moduledoc """
  Shared test fixtures for Banking resources.

  Uses the explicit `AshCloak.encrypt_and_set/3` idiom to correctly set the
  encrypted `access_token` on `PlaidItem` records.
  """

  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.{Account, PlaidItem, Transaction}

  @doc """
  Creates a `PlaidItem` bypassing authorization, using Cloak-correct token encryption.
  Accepts an optional `attrs` map to override defaults.
  """
  def create_plaid_item!(user, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    PlaidItem
    |> Ash.Changeset.for_create(:create, %{status: Map.get(attrs, :status, :active)})
    |> Ash.Changeset.force_change_attribute(
      :plaid_item_id,
      Map.get(attrs, :plaid_item_id, "item-#{unique}")
    )
    |> AshCloak.encrypt_and_set(:access_token, Map.get(attrs, :access_token, "access-#{unique}"))
    |> Ash.Changeset.force_change_attribute(
      :institution_name,
      Map.get(attrs, :institution_name, "Test Bank")
    )
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.create!(authorize?: false)
  end

  @doc """
  Creates an `Account` under the given `plaid_item`, bypassing authorization.
  Accepts an optional `attrs` map to override defaults.
  """
  def create_account!(plaid_item, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      plaid_account_id: Map.get(attrs, :plaid_account_id, "acc-#{unique}"),
      name: Map.get(attrs, :name, "Checking"),
      type: Map.get(attrs, :type, "depository"),
      subtype: Map.get(attrs, :subtype, "checking"),
      plaid_item_id: plaid_item.id
    }

    Account
    |> Ash.Changeset.for_create(:create, defaults)
    |> Ash.create!(authorize?: false)
  end

  @doc """
  Creates a `Transaction` under the given `account`, bypassing authorization.
  Accepts an optional keyword or map of `attrs` to override defaults.
  """
  def create_transaction!(account, attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    attrs_map = Map.new(attrs)

    defaults = %{
      plaid_transaction_id: Map.get(attrs_map, :plaid_transaction_id, "txn-#{unique}"),
      amount: Map.get(attrs_map, :amount, 500),
      date: Map.get(attrs_map, :date, ~D[2025-06-01]),
      merchant_name: Map.get(attrs_map, :merchant_name, "Test Merchant"),
      account_id: account.id,
      is_pending: Map.get(attrs_map, :is_pending, false),
      personal_finance_category: Map.get(attrs_map, :personal_finance_category, nil),
      meta_category_id: Map.get(attrs_map, :meta_category_id)
    }

    Transaction
    |> Ash.Changeset.for_create(:create, defaults)
    |> Ash.create!(authorize?: false)
  end

  @doc """
  Creates a `BudgetTarget` for `meta_category` as `user`.

  Uses the primary `:create` action with `actor: user` so household_id is
  stamped by policy-compliant `SetHouseholdFromActor`.
  """
  def create_budget_target!(user, meta_category, attrs \\ %{}) do
    attrs_map = Map.new(attrs)

    Banking.create_budget_target!(
      %{
        amount: Map.get(attrs_map, :amount, 10_000),
        period_type: Map.get(attrs_map, :period_type, :monthly),
        meta_category_id: meta_category.id
      },
      actor: user
    )
  end
end
