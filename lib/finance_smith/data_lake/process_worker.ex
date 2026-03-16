defmodule FinanceSmith.DataLake.ProcessWorker do
  @moduledoc """
  Oban worker that processes a raw Plaid sync response already archived to B2.

  Triggered by `SyncWorker` after a successful B2 upload. Accepts the B2 object
  key, downloads the archived JSON, resolves the matching PlaidItem, and upserts
  transactions to PostgreSQL via `TransactionProcessor.process_from_b2/1`.

  If the B2 upload failed during sync, `SyncWorker` falls back to in-memory
  processing directly rather than enqueueing this worker.

  ## On-demand usage

  Call `ProcessWorker.enqueue(object_key)` to reprocess any archived B2 object
  at any time — useful for backfilling or replaying a specific sync page.
  """

  use Oban.Worker,
    queue: :data_lake,
    max_attempts: 3,
    unique: [period: 300, fields: [:args]]

  alias FinanceSmith.DataLake.TransactionProcessor

  require Logger

  @doc """
  Enqueues a processing job for the given B2 object key.

  The unique constraint prevents duplicate jobs for the same key within 5 minutes.
  """
  @spec enqueue(String.t()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(object_key) when is_binary(object_key) do
    %{object_key: object_key}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"object_key" => object_key}}) do
    Logger.info("[ProcessWorker] Processing B2 object. key=#{object_key}")
    TransactionProcessor.process_from_b2(object_key)
  end
end
