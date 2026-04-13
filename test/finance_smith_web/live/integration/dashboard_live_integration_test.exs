defmodule FinanceSmithWeb.DashboardLiveIntegrationTest do
  @moduledoc """
  LiveView integration test for the dashboard Plaid Link flow.

  Simulates the `PlaidLink` JS hook `onSuccess` callback without a browser:
    1. Mounts the dashboard as an authenticated user.
    2. Generates a real sandbox `public_token` via the Plaid Sandbox API.
    3. Pushes `plaid_link_success` to the LiveView — simulating what the hook
       sends after Plaid Link completes inline.
    4. Asserts the full server-side lifecycle: `exchange_public_token` (real
       Plaid API), PlaidItem persisted with encrypted access_token, redirect,
       and SyncWorker enqueued.

  Note: The `request_link_token` → `push_event("open_plaid_link")` path is NOT
  tested here. That path requires `redirect_uri` pre-registration in the Plaid
  developer console (for OAuth-capable institutions). It is already covered by
  the Mox-based unit test in `test/finance_smith_web/live/dashboard_live_test.exs`.

  Requires `PLAID_CLIENT_ID` and `SANDBOX_PLAID_SECRET` (see `.env.example`).

  Excluded from the default suite. Run with:

      mix test test/finance_smith_web/live/integration/dashboard_live_integration_test.exs --include integration

  AGENT_SECURITY Rule 1: Credentials read from env vars only — never hardcoded.
  AGENT_SECURITY Rule 2: Token values are never logged or IO.inspected.
  """

  use FinanceSmithWeb.ConnCase, async: false
  use Oban.Testing, repo: FinanceSmith.Repo, prefix: "machine"

  import Phoenix.LiveViewTest

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
    email = "integration-dash-#{System.unique_integer([:positive])}@example.com"
    Identity.register!(email, "ValidPassword1!", authorize?: false)
  end

  test "full Plaid Link lifecycle via dashboard", %{conn: conn} do
    unless sandbox_configured?() do
      IO.warn(
        "[integration] Skipping: set PLAID_CLIENT_ID and SANDBOX_PLAID_SECRET to run this test.",
        []
      )

      assert true
    else
      user = register_user!()

      {:ok, view, _html} =
        conn
        |> log_in_user(user)
        |> live("/dashboard")

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
