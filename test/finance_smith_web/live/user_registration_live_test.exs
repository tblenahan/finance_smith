defmodule FinanceSmithWeb.UserRegistrationLiveTest do
  # LiveView tests must NOT be async: true — Phoenix.LiveViewTest spawns a
  # separate process for the LiveView, which needs to share the Ecto sandbox
  # connection. ConnCase sets shared: true only when async is false.
  use FinanceSmithWeb.ConnCase

  import Phoenix.LiveViewTest

  require Ash.Query

  alias FinanceSmith.Identity

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_existing!(password \\ "CorrectHorseBattery1!") do
    email = unique_email()
    user = Identity.register!(email, password, authorize?: false)
    loaded = Ash.load!(user, :household, authorize?: false)
    %{user: loaded, email: email, password: password}
  end

  # ---------------------------------------------------------------------------
  # Mount / initial render
  # ---------------------------------------------------------------------------

  describe "mount" do
    test "renders the Create/Join toggle defaulting to create mode", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/users/register")

      assert html =~ "Create Household"
      assert html =~ "Join Existing"
      assert html =~ "Initialize Identity"
    end

    test "create mode shows household_name input and hides existing-member fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/users/register")

      assert has_element?(view, "input[name='user[household_name]']")
      refute has_element?(view, "input[name='user[existing_member_email]']")
      refute has_element?(view, "input[name='user[existing_member_password]']")
    end
  end

  # ---------------------------------------------------------------------------
  # Mode toggle
  # ---------------------------------------------------------------------------

  describe "set_mode event" do
    test "switching to join mode reveals existing-member fields and hides household_name", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/users/register")

      render_click(view, "set_mode", %{"mode" => "join"})

      assert has_element?(view, "input[name='user[existing_member_email]']")
      assert has_element?(view, "input[name='user[existing_member_password]']")
      refute has_element?(view, "input[name='user[household_name]']")
    end

    test "switching back to create mode restores household_name and hides existing-member fields",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/users/register")

      render_click(view, "set_mode", %{"mode" => "join"})
      render_click(view, "set_mode", %{"mode" => "create"})

      assert has_element?(view, "input[name='user[household_name]']")
      refute has_element?(view, "input[name='user[existing_member_email]']")
    end

    test "switching mode clears password fields from the rendered HTML", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/users/register")

      # Type a password via validate
      render_change(view, "validate", %{"user" => %{"password" => "typed1234!"}})

      # Switch mode — the assign should be cleared
      html = render_click(view, "set_mode", %{"mode" => "join"})

      refute html =~ "typed1234!"
    end
  end

  # ---------------------------------------------------------------------------
  # Create-mode submission
  # ---------------------------------------------------------------------------

  describe "create-mode submit" do
    test "creates a user and redirects to the login page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/users/register")
      email = unique_email()

      assert {:error, {:redirect, %{to: "/users/log_in"}}} =
               view
               |> form("#register_form",
                 user: %{email: email, password: "SecurePass99!"}
               )
               |> render_submit()

      # Verify the user row was persisted
      assert [user] =
               FinanceSmith.Identity.User
               |> Ash.Query.filter(email == ^email)
               |> Ash.read!(authorize?: false)

      assert user.email == email
    end

    test "creates a user with the provided household name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/users/register")
      email = unique_email()

      {:error, {:redirect, %{to: "/users/log_in"}}} =
        view
        |> form("#register_form",
          user: %{email: email, password: "SecurePass99!", household_name: "Smith Estate"}
        )
        |> render_submit()

      [user] =
        FinanceSmith.Identity.User
        |> Ash.Query.filter(email == ^email)
        |> Ash.read!(authorize?: false)

      loaded = Ash.load!(user, :household, authorize?: false)
      assert loaded.household.name == "Smith Estate"
    end

    test "uses 'My Household' when household_name is left blank", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/users/register")
      email = unique_email()

      {:error, {:redirect, _}} =
        view
        |> form("#register_form",
          user: %{email: email, password: "SecurePass99!", household_name: ""}
        )
        |> render_submit()

      [user] =
        FinanceSmith.Identity.User
        |> Ash.Query.filter(email == ^email)
        |> Ash.read!(authorize?: false)

      loaded = Ash.load!(user, :household, authorize?: false)
      assert loaded.household.name == "My Household"
    end

    test "shows an error and does not redirect on weak password", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/users/register")

      html =
        view
        |> form("#register_form", user: %{email: unique_email(), password: "weak"})
        |> render_submit()

      assert html =~ ~r/error|invalid|password/i
      assert Process.alive?(view.pid)
    end

    test "shows an error on duplicate email", %{conn: conn} do
      existing = Identity.register!(unique_email(), "SecurePass99!", authorize?: false)
      {:ok, view, _html} = live(conn, "/users/register")

      html =
        view
        |> form("#register_form", user: %{email: existing.email, password: "SecurePass99!"})
        |> render_submit()

      assert html =~ ~r/error|already|taken|unique/i
      assert Process.alive?(view.pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Join-mode submission
  # ---------------------------------------------------------------------------

  describe "join-mode submit" do
    test "new user joins the existing member's household and redirects to login", %{conn: conn} do
      %{user: existing, email: existing_email, password: existing_password} = register_existing!()
      new_email = unique_email()

      {:ok, view, _html} = live(conn, "/users/register")
      render_click(view, "set_mode", %{"mode" => "join"})

      assert {:error, {:redirect, %{to: "/users/log_in"}}} =
               view
               |> form("#register_form",
                 user: %{
                   email: new_email,
                   password: "NewMember9!A",
                   existing_member_email: existing_email,
                   existing_member_password: existing_password
                 }
               )
               |> render_submit()

      [new_user] =
        FinanceSmith.Identity.User
        |> Ash.Query.filter(email == ^new_email)
        |> Ash.read!(authorize?: false)

      assert new_user.household_id == existing.household_id
    end

    test "shows 'Invalid credentials' and clears passwords on wrong existing-member password",
         %{conn: conn} do
      %{email: existing_email} = register_existing!()

      {:ok, view, _html} = live(conn, "/users/register")
      render_click(view, "set_mode", %{"mode" => "join"})

      html =
        view
        |> form("#register_form",
          user: %{
            email: unique_email(),
            password: "NewMember9!A",
            existing_member_email: existing_email,
            existing_member_password: "WrongPass1!"
          }
        )
        |> render_submit()

      assert html =~ "Invalid credentials"
      # Password fields must not contain the submitted plaintext
      refute html =~ "NewMember9!A"
      refute html =~ "WrongPass1!"
      assert Process.alive?(view.pid)
    end

    test "shows an error for an unknown existing-member email", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/users/register")
      render_click(view, "set_mode", %{"mode" => "join"})

      html =
        view
        |> form("#register_form",
          user: %{
            email: unique_email(),
            password: "NewMember9!A",
            existing_member_email: "ghost-#{System.unique_integer([:positive])}@example.com",
            existing_member_password: "AnyPassword1!"
          }
        )
        |> render_submit()

      assert html =~ "Invalid credentials"
      assert Process.alive?(view.pid)
    end

    test "no redirect on error — the form remains interactive", %{conn: conn} do
      %{email: existing_email} = register_existing!()

      {:ok, view, _html} = live(conn, "/users/register")
      render_click(view, "set_mode", %{"mode" => "join"})

      # This should NOT raise {:error, {:redirect, _}}
      html =
        view
        |> form("#register_form",
          user: %{
            email: unique_email(),
            password: "NewMember9!A",
            existing_member_email: existing_email,
            existing_member_password: "WrongPass1!"
          }
        )
        |> render_submit()

      assert is_binary(html)
      assert has_element?(view, "button[type='submit']")
    end
  end
end
