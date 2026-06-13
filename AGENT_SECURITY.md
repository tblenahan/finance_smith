# Security rules for AI agents and developers

This file is the **canonical guardrail list** for anyone (human or tool) writing code in this repository. It does not replace the household-facing policy document.

**Read first:** [SECURITY.md](SECURITY.md) — what the application promises operators, how data is protected, and what is still on the roadmap.

When you implement a `[PLANNED]` control from that document, update **both** `SECURITY.md` and this file (and [docs/infrastructure.md](docs/infrastructure.md) if deployment topology changes).

---

## Status legend (same as SECURITY.md)

| Tag | Meaning |
|-----|---------|
| `[ACTIVE]` | Implemented in the codebase. |
| `[PLANNED]` | Required control **not** implemented yet. |

**Do not** treat `[PLANNED]` items as live. Do not generate code that assumes they exist. When you ship a planned control, retag it `[ACTIVE]` in `SECURITY.md` and cite the implementing module.

---

## Agent rules: secret management

- **NEVER** hardcode any secret, key, token, or credential in Elixir source, `config/*.exs` (except documented test-only patterns), or test fixtures.
- **NEVER** log the values of `CLOAK_KEY`, `SANDBOX_PLAID_SECRET`, `PRODUCTION_PLAID_SECRET`, `B2_APP_KEY`, or any derived credential. Use `Logger.debug("[Module] action succeeded")` without interpolating sensitive values.
- **NEVER** add new required secrets to `config/runtime.exs` without a matching entry in `.env.example` (placeholder) and the environment table in `SECURITY.md`.
- For tests, use the patterns in `config/test.exs` (e.g. `CLOAK_KEY_TEST` / `SECRET_KEY_BASE_TEST`). Do not introduce extra hardcoded production-like keys.

---

## Agent rules: encryption and sensitive data

- **NEVER** remove or bypass the `cloak` block on `FinanceSmith.Banking.PlaidItem`. The `access_token` attribute must stay inside `cloak do ... end`.
- **NEVER** load `plaid_item.access_token` for bulk UI or broad `Ash.read!` lists. Load and use it only in the three code paths that perform Plaid API calls:
  1. **Sync pipeline** — `FinanceSmith.DataLake.SyncWorker` and its helper `FinanceSmith.Banking.BalanceRefresh`. `BalanceRefresh.run/1` receives an already-loaded struct; it never performs its own `access_token` read.
  2. **Item creation** — `FinanceSmith.Banking.PlaidItem.Changes.ExchangePublicToken`, which loads the token immediately after the `PlaidItem` is persisted in order to call Plaid `accounts/get` and seed `Account` rows. This single-record load inside an `after_action` hook is intentional and acceptable.
  3. **Actor-authorized balance refresh** — `FinanceSmith.Banking.PlaidItem.Changes.FetchRealtimeBalances`, invoked by the `:fetch_realtime_balances` action. The `authorize?: false` scope is **strictly limited** to a single `Ash.read_one!/2` that loads only `:access_token` and `:accounts` for the network request inside `before_action`. It never escapes into the UI read layer, and the calling LiveView (`AccountLive`) receives no token-bearing struct in response.
- **Prefer UI-safe code interfaces:** For LiveViews and any non-system read path, use `FinanceSmith.Banking.get_plaid_item_summary_by_id/1` (action `:read_for_ui`) or `list_active_plaid_items/0` (action `:list_active`), both of which exclude `access_token`. The interface `get_plaid_item_by_id/1` uses the primary `:read` action and can decrypt the token — only use it in system/test contexts.
- **NEVER** change the vault cipher away from AES-GCM without a documented key rotation and migration plan.
- **NEVER** mark `access_token` as `sensitive?: false` or expose it in HTTP responses or logs.
- New application-managed secrets (e.g. a future provider token) should use **AshCloak + `FinanceSmith.Vault`**, following the same pattern as `PlaidItem.access_token` or `User` MFA fields.

---

## Agent rules: dependencies

- **NEVER** add dependencies with known CVEs to `mix.exs`.
- **NEVER** pin to a version more than one major behind current stable without a documented reason.
- Before adding a dependency that touches secrets, cryptography, or network I/O, review changelog and security advisories.

---

## Authorization posture (current code)

- **`FinanceSmith.Identity.User`** uses `Ash.Policy.Authorizer` with explicit policies and documented bypasses for registration, sign-in, and internal lockout actions.
- **`FinanceSmith.Banking.PlaidItem`**, **`FinanceSmith.Banking.Account`**, and **`FinanceSmith.Banking.Transaction`** declare `Ash.Policy.Authorizer`. Reads are authorized for the actor via a two-branch expression:
  1. **Personal ownership:** `user_id == ^actor(:id)` (direct on `PlaidItem`, via relationship path for `Account` and `Transaction`).
  2. **Household membership:** `^actor(:household_id)` matches the owning user's `household_id`, allowing all members of the same household to read each other's Plaid items, accounts, and transactions.
  Writes are system-only and are `forbid_if always()` at the policy layer; Oban workers perform writes with `authorize?: false`. The sole user-facing write is `PlaidItem.create_from_public_token`, which requires an actor to be present.
