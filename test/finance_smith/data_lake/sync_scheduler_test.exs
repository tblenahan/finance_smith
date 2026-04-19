defmodule FinanceSmith.DataLake.SyncSchedulerTest do
  use FinanceSmith.DataCase, async: false
  use Oban.Testing, repo: FinanceSmith.Repo, prefix: "machine"

  alias FinanceSmith.DataLake.{SyncScheduler, SyncWorker}
  alias FinanceSmith.Identity

  import FinanceSmith.BankingFixtures

  defp unique_email, do: "scheduler-#{System.unique_integer([:positive])}@example.com"

  defp register_user! do
    Identity.register!(unique_email(), "ValidPassword1!", authorize?: false)
  end

  describe "perform/1" do
    test "enqueues SyncWorker for each active PlaidItem" do
      user = register_user!()
      item = create_plaid_item!(user, %{status: :active})

      assert :ok = perform_job(SyncScheduler, %{})

      assert_enqueued(
        worker: SyncWorker,
        args: %{"plaid_item_id" => item.id}
      )
    end

    test "does not enqueue SyncWorker for items in :error status" do
      user = register_user!()
      create_plaid_item!(user, %{status: :error})

      assert :ok = perform_job(SyncScheduler, %{})

      refute_enqueued(worker: SyncWorker)
    end

    test "enqueues only active items when both active and error items exist" do
      user = register_user!()
      active_item = create_plaid_item!(user, %{status: :active})
      create_plaid_item!(user, %{status: :error})

      assert :ok = perform_job(SyncScheduler, %{})

      assert_enqueued(
        worker: SyncWorker,
        args: %{"plaid_item_id" => active_item.id}
      )

      assert length(all_enqueued(worker: SyncWorker)) == 1
    end

    test "succeeds with no PlaidItems" do
      assert :ok = perform_job(SyncScheduler, %{})
      refute_enqueued(worker: SyncWorker)
    end
  end
end
