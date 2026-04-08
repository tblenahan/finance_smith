defmodule FinanceSmith.Integration.PlaidSandboxTest do
  @moduledoc """
  End-to-end Plaid sandbox flow: sandbox public token, Ash `create_from_public_token`,
  AshCloak encryption, and `SyncWorker` transaction sync.

  Requires `PLAID_CLIENT_ID` and `SANDBOX_PLAID_SECRET` (see `.env.example`).

  Excluded from the default suite. Run:

      mix test test/finance_smith/integration/plaid_sandbox_test.exs --include integration

  `Application.put_env(:finance_smith, :plaid_client, ...)` is toggled only while
  credentials are present; prefer running this file alone when using
  `--include integration` alongside other tests to avoid cross-test races on
  `:plaid_client`.
  """

  use FinanceSmith.DataCase, async: false
  use Oban.Testing, repo: FinanceSmith.Repo

  alias FinanceSmith.Banking
  alias FinanceSmith.Banking.Plaid.Sandbox
  alias FinanceSmith.Banking.PlaidItem
  alias FinanceSmith.DataLake.SyncWorker
  alias FinanceSmith.Identity

  @moduletag :integration

  @institution_id "ins_109508"
  @products ["transactions"]

  defp sandbox_configured? do
    id = System.get_env("PLAID_CLIENT_ID")
    secret = System.get_env("SANDBOX_PLAID_SECRET")
    is_binary(id) and id != "" and is_binary(secret) and secret != ""
  end

  setup do
    if sandbox_configured?() do
      Application.put_env(:finance_smith, :plaid_client, FinanceSmith.Banking.Plaid)

      on_exit(fn ->
        Application.put_env(:finance_smith, :plaid_client, FinanceSmith.Banking.MockPlaid)
      end)
    end

    :ok
  end

  defp register_user! do
    email = "integration-#{System.unique_integer([:positive])}@example.com"
    Identity.register!(email, "ValidPassword1!", authorize?: false)
  end

  test "sandbox public token through Ash create, encryption, and sync" do
    unless sandbox_configured?() do
      IO.warn(
        "[integration] Skipping: set PLAID_CLIENT_ID and SANDBOX_PLAID_SECRET to run this test.",
        []
      )

      assert true
    else
      user = register_user!()

      assert {:ok, %{public_token: public_token}} =
               Sandbox.create_public_token(%{
                 institution_id: @institution_id,
                 initial_products: @products
               })

      assert is_binary(public_token)

      assert {:ok, plaid_item} =
               Banking.create_plaid_item_from_public_token(
                 public_token,
                 %{institution_name: "Sandbox"},
                 actor: user
               )

      assert is_binary(plaid_item.plaid_item_id) and plaid_item.plaid_item_id != ""
      assert plaid_item.status == :active
      assert plaid_item.user_id == user.id

      loaded = Ash.load!(plaid_item, :access_token, authorize?: false)
      assert is_binary(loaded.access_token) and byte_size(loaded.access_token) > 0

      {:ok, uuid_bytes} = Ecto.UUID.dump(plaid_item.id)

      enc =
        Repo.one!(
          from(p in "plaid_items",
            where: p.id == ^uuid_bytes,
            select: p.encrypted_access_token
          )
        )

      assert is_binary(enc) and byte_size(enc) > 0
      assert byte_size(enc) > byte_size(loaded.access_token)

      assert_enqueued(worker: SyncWorker, args: %{"plaid_item_id" => plaid_item.id})

      # Use perform_job(worker, args) so Oban builds a job with attempted_at set.
      # Jobs from all_enqueued can have attempted_at nil and break Executor.record_finished/1.
      Oban.Testing.with_testing_mode(:inline, fn ->
        assert :ok = perform_job(SyncWorker, %{"plaid_item_id" => plaid_item.id})
      end)

      refreshed =
        PlaidItem
        |> Ash.get!(plaid_item.id, load: [:accounts], authorize?: false)

      assert refreshed.status == :active
      assert is_list(refreshed.accounts)
      # Sandbox first sync often returns no added rows; empty cursor is stored as nil.
      assert refreshed.next_cursor in [nil, ""]
    end
  end
end
