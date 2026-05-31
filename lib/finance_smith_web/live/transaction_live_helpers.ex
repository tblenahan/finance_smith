defmodule FinanceSmithWeb.TransactionLiveHelpers do
  @moduledoc """
  Shared helpers for LiveViews that display the paginated transaction table.

  Provides param parsing, query execution, and the atom lookup maps used to
  safely convert URL string params to Ash-compatible atoms.
  """

  alias FinanceSmith.Banking

  require Logger

  @sort_field_atoms %{"date" => :date, "amount" => :amount, "merchant_name" => :merchant_name}
  @sort_dir_atoms %{"asc" => :asc, "desc" => :desc}
  @valid_sort_by_fields Map.keys(@sort_field_atoms) ++ ["category"]
  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @doc """
  Returns the default transaction params map, with a 30-day date_from window.
  """
  def default_tx_params do
    %{
      sort_by: "date",
      sort_dir: "desc",
      after_cursor: nil,
      before_cursor: nil,
      date_from: Date.add(Date.utc_today(), -30),
      date_to: nil,
      meta_category_id: nil,
      search: nil
    }
  end

  @doc """
  Parses URL query params into a typed transaction params map.
  Unknown or invalid values are replaced with safe defaults.
  """
  def parse_tx_params(url_params) do
    %{
      sort_by: valid_sort_by(url_params["sort_by"]),
      sort_dir: valid_sort_dir(url_params["sort_dir"]),
      after_cursor: url_params["after"],
      before_cursor: url_params["before"],
      date_from: parse_date(url_params["date_from"], Date.add(Date.utc_today(), -30)),
      date_to: parse_date(url_params["date_to"], nil),
      meta_category_id: valid_uuid(url_params["category"]),
      search: nilify(url_params["search"])
    }
  end

  @doc """
  Returns the list of `MetaCategory` records visible to `user`.

  The optional `scope_filters` argument is accepted for call-site
  compatibility but is not used — meta-categories are household-level
  and the Ash policy scopes reads to the actor's household automatically.

  Returns a list of structs with at least `:id` and `:name` fields.
  """
  @spec list_categories(map(), map()) :: [map()]
  def list_categories(user, _scope_filters \\ %{}) do
    case Banking.list_meta_categories(actor: user, query: [sort: [name: :asc]]) do
      {:ok, records} ->
        records

      {:error, reason} ->
        Logger.warning("[TransactionLiveHelpers] list_categories failed", error: inspect(reason))
        []
    end
  end

  @doc """
  Executes the `:list` action for `user` using the given `tx_params`.
  An optional `scope_filters` map is merged with the filter args to support
  connection- or account-scoped views.

  Returns `{:ok, %Ash.Page.Keyset{}}` on success or `{:error, reason}` when the
  action fails. Callers are expected to surface the error distinctly from the
  empty state.
  """
  @spec fetch_transactions(
          FinanceSmith.Identity.User.t() | map(),
          map(),
          map()
        ) :: {:ok, Ash.Page.Keyset.t()} | {:error, term()}
  def fetch_transactions(user, tx_params, scope_filters \\ %{}) do
    sort_dir = Map.fetch!(@sort_dir_atoms, tx_params.sort_dir)
    sort = build_sort(tx_params.sort_by, sort_dir)

    page_opts =
      [limit: 25, count: true]
      |> maybe_put_cursor(:after, tx_params.after_cursor)
      |> maybe_put_cursor(:before, tx_params.before_cursor)

    input =
      Map.merge(
        %{
          date_from: tx_params.date_from,
          date_to: tx_params.date_to,
          meta_category_id: tx_params.meta_category_id,
          search: tx_params.search
        },
        scope_filters
      )

    case Banking.list_transactions(input, actor: user, query: [sort: sort], page: page_opts) do
      {:ok, page} ->
        {:ok, page}

      {:error, reason} = err ->
        Logger.error("[TransactionLiveHelpers] list_transactions failed", error: inspect(reason))
        err
    end
  end

  @doc """
  Applies a resolved (posted) transaction to the current page in memory.

  When Plaid promotes a pending transaction to posted, the backend calls
  `Transaction.resolve_pending` and broadcasts on `"transaction:updated"`.
  Rather than re-querying the database, this function swaps the old pending
  row in `page.results` with a rebuilt display struct derived entirely from
  in-memory data — zero DB queries.

  The swap is keyed on `pending_transaction_id`: the posted transaction's
  `pending_transaction_id` must equal the pending row's `plaid_transaction_id`
  in order to be replaced.

  Associations (`account`, `meta_category`) from `notification.data` are
  `%Ash.NotLoaded{}` because the backend fetched the record without loading
  them. We reuse the existing row's loaded `:account` (unchanged on resolve)
  and look up `:meta_category` from the LiveView's in-memory `categories` list.

  Active UI filters are respected: if the rebuilt row no longer matches
  `tx_params`, it is dropped from the results rather than inserted blind.
  The `page.count` field is intentionally left unchanged (the underlying DB
  row still exists).

  Security: we only ever touch rows already present in `page.results`, which
  were policy-scoped to the actor at query time. Cross-household PubSub payloads
  are silently ignored because no matching pending row will exist in the results.
  """
  @spec apply_resolved_transaction(
          Ash.Page.Keyset.t() | nil,
          struct(),
          map(),
          [struct()]
        ) :: Ash.Page.Keyset.t() | nil
  def apply_resolved_transaction(nil, _updated_txn, _tx_params, _categories), do: nil

  def apply_resolved_transaction(page, updated_txn, tx_params, categories) do
    pending_id = updated_txn.pending_transaction_id

    if is_nil(pending_id) or pending_id == "" do
      page
    else
      new_results =
        Enum.flat_map(page.results, fn current_txn ->
          if current_txn.plaid_transaction_id == pending_id do
            rebuilt = %{
              updated_txn
              | account: current_txn.account,
                meta_category: category_lookup(categories, updated_txn.meta_category_id)
            }

            if matches_filters?(rebuilt, tx_params), do: [rebuilt], else: []
          else
            [current_txn]
          end
        end)

      %{page | results: new_results}
    end
  end

  # --- Private helpers --------------------------------------------------------

  defp category_lookup(_categories, nil), do: nil

  defp category_lookup(categories, meta_category_id) do
    Enum.find(categories, fn cat -> cat.id == meta_category_id end)
  end

  defp matches_filters?(txn, tx_params) do
    matches_date_from?(txn, tx_params.date_from) and
      matches_date_to?(txn, tx_params.date_to) and
      matches_category?(txn, tx_params.meta_category_id) and
      matches_search?(txn, tx_params.search)
  end

  defp matches_date_from?(_txn, nil), do: true

  defp matches_date_from?(txn, date_from),
    do: Date.compare(txn.date, date_from) in [:gt, :eq]

  defp matches_date_to?(_txn, nil), do: true

  defp matches_date_to?(txn, date_to),
    do: Date.compare(txn.date, date_to) in [:lt, :eq]

  defp matches_category?(_txn, nil), do: true
  defp matches_category?(txn, id), do: txn.meta_category_id == id

  defp matches_search?(_txn, nil), do: true
  defp matches_search?(_txn, ""), do: true

  defp matches_search?(txn, search) do
    needle = String.downcase(search)
    haystack = String.downcase(txn.merchant_name || "")
    String.contains?(haystack, needle)
  end

  defp valid_sort_by(field) when field in @valid_sort_by_fields, do: field
  defp valid_sort_by(_), do: "date"

  defp build_sort("category", dir), do: [{:"meta_category.name", dir}, {:inserted_at, :desc}]

  defp build_sort(field, dir) do
    sort_field = Map.fetch!(@sort_field_atoms, field)
    [{sort_field, dir}, {:inserted_at, :desc}]
  end

  defp valid_sort_dir(dir) when dir in ["asc", "desc"], do: dir
  defp valid_sort_dir(_), do: "desc"

  defp valid_uuid(value) when is_binary(value) do
    if Regex.match?(@uuid_regex, value), do: value, else: nil
  end

  defp valid_uuid(_), do: nil

  defp parse_date(nil, default), do: default
  defp parse_date("", default), do: default

  defp parse_date(str, default) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> default
    end
  end

  defp nilify(""), do: nil
  defp nilify(nil), do: nil
  defp nilify(v), do: v

  defp maybe_put_cursor(opts, _key, nil), do: opts
  defp maybe_put_cursor(opts, key, cursor), do: Keyword.put(opts, key, cursor)
end
