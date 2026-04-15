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
      category: nil,
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
      category: nilify(url_params["category"]),
      search: nilify(url_params["search"])
    }
  end

  @doc """
  Executes the `:list` action for `user` using the given `tx_params`.
  An optional `scope_filters` map is merged with the filter args to support
  connection- or account-scoped views.

  Returns an `Ash.Page.Keyset` on success, or `nil` on error.
  """
  def fetch_transactions(user, tx_params, scope_filters \\ %{}) do
    sort_field = Map.fetch!(@sort_field_atoms, tx_params.sort_by)
    sort_dir = Map.fetch!(@sort_dir_atoms, tx_params.sort_dir)
    sort = [{sort_field, sort_dir}, {:inserted_at, :desc}]

    page_opts =
      [limit: 25]
      |> maybe_put_cursor(:after, tx_params.after_cursor)
      |> maybe_put_cursor(:before, tx_params.before_cursor)

    input =
      Map.merge(
        %{
          date_from: tx_params.date_from,
          date_to: tx_params.date_to,
          category: tx_params.category,
          search: tx_params.search
        },
        scope_filters
      )

    case Banking.list_transactions(input, actor: user, query: [sort: sort], page: page_opts) do
      {:ok, page} ->
        page

      {:error, reason} ->
        Logger.error("[TransactionLiveHelpers] list_transactions failed: #{inspect(reason)}")
        nil
    end
  end

  # --- Private helpers --------------------------------------------------------

  defp valid_sort_by(field) when field in ["date", "amount", "merchant_name"], do: field
  defp valid_sort_by(_), do: "date"

  defp valid_sort_dir(dir) when dir in ["asc", "desc"], do: dir
  defp valid_sort_dir(_), do: "desc"

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
