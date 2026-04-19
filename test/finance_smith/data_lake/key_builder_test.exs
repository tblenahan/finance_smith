defmodule FinanceSmith.DataLake.KeyBuilderTest do
  use ExUnit.Case, async: true

  alias FinanceSmith.DataLake.KeyBuilder

  defp fake_plaid_item do
    %FinanceSmith.Banking.PlaidItem{
      id: "01938d00-0000-7000-8000-000000000001",
      plaid_item_id: "item_sandbox_abc123",
      access_token: "access-sandbox-xxx",
      status: :active,
      user_id: "01938d00-0000-7000-8000-000000000042",
      user: %{
        household_id: "01938d00-0000-7000-8000-000000000099"
      }
    }
  end

  describe "build/2" do
    test "produces the expected time-partitioned key format" do
      item = fake_plaid_item()
      dt = ~U[2026-03-15 14:30:45.123456Z]

      key = KeyBuilder.build(item, dt)

      assert key ==
               "plaid_sync/01938d00-0000-7000-8000-000000000099/01938d00-0000-7000-8000-000000000042/item_sandbox_abc123/2026/03/2026-03-15T14-30-45.123456Z.json"
    end

    test "zero-pads single-digit months" do
      item = fake_plaid_item()
      dt = ~U[2026-01-05 08:00:00Z]

      key = KeyBuilder.build(item, dt)
      assert key =~ "/01/"
    end

    test "replaces colons with dashes in the timestamp" do
      item = fake_plaid_item()
      dt = ~U[2026-12-31 23:59:59Z]

      key = KeyBuilder.build(item, dt)
      refute key =~ ":"
    end

    test "uses household_id from the loaded user relationship" do
      item = fake_plaid_item()
      dt = ~U[2026-06-01 00:00:00Z]

      key = KeyBuilder.build(item, dt)
      assert key =~ "01938d00-0000-7000-8000-000000000099"
    end

    test "uses plaid_item_id (Plaid's ID, not our UUID)" do
      item = fake_plaid_item()
      dt = ~U[2026-06-01 00:00:00Z]

      key = KeyBuilder.build(item, dt)
      assert key =~ "item_sandbox_abc123"
      refute key =~ item.id
    end
  end

  describe "extract_plaid_item_id/1" do
    test "extracts the Plaid item ID from a well-formed key" do
      key =
        "plaid_sync/household-uuid/user-uuid/item_sandbox_abc123/2026/03/2026-03-15T14-30-45Z.json"

      assert {:ok, "item_sandbox_abc123"} = KeyBuilder.extract_plaid_item_id(key)
    end

    test "returns :error for a key with missing segments" do
      assert :error = KeyBuilder.extract_plaid_item_id("plaid_sync/household-only")
    end

    test "returns :error for a completely unrelated path" do
      assert :error = KeyBuilder.extract_plaid_item_id("some/random/path.json")
    end

    test "returns :error for an empty string" do
      assert :error = KeyBuilder.extract_plaid_item_id("")
    end

    test "handles keys with extra path segments" do
      key = "plaid_sync/hh-id/user-id/item_id/2026/03/timestamp.json"
      assert {:ok, "item_id"} = KeyBuilder.extract_plaid_item_id(key)
    end

    test "returns :error for a legacy 3-segment key layout (pre-user_id)" do
      # Keys written before caf4653 omit the user_id segment; they must be
      # re-keyed before replay and must never silently match the parser.
      legacy = "plaid_sync/hh-id/item_sandbox_abc123/2026/03/2026-03-15T14-30-45Z.json"
      assert :error = KeyBuilder.extract_plaid_item_id(legacy)
    end

    test "returns :error when the year segment is not 4 characters long" do
      short_year = "plaid_sync/hh-id/user-id/item_id/202/03/ts.json"
      long_year = "plaid_sync/hh-id/user-id/item_id/20266/03/ts.json"
      assert :error = KeyBuilder.extract_plaid_item_id(short_year)
      assert :error = KeyBuilder.extract_plaid_item_id(long_year)
    end

    test "returns :error when the year segment is not numeric" do
      # Must reject keys where the 4-char slot happens to be alpha, to prevent a
      # legacy layout whose 4th segment is a 4-char non-numeric string from being
      # silently misparsed as "{item_id, year}".
      assert :error =
               KeyBuilder.extract_plaid_item_id(
                 "plaid_sync/hh-id/user-id/item_id/YEAR/03/ts.json"
               )

      assert :error =
               KeyBuilder.extract_plaid_item_id(
                 "plaid_sync/hh-id/user-id/item_id/20a6/03/ts.json"
               )
    end
  end
end
