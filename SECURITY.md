# Security Policy & Architecture

## Overview

Finance Smith is a strictly scoped, privately hosted financial data pipeline. It aggregates personal transaction data from external providers (Plaid) into a self-managed PostgreSQL database, with raw payloads archived to Backblaze B2 object storage. The application is designed for single-household use and is never intended to be a multi-tenant SaaS product.

The foundational security principles are:

- **Data sovereignty:** All financial data is owned and stored by the household operator, never shared with third parties beyond the minimum required for API integrations.
- **Strict secret isolation:** No credentials are embedded in the codebase. All secrets are injected from the host environment at runtime.
- **Least privilege:** Every external API integration is configured with the minimum permissions required for its function.
- **Defense in depth for sensitive tokens:** The Plaid `access_token` (which grants permanent read access to bank accounts) is encrypted at rest and only decrypted in memory at the moment of use.

---

## Status Legend

Each control in this document is tagged to indicate its current implementation state:

| Tag | Meaning |
|---|---|
| `[ACTIVE]` | Implemented and operational in the current codebase. |
| `[PLANNED]` | Defined as a required security control; not yet implemented. |

**Important for AI agents and contributors:** Do not treat `[PLANNED]` items as if they exist. Do not generate code that assumes these controls are active. When implementing a `[PLANNED]` item, update this document to change its tag to `[ACTIVE]` and add a reference to the relevant module.

---

## 1. Secret Management & Environment Configuration

### `[ACTIVE]` Environment-Based Secret Injection

All external API credentials and cryptographic keys are isolated from the application codebase entirely.

- **Storage:** Secrets are stored on the deployment host in a `.env` file. This file is listed in `.gitignore` and must never be committed to version control.
- **File permissions:** The `.env` file must be restricted to the OS user running the Elixir release:

  ```bash
  chmod 600 /path/to/.env
  ```

- **Runtime injection:** [`config/runtime.exs`](config/runtime.exs) reads all secrets from the host environment via `System.get_env/1`. Every required variable is enforced with an explicit startup crash if missing — the application will not start with incomplete credentials. Example pattern:

  ```elixir
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise "environment variable CLOAK_KEY is missing."
  ```

- **Template:** [``.env.example``](.env.example) documents all required variables with placeholder values. The example file contains development-only placeholder credentials that must never be used in production.

### Required Environment Variables

| Variable | Purpose | Required In |
|---|---|---|
| `DATABASE_URL` | PostgreSQL connection string | Production |
| `POOL_SIZE` | DB connection pool size | Production |
| `CLOAK_KEY` | Base64-encoded AES-256-GCM key for token encryption | All |
| `PLAID_CLIENT_ID` | Plaid API client identifier | All |
| `PLAID_SECRET` | Plaid API secret | All |
| `B2_KEY_ID` | Backblaze B2 application key ID | All |
| `B2_APP_KEY` | Backblaze B2 application key | All |
| `B2_BUCKET_NAME` | Target B2 bucket name | All |

Generating a new `CLOAK_KEY`:
```bash
32 |> :crypto.strong_rand_bytes() |> Base.encode64() |> IO.puts()
```

### Agent Rules: Secret Management

- **NEVER** hardcode any secret, key, token, or credential in Elixir source files, config files (`config.exs`, `dev.exs`, `test.exs`), or test fixtures.
- **NEVER** log the values of `CLOAK_KEY`, `PLAID_SECRET`, `B2_APP_KEY`, or any derived credential. Use `Logger.debug("[Module] action succeeded")` without value interpolation for sensitive fields.
- **NEVER** add new required secrets to `config/runtime.exs` without adding a corresponding entry to `.env.example` (with a placeholder) and to the table above.
- When writing tests that require secrets, use the fixed development keys already present in `config/test.exs`. Do not introduce additional hardcoded test keys.

---

## 2. Encryption at Rest

### `[ACTIVE]` Plaid Access Token — AES-256-GCM via Cloak

