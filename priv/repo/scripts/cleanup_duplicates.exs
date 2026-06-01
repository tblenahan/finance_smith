# One-off cleanup for historical Plaid pending/posted duplicate rows.
#
# Finds posted transactions (is_pending = false) whose JSONB metadata still
# contains "pending_transaction_id", deletes the stale pending duplicate row,
# backfills the dedicated pending_transaction_id column, and strips the metadata key.
#
# Idempotent: a second run after --execute finds zero candidates.
#
# Usage:
#   mix run priv/repo/scripts/cleanup_duplicates.exs           # dry run (default)
#   mix run priv/repo/scripts/cleanup_duplicates.exs --execute # apply changes

defmodule FinanceSmith.Scripts.CleanupDuplicates do
  @moduledoc false

  import Ecto.Query

  require Ash.Query

  alias FinanceSmith.Banking.Transaction
  alias FinanceSmith.Repo

  @type counters :: %{
          candidates_found: non_neg_integer(),
          skipped_invalid_pending_id: non_neg_integer(),
          skipped_self_reference: non_neg_integer(),
          orphans_to_delete: non_neg_integer(),
          orphans_deleted: non_neg_integer(),
          orphans_missing: non_neg_integer(),
          orphans_skipped_unsafe: non_neg_integer(),
          backfills_planned: non_neg_integer(),
          backfills_applied: non_neg_integer(),
          metadata_strips_planned: non_neg_integer(),
          metadata_strips_applied: non_neg_integer()
        }

  def run(argv \\ System.argv()) do
    dry_run? = "--execute" not in argv
    print_banner(dry_run?)

    counters = empty_counters()

    candidates = fetch_candidates()

    counters =
      Map.put(counters, :candidates_found, length(candidates))

    counters =
      Enum.reduce(candidates, counters, fn posted, acc ->
        process_candidate(posted, dry_run?, acc)
      end)

    print_summary(counters, dry_run?)
  end

  defp empty_counters do
    %{
      candidates_found: 0,
      skipped_invalid_pending_id: 0,
      skipped_self_reference: 0,
      orphans_to_delete: 0,
      orphans_deleted: 0,
      orphans_missing: 0,
      orphans_skipped_unsafe: 0,
      backfills_planned: 0,
      backfills_applied: 0,
      metadata_strips_planned: 0,
      metadata_strips_applied: 0
    }
  end

  defp fetch_candidates do
    from(t in "transactions",
      prefix: "core",
      where: t.is_pending == false,
      where: fragment("? \\? ?", t.metadata, "pending_transaction_id"),
      select: %{
        id: t.id,
        account_id: t.account_id,
        plaid_transaction_id: t.plaid_transaction_id,
        column_pending_id: t.pending_transaction_id,
        metadata_pending_id: fragment("? ->> ?", t.metadata, "pending_transaction_id")
      }
    )
    |> Repo.all()
  end

  defp process_candidate(posted, dry_run?, counters) do
    pending_id =
      posted.metadata_pending_id
      |> normalize_pending_id()

    cond do
      is_nil(pending_id) ->
        warn("Skipping posted=#{posted.id}: empty pending_transaction_id in metadata")
        inc(counters, :skipped_invalid_pending_id)

      pending_id == posted.plaid_transaction_id ->
        warn(
          "Skipping posted=#{posted.id}: metadata pending_transaction_id equals plaid_transaction_id"
        )

        inc(counters, :skipped_self_reference)

      true ->
        if dry_run? do
          counters
          |> then(&handle_orphan(&1, posted, pending_id, true))
          |> then(&handle_backfill(&1, posted, pending_id, true))
          |> then(&handle_metadata_strip(&1, posted, true))
        else
          apply_candidate!(posted, pending_id, counters)
        end
    end
  end

  defp apply_candidate!(posted, pending_id, counters) do
    Repo.transaction(fn ->
      counters
      |> then(&handle_orphan(&1, posted, pending_id, false))
      |> then(&handle_backfill(&1, posted, pending_id, false))
      |> then(&handle_metadata_strip(&1, posted, false))
    end)
    |> case do
      {:ok, updated_counters} -> updated_counters
      {:error, reason} -> raise "Transaction failed for posted=#{posted.id}: #{inspect(reason)}"
    end
  end

  defp normalize_pending_id(nil), do: nil

  defp normalize_pending_id(value) when is_binary(value) do
    value |> String.trim() |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp handle_orphan(counters, posted, pending_id, dry_run?) do
    case find_orphan(pending_id) do
      nil ->
        inc(counters, :orphans_missing)

      orphan ->
        case classify_orphan(posted, orphan) do
          :safe ->
            if dry_run? do
              info(
                "Would delete orphan=#{orphan.id} for posted=#{posted.id} pending_id=#{pending_id}"
              )
            else
              destroy_orphan!(orphan.id)
            end

            counters
            |> inc(:orphans_to_delete)
            |> then(fn c -> if dry_run?, do: c, else: inc(c, :orphans_deleted) end)

          {:unsafe, reason} ->
            warn(
              "Skipping orphan delete for posted=#{posted.id} orphan=#{orphan.id}: #{reason}"
            )

            inc(counters, :orphans_skipped_unsafe)
        end
    end
  end

  defp find_orphan(pending_id) do
    Transaction
    |> Ash.Query.filter(plaid_transaction_id == ^pending_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> nil
      {:ok, %Transaction{} = record} -> record
      {:error, error} -> raise "Orphan lookup failed for pending_id=#{pending_id}: #{inspect(error)}"
      other -> raise "Unexpected Ash.read_one result for pending_id=#{pending_id}: #{inspect(other)}"
    end
  end

  defp classify_orphan(posted, orphan) do
    cond do
      orphan.id == posted.id ->
        {:unsafe, "orphan is the posted row"}

      orphan.account_id != posted.account_id ->
        {:unsafe, "orphan account_id mismatch"}

      orphan.is_pending != true ->
        {:unsafe, "orphan is not pending"}

      true ->
        :safe
    end
  end

  defp destroy_orphan!(orphan_id) do
    %Ash.BulkResult{status: status} =
      Transaction
      |> Ash.Query.filter(id == ^orphan_id)
      |> Ash.bulk_destroy(:destroy, %{}, authorize?: false, return_errors?: true)

    if status == :error do
      raise "Ash.bulk_destroy failed for orphan id=#{orphan_id}"
    end
  end

  defp handle_backfill(counters, posted, pending_id, dry_run?) do
    if posted.column_pending_id == pending_id do
      counters
    else
      if dry_run? do
        inc(counters, :backfills_planned)
      else
        apply_backfill!(posted.id, pending_id)
        inc(counters, :backfills_planned) |> inc(:backfills_applied)
      end
    end
  end

  defp apply_backfill!(posted_id, pending_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, _} =
      from(t in "transactions", prefix: "core", where: t.id == ^posted_id)
      |> Repo.update_all(set: [pending_transaction_id: pending_id, updated_at: now])

    :ok
  end

  defp handle_metadata_strip(counters, posted, dry_run?) do
    if dry_run? do
      inc(counters, :metadata_strips_planned)
    else
      apply_metadata_strip!(posted.id)
      inc(counters, :metadata_strips_planned) |> inc(:metadata_strips_applied)
    end
  end

  defp apply_metadata_strip!(posted_id) do
    metadata =
      from(t in "transactions", prefix: "core", where: t.id == ^posted_id, select: t.metadata)
      |> Repo.one()

    if is_nil(metadata) do
      raise "Posted row not found for metadata strip id=#{posted_id}"
    end

    stripped = Map.delete(metadata, "pending_transaction_id")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case from(t in "transactions", prefix: "core", where: t.id == ^posted_id)
         |> Repo.update_all(set: [metadata: stripped, updated_at: now]) do
      {1, _} -> :ok
      {0, _} -> raise "Metadata strip updated zero rows for id=#{posted_id}"
    end
  end

  defp inc(counters, key) do
    Map.update!(counters, key, &(&1 + 1))
  end

  defp print_banner(dry_run?) do
    mode =
      if dry_run? do
        color("DRY RUN", :yellow)
      else
        color("EXECUTE", :green)
      end

    host =
      Repo.config()
      |> Keyword.get(:hostname, "unknown")

    IO.puts("\n#{color("Duplicate transaction cleanup", :cyan)} — mode: #{mode}")
    IO.puts("Database host: #{host}\n")
  end

  defp print_summary(counters, dry_run?) do
    IO.puts("\n#{color("── Summary ──", :cyan)}")

    IO.puts("Candidates found:              #{counters.candidates_found}")
    IO.puts("Skipped (invalid pending id):  #{counters.skipped_invalid_pending_id}")
    IO.puts("Skipped (self-reference):        #{counters.skipped_self_reference}")

    if dry_run? do
      IO.puts(
        "Orphans to delete:             #{color(to_string(counters.orphans_to_delete), :yellow)}"
      )

      IO.puts("Orphans missing:               #{counters.orphans_missing}")
      IO.puts("Orphans skipped (unsafe):      #{counters.orphans_skipped_unsafe}")

      IO.puts(
        "Backfills planned:             #{color(to_string(counters.backfills_planned), :yellow)}"
      )

      IO.puts(
        "Metadata strips planned:       #{color(to_string(counters.metadata_strips_planned), :yellow)}"
      )

      IO.puts("\n#{color("Re-run with --execute to apply changes.", :yellow)}")
    else
      IO.puts("Orphans deleted:               #{color(to_string(counters.orphans_deleted), :green)}")
      IO.puts("Orphans missing:               #{counters.orphans_missing}")
      IO.puts("Orphans skipped (unsafe):      #{counters.orphans_skipped_unsafe}")

      IO.puts(
        "Backfills applied:             #{color(to_string(counters.backfills_applied), :green)}"
      )

      IO.puts(
        "Metadata strips applied:       #{color(to_string(counters.metadata_strips_applied), :green)}"
      )
    end

    IO.puts("")
  end

  defp info(message), do: IO.puts(color(message, :default))
  defp warn(message), do: IO.puts(color(message, :red))

  defp color(text, :yellow), do: IO.ANSI.yellow() <> text <> IO.ANSI.reset()
  defp color(text, :green), do: IO.ANSI.green() <> text <> IO.ANSI.reset()
  defp color(text, :red), do: IO.ANSI.red() <> text <> IO.ANSI.reset()
  defp color(text, :cyan), do: IO.ANSI.cyan() <> text <> IO.ANSI.reset()
  defp color(text, :default), do: text
end

FinanceSmith.Scripts.CleanupDuplicates.run()
