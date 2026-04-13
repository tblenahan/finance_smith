# Security Policy & Architecture

This document is for **household operators, deployers, and security reviewers**: what Finance Smith does to protect data, what you must configure, and what remains on the roadmap.

**Developers and AI coding tools** must follow **[AGENT_SECURITY.md](AGENT_SECURITY.md)** for implementation rules (secrets, logging, Cloak, `authorize?: false`, dependencies).

---

## Overview

Finance Smith is a strictly scoped, privately hosted financial application. It aggregates personal transaction data from external providers (Plaid) into a self-managed PostgreSQL database, with optional archival of raw payloads to Backblaze B2. It is designed for **single-household** use and is not a multi-tenant SaaS product.

The application **runs an HTTP server** (Phoenix / Bandit) for the web UI: registration, sign-in, optional TOTP multi-factor authentication (MFA), and authenticated LiveView pages. **TLS termination** for internet-facing deployments is an **operator responsibility** (reverse proxy); see [§5](#5-infrastructure--network-security).

Foundational principles:

- **Data sovereignty:** Financial data is owned and stored by the household operator, shared with third parties only as required for chosen integrations (e.g. Plaid).
- **Strict secret isolation:** Credentials are not embedded in the codebase; secrets are supplied via the host environment.
- **Least privilege:** External integrations use minimum necessary permissions (e.g. scoped B2 application keys).
- **Defense in depth for sensitive tokens:** The Plaid `access_token` is encrypted at rest and used only where the sync pipeline needs it.

---

## Status legend

| Tag | Meaning |
|-----|---------|
| `[ACTIVE]` | Implemented in the current codebase. |
| `[PLANNED]` | Agreed security control **not** yet implemented; do not assume it is enforced. |

Contributors should keep tags aligned with the code. Coding constraints for agents live in [AGENT_SECURITY.md](AGENT_SECURITY.md).

---

## 1. Secret management & environment configuration

### `[ACTIVE]` Environment-based secret injection

- **Storage:** Secrets are typically provided via a `.env` file on the host (gitignored). Never commit `.env`.
- **File permissions:** Restrict the file to the OS user running the application:

  ```bash
  chmod 600 /path/to/.env
  ```

- **Production:** [`config/runtime.exs`](config/runtime.exs) reads required values with `System.get_env/1` and **raises at startup** if mandatory variables are missing (database, Cloak, Plaid, B2, Phoenix secret key base, etc.).
- **Development / test:** [`config/config.exs`](config/config.exs) can load `.env` before other config; [`config/dev.exs`](config/dev.exs) and [`config/test.exs`](config/test.exs) define non-production behavior (e.g. B2 may be omitted in dev/test).
- **Template:** [`.env.example`](.env.example) lists variables with placeholders. Do not use placeholder values in production.

### Environment variables (summary)

| Variable | Purpose | Required in |
|----------|---------|-------------|
| `DATABASE_URL` | PostgreSQL URL | **Production** (`runtime.exs`) |
| `POOL_SIZE` | DB pool size | **Production** |
| `SECRET_KEY_BASE` | Phoenix session signing | **Production**; also dev/test via `SECRET_KEY_BASE` / `SECRET_KEY_BASE_TEST` |
| `PORT` | HTTP listen port | **Production** (default 4000 if unset) |
| `CLOAK_KEY` | Base64 AES-256-GCM key for Vault / AshCloak | **Dev and prod** (see `dev.exs` / `runtime.exs`); test may use `CLOAK_KEY_TEST` |
| `PLAID_CLIENT_ID`, `SANDBOX_PLAID_SECRET` | Plaid API (sandbox) | **Dev/test** via `config.exs`; also **Production** when `PLAID_ENV=sandbox` |
| `PLAID_CLIENT_ID`, `PRODUCTION_PLAID_SECRET` | Plaid API (production) | **Production** — enforced via `runtime.exs` when `PLAID_ENV` is unset or `production` |
| `PLAID_ENV` | Plaid environment selector (`sandbox` or `production`) | **Production** (`runtime.exs`). Defaults to `production`. Set to `sandbox` for prod-mode containers targeting Plaid Sandbox (e.g. staging). |
| `B2_KEY_ID`, `B2_APP_KEY`, `B2_BUCKET_NAME` | Backblaze B2 | **Production** (`runtime.exs`). **Dev/test:** may be empty (archive disabled; sync still processes in memory) |
| `POSTGRES_*`, `POSTGRES_POOL_SIZE` | Local or external DB in dev/test | **Dev/test** when not using `DATABASE_URL` |
| `CLOUDFLARE_TUNNEL_TOKEN` | Cloudflare Tunnel daemon auth token | **Production** when using the tunnel; **local Compose** only if you run `docker compose --profile tunnel` (see [`compose.yaml`](compose.yaml)) |

Additional keys (e.g. `CLOAK_KEY_TEST`, `POSTGRES_TEST_DB`) appear in [`.env.example`](.env.example).

Generate a new `CLOAK_KEY` (32 random bytes, base64):

```bash
elixir -e '32 |> :crypto.strong_rand_bytes() |> Base.encode64() |> IO.puts()'
```

---

## 2. Encryption at rest

### `[ACTIVE]` Plaid access token — AES-256-GCM (Cloak / AshCloak)

The Plaid `access_token` grants ongoing read access to linked accounts. It is the most sensitive credential the app stores.

- **Vault:** [`lib/finance_smith/vault.ex`](lib/finance_smith/vault.ex) — `Cloak.Ciphers.AES.GCM` with a 12-byte IV; key from `CLOAK_KEY`.
- **Storage:** [`lib/finance_smith/banking/plaid_item.ex`](lib/finance_smith/banking/plaid_item.ex) — AshCloak encrypts `access_token` into the `encrypted_access_token` column.
- **Use:** The token is consumed inside the **Oban-backed sync pipeline** ([`SyncWorker`](lib/finance_smith/data_lake/sync_worker.ex)) when calling Plaid. It must not be loaded for bulk UI listing of items.

### `[ACTIVE]` MFA secrets (TOTP)

When MFA is enabled, **`mfa_secret`** and **`recovery_codes`** on the `User` resource are encrypted with the same Vault ([`lib/finance_smith/identity/user.ex`](lib/finance_smith/identity/user.ex)).

### `[ACTIVE]` Backblaze B2 — server-side encryption

Archived raw JSON is stored in a **private** B2 bucket with **Backblaze default encryption** (bucket-level SSE). Operators enable this when creating the bucket.

### `[ACTIVE]` B2 content integrity

Uploads send an `X-Bz-Content-Sha1` header so B2 can reject corrupted payloads. Implementation: [`lib/finance_smith/data_lake/b2.ex`](lib/finance_smith/data_lake/b2.ex).

---

## 3. External services & API integrations

### A. Plaid

#### `[ACTIVE]` Data in transit

Requests use the `plaid_elixir` library over **TLS**. Production uses `https://production.plaid.com/` (TLS 1.2+).

#### `[ACTIVE]` Credential scoping

One Plaid environment per runtime configuration. Dev/test always uses the Plaid Sandbox. In production, [`config/runtime.exs`](config/runtime.exs) selects the environment via `PLAID_ENV`:

- `PLAID_ENV` unset or `production` (default) → `https://production.plaid.com/` + `PRODUCTION_PLAID_SECRET`.
- `PLAID_ENV=sandbox` → `https://sandbox.plaid.com/` + `SANDBOX_PLAID_SECRET`. Useful for staging prod-mode containers where live Plaid access is not desired.

The startup `raise` ensures the correct secret is present for whichever environment is selected.

#### `[PLANNED]` Webhook signature verification

There is **no Plaid webhook ingestion endpoint** today; sync is **on-demand** via Oban. The app **does** expose **browser** HTTP routes (login, MFA, dashboard).

If webhooks are added:

- Validate Plaid’s `Plaid-Verification` JWT on every request using Plaid’s published keys.
- Reject failed verification with `401` before enqueueing work.
- Reference: [Plaid webhook verification](https://plaid.com/docs/api/webhooks/webhook-verification/).

### B. Backblaze B2

#### `[ACTIVE]` Scoped application keys

Use an application key limited to the archive bucket with **read** and **write** only—not the master account key. See [`docs/infrastructure.md`](docs/infrastructure.md).

#### `[ACTIVE]` Auth token isolation

Session tokens for the B2 API live in the **`B2.AuthServer`** process ([`lib/finance_smith/data_lake/b2/auth_server.ex`](lib/finance_smith/data_lake/b2/auth_server.ex)), not on disk or in the database; refreshed on `401`.

#### `[PLANNED]` Event notification HMAC

If B2 event notifications are enabled later, validate `X-Bz-Event-Notification-Signature` before acting on payloads.

### C. AWS (not in current architecture)

No AWS SDK or services in the default pipeline. Future AWS use should follow least-privilege IAM (`[PLANNED]` in prior revisions; treat as policy guidance if added).

---

## 4. Application security

### A. User authentication

#### `[ACTIVE]` Password hashing

Registration and sign-in use **`bcrypt_elixir`** (`Bcrypt`). Passwords are never stored in plaintext; `password_hash` is marked sensitive on the Ash `User` resource. Dedicated actions: `:register`, `:sign_in` ([`lib/finance_smith/identity/user.ex`](lib/finance_smith/identity/user.ex), [`lib/finance_smith/identity.ex`](lib/finance_smith/identity.ex)).

#### `[ACTIVE]` Multi-factor authentication (TOTP)

Users can enable **TOTP** (compatible authenticator apps) via LiveView flows; MFA verification is required before accessing the main authenticated session. Secrets at rest use Vault as described in [§2](#2-encryption-at-rest).

#### `[ACTIVE]` Account lockout

Failed sign-in attempts are tracked; persistent lockout is enforced after repeated failures (see domain and User actions).

### B. Authorization

#### `[ACTIVE]` Policies on `User`

`FinanceSmith.Identity.User` uses **`Ash.Policy.Authorizer`** with policies for self-service read and MFA actions, and documented bypasses for unauthenticated registration and sign-in.

#### `[PLANNED]` Policies on banking resources

`PlaidItem`, `Account`, `Transaction`, and `Household` do **not** yet use the same policy model as `User`. Background jobs and some call sites use **`authorize?: false`** for system operations. Tightening banking authorization to the authenticated actor and `household_id` is recommended before any multi-household or shared-host deployment.

#### `[PLANNED]` Ash multitenancy

`Household` is a logical grouping; Ash **multitenancy** is not configured. If multiple households could share one instance, add resource-level multitenancy and automatic `household_id` scoping.

---

## 5. Infrastructure & network security

### `[ACTIVE]` SSH key-pair authentication

Production host access should use SSH keys; disable password auth in `sshd_config` where applicable:

```
PasswordAuthentication no
ChallengeResponseAuthentication no
```

### `[ACTIVE]` HTTPS / TLS termination (operator responsibility)

TLS termination is the **operator's responsibility**. The application does not terminate TLS itself; Phoenix listens on plain HTTP and relies on a reverse proxy to handle HTTPS and set the `x-forwarded-proto` header. Phoenix is configured to trust that header: `force_ssl: [rewrite_on: [:x_forwarded_proto]]` in `config/runtime.exs`. The real client IP is restored from `cf-connecting-ip` / `x-forwarded-for` by the `RemoteIp` plug in `FinanceSmithWeb.Endpoint`.

**Cloudflare Tunnel (supported Compose option):** The repo ships a `cloudflared` service in [`compose.yaml`](compose.yaml) as a convenient TLS termination path. It is **opt-in** (`profiles: ['tunnel']`); start it with `docker compose --profile tunnel up` when `CLOUDFLARE_TUNNEL_TOKEN` is set. The daemon opens an outbound-only QUIC connection to Cloudflare's edge (Zero Trust > Networks > Tunnels), which terminates TLS and forwards plain HTTP to Phoenix at `http://localhost:4000`.

When using Cloudflare Tunnel:

- TLS 1.2+ and certificate lifecycle are managed entirely by Cloudflare — no certificates to rotate manually.
- `Strict-Transport-Security` can be enforced via Cloudflare's edge settings (enable HSTS in the Cloudflare SSL/TLS dashboard for the zone).
- The tunnel token (`CLOUDFLARE_TUNNEL_TOKEN`) must be set in the host environment; see the environment variables table above.

Any other reverse proxy (nginx, Caddy, Traefik, etc.) that correctly sets `x-forwarded-proto` and trusted `x-forwarded-for` / real-IP headers is equally valid.

---

## 6. Dependency & vulnerability management

### `[ACTIVE]` Elixir dependency auditing

Run `mix audit` regularly (e.g. in CI) to surface known CVEs in dependencies. Patch within a reasonable window unless a documented exception exists.

### `[ACTIVE]` OS security patching

Enable automated security updates on the deployment host where your distribution supports it.

---

## 7. Data retention & deletion

### `[ACTIVE]` Cascade deletes in PostgreSQL

Deleting a `PlaidItem` cascades to related `Account` and `Transaction` rows per foreign keys in the schema. Deleting a user cascades to their Plaid items (see migrations and Ash `references`).

### `[PLANNED]` B2 data lake purge

Deleting a `PlaidItem` does **not** yet automatically delete archived objects under `plaid_sync/...` in B2. Operators may need manual cleanup until an automated purge is implemented.

### `[ACTIVE]` Oban job pruning

Completed and discarded Oban jobs are pruned after seven days (`Oban.Plugins.Pruner`), limiting retention of job arguments that may reference object keys.

---

## Reporting security issues

If you discover a security vulnerability in this project, contact the maintainer privately (do not open a public issue with exploit details until coordinated disclosure is agreed).
