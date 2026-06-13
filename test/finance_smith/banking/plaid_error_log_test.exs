defmodule FinanceSmith.Banking.PlaidErrorLogTest do
  use ExUnit.Case, async: true

  alias FinanceSmith.Banking.PlaidErrorLog

  describe "from_reason/1" do
    test "extracts known fields from Plaid.Error" do
      reason = %Plaid.Error{
        error_type: "INVALID_INPUT",
        error_code: "INVALID_ACCESS_TOKEN",
        error_message: "provided access token is invalid",
        display_message: "Token invalid",
        request_id: "req_123",
        http_code: 400
      }

      assert %{
               error_type: "INVALID_INPUT",
               error_code: "INVALID_ACCESS_TOKEN",
               error_message: "provided access token is invalid",
               display_message: "Token invalid",
               request_id: "req_123",
               http_code: 400
             } = PlaidErrorLog.from_reason(reason)
    end

    test "redacts token-like fragments from generic reason messages" do
      reason = {:error, "public_token=public-sandbox-abc123 access_token=access-sandbox-def456"}
      normalized = PlaidErrorLog.from_reason(reason)

      assert normalized.reason_class == "tuple"
      refute String.contains?(normalized.reason_message, "public-sandbox-abc123")
      refute String.contains?(normalized.reason_message, "access-sandbox-def456")
      assert String.contains?(normalized.reason_message, "[REDACTED_TOKEN]")
    end

    test "redacts token-like fragments from Plaid.Error messages" do
      reason = %Plaid.Error{
        error_type: "INVALID_INPUT",
        error_code: "INVALID_ACCESS_TOKEN",
        error_message: "provided access_token=access-production-abc123",
        display_message: "link_token=link-sandbox-xyz789",
        request_id: "req_456",
        http_code: 400
      }

      normalized = PlaidErrorLog.from_reason(reason)

      refute String.contains?(normalized.error_message, "access-production-abc123")
      refute String.contains?(normalized.display_message, "link-sandbox-xyz789")
      assert String.contains?(normalized.error_message, "[REDACTED_TOKEN]")
      assert String.contains?(normalized.display_message, "[REDACTED_TOKEN]")
    end

    test "redacts link_token prefix patterns from generic reason messages" do
      reason = "link_token=link-production-abc123 link-sandbox-def456"
      normalized = PlaidErrorLog.from_reason(reason)

      refute String.contains?(normalized.reason_message, "link-production-abc123")
      refute String.contains?(normalized.reason_message, "link-sandbox-def456")
      assert String.contains?(normalized.reason_message, "[REDACTED_TOKEN]")
    end
  end

  describe "from_link_exit/1" do
    test "keeps only populated diagnostic fields" do
      params = %{
        "error_type" => "INSTITUTION_ERROR",
        "error_code" => "INSTITUTION_REGISTRATION_REQUIRED",
        "request_id" => "req_987",
        "institution_id" => "ins_456",
        "institution_name" => "American Express",
        "link_session_id" => "session_456",
        "link_status" => "institution_not_supported",
        "display_message" => "Contact your app provider.",
        "unused" => "ignored"
      }

      assert %{
               error_type: "INSTITUTION_ERROR",
               error_code: "INSTITUTION_REGISTRATION_REQUIRED",
               request_id: "req_987",
               institution_id: "ins_456",
               institution_name: "American Express",
               link_session_id: "session_456",
               link_status: "institution_not_supported",
               display_message: "Contact your app provider."
             } = PlaidErrorLog.from_link_exit(params)
    end

    test "redacts token-like fragments from error_message" do
      params = %{
        "error_code" => "INVALID_INPUT",
        "error_message" => "public_token=public-sandbox-abc123 link-sandbox-def456"
      }

      normalized = PlaidErrorLog.from_link_exit(params)

      refute String.contains?(normalized.error_message, "public-sandbox-abc123")
      refute String.contains?(normalized.error_message, "link-sandbox-def456")
      assert String.contains?(normalized.error_message, "[REDACTED_TOKEN]")
    end
  end
end
