defmodule FinanceSmithWeb.BudgetsLiveTest do
  # LiveView tests must NOT be async: true — Phoenix.LiveViewTest spawns a
  # separate LiveView process that needs the shared sandbox DB connection.
  # ConnCase sets shared: true only when async is false.
  use FinanceSmithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import FinanceSmith.BankingFixtures

  alias FinanceSmith.Banking
  alias FinanceSmith.Identity

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  defp share_household!(user1, user2) do
    user2
    |> Ash.Changeset.for_update(:update, %{})
    |> Ash.Changeset.force_change_attribute(:household_id, user1.household_id)
    |> Ash.update!(authorize?: false)

    Ash.get!(Identity.User, user2.id, authorize?: false)
  end

  defp seed_budget!(user, opts \\ []) do
    category_name =
      Keyword.get(opts, :category, "Groceries #{System.unique_integer([:positive])}")

    amount = Keyword.get(opts, :amount, 50_000)

    account = create_account!(create_plaid_item!(user))
    category = seed_meta_category!(user.household_id, category_name)
    target = create_budget_target!(user, category, %{amount: amount, period_type: :monthly})

    %{account: account, category: category, target: target}
  end

  describe "mount" do
    test "redirects unauthenticated requests to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} = live(conn, "/budgets")
    end

    test "renders the empty state when no targets exist", %{conn: conn} do
      user = register_user!()

      {:ok, _view, html} = conn |> log_in_user(user) |> live("/budgets")

      assert html =~ "Budgets"
      assert html =~ "There is no data here. Only an anomaly."
      assert html =~ "Define Targets"
    end

    test "does not show another household's targets", %{conn: conn} do
      other = register_user!()
      seed_budget!(other, category: "Other Household Rent")

      user = register_user!()
      {:ok, _view, html} = conn |> log_in_user(user) |> live("/budgets")

      refute html =~ "Other Household Rent"
      assert html =~ "There is no data here. Only an anomaly."
    end
  end

  describe "matrix view" do
    test "renders targets with window metrics and velocity badge", %{conn: conn} do
      user = register_user!()
      %{account: account, category: category} = seed_budget!(user, category: "Groceries")

      create_transaction!(account,
        amount: 1_000,
        date: Date.utc_today(),
        meta_category_id: category.id
      )

      {:ok, _view, html} = conn |> log_in_user(user) |> live("/budgets")

      assert html =~ "Groceries"
      assert html =~ "$500.00"
      assert html =~ "$10.00"
      assert html =~ "Cruising"
      assert html =~ "% of limit"
    end

    test "flags runaway spend as Over", %{conn: conn} do
      user = register_user!()
      %{account: account, category: category} = seed_budget!(user, amount: 1_000)

      create_transaction!(account,
        amount: 5_000,
        date: Date.utc_today(),
        meta_category_id: category.id
      )

      {:ok, _view, html} = conn |> log_in_user(user) |> live("/budgets")

      assert html =~ "Over"
    end

    test "switches windows", %{conn: conn} do
      user = register_user!()
      seed_budget!(user)

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      html =
        view
        |> element(~s(button[phx-value-window="weekly"]))
        |> render_click()

      {start_date, _end_date} = FinanceSmith.Banking.DatePeriod.to_range(:weekly)
      assert html =~ Calendar.strftime(start_date, "%b %d")
    end
  end

  describe "cards view" do
    test "renders budget cards with pacing microcopy", %{conn: conn} do
      user = register_user!()
      %{account: account, category: category, target: target} = seed_budget!(user)

      create_transaction!(account,
        amount: 2_500,
        date: Date.utc_today(),
        meta_category_id: category.id
      )

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      html =
        view
        |> element(~s(button[phx-value-mode="cards"]))
        |> render_click()

      assert html =~ "budget-card-#{target.id}"
      assert html =~ "of limit"
      assert html =~ "Projected"
    end
  end

  describe "scope switching" do
    test "personal scope counts only the actor's transactions", %{conn: conn} do
      owner = register_user!()
      member = share_household!(owner, register_user!())

      %{account: owner_account, category: category} = seed_budget!(owner)
      member_account = create_account!(create_plaid_item!(member))

      create_transaction!(owner_account,
        amount: 1_000,
        date: Date.utc_today(),
        meta_category_id: category.id
      )

      create_transaction!(member_account,
        amount: 600,
        date: Date.utc_today(),
        meta_category_id: category.id
      )

      {:ok, view, html} = conn |> log_in_user(owner) |> live("/budgets")

      # Household scope aggregates both members.
      assert html =~ "$16.00"

      html =
        view
        |> element(~s(form[phx-change="change_view_scope"]))
        |> render_change(%{scope: "scope_personal"})

      assert html =~ "$10.00"
      refute html =~ "$16.00"
      assert html =~ "Personal lens"
    end
  end

  describe "drill-down" do
    test "renders the category's transactions from URL state", %{conn: conn} do
      user = register_user!()
      %{account: account, category: category} = seed_budget!(user, category: "Dining")
      other_category = seed_meta_category!(user.household_id, "Utilities")

      create_transaction!(account,
        amount: 1_200,
        date: Date.utc_today(),
        merchant_name: "Drill Bistro",
        meta_category_id: category.id
      )

      create_transaction!(account,
        amount: 900,
        date: Date.utc_today(),
        merchant_name: "Power Company",
        meta_category_id: other_category.id
      )

      today = Date.to_iso8601(Date.utc_today())

      {:ok, _view, html} =
        conn
        |> log_in_user(user)
        |> live("/budgets?category=#{category.id}&date_from=#{today}&date_to=#{today}")

      assert html =~ "Inspecting"
      assert html =~ "Drill Bistro"
      refute html =~ "Power Company"
      assert html =~ "Close inspection"
    end

    test "personal scope filters the drill-down transactions", %{conn: conn} do
      owner = register_user!()
      member = share_household!(owner, register_user!())

      %{account: owner_account, category: category} = seed_budget!(owner)
      member_account = create_account!(create_plaid_item!(member))

      create_transaction!(owner_account,
        amount: 1_000,
        date: Date.utc_today(),
        merchant_name: "Owner Store",
        meta_category_id: category.id
      )

      create_transaction!(member_account,
        amount: 600,
        date: Date.utc_today(),
        merchant_name: "Member Store",
        meta_category_id: category.id
      )

      today = Date.to_iso8601(Date.utc_today())

      {:ok, view, html} =
        conn
        |> log_in_user(owner)
        |> live("/budgets?category=#{category.id}&date_from=#{today}&date_to=#{today}")

      assert html =~ "Owner Store"
      assert html =~ "Member Store"

      html =
        view
        |> element(~s(form[phx-change="change_view_scope"]))
        |> render_change(%{scope: "scope_personal"})

      assert html =~ "Owner Store"
      refute html =~ "Member Store"
    end

    test "clicking a card opens the drill-down via patch", %{conn: conn} do
      user = register_user!()
      %{category: category, target: target} = seed_budget!(user)

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      view
      |> element(~s(button[phx-value-mode="cards"]))
      |> render_click()

      view
      |> element("#budget-card-#{target.id}")
      |> render_click()

      assert_patch(view)
      assert render(view) =~ "Inspecting"
      assert render(view) =~ category.name
    end
  end

  describe "inline editing" do
    test "double-click hook opens the editor and submit saves the new amount", %{conn: conn} do
      user = register_user!()
      %{target: target} = seed_budget!(user, amount: 50_000)

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      view
      |> element("#target-amount-#{target.id}")
      |> render_hook("begin_edit", %{"id" => target.id})

      assert has_element?(view, "#edit-target-form")

      html =
        view
        |> form("#edit-target-form", edit_target: %{amount: "750.25"})
        |> render_submit()

      assert html =~ "Target updated."
      assert Banking.get_budget_target_by_id!(target.id, actor: user).amount == 75_025
    end

    test "rejects invalid input and keeps the stored amount", %{conn: conn} do
      user = register_user!()
      %{target: target} = seed_budget!(user, amount: 50_000)

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      view
      |> element("#target-amount-#{target.id}")
      |> render_hook("begin_edit", %{"id" => target.id})

      html =
        view
        |> form("#edit-target-form", edit_target: %{amount: "not-money"})
        |> render_submit()

      assert html =~ "is invalid"
      assert Banking.get_budget_target_by_id!(target.id, actor: user).amount == 50_000
    end

    test "escape cancels the editor without saving", %{conn: conn} do
      user = register_user!()
      %{target: target} = seed_budget!(user, amount: 50_000)

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      view
      |> element("#target-amount-#{target.id}")
      |> render_hook("begin_edit", %{"id" => target.id})

      view |> render_hook("cancel_edit", %{})

      refute has_element?(view, "#edit-target-form")
      assert Banking.get_budget_target_by_id!(target.id, actor: user).amount == 50_000
    end
  end

  describe "smart sheet" do
    test "creates a target for a category without one", %{conn: conn} do
      user = register_user!()
      category = seed_meta_category!(user.household_id, "Subscriptions")

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      view |> element("button", "Define Targets") |> render_click()

      view
      |> form("#sheet-row-new-#{category.id}", %{
        "row_new_#{category.id}" => %{"amount" => "42", "period_type" => "monthly"}
      })
      |> render_change()

      html =
        view
        |> element(~s(button[phx-click="apply_sheet"]))
        |> render_click()

      assert html =~ "Targets updated. Inevitable."

      [target] = Banking.list_budget_targets!(actor: user)
      assert target.amount == 4_200
      assert target.period_type == :monthly
      assert target.meta_category_id == category.id
    end

    test "updates an existing target and skips untouched rows", %{conn: conn} do
      user = register_user!()
      %{target: target} = seed_budget!(user, amount: 50_000, category: "Groceries")
      %{target: untouched} = seed_budget!(user, amount: 10_000, category: "Dining")

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      view |> element("button", "Adjust Targets") |> render_click()

      view
      |> form("#sheet-row-#{target.id}", %{
        "row_#{target.id}" => %{"amount" => "612.50", "period_type" => "monthly"}
      })
      |> render_change()

      view
      |> element(~s(button[phx-click="apply_sheet"]))
      |> render_click()

      assert Banking.get_budget_target_by_id!(target.id, actor: user).amount == 61_250

      unchanged = Banking.get_budget_target_by_id!(untouched.id, actor: user)
      assert unchanged.amount == 10_000
      assert unchanged.updated_at == untouched.updated_at
    end

    test "surfaces per-row errors and keeps the sheet open", %{conn: conn} do
      user = register_user!()
      %{target: target} = seed_budget!(user, amount: 50_000)

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      view |> element("button", "Adjust Targets") |> render_click()

      view
      |> form("#sheet-row-#{target.id}", %{
        "row_#{target.id}" => %{"amount" => "-10", "period_type" => "monthly"}
      })
      |> render_change()

      html =
        view
        |> element(~s(button[phx-click="apply_sheet"]))
        |> render_click()

      assert html =~ "We have a... discrepancy."
      assert has_element?(view, "#sheet-row-#{target.id}")
      assert Banking.get_budget_target_by_id!(target.id, actor: user).amount == 50_000
    end

    test "creates and updates in the same apply", %{conn: conn} do
      user = register_user!()
      %{target: existing} = seed_budget!(user, amount: 50_000, category: "Groceries")
      new_category = seed_meta_category!(user.household_id, "Subscriptions")

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      view |> element("button", "Adjust Targets") |> render_click()

      view
      |> form("#sheet-row-#{existing.id}", %{
        "row_#{existing.id}" => %{"amount" => "600", "period_type" => "monthly"}
      })
      |> render_change()

      view
      |> form("#sheet-row-new-#{new_category.id}", %{
        "row_new_#{new_category.id}" => %{"amount" => "42", "period_type" => "monthly"}
      })
      |> render_change()

      html =
        view
        |> element(~s(button[phx-click="apply_sheet"]))
        |> render_click()

      assert html =~ "Targets updated. Inevitable."
      assert Banking.get_budget_target_by_id!(existing.id, actor: user).amount == 60_000

      created =
        Banking.list_budget_targets!(actor: user)
        |> Enum.find(&(&1.meta_category_id == new_category.id))

      assert created.amount == 4_200
    end

    test "rolls back the batch on a concurrent unique conflict and allows safe retry", %{
      conn: conn
    } do
      user = register_user!()
      %{target: existing} = seed_budget!(user, amount: 50_000, category: "Groceries")
      new_category = seed_meta_category!(user.household_id, "Subscriptions")

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      view |> element("button", "Adjust Targets") |> render_click()

      view
      |> form("#sheet-row-#{existing.id}", %{
        "row_#{existing.id}" => %{"amount" => "600", "period_type" => "monthly"}
      })
      |> render_change()

      view
      |> form("#sheet-row-new-#{new_category.id}", %{
        "row_new_#{new_category.id}" => %{"amount" => "42", "period_type" => "monthly"}
      })
      |> render_change()

      # Race a create for the same identity so the sheet's create fails at submit time.
      raced =
        create_budget_target!(user, new_category, %{amount: 1_000, period_type: :monthly})

      html =
        view
        |> element(~s(button[phx-click="apply_sheet"]))
        |> render_click()

      assert html =~ "We have a... discrepancy."
      assert has_element?(view, "#sheet-row-new-#{new_category.id}")
      assert Banking.get_budget_target_by_id!(existing.id, actor: user).amount == 50_000
      assert Banking.get_budget_target_by_id!(raced.id, actor: user).amount == 1_000

      :ok = Banking.destroy_budget_target(raced, actor: user)

      html =
        view
        |> element(~s(button[phx-click="apply_sheet"]))
        |> render_click()

      assert html =~ "Targets updated. Inevitable."
      assert Banking.get_budget_target_by_id!(existing.id, actor: user).amount == 60_000

      created =
        Banking.list_budget_targets!(actor: user)
        |> Enum.find(&(&1.meta_category_id == new_category.id))

      assert created.amount == 4_200
      refute created.id == raced.id
    end

    test "accepts dollar amounts with a space after the currency symbol", %{conn: conn} do
      user = register_user!()
      category = seed_meta_category!(user.household_id, "Utilities")

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      view |> element("button", "Define Targets") |> render_click()

      view
      |> form("#sheet-row-new-#{category.id}", %{
        "row_new_#{category.id}" => %{"amount" => "$ 50.00", "period_type" => "monthly"}
      })
      |> render_change()

      html =
        view
        |> element(~s(button[phx-click="apply_sheet"]))
        |> render_click()

      assert html =~ "Targets updated. Inevitable."

      [target] = Banking.list_budget_targets!(actor: user)
      assert target.amount == 5_000
    end

    test "marks removal as pending until apply and preserves sibling edits", %{conn: conn} do
      user = register_user!()
      %{target: keep} = seed_budget!(user, amount: 50_000, category: "Groceries")
      %{target: remove} = seed_budget!(user, amount: 10_000, category: "Dining")

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      view |> element("button", "Adjust Targets") |> render_click()

      view
      |> form("#sheet-row-#{keep.id}", %{
        "row_#{keep.id}" => %{"amount" => "612.50", "period_type" => "monthly"}
      })
      |> render_change()

      html =
        view
        |> element(~s(button[phx-click="remove_target"][phx-value-id="#{remove.id}"]))
        |> render_click()

      assert html =~ "Pending removal"
      assert Banking.get_budget_target_by_id!(remove.id, actor: user).amount == 10_000

      html =
        view
        |> element(~s(button[phx-click="apply_sheet"]))
        |> render_click()

      assert html =~ "Targets updated. Inevitable."
      assert Banking.get_budget_target_by_id!(keep.id, actor: user).amount == 61_250
      assert {:error, _} = Banking.get_budget_target_by_id(remove.id, actor: user)
    end

    test "removes a target after marking pending and applying", %{conn: conn} do
      user = register_user!()
      %{target: target} = seed_budget!(user)

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      view |> element("button", "Adjust Targets") |> render_click()

      view
      |> element(~s(button[phx-click="remove_target"][phx-value-id="#{target.id}"]))
      |> render_click()

      assert Banking.get_budget_target_by_id!(target.id, actor: user)

      view
      |> element(~s(button[phx-click="apply_sheet"]))
      |> render_click()

      assert {:error, _} = Banking.get_budget_target_by_id(target.id, actor: user)
    end
  end

  describe "cross-household write isolation" do
    test "begin_edit and remove_target ignore foreign target ids", %{conn: conn} do
      other = register_user!()
      %{target: foreign} = seed_budget!(other, category: "Other Household Rent")

      user = register_user!()
      %{target: own} = seed_budget!(user, amount: 50_000, category: "Groceries")

      {:ok, view, _html} = conn |> log_in_user(user) |> live("/budgets")

      view
      |> element("#target-amount-#{own.id}")
      |> render_hook("begin_edit", %{"id" => foreign.id})

      refute has_element?(view, "#edit-target-form")

      view |> element("button", "Adjust Targets") |> render_click()

      view
      |> element(~s(button[phx-click="remove_target"][phx-value-id="#{own.id}"]))
      |> render_click()

      # Forged foreign id is a no-op; own pending-remove state is unchanged by a
      # separate forged event that never matches a sheet row.
      render_click(view, "remove_target", %{"id" => foreign.id})

      assert has_element?(view, "#sheet-row-#{own.id}")
      assert render(view) =~ "Pending removal"
      assert Banking.get_budget_target_by_id!(own.id, actor: user).amount == 50_000

      assert Banking.get_budget_target_by_id!(foreign.id, actor: other).amount ==
               foreign.amount
    end
  end
end
