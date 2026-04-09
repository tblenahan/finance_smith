defmodule FinanceSmithWeb.AshErrorHTMLTest do
  use ExUnit.Case, async: true

  alias FinanceSmithWeb.AshErrorHTML

  describe "format_for_user/1 — InvalidArgument var interpolation" do
    test "interpolates %{min} for a password min-length violation" do
      inner =
        Ash.Error.Action.InvalidArgument.exception(
          field: :password,
          message: "length must be greater than or equal to %{min}",
          value: "secret",
          vars: [
            min: 12,
            field: :password,
            message: "length must be greater than or equal to %{min}"
          ]
        )

      outer = %Ash.Error.Invalid{errors: [inner]}

      result = AshErrorHTML.format_for_user(outer)

      assert result =~ "12"
      refute result =~ "secret"
      refute result =~ "%{min}"
    end

    test "does not leak the password value in the output" do
      my_password = "SuperSecret123!"

      inner =
        Ash.Error.Action.InvalidArgument.exception(
          field: :password,
          message: "length must be greater than or equal to %{min}",
          value: my_password,
          vars: [min: 12]
        )

      outer = %Ash.Error.Invalid{errors: [inner]}

      result = AshErrorHTML.format_for_user(outer)

      refute result =~ my_password
    end

    test "interpolates %{max} for a max-length violation on a non-password field" do
      inner =
        Ash.Error.Changes.InvalidArgument.exception(
          field: :username,
          message: "length must be less than or equal to %{max}",
          value: "averylongusername",
          vars: [max: 20]
        )

      outer = %Ash.Error.Invalid{errors: [inner]}

      result = AshErrorHTML.format_for_user(outer)

      assert result =~ "20"
      refute result =~ "averylongusername"
      refute result =~ "%{max}"
    end

    test "joins multiple nested errors with a comma" do
      inner1 =
        Ash.Error.Action.InvalidArgument.exception(
          field: :password,
          message: "must contain at least one letter",
          value: "123456789012",
          vars: []
        )

      inner2 =
        Ash.Error.Action.InvalidArgument.exception(
          field: :password,
          message: "must contain at least one number",
          value: "abcdefghijkl",
          vars: []
        )

      outer = %Ash.Error.Invalid{errors: [inner1, inner2]}

      result = AshErrorHTML.format_for_user(outer)

      assert result =~ "letter"
      assert result =~ "number"
      assert String.contains?(result, ",")
    end

    test "returns a fallback string for an empty error list" do
      outer = %Ash.Error.Invalid{errors: []}
      result = AshErrorHTML.format_for_user(outer)
      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "handles non-Invalid top-level errors gracefully" do
      result = AshErrorHTML.format_for_user(:something_unexpected)
      assert is_binary(result)
    end
  end

  describe "format_for_user/1 — message capitalisation and punctuation" do
    test "capitalises the first letter of the message" do
      inner =
        Ash.Error.Action.InvalidArgument.exception(
          field: :email,
          message: "is invalid",
          value: "notanemail",
          vars: []
        )

      result = AshErrorHTML.format_for_user(%Ash.Error.Invalid{errors: [inner]})
      assert String.first(result) == String.upcase(String.first(result))
    end

    test "appends a period if the message does not end with one" do
      inner =
        Ash.Error.Action.InvalidArgument.exception(
          field: :email,
          message: "is invalid",
          value: "notanemail",
          vars: []
        )

      result = AshErrorHTML.format_for_user(%Ash.Error.Invalid{errors: [inner]})
      assert String.ends_with?(result, ".")
    end

    test "returns fallback when the message is only whitespace" do
      inner =
        Ash.Error.Action.InvalidArgument.exception(
          field: :email,
          message: "  \n\t  ",
          value: "x",
          vars: []
        )

      result = AshErrorHTML.format_for_user(%Ash.Error.Invalid{errors: [inner]})

      assert result == "We have a... discrepancy."
    end
  end
end
