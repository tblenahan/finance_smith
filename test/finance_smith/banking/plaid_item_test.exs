defmodule FinanceSmith.Banking.PlaidItemTest do
  use FinanceSmith.DataCase, async: false
  use Oban.Testing, repo: FinanceSmith.Repo

  import Mox

  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.PlaidItem
  alias FinanceSmith.Identity
  alias FinanceSmith.Test.PlaidTestHelpers

  setup :verify_on_exit!

  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp register_user!(opts \\ []) do
    email = Keyword.get(opts, :email, unique_email())
    Identity.register!(email, "ValidPassword1!", authorize?: false)
  end

  describe "create_from_public_token (via Banking.create_plaid_item_from_public_token/3)" do
    test "requires public_token argument" do
      user = register_user!()

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(PlaidItem, %{}, action: :create_from_public_token, actor: user)
    end

    test "creates item with encrypted access_token, relates user, and enqueues SyncWorker" do
      user = register_user!()
      plaid_item_id = "item_test_#{System.unique_integer([:positive])}"
      access = "access-sandbox-test-#{System.unique_integer([:positive])}"

      expect(FinanceSmith.Banking.MockPlaid, :exchange_public_token, fn %{
                                                                          public_token:
                                                                            "public-xyz"
                                                                        } ->
        {:ok, %{access_token: access, item_id: plaid_item_id, request_id: "req_1"}}
      end)

      expect(FinanceSmith.Banking.MockPlaid, :get_accounts, fn %{access_token: ^access} ->
        {:ok, PlaidTestHelpers.mock_accounts_response(account_id: "acc_item_test")}
      end)

      assert {:ok, plaid_item} =
               Banking.create_plaid_item_from_public_token(
                 "public-xyz",
                 %{institution_name: "Test Bank"},
                 actor: user
               )

      assert plaid_item.plaid_item_id == plaid_item_id
      assert plaid_item.institution_name == "Test Bank"
      assert plaid_item.status == :active
      assert plaid_item.user_id == user.id

      loaded = Ash.load!(plaid_item, :access_token, authorize?: false)
      assert loaded.access_token == access

      assert_enqueued(
        worker: FinanceSmith.DataLake.SyncWorker,
        args: %{"plaid_item_id" => plaid_item.id}
      )

      assert [_] = Ash.load!(plaid_item, :accounts, authorize?: false).accounts
    end

    test "returns Ash error when Plaid exchange fails" do
      user = register_user!()

      expect(FinanceSmith.Banking.MockPlaid, :exchange_public_token, fn _ ->
        {:error, %Plaid.Error{error_code: "INVALID_PUBLIC_TOKEN"}}
      end)

      assert {:error, %Ash.Error.Invalid{}} =
               Banking.create_plaid_item_from_public_token(
                 "bad-token",
                 %{},
                 actor: user
               )
    end

    test "returns error when plaid_item_id already exists" do
      user = register_user!()
      shared_item_id = "item_dup_#{System.unique_integer([:positive])}"
      access_a = "access-a-#{System.unique_integer([:positive])}"

      expect(FinanceSmith.Banking.MockPlaid, :exchange_public_token, 2, fn _ ->
        {:ok, %{access_token: access_a, item_id: shared_item_id, request_id: "req_dup"}}
      end)

      expect(FinanceSmith.Banking.MockPlaid, :get_accounts, fn %{access_token: ^access_a} ->
        {:ok, PlaidTestHelpers.mock_accounts_response()}
      end)

      assert {:ok, _} =
               Banking.create_plaid_item_from_public_token("pub-one", %{}, actor: user)

      assert {:error, %Ash.Error.Invalid{}} =
               Banking.create_plaid_item_from_public_token("pub-two", %{}, actor: user)
    end
  end
end
