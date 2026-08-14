defmodule FinanceSmith.Banking.BudgetTargetTest do
  use FinanceSmith.DataCase, async: true

  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.{DatePeriod, MetaCategory}
  alias FinanceSmith.Identity

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  defp seed_meta_category!(household_id, name) do
    unique = System.unique_integer([:positive])

    MetaCategory
    |> Ash.Changeset.for_create(:create_system, %{
      name: "#{name}-#{unique}",
      household_id: household_id
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_duplicate_account!(plaid_item, canonical_account) do
    account = create_account!(plaid_item)

    account
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:duplicate_of_id, canonical_account.id)
    |> Ash.update!(authorize?: false)
  end

  defp load_window!(user, start_date, end_date) do
    Banking.list_budget_targets_for_window!(
      %{start_date: start_date, end_date: end_date},
      actor: user
    )
  end

  describe "actual_spend" do
    test "counts in-window outflows and ignores inflows, other categories, out-of-window dates, and duplicate accounts" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)
      duplicate_account = create_duplicate_account!(plaid_item, account)
      groceries = seed_meta_category!(user.household_id, "Groceries")
      dining = seed_meta_category!(user.household_id, "Dining")
      target = create_budget_target!(user, groceries, %{amount: 50_000, period_type: :monthly})

      start_date = ~D[2026-04-01]
      end_date = ~D[2026-04-30]

      _in_window_outflow =
        create_transaction!(account,
          amount: 1_000,
          date: ~D[2026-04-10],
          meta_category_id: groceries.id
        )

      _pending_outflow =
        create_transaction!(account,
          amount: 250,
          date: ~D[2026-04-15],
          is_pending: true,
          meta_category_id: groceries.id
        )

      _in_window_inflow =
        create_transaction!(account,
          amount: -500,
          date: ~D[2026-04-12],
          meta_category_id: groceries.id
        )

      _other_category =
        create_transaction!(account,
          amount: 999,
          date: ~D[2026-04-10],
          meta_category_id: dining.id
        )

      _outside_window =
        create_transaction!(account,
          amount: 800,
          date: ~D[2026-03-31],
          meta_category_id: groceries.id
        )

      _duplicate_outflow =
        create_transaction!(duplicate_account,
          amount: 700,
          date: ~D[2026-04-10],
          meta_category_id: groceries.id
        )

      [loaded] = load_window!(user, start_date, end_date)
      assert loaded.id == target.id
      assert loaded.actual_spend == 1_250
    end
  end

  describe "scaled_target" do
    test "rounds to the nearest cent using numeric division" do
      user = register_user!()
      groceries = seed_meta_category!(user.household_id, "Groceries")
      _target = create_budget_target!(user, groceries, %{amount: 1_000, period_type: :monthly})

      # April 2026 has 30 days. Window Apr 1–20 is 20 inclusive days.
      # 1000 * 20 / 30 = 666.6... → 667 (integer division would yield 666).
      start_date = ~D[2026-04-01]
      end_date = ~D[2026-04-20]
      assert DatePeriod.period_day_count(:monthly, start_date) == 30
      assert DatePeriod.day_count(start_date, end_date) == 20

      [loaded] = load_window!(user, start_date, end_date)
      assert loaded.scaled_target == 667
    end
  end

  describe "projected_spend" do
    test "is 0 when the window is entirely in the future" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)
      groceries = seed_meta_category!(user.household_id, "Groceries")
      _target = create_budget_target!(user, groceries, %{amount: 10_000, period_type: :monthly})

      start_date = ~D[2099-01-01]
      end_date = ~D[2099-01-31]
      assert DatePeriod.elapsed_days(start_date, end_date, Date.utc_today()) == 0

      _future_outflow =
        create_transaction!(account,
          amount: 2_000,
          date: ~D[2099-01-15],
          meta_category_id: groceries.id
        )

      [loaded] = load_window!(user, start_date, end_date)
      assert loaded.actual_spend == 2_000
      assert loaded.projected_spend == 0
    end
  end

  describe "unique identity" do
    test "rejects a second target for the same meta_category and period_type" do
      user = register_user!()
      groceries = seed_meta_category!(user.household_id, "Groceries")
      _existing = create_budget_target!(user, groceries, %{period_type: :monthly})

      assert {:error, %Ash.Error.Invalid{}} =
               Banking.create_budget_target(
                 %{amount: 5_000, period_type: :monthly, meta_category_id: groceries.id},
                 actor: user
               )
    end

    test "allows a different period_type on the same meta_category" do
      user = register_user!()
      groceries = seed_meta_category!(user.household_id, "Groceries")
      monthly = create_budget_target!(user, groceries, %{period_type: :monthly})
      weekly = create_budget_target!(user, groceries, %{period_type: :weekly})

      assert monthly.id != weekly.id
    end
  end

  describe "create stamps household_id from actor" do
    test "household_id matches the creating user's household" do
      user = register_user!()
      groceries = seed_meta_category!(user.household_id, "Groceries")
      target = create_budget_target!(user, groceries)

      assert target.household_id == user.household_id
    end
  end
end
