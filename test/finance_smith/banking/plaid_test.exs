defmodule FinanceSmith.Banking.PlaidTest do
  @moduledoc """
  Integration tests for the Plaid service wrapper against the Plaid sandbox API.

  These tests require valid sandbox credentials in the environment:

      PLAID_CLIENT_ID=your_client_id
      PLAID_SECRET=your_sandbox_secret

  Run them explicitly with:

      mix test --only external

  They are excluded from the default test run to avoid failures in CI
  environments without Plaid credentials.
  """

  use ExUnit.Case, async: false

  @moduletag :external

  # Alias our service wrapper as PlaidService so that bare Plaid.* module
  # references (e.g. Plaid.Accounts, Plaid.Item) resolve to the plaid_elixir
  # library rather than FinanceSmith.Banking.Plaid.*.
  alias FinanceSmith.Banking.Plaid, as: PlaidService
  alias FinanceSmith.Banking.Plaid.Sandbox

  # Sandbox Chase institution — always available in the Plaid sandbox.
  @institution_id "ins_109508"
  @products ["transactions"]

  # ---------------------------------------------------------------------------
  # Shared helper
  # ---------------------------------------------------------------------------

  # Creates a fresh sandbox access token and returns %{access_token, item_id}.
  defp create_access_token do
    {:ok, %{public_token: public_token}} =
      Sandbox.create_public_token(%{
        institution_id: @institution_id,
        initial_products: @products
      })

    {:ok, result} = PlaidService.exchange_public_token(%{public_token: public_token})
    result
  end

  # ---------------------------------------------------------------------------
  # Sandbox.create_public_token/1
  # ---------------------------------------------------------------------------

  describe "Sandbox.create_public_token/1" do
    test "creates a public token for a sandbox institution" do
      assert {:ok, result} =
               Sandbox.create_public_token(%{
                 institution_id: @institution_id,
                 initial_products: @products
               })

      assert is_binary(result.public_token)
      assert String.starts_with?(result.public_token, "public-sandbox-")
      assert is_binary(result.request_id)
    end
  end

  # ---------------------------------------------------------------------------
  # exchange_public_token/1
  # ---------------------------------------------------------------------------

  describe "exchange_public_token/1" do
    test "exchanges a sandbox public token for an access token and item ID" do
      {:ok, %{public_token: public_token}} =
        Sandbox.create_public_token(%{
          institution_id: @institution_id,
          initial_products: @products
        })

      assert {:ok, result} = PlaidService.exchange_public_token(%{public_token: public_token})

      assert is_binary(result.access_token)
      assert String.starts_with?(result.access_token, "access-sandbox-")
      assert is_binary(result.item_id)
      assert is_binary(result.request_id)
    end
  end

  # ---------------------------------------------------------------------------
  # get_accounts/1
  # ---------------------------------------------------------------------------

  describe "get_accounts/1" do
    setup do
      %{access_token: access_token} = create_access_token()
      %{access_token: access_token}
    end

    test "returns a non-empty list of accounts for a valid access token", %{
      access_token: access_token
    } do
      assert {:ok, result} = PlaidService.get_accounts(%{access_token: access_token})

      assert %Plaid.Accounts{} = result
      assert length(result.accounts) > 0

      account = hd(result.accounts)
      assert is_binary(account.account_id)
      assert is_binary(account.name)
      assert is_binary(account.type)
      assert %Plaid.Accounts.Account.Balance{} = account.balances
    end

    test "returns item metadata alongside accounts", %{access_token: access_token} do
      assert {:ok, result} = PlaidService.get_accounts(%{access_token: access_token})
      assert %Plaid.Item{} = result.item
      assert is_binary(result.item.item_id)
    end
  end

  # ---------------------------------------------------------------------------
  # get_balance/1
  # ---------------------------------------------------------------------------

  describe "get_balance/1" do
    setup do
      %{access_token: access_token} = create_access_token()
      %{access_token: access_token}
    end

    test "returns accounts with current balance populated", %{access_token: access_token} do
      assert {:ok, result} = PlaidService.get_balance(%{access_token: access_token})

      assert %Plaid.Accounts{} = result
      assert length(result.accounts) > 0

      for account <- result.accounts do
        assert %Plaid.Accounts.Account.Balance{} = account.balances
        assert is_number(account.balances.current)
      end
    end

    test "accepts an account_ids filter and returns only matching accounts", %{
      access_token: access_token
    } do
      {:ok, all} = PlaidService.get_balance(%{access_token: access_token})
      target_id = hd(all.accounts).account_id

      assert {:ok, filtered} =
               PlaidService.get_balance(%{
                 access_token: access_token,
                 options: %{account_ids: [target_id]}
               })

      assert length(filtered.accounts) == 1
      assert hd(filtered.accounts).account_id == target_id
    end
  end

  # ---------------------------------------------------------------------------
  # get_item/1
  # ---------------------------------------------------------------------------

  describe "get_item/1" do
    setup do
      token_info = create_access_token()
      %{access_token: token_info.access_token, item_id: token_info.item_id}
    end

    test "returns an item whose item_id matches the exchanged token", %{
      access_token: access_token,
      item_id: item_id
    } do
      assert {:ok, result} = PlaidService.get_item(%{access_token: access_token})

      assert %Plaid.Item{} = result
      assert result.item_id == item_id
    end

    test "returns institution_id", %{access_token: access_token} do
      assert {:ok, result} = PlaidService.get_item(%{access_token: access_token})
      assert is_binary(result.institution_id)
    end

    test "returns available_products as a list", %{access_token: access_token} do
      assert {:ok, result} = PlaidService.get_item(%{access_token: access_token})
      assert is_list(result.available_products)
    end
  end

  # ---------------------------------------------------------------------------
  # get_institution/1
  # ---------------------------------------------------------------------------

  describe "get_institution/1" do
    test "looks up institution by ID and returns a non-empty name" do
      assert {:ok, result} =
               PlaidService.get_institution(%{
                 institution_id: @institution_id,
                 country_codes: ["US"]
               })

      assert %Plaid.Institutions.Institution{} = result
      # Sandbox institutions use fake names (e.g. "First Platypus Bank"),
      # not the real institution name, so we just assert a non-empty string.
      assert is_binary(result.name) and result.name != ""
      assert result.institution_id == @institution_id
    end

    test "returns a list of supported products" do
      assert {:ok, result} =
               PlaidService.get_institution(%{
                 institution_id: @institution_id,
                 country_codes: ["US"]
               })

      assert is_list(result.products)
      assert length(result.products) > 0
    end

    test "returns optional metadata (logo, url) when requested" do
      assert {:ok, result} =
               PlaidService.get_institution(%{
                 institution_id: @institution_id,
                 country_codes: ["US"],
                 options: %{include_optional_metadata: true}
               })

      # url and logo are present (may be nil for some sandbox institutions
      # but the keys exist on the struct)
      assert Map.has_key?(result, :url)
      assert Map.has_key?(result, :logo)
    end
  end

  # ---------------------------------------------------------------------------
  # remove_item/1
  # ---------------------------------------------------------------------------

  describe "remove_item/1" do
    test "removes a sandbox item and returns a request_id" do
      %{access_token: access_token} = create_access_token()

      assert {:ok, result} = PlaidService.remove_item(%{access_token: access_token})
      assert is_binary(result.request_id)
    end

    test "renders the access token invalid after removal" do
      %{access_token: access_token} = create_access_token()

      {:ok, _} = PlaidService.remove_item(%{access_token: access_token})

      assert {:error, %Plaid.Error{error_code: error_code}} =
               PlaidService.get_accounts(%{access_token: access_token})

      # Plaid returns ITEM_NOT_FOUND or NO_ACCOUNTS for a removed item.
      assert error_code in ["ITEM_NOT_FOUND", "NO_ACCOUNTS", "INVALID_ACCESS_TOKEN"]
    end
  end

  # ---------------------------------------------------------------------------
  # Sandbox.fire_webhook/1
  # ---------------------------------------------------------------------------

  describe "Sandbox.fire_webhook/1" do
    setup do
      # The item must have a webhook URL configured for fire_webhook to succeed.
      # Pass a webhook URL in the options when creating the sandbox public token.
      {:ok, %{public_token: public_token}} =
        Sandbox.create_public_token(%{
          institution_id: @institution_id,
          initial_products: @products,
          options: %{webhook: "https://www.example.com/webhook"}
        })

      {:ok, %{access_token: access_token}} =
        PlaidService.exchange_public_token(%{public_token: public_token})

      %{access_token: access_token}
    end

    test "fires a DEFAULT_UPDATE webhook and confirms delivery", %{access_token: access_token} do
      assert {:ok, result} =
               Sandbox.fire_webhook(%{
                 access_token: access_token,
                 webhook_type: "TRANSACTIONS",
                 webhook_code: "DEFAULT_UPDATE"
               })

      assert result.webhook_fired == true
      assert is_binary(result.request_id)
    end
  end

  # ---------------------------------------------------------------------------
  # sync_transactions/1
  # ---------------------------------------------------------------------------

  describe "sync_transactions/1" do
    setup do
      %{access_token: access_token} = create_access_token()
      %{access_token: access_token}
    end

    test "returns a cursor and list of added transactions on initial sync", %{
      access_token: access_token
    } do
      assert {:ok, result} = PlaidService.sync_transactions(%{access_token: access_token})

      assert %Plaid.Transactions.Sync{} = result
      assert is_binary(result.next_cursor)
      assert is_boolean(result.has_more)
      assert is_list(result.added)
    end

    test "returns an empty added list and stable cursor on a repeated sync", %{
      access_token: access_token
    } do
      # Drain all pages to get a fully up-to-date cursor.
      cursor = drain_sync(access_token, nil)

      assert {:ok, second} =
               PlaidService.sync_transactions(%{access_token: access_token, cursor: cursor})

      assert second.added == []
      assert second.modified == []
      assert second.removed == []
      assert second.has_more == false
    end
  end

  # Recursively pages through transactions/sync until has_more is false,
  # returning the final next_cursor.
  defp drain_sync(access_token, cursor) do
    params =
      if cursor,
        do: %{access_token: access_token, cursor: cursor},
        else: %{access_token: access_token}

    {:ok, result} = PlaidService.sync_transactions(params)

    if result.has_more do
      drain_sync(access_token, result.next_cursor)
    else
      result.next_cursor
    end
  end
end
