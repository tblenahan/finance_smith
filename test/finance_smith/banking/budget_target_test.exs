defmodule FinanceSmith.Banking.BudgetTargetTest do
  use FinanceSmith.DataCase, async: true

  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.DatePeriod
  alias FinanceSmith.Identity

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  defp create_duplicate_account!(plaid_item, canonical_account) do
    account = create_account!(plaid_item)

    account
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:duplicate_of_id, canonical_account.id)
    |> Ash.update!(authorize?: false)
  end

  defp load_window!(user, start_date, end_date, extra_args \\ %{}) do
    Banking.list_budget_targets_for_window!(
      Map.merge(%{start_date: start_date, end_date: end_date}, extra_args),
      actor: user
    )
  end

  defp share_household!(user1, user2) do
    # Move user2 into user1's household so they share it. household_id is not
    # a public input on the default :update action, so force_change_attribute/3
    # is used (test-only helper; mirrors other authorize?: false test setup).
    user2
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:household_id, user1.household_id)
    |> Ash.update!(authorize?: false)

    Ash.get!(Identity.User, user2.id, authorize?: false)
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

    test "extrapolates spend across an in-progress window with numeric rounding" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)
      groceries = seed_meta_category!(user.household_id, "Groceries")
      _target = create_budget_target!(user, groceries, %{amount: 10_000, period_type: :monthly})

      today = Date.utc_today()
      start_date = Date.add(today, -2)
      end_date = Date.add(today, 2)

      assert DatePeriod.day_count(start_date, end_date) == 5
      assert DatePeriod.elapsed_days(start_date, end_date, today) == 3

      _outflow =
        create_transaction!(account,
          amount: 1_000,
          date: Date.add(today, -1),
          meta_category_id: groceries.id
        )

      # 1000 * 5 / 3 = 1666.6... → 1667
      [loaded] = load_window!(user, start_date, end_date)
      assert loaded.actual_spend == 1_000
      assert loaded.projected_spend == 1_667
    end

    test "ignores future in-window transactions when extrapolating projected_spend" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)
      groceries = seed_meta_category!(user.household_id, "Groceries")
      _target = create_budget_target!(user, groceries, %{amount: 10_000, period_type: :monthly})

      today = Date.utc_today()
      start_date = Date.add(today, -2)
      end_date = Date.add(today, 2)

      assert DatePeriod.day_count(start_date, end_date) == 5
      assert DatePeriod.elapsed_days(start_date, end_date, today) == 3
      assert DatePeriod.as_of_date(end_date, today) == today

      _past_outflow =
        create_transaction!(account,
          amount: 1_000,
          date: Date.add(today, -1),
          meta_category_id: groceries.id
        )

      _future_outflow =
        create_transaction!(account,
          amount: 500,
          date: Date.add(today, 1),
          meta_category_id: groceries.id
        )

      # Window actual_spend includes the future row (1_000 + 500).
      # projected_spend extrapolates only through as_of (today): 1000 * 5 / 3 → 1667.
      [loaded] = load_window!(user, start_date, end_date)
      assert loaded.actual_spend == 1_500
      assert loaded.projected_spend == 1_667
    end

    test "equals actual_spend when the window is fully elapsed" do
      user = register_user!()
      plaid_item = create_plaid_item!(user)
      account = create_account!(plaid_item)
      groceries = seed_meta_category!(user.household_id, "Groceries")
      _target = create_budget_target!(user, groceries, %{amount: 10_000, period_type: :monthly})

      today = Date.utc_today()
      start_date = Date.add(today, -20)
      end_date = Date.add(today, -11)

      assert DatePeriod.day_count(start_date, end_date) == 10
      assert DatePeriod.elapsed_days(start_date, end_date, today) == 10

      _outflow =
        create_transaction!(account,
          amount: 2_500,
          date: Date.add(today, -15),
          meta_category_id: groceries.id
        )

      [loaded] = load_window!(user, start_date, end_date)
      assert loaded.actual_spend == 2_500
      assert loaded.projected_spend == 2_500
    end
  end

  describe "user_id scoping" do
    defp seed_two_member_household!(date) do
      owner = register_user!()
      member = share_household!(owner, register_user!())

      owner_account = create_account!(create_plaid_item!(owner))
      member_account = create_account!(create_plaid_item!(member))

      groceries = seed_meta_category!(owner.household_id, "Groceries")
      _target = create_budget_target!(owner, groceries, %{amount: 50_000, period_type: :monthly})

      _owner_outflow =
        create_transaction!(owner_account,
          amount: 1_000,
          date: date,
          meta_category_id: groceries.id
        )

      _member_outflow =
        create_transaction!(member_account,
          amount: 600,
          date: date,
          meta_category_id: groceries.id
        )

      %{owner: owner, member: member}
    end

    test "without user_id, actual_spend is household-wide" do
      %{owner: owner} = seed_two_member_household!(~D[2026-04-10])

      [loaded] = load_window!(owner, ~D[2026-04-01], ~D[2026-04-30])
      assert loaded.actual_spend == 1_600
    end

    test "with user_id, actual_spend counts only that member's transactions" do
      %{owner: owner, member: member} = seed_two_member_household!(~D[2026-04-10])

      [loaded] = load_window!(owner, ~D[2026-04-01], ~D[2026-04-30], %{user_id: member.id})
      assert loaded.actual_spend == 600

      [loaded] = load_window!(owner, ~D[2026-04-01], ~D[2026-04-30], %{user_id: owner.id})
      assert loaded.actual_spend == 1_000
    end

    test "projected_spend respects the user_id filter across an in-progress window" do
      today = Date.utc_today()
      start_date = Date.add(today, -2)
      end_date = Date.add(today, 2)

      assert DatePeriod.day_count(start_date, end_date) == 5
      assert DatePeriod.elapsed_days(start_date, end_date, today) == 3

      %{owner: owner, member: member} = seed_two_member_household!(Date.add(today, -1))

      # Member-only base of 600 extrapolated: 600 * 5 / 3 = 1000.
      [loaded] = load_window!(owner, start_date, end_date, %{user_id: member.id})
      assert loaded.actual_spend == 600
      assert loaded.projected_spend == 1_000

      # Unscoped extrapolation uses the household-wide 1_600: 1600 * 5 / 3 → 2667.
      [loaded] = load_window!(owner, start_date, end_date)
      assert loaded.actual_spend == 1_600
      assert loaded.projected_spend == 2_667
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
