# Infrastructure Setup Guide

This document describes the external infrastructure required to operate the
Backblaze B2 data lake. The Elixir application syncs Plaid on demand and
archives raw responses to B2. No AWS services or scheduled jobs are required.

---

## 1. Backblaze B2

### 1.1 Create the Bucket

1. Log in to the [Backblaze B2 Console](https://secure.backblaze.com/b2_buckets.htm).
2. Create a new **private** bucket (e.g. `Finance-bucket`).
3. Leave "Default Encryption" enabled.
4. Under **Lifecycle Settings** → set files to "Keep all versions" to ensure the
   immutable data lake (cost-free within the 10 GB free tier).

### 1.2 Create a Scoped Application Key

Create a key with the minimum permissions required:

1. Navigate to **App Keys** → **Add a New Application Key**.
2. Set the key name (e.g. `my-app-name`).
3. Under **Allow access to Bucket(s)**, select **only the Plaid bucket**.
4. Under **Type of Access**, select **Read and Write**.
5. Leave all other options at defaults.
6. Copy the values to your `.env`:

```
B2_KEY_ID=<keyID>
B2_APP_KEY=<applicationKey>
B2_KEY_NAME=<keyName>
B2_BUCKET_NAME=<bucketName>
```

### 1.3 File permissions on the deployment host

After copying `.env` to the server:

```bash
chmod 600 /path/to/.env
```

This restricts reads to the OS user running the Elixir release.

---

## 2. Sync pipeline

The sync pipeline runs entirely inside the Elixir application with no
additional cloud infrastructure:

- **On-demand sync**: Call `FinanceSmith.DataLake.SyncWorker.enqueue(plaid_item_id)`
  from anywhere in the application (e.g. after a user connects a new bank).

Each `SyncWorker` job:

1. Calls `Plaid.sync_transactions` in a cursor-based loop.
2. Archives each page as raw JSON to B2 under the path:
   `plaid_sync/{household_id}/{plaid_item_id}/{YYYY}/{MM}/{timestamp}.json`
3. On a successful upload, enqueues a `ProcessWorker` job with the B2 object key.
   `ProcessWorker` downloads the archived JSON and upserts transactions to
   PostgreSQL — decoupling the Plaid sync loop from the database write.
4. If the B2 upload fails, falls back to processing transactions from the
   in-memory Plaid response so that data is never lost.
5. Persists the updated cursor to `plaid_items.next_cursor`.

To reprocess any previously archived B2 object (e.g. for backfilling):

```elixir
FinanceSmith.DataLake.ProcessWorker.enqueue("plaid_sync/hh-id/item-id/2026/03/ts.json")
```

---

## 3. Summary: Environment Variables

```
# Backblaze B2
B2_KEY_ID=
B2_APP_KEY=
B2_KEY_NAME=
B2_BUCKET_NAME=
```
