defmodule FinanceSmith.DataLake.SyncScheduler do
  @moduledoc """
  Periodic fan-out worker scheduled by Oban Cron.

  On each tick it reads every active PlaidItem and enqueues a SyncWorker job
  for each one. The SyncWorker unique constraint (`period: 300`) de-duplicates
  overlapping cron ticks and any concurrent manual triggers, so this is safe
  to call as often as needed.

  Items in `:error` status (e.g. `ITEM_LOGIN_REQUIRED`) are excluded by the
  `:list_active` action and will not be synced until re-authenticated.
  """

  use Oban.Worker, queue: :data_lake, max_attempts: 1

  alias FinanceSmith.Banking
  alias FinanceSmith.DataLake.SyncWorker

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    items = Banking.list_active_plaid_items!(authorize?: false)

    Enum.each(items, fn %{id: id} ->
      SyncWorker.enqueue(id)
    end)

    Logger.info("[SyncScheduler] Enqueued #{length(items)} sync job(s).")
    :ok
  end
end
