defmodule FinanceSmith.Banking.PlaidItem.Changes.ExchangePublicToken do
  @moduledoc """
  Exchanges a Plaid public_token for a durable access_token and item_id via
  the Plaid API, then sets both attributes on the changeset so they are
  persisted (and AshCloak-encrypted) by the normal create flow.

  On success, enqueues a SyncWorker job so the new item's transactions are
  pulled immediately after creation.

  Security:
  - public_token and access_token are never logged (AGENT_SECURITY Rule 2).
  - access_token is set as a changeset attribute and encrypted at rest by
    AshCloak before the INSERT reaches the database (Rule 5).
  """
  use Ash.Resource.Change

  alias AshCloak
  alias FinanceSmith.DataLake.SyncWorker

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
      case SyncWorker.enqueue(plaid_item.id) do
        {:ok, _job} ->
          Logger.info("[ExchangePublicToken] SyncWorker enqueued for plaid_item=#{plaid_item.id}")

        {:error, reason} ->
          Logger.warning(
            "[ExchangePublicToken] SyncWorker enqueue failed for plaid_item=#{plaid_item.id}: #{inspect(reason)}"
          )
      end

      {:ok, plaid_item}
    end)
  end

  defp plaid_client do
    Application.get_env(:finance_smith, :plaid_client, FinanceSmith.Banking.Plaid)
  end
end