- **`FinanceSmith.Identity.Household`** declares `Ash.Policy.Authorizer`. Reads are restricted to the actor whose `household_id` matches the record's `id`. All write actions are `forbid_if always()` at the policy layer; household creation is system-only via `authorize?: false` in registration logic.
- **`authorize?: false`** is used intentionally for Oban workers (`SyncWorker`, `TransactionProcessor`), session/user resolution, and some internal change modules. **Do not** add new `authorize?: false` on **user-facing** LiveView or controller paths without explicit security review. New system-only paths should be commented as such.
- **Household read-sharing scope:** All members of a household can read all banking data belonging to any member of that household. This is intentional: Finance Smith is a single-household application and household members are trusted. If a multi-household deployment model is ever needed, add Ash multitenancy and re-scope policies.

---

## Webhooks and untrusted HTTP inputs

- There is **no** Plaid (or similar) **ingestion** webhook route today; sync is on-demand via Oban.
- **Before** adding any **public** HTTP endpoint that accepts payloads from an external provider (Plaid, B2 event notifications, etc.), implement the cryptographic verification described under `[PLANNED]` in `SECURITY.md` for that integration. Do not deploy an unverified endpoint that enqueues background work.

---

## Implementation index (quick pointers)

| Concern | Location |
|---------|----------|
| Cloak vault | [`lib/finance_smith/vault.ex`](lib/finance_smith/vault.ex) |
| Plaid token encryption | [`lib/finance_smith/banking/plaid_item.ex`](lib/finance_smith/banking/plaid_item.ex) |
| MFA fields encryption | [`lib/finance_smith/identity/user.ex`](lib/finance_smith/identity/user.ex) |
| Prod secret enforcement + `PLAID_ENV` branching | [`config/runtime.exs`](config/runtime.exs) |
| Dev/test env + optional B2 | [`config/dev.exs`](config/dev.exs), [`config/test.exs`](config/test.exs) |
| Transaction sync + token use | [`lib/finance_smith/data_lake/sync_worker.ex`](lib/finance_smith/data_lake/sync_worker.ex) |
| Real-time balance refresh (shared) | [`lib/finance_smith/banking/balance_refresh.ex`](lib/finance_smith/banking/balance_refresh.ex) |
| Item creation + accounts bootstrap (token use) | [`lib/finance_smith/banking/plaid_item/changes/exchange_public_token.ex`](lib/finance_smith/banking/plaid_item/changes/exchange_public_token.ex) |
| Actor-authorized UI balance refresh (token use) | [`lib/finance_smith/banking/plaid_item/changes/fetch_realtime_balances.ex`](lib/finance_smith/banking/plaid_item/changes/fetch_realtime_balances.ex) |
| B2 upload (SHA-1 header) | [`lib/finance_smith/data_lake/b2.ex`](lib/finance_smith/data_lake/b2.ex) |
| B2 auth token process | [`lib/finance_smith/data_lake/b2/auth_server.ex`](lib/finance_smith/data_lake/b2/auth_server.ex) |

---

## Agent directives (summary)

1. Never hardcode secrets, tokens, or credentials in any source file.
2. Never log or `IO.inspect` sensitive values: `access_token`, `CLOAK_KEY`, `SANDBOX_PLAID_SECRET`, `PRODUCTION_PLAID_SECRET`, `B2_APP_KEY`, or any decrypted value from `FinanceSmith.Vault`.
3. Always add new required secrets to `config/runtime.exs` (with startup `raise`) and `.env.example` (placeholder), and extend the table in `SECURITY.md`.
4. Never commit `.env`. Confirm `.gitignore` before staging secrets-adjacent files.
5. Never remove, bypass, or weaken AshCloak encryption on `PlaidItem.access_token`.
6. Never load `access_token` in bulk reads for UI. Acceptable load sites: (a) `SyncWorker` (struct passed to `BalanceRefresh`) for ongoing sync, (b) `ExchangePublicToken` immediately after item creation to call Plaid `accounts/get`, and (c) `FetchRealtimeBalances` — a tightly scoped single-record load inside `before_action` for the actor-authorized UI balance refresh. All three sites are documented; any new site requires explicit review.
7. When adding new secrets managed by the app, use AshCloak + Vault like existing tokens.
8. Do not add `authorize?: false` to **new** user-facing production paths without review. Workers and session/bootstrap code may continue to use it where already established.
9. When adding or changing Ash policies, avoid a blanket `authorize_if always()` on sensitive actions without an explicit constraint (documented bypasses for unauthenticated actions such as `:register` / `:sign_in` are acceptable).
10. Before adding a public provider webhook or callback, implement signature/JWT verification per `SECURITY.md`; never ship unverified enqueue endpoints.
11. Run `mix audit` (alias for `mix deps.audit`) before committing changes to `mix.exs`. The `mix_audit` package is a dev dependency — run `mix deps.get` first if it is not yet compiled.
12. Never add crypto or hashing dependencies unless they are well-audited libraries (e.g. `bcrypt_elixir`, `argon2_elixir`, `cloak`). Do not implement custom crypto.
