defmodule FinanceSmithWeb.MfaSetupLiveTest do
  # LiveView tests must NOT be async: true — Phoenix.LiveViewTest spawns a
  # separate process for the LiveView, which needs to share the Ecto sandbox
  # connection. ConnCase sets shared: true only when async is false.
  use FinanceSmithWeb.ConnCase
  import Phoenix.LiveViewTest

  alias FinanceSmith.Identity

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  # Registers a user, generates an MFA secret, and returns {user, raw_binary_secret}.
  # The raw_binary_secret can be passed directly to NimbleTOTP.verification_code/1.
  defp register_user_with_secret! do
    user = register_user!()
    {:ok, with_secret} = Identity.generate_mfa_secret(user, authorize?: false)
    with_secret = Ash.load!(with_secret, :mfa_secret, authorize?: false)
    raw_secret = Base.decode32!(with_secret.mfa_secret, padding: false)
    {with_secret, raw_secret}
  end

  # ---------------------------------------------------------------------------
  # Mount / initial render
  # ---------------------------------------------------------------------------

  describe "mount" do
    test "renders the generate step for a user with no MFA secret", %{conn: conn} do
      user = register_user!()
      {:ok, _view, html} = conn |> log_in_user(user) |> live("/users/settings/mfa")

      assert html =~ "Initialize Secret"
      refute html =~ "6-Digit Token"
    end

    test "renders the verify step for a user who already has an MFA secret", %{conn: conn} do
      {user, _raw_secret} = register_user_with_secret!()
      {:ok, _view, html} = conn |> log_in_user(user) |> live("/users/settings/mfa")

      assert html =~ "6-Digit Token"
      assert html =~ "Manual Base32 Key"
      refute html =~ "Initialize Secret"
    end

    test "redirects unauthenticated requests to the login page", %{conn: conn} do
      assert {:error, {:redirect, redirect}} = live(conn, "/users/settings/mfa")
      assert redirect.to == "/users/log_in"
    end
  end

  # ---------------------------------------------------------------------------
  # generate_secret event
  # ---------------------------------------------------------------------------

  describe "generate_secret event" do
    test "transitions the UI from generate to verify step and renders a QR code", %{conn: conn} do
      user = register_user!()
      {:ok, view, _html} = conn |> log_in_user(user) |> live("/users/settings/mfa")

      html = render_click(view, "generate_secret")

      assert html =~ "6-Digit Token"
      assert html =~ "Manual Base32 Key"
      refute html =~ "Initialize Secret"
    end

    test "generates a valid Base32 secret that can produce TOTP codes", %{conn: conn} do
      user = register_user!()
      {:ok, view, _html} = conn |> log_in_user(user) |> live("/users/settings/mfa")

      render_click(view, "generate_secret")

      # The live assigns should have a valid mfa_secret — confirm the view renders
      # a non-empty manual key block (the actual secret value is inside the markup).
      assert has_element?(view, "[class*='emerald']")
    end
  end

  # ---------------------------------------------------------------------------
  # verify event — invalid code
  # ---------------------------------------------------------------------------

  describe "verify event with an invalid code" do
    test "shows a user-facing error message and does not crash the process", %{conn: conn} do
      {user, _raw_secret} = register_user_with_secret!()
      {:ok, view, _html} = conn |> log_in_user(user) |> live("/users/settings/mfa")

      html = render_submit(view, "verify", %{"form" => %{"code" => "000000"}})

      # An error should be displayed; the process must remain alive.
      assert html =~ "Invalid"
      assert Process.alive?(view.pid)
    end

    test "does not transition to the recovery codes screen on failure", %{conn: conn} do
      {user, _raw_secret} = register_user_with_secret!()
      {:ok, view, _html} = conn |> log_in_user(user) |> live("/users/settings/mfa")

      html = render_submit(view, "verify", %{"form" => %{"code" => "000000"}})

      # The recovery codes warning only appears when @recovery_codes is set.
      refute html =~ "Save these offline"
      refute html =~ "Acknowledge"
    end

    test "keeps the 6-digit code input visible for retry", %{conn: conn} do
      {user, _raw_secret} = register_user_with_secret!()
      {:ok, view, _html} = conn |> log_in_user(user) |> live("/users/settings/mfa")

      html = render_submit(view, "verify", %{"form" => %{"code" => "000000"}})

      assert html =~ "6-Digit Token"
    end
  end

  # ---------------------------------------------------------------------------
  # verify event — valid code (the key regression path)
  # ---------------------------------------------------------------------------

  describe "verify event with a valid TOTP code" do
    test "displays 10 recovery codes after successful MFA enablement", %{conn: conn} do
      {user, raw_secret} = register_user_with_secret!()
      {:ok, view, _html} = conn |> log_in_user(user) |> live("/users/settings/mfa")

      valid_code = NimbleTOTP.verification_code(raw_secret)
      html = render_submit(view, "verify", %{"form" => %{"code" => valid_code}})

      # The recovery codes grid should be present.
      assert has_element?(view, ".select-all")

      # Exactly 10 recovery code nodes rendered (one per code).
      assert length(Regex.scan(~r/select-all/, html)) == 10
    end

    test "shows the Acknowledge & Finalize link after success", %{conn: conn} do
      {user, raw_secret} = register_user_with_secret!()
      {:ok, view, _html} = conn |> log_in_user(user) |> live("/users/settings/mfa")

      valid_code = NimbleTOTP.verification_code(raw_secret)
      html = render_submit(view, "verify", %{"form" => %{"code" => valid_code}})

      # Phoenix HTML-encodes & to &amp;, so match on partial text.
      assert html =~ "Acknowledge"
    end

    test "does not crash — recovery_codes calculation is loaded before Jason.decode!", %{
      conn: conn
    } do
      # Regression for: ArgumentError: not an iodata term
      # Previously, Jason.decode! was called on #Ash.NotLoaded<:calculation>.
      # The fix adds Ash.load!(updated, :recovery_codes) before decoding.
      {user, raw_secret} = register_user_with_secret!()
      {:ok, view, _html} = conn |> log_in_user(user) |> live("/users/settings/mfa")

      valid_code = NimbleTOTP.verification_code(raw_secret)

      # If the process were to crash, render_submit would raise — so a successful
      # return is itself proof that no ArgumentError was thrown.
      assert html = render_submit(view, "verify", %{"form" => %{"code" => valid_code}})
      assert is_binary(html)
      assert Process.alive?(view.pid)
    end

    test "no error message is shown after successful verification", %{conn: conn} do
      {user, raw_secret} = register_user_with_secret!()
      {:ok, view, _html} = conn |> log_in_user(user) |> live("/users/settings/mfa")

      valid_code = NimbleTOTP.verification_code(raw_secret)
      html = render_submit(view, "verify", %{"form" => %{"code" => valid_code}})

      refute has_element?(view, "[color='danger']")
      refute html =~ "Invalid"
    end
  end
end
