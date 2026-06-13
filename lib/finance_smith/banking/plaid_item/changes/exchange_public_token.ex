defmodule FinanceSmith.Banking.PlaidItem.Changes.ExchangePublicToken do
  @moduledoc """
  Exchanges a Plaid public_token for a durable access_token and item_id via
  the Plaid API, then sets both attributes on the changeset so they are
  persisted (and AshCloak-encrypted) by the normal create flow.

  On success, calls Plaid `accounts/get`, persists `Account` rows for
  `TransactionProcessor` to resolve `account_id`, then enqueues SyncWorker.

  Security:
  - public_token and access_token are never logged (AGENT_SECURITY Rule 2).
  - access_token is set as a changeset attribute and encrypted at rest by
    AshCloak before the INSERT reaches the database (Rule 5).
  """
  use Ash.Resource.Change

  alias AshCloak
  alias FinanceSmith.Banking.{Account, PlaidBalances, PlaidItem, PlaidStrings}
  alias FinanceSmith.DataLake.SyncWorker

  require Ash.Query
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      public_token = Ash.Changeset.get_argument(changeset, :public_token)

      case plaid_client().exchange_public_token(%{public_token: public_token}) do
        {:ok, %{access_token: access_token, item_id: item_id}} ->
          changeset
          |> AshCloak.encrypt_and_set(:access_token, access_token)
          |> Ash.Changeset.force_change_attribute(:plaid_item_id, item_id)

        {:error, reason} ->
          Logger.error("[ExchangePublicToken] Plaid token exchange failed: #{inspect(reason)}")

          Ash.Changeset.add_error(
            changeset,
            Ash.Error.Changes.InvalidArgument.exception(
              field: :public_token,
              message: "Plaid token exchange failed. We have a... discrepancy."
            )
          )
      end
    end)
    |> Ash.Changeset.after_action(fn _changeset, plaid_item ->
      item_with_token = load_plaid_item_with_token!(plaid_item.id)

      case plaid_client().get_accounts(%{access_token: item_with_token.access_token}) do
        {:error, reason} ->
          Logger.error("[ExchangePublicToken] Plaid accounts/get failed: #{inspect(reason)}")

          {:error,
           Ash.Error.Changes.InvalidArgument.exception(
             field: :public_token,
             message: "Plaid could not load accounts for this item. We have a... discrepancy."
           )}

        {:ok, %{accounts: []}} ->
          Logger.error("[ExchangePublicToken] Plaid accounts/get returned no accounts")

          {:error,
           Ash.Error.Changes.InvalidArgument.exception(
             field: :public_token,
             message: "No accounts returned for this item. We have a... discrepancy."
           )}

        {:ok, %{accounts: accounts}} ->
          Enum.each(accounts, &create_account_from_plaid!(&1, plaid_item.id))

          Logger.info(
            "[ExchangePublicToken] Persisted #{length(accounts)} account(s) for plaid_item=#{plaid_item.id}"
          )

          case SyncWorker.enqueue(plaid_item.id) do
            {:ok, _job} ->
              Logger.info(
                "[ExchangePublicToken] SyncWorker enqueued for plaid_item=#{plaid_item.id}"
              )

            {:error, reason} ->
              Logger.warning(
                "[ExchangePublicToken] SyncWorker enqueue failed for plaid_item=#{plaid_item.id}: #{inspect(reason)}"
              )
          end

          {:ok, plaid_item}
      end
    end)
  end

  defp load_plaid_item_with_token!(id) do
    PlaidItem
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load(:access_token)
    |> Ash.read_one!(authorize?: false)
  end

  defp create_account_from_plaid!(plaid_account, plaid_item_id) do
    attrs = %{
      plaid_account_id: plaid_account.account_id,
      plaid_item_id: plaid_item_id,
      name: plaid_account.name,
      mask: plaid_account.mask,
      type: PlaidStrings.normalize(plaid_account.type),
      subtype: PlaidStrings.normalize(plaid_account.subtype),
      current_balance: PlaidBalances.balance_to_cents(plaid_account.balances),
      available_balance: PlaidBalances.balance_available_to_cents(plaid_account.balances),
      credit_limit: PlaidBalances.balance_limit_to_cents(plaid_account.balances)
    }

    Account
    |> Ash.Changeset.for_create(:upsert_from_plaid, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp plaid_client do
    Application.get_env(:finance_smith, :plaid_client, FinanceSmith.Banking.Plaid)
  end
end
