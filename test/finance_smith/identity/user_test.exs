defmodule FinanceSmith.Identity.UserTest do
  use FinanceSmith.DataCase, async: true

  alias FinanceSmith.Identity

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user!(opts \\ []) do
    email = Keyword.get(opts, :email, unique_email())
    password = Keyword.get(opts, :password, "ValidPassword1!")
    Identity.register!(email, password, authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  describe "register/3" do
    test "creates a user with a hashed password and linked household" do
      email = unique_email()
      assert {:ok, user} = Identity.register(email, "SecurePass99!", authorize?: false)

      assert user.email == email
      assert is_binary(user.password_hash)
      refute user.password_hash == "SecurePass99!"
      assert Bcrypt.verify_pass("SecurePass99!", user.password_hash)

      loaded = Ash.load!(user, :household, authorize?: false)
      assert loaded.household.name == "My Household"
    end

    test "accepts a custom household name" do
      assert {:ok, user} =
               Identity.register(
                 unique_email(),
                 "SecurePass99!",
                 %{household_name: "Smith Estate"},
                 authorize?: false
               )

      loaded = Ash.load!(user, :household, authorize?: false)
      assert loaded.household.name == "Smith Estate"
    end

    test "rejects a duplicate email" do
      email = unique_email()
      register_user!(email: email)

      assert {:error, %Ash.Error.Invalid{}} =
               Identity.register(email, "AnotherPass1!", authorize?: false)
    end
  end

  # ---------------------------------------------------------------------------
  # Sign-in / verify_sign_in
  # ---------------------------------------------------------------------------

  describe "verify_sign_in/2" do
    setup do
      email = unique_email()
      password = "CorrectHorseBattery1!"
      register_user!(email: email, password: password)
      %{email: email, password: password}
    end

    test "returns {:ok, user} for correct credentials", %{email: email, password: password} do
      assert {:ok, user} = Identity.verify_sign_in(email, password)
      assert user.email == email
    end

    test "returns {:error, :invalid_credentials} for wrong password", %{email: email} do
      assert {:error, :invalid_credentials} = Identity.verify_sign_in(email, "WrongPassword1!")
    end

    test "returns {:error, :invalid_credentials} for non-existent email" do
      assert {:error, :invalid_credentials} =
               Identity.verify_sign_in("ghost@example.com", "AnyPass1!")
    end
  end

  # ---------------------------------------------------------------------------
  # MFA secret generation
  # ---------------------------------------------------------------------------

  describe "generate_mfa_secret/2" do
    test "sets a Base32 mfa_secret and resets mfa_enabled to false" do
      user = register_user!()
      assert {:ok, updated} = Identity.generate_mfa_secret(user, authorize?: false)

      # Load sensitive fields
      loaded = Ash.load!(updated, [:mfa_secret, :mfa_enabled], authorize?: false)
      assert is_binary(loaded.mfa_secret)
      assert String.length(loaded.mfa_secret) > 0
      # Must be valid Base32
      assert {:ok, _} = Base.decode32(loaded.mfa_secret, padding: false)
      assert loaded.mfa_enabled == false
    end

    test "calling again replaces the previous secret" do
      user = register_user!()
      {:ok, first} = Identity.generate_mfa_secret(user, authorize?: false)
      first_loaded = Ash.load!(first, :mfa_secret, authorize?: false)

      {:ok, second} = Identity.generate_mfa_secret(first, authorize?: false)
      second_loaded = Ash.load!(second, :mfa_secret, authorize?: false)

      refute first_loaded.mfa_secret == second_loaded.mfa_secret
    end
  end

  # ---------------------------------------------------------------------------
  # Enable MFA
  # ---------------------------------------------------------------------------

  describe "enable_mfa/3" do
    setup do
      user = register_user!()
      {:ok, with_secret} = Identity.generate_mfa_secret(user, authorize?: false)
      with_secret = Ash.load!(with_secret, :mfa_secret, authorize?: false)
      raw_secret = Base.decode32!(with_secret.mfa_secret, padding: false)
      %{user: with_secret, raw_secret: raw_secret}
    end

    test "sets mfa_enabled and populates 10 recovery codes on valid TOTP code", %{
      user: user,
      raw_secret: raw_secret
    } do
      valid_code = NimbleTOTP.verification_code(raw_secret)

      assert {:ok, enabled_user} =
               Identity.enable_mfa(user, valid_code, authorize?: false)

      loaded = Ash.load!(enabled_user, [:mfa_enabled, :recovery_codes], authorize?: false)
      assert loaded.mfa_enabled == true
      assert is_binary(loaded.recovery_codes)

      codes = Jason.decode!(loaded.recovery_codes)
      assert is_list(codes)
      assert length(codes) == 10
      Enum.each(codes, &assert(is_binary(&1)))
    end

    test "returns an error and leaves mfa_enabled false on invalid code", %{user: user} do
      assert {:error, %Ash.Error.Invalid{}} =
               Identity.enable_mfa(user, "000000", authorize?: false)

      loaded = Ash.load!(user, :mfa_enabled, authorize?: false)
      assert loaded.mfa_enabled == false
    end

    test "returns an error when no secret is set" do
      user = register_user!()
      # The change module loads mfa_secret internally; a freshly registered user
      # has no secret set, so it returns an appropriate error.
      assert {:error, %Ash.Error.Invalid{}} =
               Identity.enable_mfa(user, "123456", authorize?: false)
    end

    test "recovery_codes calculation is immediately loadable and JSON-decodable after the action",
         %{user: user, raw_secret: raw_secret} do
      # Regression: MfaSetupLive previously crashed with
      # "ArgumentError: not an iodata term" because Jason.decode! was called on
      # #Ash.NotLoaded<:calculation> — the calculation must be explicitly loaded
      # on the action result before access.
      valid_code = NimbleTOTP.verification_code(raw_secret)
      {:ok, enabled_user} = Identity.enable_mfa(user, valid_code, authorize?: false)

      loaded = Ash.load!(enabled_user, :recovery_codes, authorize?: false)
      assert is_binary(loaded.recovery_codes)

      codes = Jason.decode!(loaded.recovery_codes)
      assert is_list(codes)
      assert length(codes) == 10
      assert Enum.all?(codes, &is_binary/1)
    end

    test "mfa_enabled is persisted to the database (not just in-memory)", %{
      user: user,
      raw_secret: raw_secret
    } do
      # Regression: force_change_attribute must be used inside before_action or
      # the attribute change is silently dropped post-validation.
      valid_code = NimbleTOTP.verification_code(raw_secret)
      {:ok, _} = Identity.enable_mfa(user, valid_code, authorize?: false)

      refreshed = Ash.get!(FinanceSmith.Identity.User, user.id, authorize?: false)
      assert refreshed.mfa_enabled == true
    end
  end

  # ---------------------------------------------------------------------------
  # Verify MFA login
  # ---------------------------------------------------------------------------

  describe "verify_mfa_login/3" do
    setup do
      user = register_user!()
      {:ok, with_secret} = Identity.generate_mfa_secret(user, authorize?: false)
      with_secret = Ash.load!(with_secret, :mfa_secret, authorize?: false)
      raw_secret = Base.decode32!(with_secret.mfa_secret, padding: false)
      valid_code = NimbleTOTP.verification_code(raw_secret)
      {:ok, mfa_user} = Identity.enable_mfa(with_secret, valid_code, authorize?: false)
      mfa_user = Ash.load!(mfa_user, [:mfa_secret, :recovery_codes], authorize?: false)
      raw_secret = Base.decode32!(mfa_user.mfa_secret, padding: false)
      %{user: mfa_user, raw_secret: raw_secret}
    end

    test "succeeds with a valid TOTP code", %{user: user, raw_secret: raw_secret} do
      code = NimbleTOTP.verification_code(raw_secret)
      assert {:ok, _} = Identity.verify_mfa_login(user, code, authorize?: false)
    end

    test "succeeds with a valid recovery code and consumes it", %{user: user} do
      codes = Jason.decode!(user.recovery_codes)
      recovery_code = hd(codes)

      assert {:ok, updated} =
               Identity.verify_mfa_login(user, recovery_code, authorize?: false)

      updated = Ash.load!(updated, :recovery_codes, authorize?: false)
      remaining = Jason.decode!(updated.recovery_codes)
      assert length(remaining) == 9
      refute recovery_code in remaining
    end

    test "returns an error for an invalid code", %{user: user} do
      assert {:error, %Ash.Error.Invalid{}} =
               Identity.verify_mfa_login(user, "INVALID", authorize?: false)
    end
  end
end
