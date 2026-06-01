# One-off cleanup for duplicate Plaid account connections.
#
# Background: re-connecting a bank (e.g. Chase) creates a new Plaid item with new
# account objects even though they represent the same real cards. Each sync then
# writes a separate transaction row per connection, producing identical-looking
# duplicates in the ledger.
#
# This script detects duplicate account groups by matching on:
#   (user_id, institution_name, mask, subtype)
# across different Plaid items. For each group the oldest-inserted account is
# treated as canonical; newer accounts are marked as duplicates.
#
# Per duplicate account:
#   1. Sets duplicate_of_id = canonical.id (raw Repo.update_all; the FK column is
#      not in the Account default :update accept list since it is a non-public
#      belongs_to relationship).
#   2. Bulk-destroys all transactions on the duplicate account via Ash, so lifecycle
#      hooks are respected for any future additions.
#
# Idempotent: discovery filters by duplicate_of_id IS NULL. After --execute the
# duplicate accounts have duplicate_of_id set and fall out of the candidate set.
# A second run finds zero groups.
#
# Usage:
#   mix run priv/repo/scripts/cleanup_duplicate_accounts.exs           # dry run
#   mix run priv/repo/scripts/cleanup_duplicate_accounts.exs --execute # apply

defmodule FinanceSmith.Scripts.CleanupDuplicateAccounts do
  @moduledoc false

  import Ecto.Query

  require Ash.Query

  alias FinanceSmith.Banking.Transaction
  alias FinanceSmith.Repo

  def run(argv \\ System.argv()) do
    dry_run? = "--execute" not in argv
    print_banner(dry_run?)

    groups = fetch_duplicate_groups()

    if Enum.empty?(groups) do
      IO.puts(color("No duplicate account groups found. Nothing to do.\n", :green))
    else
      counters =
        Enum.reduce(groups, empty_counters(), fn {_key, accounts}, acc ->
          process_group(accounts, dry_run?, acc)
        end)

      print_summary(counters, dry_run?)
    end
  end

  # ── Discovery ──────────────────────────────────────────────────────────────

  # Returns a map of group_key => [account_map, ...] sorted oldest-first.
  # Only considers active accounts with no duplicate_of_id already set.
  defp fetch_duplicate_groups do
    all_accounts =
      from(a in "accounts",
        prefix: "core",
        join: pi in "plaid_items",
        on: pi.id == a.plaid_item_id,
        prefix: "core",
        where: a.status == "active",
        where: is_nil(a.duplicate_of_id),
        where: not is_nil(a.mask),
        where: not is_nil(pi.institution_name),
        select: %{
          account_id: a.id,
          account_name: a.name,
          mask: a.mask,
          type: a.type,
          subtype: a.subtype,
          plaid_item_id: pi.id,
          institution: pi.institution_name,
          user_id: pi.user_id,
          inserted_at: a.inserted_at
        },
        order_by: [a.mask, a.inserted_at]
      )
      |> Repo.all()

    all_accounts
    |> Enum.group_by(fn a ->
      {a.user_id, a.institution, a.mask, String.downcase(a.subtype || "")}
    end)
    |> Enum.filter(fn {_, accounts} ->
      length(accounts) > 1 and
        accounts |> Enum.map(& &1.plaid_item_id) |> Enum.uniq() |> length() > 1
    end)
  end

  # ── Per-group processing ───────────────────────────────────────────────────

  defp process_group(accounts, dry_run?, counters) do
    # Sort ascending by inserted_at; the first is canonical.
    [canonical | duplicates] = Enum.sort_by(accounts, & &1.inserted_at, NaiveDateTime)

    IO.puts(
      "\n#{color("Group", :cyan)} #{canonical.institution} ···#{canonical.mask} " <>
        "(#{canonical.subtype}) — canonical: #{fmt_id(canonical.account_id)}"
    )

    Enum.reduce(duplicates, counters, fn dup, acc ->
      process_duplicate(canonical, dup, dry_run?, acc)
    end)
  end

  defp process_duplicate(canonical, dup, dry_run?, counters) do
    txn_count = count_transactions(dup.account_id)

    IO.puts(
      "  duplicate: #{fmt_id(dup.account_id)} " <>
        "(plaid_item=#{fmt_id(dup.plaid_item_id)}, #{txn_count} txn(s))"
    )

    if dry_run? do
      IO.puts("  → would set duplicate_of_id, delete #{txn_count} transaction(s)")

      counters
      |> inc(:duplicate_accounts_found)
      |> inc(:transactions_to_delete, txn_count)
    else
      apply_duplicate!(canonical, dup, txn_count, counters)
    end
  end

  # ── Execute path ───────────────────────────────────────────────────────────

  defp apply_duplicate!(canonical, dup, txn_count, counters) do
    Repo.transaction(fn ->
      set_duplicate_of_id!(dup.account_id, canonical.account_id)
      destroy_transactions!(dup.account_id)

      IO.puts(
        "  ✓ set duplicate_of_id, deleted #{txn_count} transaction(s)"
      )

      counters
      |> inc(:duplicate_accounts_found)
      |> inc(:duplicate_accounts_marked)
      |> inc(:transactions_to_delete, txn_count)
      |> inc(:transactions_deleted, txn_count)
    end)
    |> case do
      {:ok, updated_counters} ->
        updated_counters

      {:error, reason} ->
        warn(
          "  Transaction rollback for duplicate=#{fmt_id(dup.account_id)}: #{inspect(reason)}"
        )

        counters
        |> inc(:duplicate_accounts_found)
        |> inc(:groups_failed)
    end
  end

  defp set_duplicate_of_id!(duplicate_id, canonical_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case from(a in "accounts",
           prefix: "core",
           where: a.id == ^duplicate_id and is_nil(a.duplicate_of_id)
         )
         |> Repo.update_all(set: [duplicate_of_id: canonical_id, updated_at: now]) do
      {1, _} ->
        :ok

      {0, _} ->
        raise "duplicate_of_id update matched 0 rows for account id=#{fmt_id(duplicate_id)}"
    end
  end

  defp destroy_transactions!(account_id) do
    result =
      Transaction
      |> Ash.Query.filter(account_id == ^account_id)
      |> Ash.bulk_destroy(:destroy, %{}, authorize?: false, return_errors?: true)

    case result do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{status: :error, errors: errors} ->
        raise "bulk_destroy failed for account_id=#{fmt_id(account_id)}: #{inspect(errors)}"

      %Ash.BulkResult{status: :partial_success, errors: errors} ->
        raise "bulk_destroy partial failure for account_id=#{fmt_id(account_id)}: #{inspect(errors)}"
    end
  end

  defp count_transactions(account_id) do
    from(t in "transactions",
      prefix: "core",
      where: t.account_id == ^account_id,
      select: count(t.id)
    )
    |> Repo.one()
  end

  # ── Counters ───────────────────────────────────────────────────────────────

  defp empty_counters do
    %{
      duplicate_accounts_found: 0,
      duplicate_accounts_marked: 0,
      transactions_to_delete: 0,
      transactions_deleted: 0,
      groups_failed: 0
    }
  end

  defp inc(counters, key, amount \\ 1) do
    Map.update!(counters, key, &(&1 + amount))
  end

  # ── Output ─────────────────────────────────────────────────────────────────

  defp print_banner(dry_run?) do
    mode = if dry_run?, do: color("DRY RUN", :yellow), else: color("EXECUTE", :green)
    host = Repo.config() |> Keyword.get(:hostname, "unknown")

    IO.puts("\n#{color("Duplicate account cleanup", :cyan)} — mode: #{mode}")
    IO.puts("Database host: #{host}\n")
  end

  defp print_summary(counters, dry_run?) do
    IO.puts("\n#{color("── Summary ──", :cyan)}")

    if dry_run? do
      IO.puts(
        "Duplicate accounts found:  #{color(to_string(counters.duplicate_accounts_found), :yellow)}"
      )

      IO.puts(
        "Transactions to delete:    #{color(to_string(counters.transactions_to_delete), :yellow)}"
      )

      IO.puts("\n#{color("Re-run with --execute to apply changes.", :yellow)}")
    else
      IO.puts(
        "Duplicate accounts marked: #{color(to_string(counters.duplicate_accounts_marked), :green)}"
      )

      IO.puts(
        "Transactions deleted:      #{color(to_string(counters.transactions_deleted), :green)}"
      )

      if counters.groups_failed > 0 do
        IO.puts("Groups failed (rolled back): #{color(to_string(counters.groups_failed), :red)}")
      end
    end

    IO.puts("")
  end

  defp fmt_id(<<a::4, b::4, c::4, d::4, e::4, f::4, g::4, h::4,
               i::4, j::4, k::4, l::4, m::4, n::4, o::4, p::4,
               q::4, r::4, s::4, t::4, u::4, v::4, w::4, x::4,
               y::4, z::4, aa::4, ab::4, ac::4, ad::4, ae::4, af::4>>) do
    hex = [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p,
           q, r, s, t, u, v, w, x, y, z, aa, ab, ac, ad, ae, af]
    hex_str = Enum.map(hex, &Integer.to_string(&1, 16)) |> Enum.join() |> String.downcase()

    <<p1::binary-size(8), p2::binary-size(4), p3::binary-size(4), p4::binary-size(4), p5::binary-size(12)>> =
      hex_str

    "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
  end

  defp fmt_id(other), do: inspect(other)

  defp warn(message), do: IO.puts(color(message, :red))

  defp color(text, :yellow), do: IO.ANSI.yellow() <> text <> IO.ANSI.reset()
  defp color(text, :green), do: IO.ANSI.green() <> text <> IO.ANSI.reset()
  defp color(text, :red), do: IO.ANSI.red() <> text <> IO.ANSI.reset()
  defp color(text, :cyan), do: IO.ANSI.cyan() <> text <> IO.ANSI.reset()
end

FinanceSmith.Scripts.CleanupDuplicateAccounts.run()
