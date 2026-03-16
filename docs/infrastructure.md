# Infrastructure Setup Guide

This document describes the external infrastructure required to operate the
Backblaze B2 data lake. The Elixir application polls Plaid directly on a daily
schedule (and on-demand) and archives raw responses to B2. No AWS services are
required for the current sync pipeline.

---

## 1. Backblaze B2

### 1.1 Create the Bucket

1. Log in to the [Backblaze B2 Console](https://secure.backblaze.com/b2_buckets.htm).
2. Create a new **private** bucket (e.g. `Fin-Smith`).
3. Leave "Default Encryption" enabled.
4. Under **Lifecycle Settings** → set files to "Keep all versions" to ensure the
   immutable data lake (cost-free within the 10 GB free tier).

### 1.2 Create a Scoped Application Key

Create a key with the minimum permissions required:

1. Navigate to **App Keys** → **Add a New Application Key**.
2. Set the key name (e.g. `agent-sunglasses`).
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

- **Daily sync**: Oban's `Cron` plugin triggers `DailySyncScheduler` at 2 AM
  (configurable in `config/config.exs`). It enqueues one `SyncWorker` job per
  active `PlaidItem`.
- **On-demand sync**: Call `FinanceSmith.DataLake.SyncWorker.enqueue(plaid_item_id)`
  from anywhere in the application (e.g. after a user connects a new bank).

Each `SyncWorker` job:

1. Calls `Plaid.sync_transactions` in a cursor-based loop.
2. Archives each page as raw JSON to B2 under the path:
   `plaid_sync/{household_id}/{plaid_item_id}/{YYYY}/{MM}/{timestamp}.json`
3. Upserts transactions directly from the in-memory Plaid response.
4. Persists the updated cursor to `plaid_items.next_cursor`.

A B2 archive failure is logged as a warning but does **not** abort the sync —
transactions are always written to the database regardless of B2 availability.

---

## 3. Future: Webhook-driven ingestion

When real-time ingestion is needed (e.g. triggering a sync immediately after
Plaid fires a `TRANSACTIONS` webhook), the following approach can be added
without changing any existing modules:

1. Add a `Plug` endpoint (or Phoenix route) to receive the incoming POST.
2. Validate the `X-Bz-Event-Notification-Signature` header using the existing
   `FinanceSmith.DataLake.WebhookValidator` module (requires configuring a B2
   Event Notification Rule with `B2_WEBHOOK_SIGNING_SECRET`).
3. Insert an Oban job that calls
   `FinanceSmith.DataLake.TransactionProcessor.process_from_b2(object_key)`,
   which downloads the archived JSON from B2 and applies it to the database.

The `WebhookValidator` and `TransactionProcessor.process_from_b2/1` are
already implemented and ready for this path.

### Required B2 setup (when enabling webhooks)

1. Request Event Notifications access from Backblaze Support (the feature is
   gated; see the [announcement post](https://www.backblaze.com/blog/using-b2-event-notifications/)).
2. In the B2 console: **Bucket → Event Notifications → Add Rule**.
   - Event type: `b2:ObjectCreated:Upload`
   - Target URL: your public Plug endpoint
   - Signing Secret: value of `B2_WEBHOOK_SIGNING_SECRET`
3. Generate the signing secret locally:
   ```elixir
   # In iex -S mix
   32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
   ```
4. Set `B2_WEBHOOK_SIGNING_SECRET` in your `.env`.

---

## 4. Summary: Environment Variables

```
# Backblaze B2
B2_KEY_ID=
B2_APP_KEY=
B2_KEY_NAME=
B2_BUCKET_NAME=

# Required only when B2 event notification webhooks are enabled
B2_WEBHOOK_SIGNING_SECRET=
```
