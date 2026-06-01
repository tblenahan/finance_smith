defmodule FinanceSmith.Banking.Account.Changes.DetectDuplicateAccount do
  @moduledoc """
  Soft-links newly seeded Plaid accounts that collide with an existing account.

  The collision scope is intentionally limited to the same user and institution,
  using the Plaid mask and subtype as the account fingerprint. We preserve the
  new row for Plaid lineage, but mark it as a reporting duplicate so ingestion
  and reads can ignore it.
  """

  use Ash.Resource.Change

  alias FinanceSmith.Banking.{Account, PlaidItem}

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &maybe_soft_link_duplicate/1)
  end

  defp maybe_soft_link_duplicate(changeset) do
    with {:ok, mask} <- present_string(Ash.Changeset.get_attribute(changeset, :mask)),
         {:ok, plaid_item_id} <-
           present_value(Ash.Changeset.get_attribute(changeset, :plaid_item_id)),
         {:ok, plaid_account_id} <-
           present_value(Ash.Changeset.get_attribute(changeset, :plaid_account_id)),
         %PlaidItem{} = plaid_item <- load_plaid_item(plaid_item_id),
         %Account{} = canonical <-
           find_canonical_account(
             plaid_item,
             mask,
             Ash.Changeset.get_attribute(changeset, :subtype),
             plaid_account_id
           ) do
      Ash.Changeset.force_change_attribute(changeset, :duplicate_of_id, canonical.id)
    else
      _ -> changeset
    end
  end

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      :error
    else
      {:ok, value}
    end
  end

  defp present_string(_value), do: :error

  defp present_value(nil), do: :error
  defp present_value(value), do: {:ok, value}

  defp load_plaid_item(plaid_item_id) do
    PlaidItem
    |> Ash.Query.filter(id == ^plaid_item_id)
    |> Ash.Query.select([:id, :user_id, :institution_name])
    |> Ash.read_one!(authorize?: false)
  end

  defp find_canonical_account(
         %PlaidItem{user_id: user_id, institution_name: institution_name},
         mask,
         subtype,
         plaid_account_id
       ) do
    Account
    |> Ash.Query.filter(
      plaid_item.user_id == ^user_id and
        plaid_item.institution_name == ^institution_name and
        mask == ^mask and
        subtype == ^subtype and
        is_nil(duplicate_of_id) and
        plaid_account_id != ^plaid_account_id
    )
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end
end