The Plaid `access_token` grants permanent read access to a user's linked bank accounts. It is the most sensitive credential managed by this system.

- **Implementation:** [`lib/finance_smith/vault.ex`](lib/finance_smith/vault.ex) defines a `Cloak.Vault` using `Cloak.Ciphers.AES.GCM` with a 12-byte IV. The vault key is sourced exclusively from the `CLOAK_KEY` environment variable.
- **Resource integration:** [`lib/finance_smith/banking/plaid_item.ex`](lib/finance_smith/banking/plaid_item.ex) uses the `AshCloak` extension to transparently encrypt the `access_token` attribute. The value is stored in the database column `encrypted_access_token` and is decrypted in memory only when the field is explicitly loaded.
- **Decryption scope:** The token is only decrypted within Oban worker processes (`SyncWorker`) at the exact moment a Plaid API call is made. It is never decrypted in bulk queries or passed to non-worker contexts.

### `[ACTIVE]` Backblaze B2 — Server-Side Encryption

Raw Plaid JSON payloads archived to the B2 bucket are encrypted at rest using Backblaze's native Server-Side Encryption (SSE). This is configured at the bucket level and requires no application-side handling.

### `[ACTIVE]` B2 Content Integrity

All B2 uploads include a `X-Bz-Content-Sha1` header containing a SHA-1 hash of the payload body. B2 validates this hash server-side and rejects uploads where the hash does not match, preventing silent data corruption in transit.

Implementation: [`lib/finance_smith/data_lake/b2/b2.ex`](lib/finance_smith/data_lake/b2/b2.ex).

### Agent Rules: Encryption

- **NEVER** remove or bypass the `cloak` block in `PlaidItem`. The `access_token` attribute must always be declared within `cloak do ... end`.
- **NEVER** access `plaid_item.access_token` in a read action that loads all items in bulk (e.g., `Ash.read!`). Always load the token only within the specific worker that needs it.
- **NEVER** change the vault cipher away from AES-GCM without a formal key rotation migration plan.
- **NEVER** mark `access_token` as `sensitive?: false` or expose it in API responses.
- If adding new sensitive attributes (e.g., a future SimpleFIN token), apply `AshCloak` encryption following the same pattern as `PlaidItem.access_token`.

---

## 3. External Services & API Integrations

### A. Plaid

#### `[ACTIVE]` Data in Transit

All requests to the Plaid API are made by the `plaid_elixir` library over TLS. The production endpoint (`https://production.plaid.com/`) enforces TLS 1.2+.

#### `[ACTIVE]` Credential Scoping

Plaid credentials (`client_id` + `secret`) are loaded from environment variables and are scoped to the single configured Plaid environment (sandbox or production). The application never holds credentials for multiple environments simultaneously at runtime.

#### `[PLANNED]` Webhook Signature Verification

Plaid webhook verification was previously implemented but has been removed. The current sync pipeline is triggered on-demand via Oban rather than via Plaid webhooks. There is no HTTP endpoint in the application.

When webhook ingestion is reimplemented, the following control **must** be implemented before deploying a public endpoint:

