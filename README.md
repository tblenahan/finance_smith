# Finance Smith

## Project Purpose
Finance Smith is a centralized, self-hosted household financial dashboard. It aggregates and normalizes personal transaction data from external providers (currently Plaid) into a self-managed PostgreSQL database, exposes a data-dense Phoenix LiveView UI with filtering, sorting, and chart-based insights, and archives raw payloads to Backblaze B2 for replay and long-term retention.

## Tech Stack
* **Language:** Elixir (~> 1.19)
* **Framework:** [Ash Framework](https://ash-hq.org/) — declarative, resource-backed domain modeling
* **Web:** Phoenix LiveView, [PetalComponents](https://petal.build/), Tailwind CSS
* **Database:** PostgreSQL 17 (Dockerized)
* **Data Ingestion:** Plaid API (via `plaid_elixir`)
* **Background Jobs:** Oban — periodic and on-demand Plaid sync
* **Archive:** Backblaze B2 (optional; gracefully degraded in dev)
* **AI Development Support:** `usage_rules`

## Functional Requirements

### Implemented today
* **Plaid Link & OAuth:** Connect institutions via Plaid Link; exchange public tokens and seed accounts in one flow.
* **Transaction sync:** Cursor-based Plaid `/transactions/sync` via Oban workers, on-connect and every 30 minutes (cron). Raw JSON optionally archived to B2 before processing.
* **Dashboard:** KPI tiles (net worth, assets/liabilities, 30-day inflow/outflow), scope selector (household / personal / per institution), ECharts cashflow and outflow-categories charts with timeframe tabs (1W, 1M, 3M, 6M, 9M, 1Y, All).
* **Transaction ledger:** Keyset-paginated table with date-range, Plaid PFC category, merchant search filters, column sort, and URL query-param state — shared across Dashboard, Connection, and Account drill-down views.
* **Authentication:** Registration (with household join flow), bcrypt passwords, optional TOTP MFA, 5-attempt lockout.
* **Authorization:** Ash policies on all resources; household-scoped reads so all household members share banking data.

### Planned
* **SimpleFIN ingestion** — no client module yet; Plaid only for now.
* **Plaid webhook support** — sync is currently on-demand/cron only; no verified inbound webhook endpoint.
* **Custom categories** — ledger uses Plaid PFC labels only; user-defined categories not yet implemented.
* **Time-grain grouping** — no weekly/monthly aggregation tables in the UI yet; charts approximate this.
* **B2 purge on disconnect** — database cascades exist; object-store cleanup for `plaid_sync/…` is not automated.

## Database Schema

See [priv/repo/REPO_README.md](priv/repo/REPO_README.md) for the full entity-relationship diagram, index summary, and cascade rules.

## Getting Started

### Prerequisites
* [Elixir](https://elixir-lang.org/install.html) ~> 1.19
* [Docker](https://docs.docker.com/get-docker/) & Docker Compose
* API keys for Plaid (Sandbox for local dev — see [`.env.example`](.env.example))

### Local Development Setup

**1. Configure your environment**

```bash
cp .env.example .env
```

Edit `.env` and fill in at minimum `CLOAK_KEY`, `CLOAK_KEY_TEST`, `SECRET_KEY_BASE`, `SECRET_KEY_BASE_TEST`, `PLAID_CLIENT_ID`, and `SANDBOX_PLAID_SECRET`. See `.env.example` for generation instructions. For production/staging deploys, set `PLAID_ENV=sandbox` to target the Plaid Sandbox instead of the live API — see `.env.example` and [SECURITY.md](SECURITY.md) for details.

**2. Start the database**

```bash
docker compose up -d
```

This starts a PostgreSQL 17 container. The test database (`finance_smith_test`) is
created automatically by `docker/scripts/init-test-db.sh` on the first run.

**3. Install frontend dependencies**

```bash
cd assets && npm install && cd ..
```

**4. Create the database schema and run migrations**

```bash
mix ash.setup
```

**5. Start the server**

```bash
mix phx.server
```

The application is now available at [http://localhost:4000](http://localhost:4000). Register an account, connect a Plaid institution, and transactions will sync automatically.

**6. (Optional) Enable pre-commit format check**

To block commits when code is not formatted, point git at the repo's hooks:

```bash
git config core.hooksPath .githooks
```

After that, every commit runs `mix format --check-formatted`; if it fails, fix with
`mix format` and try again.

**7. (Optional) Launch Adminer for a database UI**

```bash
docker compose --profile debug up -d
```

Adminer will be available at [http://localhost:8080](http://localhost:8080). In the login screen, use server **127.0.0.1**, port **5432**, and the same database user/password as in `.env` (Adminer uses host networking like the Postgres service so it reaches Postgres on localhost).

**8. (Optional) Run Cloudflare Tunnel via Compose**

Set `CLOUDFLARE_TUNNEL_TOKEN` in `.env`, then:

```bash
docker compose --profile tunnel up -d
```

Plain `docker compose up` starts only PostgreSQL — the tunnel daemon is opt-in. Also set `PHX_HOST` in `.env` to your tunnel hostname so Phoenix generates correct redirect URIs for Plaid OAuth.

### Using an External / Managed Database

If you prefer to use a managed PostgreSQL instance instead of Docker, skip step 2 above
and set the following variables in your `.env` (or export them in your shell) before
running `mix ash.setup`:

```
POSTGRES_HOST=your-db-host
POSTGRES_PORT=5432
POSTGRES_USER=your-user
POSTGRES_PASSWORD=your-password
POSTGRES_DB=finance_smith_dev
POSTGRES_TEST_DB=finance_smith_test
```

No code changes are required — the application reads all connection settings from the
environment at startup.

## Related Docs

* [docs/infrastructure.md](docs/infrastructure.md) — OTP supervision, Ash domains, routing, Oban pipeline, deploy topology, and environment variable reference.
* [docs/service-state-report.md](docs/service-state-report.md) — current maturity, implemented features, and gap analysis.
* [SECURITY.md](SECURITY.md) — operator security policy: secrets, encryption, MFA, authorization, infrastructure.
* [AGENT_SECURITY.md](AGENT_SECURITY.md) — developer/agent guardrails: what never to do with secrets, Cloak, and policies.
