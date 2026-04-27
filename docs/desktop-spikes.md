# Desktop / native packaging spike notes

This document isolates the **runtime contract** that any future packaging approach (single
binary, desktop app, Tauri shell, OS service installer) must honour. The current production
delivery mechanism is a Docker container with SOPS-injected secrets; this doc exists
specifically so that Docker-first architecture decisions do not accidentally foreclose
native-app options.

---

## Purpose

Finance Smith is fundamentally a **self-hosted, single-household application**. Docker
Compose is the current deployment story, but the long-term product vision includes a
first-class desktop or native-packaged experience. Before that work begins in earnest,
every packaging spike must answer: "does this approach satisfy the environment contract
below?"

---

## Environment contract

These are the variables read at runtime. Any packaging strategy that does not use SOPS
must replace the source column with an equivalent secret-management mechanism.

| Variable | Required in prod? | Source (today) | Notes for desktop spike |
|---|---|---|---|
| `SECRET_KEY_BASE` | **Yes** | `secrets.enc.env` | Phoenix session signing. On desktop, could be derived from an OS-keychain-stored seed or generated on first launch and stored in the OS keychain. |
| `DATABASE_URL` | **Yes** | `secrets.enc.env` | In a desktop build, could become `ecto://postgres:postgres@127.0.0.1/finance_smith` pointed at a bundled or user-managed Postgres, or replaced entirely with an embedded data layer. |
| `CLOAK_KEY` | **Yes** | `secrets.enc.env` | AES-256-GCM key for `AshCloak` (`PlaidItem.access_token`, MFA fields). Must persist across restarts. OS keychain (`libsecret` / macOS Keychain / DPAPI) is the natural replacement. |
| `PLAID_CLIENT_ID` | **Yes** | `secrets.enc.env` | Could be baked into a desktop build as a compile-time constant (not a secret per se) — confirm with Plaid ToS. |
| `PRODUCTION_PLAID_SECRET` | Yes (default) | `secrets.enc.env` | Must stay secret; OS keychain required. |
| `SANDBOX_PLAID_SECRET` | Yes if `PLAID_ENV=sandbox` | `secrets.enc.env` | Same as above. |
| `PLAID_ENV` | No (default `production`) | `secrets.enc.env` | Could be a compile-time or user-settings value. |
| `B2_KEY_ID` | **Yes** | `secrets.enc.env` | B2 archive is optional in dev but required in prod `runtime.exs`. May be downgraded to optional for desktop. |
| `B2_APP_KEY` | **Yes** | `secrets.enc.env` | Same. |
| `B2_BUCKET_NAME` | **Yes** | `secrets.enc.env` | Same. |
| `PHX_HOST` | No (default `localhost`) | env / compose | For a desktop app serving on `localhost`, the default is correct. |
| `PORT` | No (default `4000`) | env / compose | Desktop could pick a random free port and open `http://localhost:<PORT>` in the system browser. |
| `POOL_SIZE` | No (default `10`) | env / compose | Reduce to 2–3 for a single-user desktop profile. |
| `LOG_DIR` | No (default `logs`) | env / compose | Desktop: `~/.local/share/finance_smith/logs` or platform equivalent. |

---

## Process model

The release is an **Erlang/OTP release** built with `mix release`. Key constraints that any
packaging must preserve:

1. **PID 1 signal forwarding** — the process that boots the BEAM must `exec` into it (or
   use `tini`/a proper init) so `SIGTERM` triggers graceful shutdown. In containers, the
   current `entrypoint.sh` uses `exec sops exec-env … bin/finance_smith start`. On a
   desktop, a launchd / systemd / Windows Service / Swift `Process` wrapper must do the
   equivalent.

2. **Migrations before start** — `FinanceSmith.Release.migrate/0` is called in the
   entrypoint before the supervision tree starts. Any packaging must run this on every
   launch (or gate it with a schema-version check) to ensure Ecto migrations are current.

3. **Secret material loaded once at startup** — `runtime.exs` reads env vars at VM boot,
   not lazily. Secrets must be present in the process environment *before* `bin/finance_smith
   start` is called. SOPS does this today; the OS keychain alternative must export variables
   into the process env before exec-ing the release.

4. **Stateless image, stateful data** — today, Postgres data lives in the `postgres_data`
   Docker volume. On a desktop, this maps to a known directory the user owns (e.g.
   `~/.local/share/finance_smith/postgres/`).

---

## Open questions / spike candidates

| Topic | Question | Candidate approaches |
|---|---|---|
| **Single-binary distribution** | Can we ship a self-contained `finance_smith` executable? | [`Bakeware`](https://github.com/bake-bake-bake/bakeware) (appends ERTS + app to a shell script); [`Burrito`](https://github.com/burrito-elixir/burrito) (cross-compile with Zig, embeds ERTS) |
| **OS-level secret store** | Replace SOPS + Age with native secret management | macOS: `security` CLI / `SecKeychainItem` API; Linux: `libsecret` / `gnome-keyring`; Windows: `DPAPI` / Windows Credential Manager |
| **Embedded Postgres** | Bundle Postgres to remove the Docker/system Postgres dependency | [`postgrex`](https://github.com/elixir-ecto/postgrex) still needs a server process; consider [`pg_embed`](https://github.com/faokunega/pg-embed) (Rust/Nif), or ship a pre-built Postgres binary alongside the release |
| **Alternative data layer** | Use SQLite to remove Postgres entirely | Requires porting Ash resources + migrations to `AshSqlite`; significant effort; trade-off: no Plaid JSON GIN indexes, no `TIMESTAMPTZ` native type |
| **Desktop shell** | Wrap the Phoenix app in a native window | Tauri (Rust + WebView), Electron (heavier), or simply open the system browser to `localhost:PORT` on launch |
| **Auto-update** | Deliver new releases to desktop users | `Bakeware`/`Burrito` + a release server; Tauri's built-in updater |

---

## Non-goals for this document

- No implementation. This is a **placeholder** to anchor future spike branches and prevent
  the current Docker containerisation work from being treated as a permanent constraint.
- No timeline. Desktop packaging is deferred until after the core product features are
  complete (SimpleFIN, time-grain aggregation, custom categories).
- No changes to Ash domains, UI, or the SOPS/Docker path described in
  [`docs/infrastructure.md`](infrastructure.md).
