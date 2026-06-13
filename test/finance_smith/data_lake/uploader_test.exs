defmodule FinanceSmith.DataLake.UploaderTest do
  use ExUnit.Case, async: true

  alias FinanceSmith.Banking.Plaid.SyncTransactionsResponse
  alias FinanceSmith.DataLake.Uploader

  describe "to_sync_payload/1" do
    test "converts a struct to a string-keyed map" do
      input = %SyncTransactionsResponse{
        added: [],
        modified: [],
        removed: [],
        next_cursor: "cursor_abc",
        has_more: false,
        request_id: "req_123"
      }

      result = Uploader.to_sync_payload(input)

      assert is_map(result)
      assert result["next_cursor"] == "cursor_abc"
      assert result["has_more"] == false
      assert result["added"] == []
      assert result["modified"] == []
      assert result["removed"] == []
    end

    test "converts Date values to ISO 8601 strings" do
      input = %{date: ~D[2026-03-15]}
      result = Uploader.to_sync_payload(input)
      assert result["date"] == "2026-03-15"
    end

    test "converts DateTime values to ISO 8601 strings" do
      input = %{timestamp: ~U[2026-03-15 14:30:00Z]}
      result = Uploader.to_sync_payload(input)
      assert result["timestamp"] == "2026-03-15T14:30:00Z"
    end

    test "converts atom values to strings" do
      input = %{status: :active}
      result = Uploader.to_sync_payload(input)
      assert result["status"] == "active"
    end

    test "preserves nil and boolean values" do
      input = %{a: nil, b: true, c: false}
      result = Uploader.to_sync_payload(input)
      assert result["a"] == nil
      assert result["b"] == true
      assert result["c"] == false
    end

    test "recursively converts nested structs" do
      input = %{
        outer: %{inner_list: [%{value: 42}], inner_atom: :ok}
      }

      result = Uploader.to_sync_payload(input)
      assert result["outer"]["inner_list"] == [%{"value" => 42}]
      assert result["outer"]["inner_atom"] == "ok"
    end

    test "handles lists of mixed types" do
      input = %{items: [1, "two", :three, nil, true]}
      result = Uploader.to_sync_payload(input)
      assert result["items"] == [1, "two", "three", nil, true]
    end

    test "includes accounts when present on sync response" do
      input = %SyncTransactionsResponse{
        added: [],
        modified: [],
        removed: [],
        next_cursor: "cursor_abc",
        has_more: false,
        request_id: "req_123",
        accounts: [
          %Plaid.Accounts.Account{
            account_id: "acc_123",
            balances: %Plaid.Accounts.Account.Balance{
              current: 1500.0,
              available: nil,
              limit: nil
            }
          }
        ]
      }

      result = Uploader.to_sync_payload(input)

      assert [%{"account_id" => "acc_123", "balances" => balances}] = result["accounts"]
      assert balances["current"] == 1500.0
    end

    test "output is JSON-encodable" do
      input = %SyncTransactionsResponse{
        added: [],
        modified: [],
        removed: [],
        next_cursor: "cursor_abc",
        has_more: false,
        request_id: "req_123"
      }

      payload = Uploader.to_sync_payload(input)
      assert {:ok, _json} = Jason.encode(payload)
    end
  end
end
