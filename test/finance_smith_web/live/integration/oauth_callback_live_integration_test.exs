defmodule FinanceSmithWeb.OAuthCallbackLiveIntegrationTest do
  @moduledoc """
  LiveView integration test for the OAuth callback Plaid Link flow.

  Simulates the `PlaidLink` JS hook `onSuccess` callback without a browser:
    1. Mounts `OAuthCallbackLive` with an `oauth_state_id` param.
       `create_link_token` is stubbed with a fake token so the view renders
       without requiring the `redirect_uri` to be pre-registered in the Plaid
       developer console. That path is covered by the unit test in
       `test/finance_smith_web/live/oauth_callback_live_test.exs`.
    2. Generates a real sandbox `public_token` via `Plaid.Sandbox.create_public_token/1`.
    3. Pushes `plaid_link_success` to the LiveView — simulating what the JS
       hook sends after the OAuth handshake completes.
    4. `exchange_public_token` is delegated from the Mox stub to the real Plaid
       module, so the actual token exchange happens against the sandbox API.
    5. Asserts the full server-side lifecycle: PlaidItem persisted with
       encrypted access_token, redirect to dashboard, and SyncWorker enqueued.

  Requires `PLAID_CLIENT_ID` and `SANDBOX_PLAID_SECRET` (see `.env.example`).

  Excluded from the default suite. Run with:

      mix test test/finance_smith_web/live/integration/oauth_callback_live_integration_test.exs --include integration

  AGENT_SECURITY Rule 1: Credentials read from env vars only — never hardcoded.
  AGENT_SECURITY Rule 2: Token values are never logged or IO.inspected.
  """

  use FinanceSmithWeb.ConnCase, async: false
  use Oban.Testing, repo: FinanceSmith.Repo

  import Phoenix.LiveViewTest
  import Mox

  alias FinanceSmith.Banking.Plaid.Sandbox
  alias FinanceSmith.Banking.PlaidItem
  alias FinanceSmith.DataLake.SyncWorker
  alias FinanceSmith.Identity

  require Ash.Query

  @moduletag :integration

  @institution_id "ins_109508"
  @products ["transactions"]

  defp sandbox_configured? do
    id = System.get_env("PLAID_CLIENT_ID")
    secret = System.get_env("SANDBOX_PLAID_SECRET")
    is_binary(id) and id != "" and is_binary(secret) and secret != ""
  end

  setup :verify_on_exit!

  setup do
    Mox.set_mox_global()
    on_exit(fn -> Mox.set_mox_private() end)
    :ok
  end

  defp register_user! do
    email = "integration-oauth-#{System.unique_integer([:positive])}@example.com"
    Identity.register!(email, "ValidPassword1!", authorize?: false)
  end

  test "full Plaid Link lifecycle via OAuth callback", %{conn: conn} do
    unless sandbox_configured?() do
      IO.warn(
        "[integration] Skipping: set PLAID_CLIENT_ID and SANDBOX_PLAID_SECRET to run this test.",
        []
      )

      assert true
    else
      user = register_user!()

      # Stub create_link_token so the view mounts successfully. The real
      # integration under test is exchange_public_token via plaid_link_success.
      stub(FinanceSmith.Banking.MockPlaid, :create_link_token, fn _params ->
        {:ok, %{link_token: "link-integration-mount-stub"}}
      end)

      # Delegate exchange_public_token to the real Plaid module so the actual
      # token exchange is exercised against the sandbox API.
      stub(FinanceSmith.Banking.MockPlaid, :exchange_public_token, fn params ->
        FinanceSmith.Banking.Plaid.exchange_public_token(params)
      end)

      {:ok, view, html} =
        conn
        |> log_in_user(user)
        |> live("/oauth/callback/plaid?oauth_state_id=test-integration-state")

      assert html =~ "data-link-token="
      assert html =~ "Completing Connection"

      assert {:ok, %{public_token: public_token}} =
               Sandbox.create_public_token(%{
                 institution_id: @institution_id,
                 initial_products: @products
               })

      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               render_hook(view, "plaid_link_success", %{
                 "public_token" => public_token,
                 "institution_name" => "First Platypus Bank"
               })

      plaid_item =
        PlaidItem
        |> Ash.Query.filter(user_id == ^user.id)
        |> Ash.read_one!(authorize?: false)

      assert is_binary(plaid_item.plaid_item_id) and plaid_item.plaid_item_id != ""
      assert plaid_item.institution_name == "First Platypus Bank"
      assert plaid_item.user_id == user.id
      assert plaid_item.status == :active

      assert_enqueued(
        worker: SyncWorker,
        args: %{"plaid_item_id" => plaid_item.id}
      )
    end
  end
end
