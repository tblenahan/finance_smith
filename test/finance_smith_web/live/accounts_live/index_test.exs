defmodule FinanceSmithWeb.AccountsLive.IndexTest do
  use FinanceSmithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FinanceSmith.BankingFixtures
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
  end

  describe "Connected Accounts list" do
    test "shows empty state when the actor has no accounts", %{conn: conn} do
      user = register_user!()

      {:ok, _view, html} = conn |> log_in_user(user) |> live("/accounts")

      assert html =~ "Connected Accounts"
      assert html =~ "There is no data here. Only an anomaly."
    end

    test "lists accounts and navigates to account show", %{conn: conn} do
      user = register_user!()
      plaid_item = BankingFixtures.create_plaid_item!(user)

      account =
        BankingFixtures.create_account!(plaid_item, %{
          name: "Primary Checking",
          plaid_account_id: "acc_index_nav"
        })

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, "/accounts")

      assert html =~ "Primary Checking"
      refute html =~ "There is no data here. Only an anomaly."

      assert {:ok, _account_view, account_html} =
               view
               |> element("a[href='/accounts/#{account.id}']")
               |> render_click()
               |> follow_redirect(conn)

      assert account_html =~ "Account"
    end

    test "household scope includes other members' accounts; personal scope excludes them", %{
      conn: conn
    } do
      owner = register_user!()
      member = register_user!()
      _member = share_household!(owner, member)
      member = Ash.get!(Identity.User, member.id, authorize?: false)

      owner_item = BankingFixtures.create_plaid_item!(owner)
      member_item = BankingFixtures.create_plaid_item!(member)

      _owner_account =
        BankingFixtures.create_account!(owner_item, %{
          name: "Owner Checking",
          plaid_account_id: "acc_owner_scope"
        })

      _member_account =
        BankingFixtures.create_account!(member_item, %{
          name: "Member Checking",
          plaid_account_id: "acc_member_scope"
        })

      {:ok, view, html} = conn |> log_in_user(owner) |> live("/accounts")

      # Default scope is household when the user has a household_id.
      assert html =~ "Owner Checking"
      assert html =~ "Member Checking"

      html =
        view
        |> form("form[phx-change='change_view_scope']", %{scope: "scope_personal"})
        |> render_change()

      assert html =~ "Owner Checking"
      refute html =~ "Member Checking"

      html =
        view
        |> form("form[phx-change='change_view_scope']", %{scope: "scope_household"})
        |> render_change()

      assert html =~ "Owner Checking"
      assert html =~ "Member Checking"
    end
  end
end
