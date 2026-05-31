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
