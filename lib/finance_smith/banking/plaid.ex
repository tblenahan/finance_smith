defmodule FinanceSmith.Banking.Plaid do
  @moduledoc """
  Thin wrapper around the `plaid_elixir` library for all Plaid API calls used
  by FinanceSmith.

  All public functions accept plain maps and return `{:ok, result}` or
  `{:error, reason}` tuples, keeping the rest of the app decoupled from the
  `plaid_elixir` internals.

  Functions in the `Sandbox` submodule are intended for development and
  testing only and call the Plaid sandbox-specific endpoints.

  ## Gotchas

  - **Balance endpoint:** `get_balance/1` (accounts/balance/get) triggers a
    real-time request to the institution and can take up to ~30s. The app
    config sets `http_options: [recv_timeout: 30_000]` in `config/config.exs`;
    do not rely on the default timeout.
  - **Sandbox fire_webhook:** `Sandbox.fire_webhook/1` requires both
    `webhook_type` and `webhook_code`, and the item must have a webhook URL
    configured at creation time. When creating a sandbox public token for
    webhook tests, pass `options: %{webhook: "https://..."}`.
  - **Sandbox institution names:** In the Plaid sandbox, institution names are
    fake (e.g. "First Platypus Bank" for `ins_109508`). Do not assert on
    real-world names like "Chase" in tests.
  """

  alias Plaid.Client
  alias Plaid.Client.Request

  @doc """
  Creates a Plaid Link token to initialise Plaid Link on the frontend.

  Required params:
    - `:client_name` – name shown to the user in Link
    - `:language` – ISO 639-1 language code, e.g. `"en"`
    - `:country_codes` – list of ISO 3166-1 alpha-2 codes, e.g. `["US"]`
    - `:user` – map with `:client_user_id` (your internal user identifier)
    - `:products` – list of products, e.g. `["transactions"]`

  See https://plaid.com/docs/api/tokens/#linktokencreate
  """
  @spec create_link_token(map()) :: {:ok, Plaid.Link.t()} | {:error, term()}
  def create_link_token(params) do
    Plaid.Link.create_link_token(params)
  end

  @doc """
  Exchanges a short-lived Link public token for a durable access token and
  item ID.

  Required params:
    - `:public_token` – the public token returned by Plaid Link on success

  Returns `{:ok, %{access_token: _, item_id: _, request_id: _}}`.
  """
  @spec exchange_public_token(map()) :: {:ok, map()} | {:error, term()}
  def exchange_public_token(params) do
    Plaid.Item.exchange_public_token(params)
  end

  @doc """
  Fetches all accounts associated with a Plaid Item.

  The balances returned by this endpoint may be cached. For real-time balances
  use `get_balance/1`.

  Required params:
    - `:access_token` – the access token for the Item

  Returns `{:ok, %Plaid.Accounts{}}`.
  """
  @spec get_accounts(map()) :: {:ok, Plaid.Accounts.t()} | {:error, term()}
  def get_accounts(params) do
    Plaid.Accounts.get(params)
  end

  @doc """
  Fetches real-time balances for accounts associated with a Plaid Item.

  Unlike `get_accounts/1`, this endpoint triggers a live balance refresh from
  the institution and is the correct endpoint to use for balance updates in the
  ETL pipeline.

  Required params:
    - `:access_token` – the access token for the Item

  Optional params:
    - `:options` – map with `:account_ids` (list of account IDs to filter to)

  Returns `{:ok, %Plaid.Accounts{}}`.

  See https://plaid.com/docs/api/products/balance/#accountsbalanceget
  """
  @spec get_balance(map()) :: {:ok, Plaid.Accounts.t()} | {:error, term()}
  def get_balance(params) do
    Plaid.Accounts.get_balance(params)
  end

  @doc """
  Fetches metadata and health status for a Plaid Item.

  Returns institution ID, available/billed products, webhook URL, and any
  current error on the Item (e.g. `LOGIN_REQUIRED`). Use this to detect items
  that need re-authentication and to populate `institution_name` on
  `PlaidItem`.

  Required params:
    - `:access_token` – the access token for the Item

  Returns `{:ok, %Plaid.Item{}}`.

  See https://plaid.com/docs/api/items/#itemget
  """
  @spec get_item(map()) :: {:ok, Plaid.Item.t()} | {:error, term()}
  def get_item(params) do
    Plaid.Item.get(params)
  end

  @doc """
  Looks up institution details by Plaid institution ID.

  Use this to enrich a `PlaidItem` with the institution's name, logo URL,
  primary color, and supported products after token exchange.

  Required params:
    - `:institution_id` – e.g. `"ins_109508"`
    - `:country_codes` – list of ISO 3166-1 alpha-2 codes, e.g. `["US"]`

  Optional params:
    - `:options` – map accepting `:include_optional_metadata` (boolean) to
      request logo and URL fields

  Returns `{:ok, %Plaid.Institutions.Institution{}}`.

  See https://plaid.com/docs/api/institutions/#institutionsget_by_id
  """
  @spec get_institution(map()) :: {:ok, Plaid.Institutions.Institution.t()} | {:error, term()}
  def get_institution(params) do
    Plaid.Institutions.get_by_id(params)
  end

  @doc """
  Removes a Plaid Item, permanently revoking its access token.

  After removal the access token is no longer valid and the Item cannot be
  recovered. Typically called during account disconnect or cleanup.

  Required params:
    - `:access_token` – the access token for the Item to remove

  Returns `{:ok, %{request_id: _}}`.

  See https://plaid.com/docs/api/items/#itemremove
  """
  @spec remove_item(map()) :: {:ok, map()} | {:error, term()}
  def remove_item(params) do
    Plaid.Item.remove(params)
  end

  @doc """
  Syncs transactions for a Plaid Item using the cursor-based sync endpoint.

  Required params:
    - `:access_token` – the access token for the Item

  Optional params:
    - `:cursor` – the `next_cursor` from a previous sync response (omit for
      the initial sync)
    - `:count` – max number of transactions to return (default: 100)

  Returns `{:ok, %Plaid.Transactions.Sync{}}`.
  """
  @spec sync_transactions(map()) :: {:ok, Plaid.Transactions.Sync.t()} | {:error, term()}
  def sync_transactions(params) do
    Plaid.Transactions.sync(params)
  end

  defmodule Sandbox do
    @moduledoc """
    Helpers for the Plaid sandbox environment. Not for production use.
    """

    @doc """
    Creates a sandbox public token that can be exchanged for an access token
    without going through the Plaid Link UI.

    Required params:
      - `:institution_id` – Plaid institution ID, e.g. `"ins_109508"` (Chase)
      - `:initial_products` – list of products to enable, e.g. `["transactions"]`

    Returns `{:ok, %{public_token: _, request_id: _}}`.

    See https://plaid.com/docs/api/sandbox/#sandboxpublic_tokencreate
    """
    @spec create_public_token(map()) :: {:ok, map()} | {:error, term()}
    def create_public_token(params) do
      mapper = fn %{"public_token" => t, "request_id" => r} ->
        %{public_token: t, request_id: r}
      end

      Request
      |> struct(method: :post, endpoint: "sandbox/public_token/create", body: params)
      |> Request.add_metadata()
      |> Plaid.send_request(Client.new())
      |> Plaid.handle_response(mapper)
    end

    @doc """
    Fires a sandbox webhook for a given Item, bypassing the usual asynchronous
    delivery. Useful for testing webhook handling logic.

    Required params:
      - `:access_token` – the access token for the Item
      - `:webhook_type` – the webhook category, e.g. `"TRANSACTIONS"`, `"ITEM"`
      - `:webhook_code` – the webhook event code to fire. Common values:
        - `"DEFAULT_UPDATE"` (type `"TRANSACTIONS"`) – new transactions available
        - `"NEW_ACCOUNTS_AVAILABLE"` (type `"TRANSACTIONS"`) – new accounts linked
        - `"HISTORICAL_UPDATE"` (type `"TRANSACTIONS"`) – historical transactions ready
        - `"INITIAL_UPDATE"` (type `"TRANSACTIONS"`) – initial transaction pull complete
        - `"TRANSACTIONS_REMOVED"` (type `"TRANSACTIONS"`) – transactions removed
        - `"ERROR"` (type `"ITEM"`) – item error

    Returns `{:ok, %{webhook_fired: true, request_id: _}}`.

    See https://plaid.com/docs/api/sandbox/#sandboxitemfire_webhook
    """
    @spec fire_webhook(map()) :: {:ok, map()} | {:error, term()}
    def fire_webhook(params) do
      mapper = fn %{"webhook_fired" => fired, "request_id" => r} ->
        %{webhook_fired: fired, request_id: r}
      end

      Request
      |> struct(method: :post, endpoint: "sandbox/item/fire_webhook", body: params)
      |> Request.add_metadata()
      |> Plaid.send_request(Client.new())
      |> Plaid.handle_response(mapper)
    end
  end
end
