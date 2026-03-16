defmodule FinanceSmith.DataLake.B2IntegrationTest do
  @moduledoc """
  Integration tests for the B2 upload/download round-trip against a real
  Backblaze B2 bucket.

  Requires valid B2 credentials in the environment:

      B2_KEY_ID=...
      B2_APP_KEY=...
      B2_BUCKET_NAME=...

  Run explicitly with:

      mix test --only external

  Excluded from the default test run to avoid failures in CI environments
  without B2 credentials.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  alias FinanceSmith.DataLake.B2
  alias FinanceSmith.DataLake.B2.AuthServer

  @test_prefix "test_integration"

  setup do
    :ok = AuthServer.refresh()
    {:ok, auth} = AuthServer.get_auth()
    assert auth.bucket_id != nil, "B2 auth failed — check B2_KEY_ID and B2_APP_KEY"
    :ok
  end

  describe "upload and download round-trip" do
    test "uploads a JSON file and downloads it back with identical content" do
      original = %{
        "test" => true,
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "data" => [1, 2, 3]
      }

      content = Jason.encode!(original)
      file_name = "#{@test_prefix}/round_trip_#{System.unique_integer([:positive])}.json"

      assert {:ok, file_id} = B2.upload_file(file_name, content)
      assert is_binary(file_id)

      assert {:ok, downloaded} = B2.download_file(file_name)

      # Req may auto-decode JSON responses into maps
      decoded =
        if is_binary(downloaded), do: Jason.decode!(downloaded), else: downloaded

      assert decoded == original
    end

    test "upload returns a file ID" do
      content = ~s({"hello": "world"})
      file_name = "#{@test_prefix}/id_check_#{System.unique_integer([:positive])}.json"

      assert {:ok, file_id} = B2.upload_file(file_name, content)
      assert is_binary(file_id) and file_id != ""
    end

    test "download returns :error for a non-existent file" do
      assert {:error, {:b2_file_not_found, _}} =
               B2.download_file(
                 "#{@test_prefix}/does_not_exist_#{System.unique_integer([:positive])}.json"
               )
    end
  end

  describe "AuthServer" do
    test "get_auth returns valid credentials after refresh" do
      assert {:ok, auth} = AuthServer.get_auth()
      assert is_binary(auth.authorization_token)
      assert is_binary(auth.api_url)
      assert is_binary(auth.download_url)
      assert is_binary(auth.bucket_id)
      assert is_binary(auth.bucket_name)
    end

    test "refresh returns :ok" do
      assert :ok = AuthServer.refresh()
    end
  end
end