- Validate the `Plaid-Verification` JWT header on every inbound webhook request using Plaid's published public keys.
- Reject all payloads that fail verification with `401 Unauthorized` before enqueuing any background jobs.
- Reference: [Plaid Webhook Verification docs](https://plaid.com/docs/api/webhooks/webhook-verification/).

---

### B. Backblaze B2

#### `[ACTIVE]` Scoped Application Keys

The application must not use master B2 account credentials. An Application Key scoped exclusively to the target bucket (`B2_BUCKET_NAME`) with only `readFiles` and `writeFiles` permissions must be created. See [`docs/infrastructure.md`](docs/infrastructure.md) for setup instructions.

#### `[ACTIVE]` Auth Token Isolation

B2 authorization tokens (obtained by calling `b2_authorize_account`) are held exclusively in the `B2.AuthServer` GenServer process memory. They are never written to disk, the database, or application logs. The token is automatically refreshed on 401 responses.

Implementation: [`lib/finance_smith/data_lake/b2/auth_server.ex`](lib/finance_smith/data_lake/b2/auth_server.ex).

#### `[PLANNED]` Event Notification HMAC Validation

If Backblaze B2 event notifications are enabled in the future to trigger processing on object creation, the `X-Bz-Event-Notification-Signature` header must be validated against an HMAC-SHA256 hash computed using the configured shared secret before processing any notification payload.

---

### C. AWS (Not in Current Architecture)

AWS services (API Gateway, SQS, IAM) are not part of the current architecture. The sync pipeline runs entirely within the Elixir application using Oban for background job scheduling. No AWS SDK dependencies are present.

If AWS integration is added in the future:

- `[PLANNED]` Use strictly scoped IAM policies. The API Gateway role should only be permitted `sqs:SendMessage` to the designated queue. The Elixir consumer role should only be permitted `sqs:ReceiveMessage` and `sqs:DeleteMessage` on the specific queue.
- `[PLANNED]` Never use root AWS credentials or credentials with `*` resource or action wildcards.

---

## 4. Application Security

### A. User Authentication

#### `[PLANNED]` Password Hashing

The `User` resource ([`lib/finance_smith/identity/user.ex`](lib/finance_smith/identity/user.ex)) has a `password_hash` attribute, but no password hashing library is present in `mix.exs` and no hashing or verification logic exists.

When authentication is implemented:

- Use `bcrypt_elixir` (via `Bcrypt`) or `argon2_elixir` for password hashing. Do not implement custom hashing.
- The `password_hash` attribute must be marked `sensitive?: true` in the Ash resource and must never be selected in read queries or returned in API responses.
- Implement a dedicated `:register` create action and a `:sign_in` read action with controlled argument handling rather than using default `create: :*` / `update: :*`.

#### `[PLANNED]` Multi-Factor Authentication (TOTP)

Access to the Phoenix LiveView dashboard requires standard credential authentication followed by a Time-based One-Time Password (TOTP). Use `NimbleTOTP` for TOTP generation and verification. The TOTP secret must be stored encrypted at rest using the same `FinanceSmith.Vault`.

---

### B. Authorization

#### `[PLANNED]` Ash Authorization Policies

No Ash authorization policies are currently defined. All resources use default actions, and `authorize?: false` is used broadly at call sites.

When authorization is implemented:

- Add `Ash.Policy.Authorizer` to each resource's `authorizers` list.
- Define `policy` blocks that scope all reads and writes to the authenticated actor's `household_id`.
- Remove `authorize?: false` from all production code paths. It is acceptable only in test setup helpers.
- Do not define bypass policies except for an explicit admin role if one is introduced.

#### `[PLANNED]` Ash Multitenancy

`Household` is currently a logical grouping with no enforced data isolation. The Ash multitenancy extension is not configured.

When the web UI is added and multiple households could theoretically share an instance, configure `multitenancy` at the resource level so that all queries are automatically scoped by `household_id` at the database level.

---

## 5. Infrastructure & Network Security

### `[ACTIVE]` SSH Key-Pair Authentication

Remote access to the production host must use SSH key-pair authentication exclusively. Password authentication over SSH must be disabled in `sshd_config`:

```
PasswordAuthentication no
ChallengeResponseAuthentication no
```

### `[PLANNED]` HTTPS / TLS Termination

The application does not currently expose an HTTP server. When a web layer is added, deploy it behind a reverse proxy (Caddy or Nginx) configured to:

- Force HTTPS on all public endpoints.
- Automatically provision and rotate TLS 1.2+ certificates (e.g., via Let's Encrypt / Caddy's automatic HTTPS).
- Set `HSTS` headers with a minimum `max-age` of 31536000.

---

## 6. Dependency & Vulnerability Management

### `[ACTIVE]` Elixir Dependency Auditing

Run `mix audit` regularly to identify Elixir/Erlang dependencies with known CVEs. This check should be added to any CI pipeline.

```bash
mix audit
```

Dependencies with known vulnerabilities should be patched within 7 days of disclosure unless a documented exception exists.

### `[ACTIVE]` OS Security Patching

The deployment host should have automated security patching enabled for its Linux distribution. Unattended upgrades (Debian/Ubuntu) or equivalent tooling should be configured.

### Agent Rules: Dependencies

- **NEVER** add dependencies with known CVEs to `mix.exs`.
- **NEVER** pin dependencies to a version older than one major version behind the current stable release without a documented reason.
- When adding a new dependency that handles secrets, cryptography, or network I/O, review its changelog and security advisories before adding it.

---

## 7. Data Retention & Deletion

### `[ACTIVE]` Cascade Deletes in PostgreSQL

The relational schema enforces cascading deletes. Removing a `PlaidItem` record triggers cascaded deletion of all associated `Account` and `Transaction` records in PostgreSQL. The `User`-to-`PlaidItem` foreign key is configured with `on_delete: :delete`.

This is defined in the `postgres do ... references do` blocks within each Ash resource.

### `[PLANNED]` B2 Data Lake Purge

When a `PlaidItem` is deleted, the corresponding archived JSON partitions in the B2 bucket (under `plaid_sync/{household_id}/{plaid_item_id}/`) must also be deleted. This is not yet implemented.

When implementing this control:

- Hook into the `PlaidItem` destroy action using `Ash.Changeset.after_action/2` or an Oban job.
- List and delete all B2 objects under the item's key prefix using the B2 API.
- Ensure the deletion is idempotent and handles partial failures gracefully (e.g., log a warning and allow the database delete to proceed rather than rolling back on a B2 error).

### `[ACTIVE]` Oban Job Pruning

Completed and discarded Oban jobs are pruned after 7 days via the `Oban.Plugins.Pruner` plugin. This prevents Oban job records (which may contain B2 object keys) from accumulating indefinitely.

---

## 8. Agent Directives (Summary)

The following rules apply to all AI coding agents working in this repository. They consolidate the rules embedded in each section above.

### Secrets & Configuration

1. Never hardcode secrets, tokens, or credentials in any source file.
2. Never log or `IO.inspect` the values of sensitive fields: `access_token`, `CLOAK_KEY`, `PLAID_SECRET`, `B2_APP_KEY`, or any decrypted value from `FinanceSmith.Vault`.
3. Always add new required secrets to both `config/runtime.exs` (with a startup `raise`) and `.env.example` (with a placeholder).
4. Never commit `.env` to git. Verify `.gitignore` before staging secrets-adjacent files.

### Encryption & Sensitive Data

5. Never remove, bypass, or weaken the `AshCloak` encryption on `PlaidItem.access_token`.
6. Never load `access_token` in a bulk read query. Only load it inside the Oban worker that requires it for a Plaid API call.
7. When adding new secrets managed by the application (e.g., SimpleFIN tokens), follow the same AshCloak + Vault pattern used for `access_token`.

### Authorization

8. Do not add `authorize?: false` to production code paths. It is acceptable only in test setup code and explicitly seeded data scripts.
9. When Ash authorization policies are implemented, never add a blanket `authorize_if always()` policy to a resource without a corresponding constraint (e.g., a role check or actor relationship check).

### Webhooks & HTTP Endpoints

10. Before adding any public HTTP endpoint that receives data from an external service (Plaid, B2, etc.), implement cryptographic signature verification as described in the `[PLANNED]` sections above. An unverified endpoint that enqueues background jobs must never be deployed.

### Dependency Management

11. Run `mix audit` before committing any change to `mix.exs`.
12. Never add a dependency for cryptographic primitives or hashing unless it is a well-audited library (e.g., `bcrypt_elixir`, `argon2_elixir`, `cloak`). Do not implement custom crypto.
