defmodule FinanceSmith.DataLake.DailySyncScheduler do
  @moduledoc """
  Oban worker that runs on a cron schedule and enqueues one `SyncWorker` job
  per active `PlaidItem`.

  Configured in `config/config.exs` to run daily at 2 AM:

      {Oban.Plugins.Cron,
       crontab: [{"0 2 * * *", FinanceSmith.DataLake.DailySyncScheduler}]}

  Each `SyncWorker` job is unique for 5 minutes (deduplication window), so
  re-running this scheduler manually will not create duplicate sync jobs for
  items already queued.
  """

  use Oban.Worker, queue: :data_lake, max_attempts: 3

  alias FinanceSmith.Banking
  alias FinanceSmith.DataLake.SyncWorker

  require Ash.Query
  require Logger

  @impl Oban.Worker
  def perform(_job) do
    active_items = load_active_plaid_items()

    Logger.info(
      "[DailySyncScheduler] Enqueueing sync for #{length(active_items)} active PlaidItem(s)"
    )

    Enum.each(active_items, fn item ->
      case SyncWorker.enqueue(item.id) do
        {:ok, _job} ->
          Logger.debug("[DailySyncScheduler] Enqueued sync. plaid_item=#{item.id}")

        {:error, reason} ->
          Logger.warning(
            "[DailySyncScheduler] Failed to enqueue. plaid_item=#{item.id} reason=#{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  defp load_active_plaid_items do
    Banking.PlaidItem
    |> Ash.Query.filter(status == :active)
    |> Ash.read!(authorize?: false)
  end
end
