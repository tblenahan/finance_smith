# Finance Smith

## Project Purpose
Finance Smith is a centralized, self-hosted service designed to aggregate, normalize, and visualize personal financial data. By pulling data from various banking and credit institutions into a single source of truth, it provides complete ownership over personal financial records and enables deep, flexible insights into spending and saving habits.

## Tech Stack
* **Language:** Elixir
* **Framework:** [Ash Framework](https://ash-hq.org/) (for declarative, resource-backed domain modeling)
* **Database:** PostgreSQL (Dockerized)
* **Data Ingestion:** Plaid / SimpleFIN APIs
* **AI Development Support:** `usage_rules` (Elixir library)

## Functional Requirements
* **Data Ingestion & ETL:** Automated background jobs to fetch, transform, and load transaction data from external providers (Plaid/SimpleFIN) into the local database.
* **Data Normalization:** Clean and standardize transaction records across disparate financial institutions.
* **User Interface:** A user-friendly front-end providing comprehensive table views of financial data.
* **Dynamic Filtering & Grouping:** Ability to view and sort data by:
    * Bank / Credit Provider
    * Account Type (Checking, Credit, Retirement, etc.)
    * Timeframes (Hour, Day, Month, Year)

## Non-Functional & Future Requirements
* **Analytics-Ready Architecture:** The database schema and domain logic are structured to easily correlate and aggregate transactions, laying the groundwork for future data science and predictive analytics features.
* **Containerized Data Layer:** PostgreSQL must run reliably within a Docker container for easy local development and deployment.

## Database Schema

See [priv/repo/README.md](priv/repo/README.md) for the full entity-relationship diagram, index summary, and cascade rules.

## Getting Started

### Prerequisites
* [Elixir](https://elixir-lang.org/install.html)
* [Docker](https://docs.docker.com/get-docker/) & Docker Compose
* API keys for Plaid or SimpleFIN (depending on configured ingestion strategy)

### Local Development Setup

**1. Configure your environment**

```bash
cp .env.example .env
```

Edit `.env` if you need to change any defaults (e.g. different port or credentials).

**2. Start the database**

```bash
docker compose up -d
```

This starts a PostgreSQL 17 container. The test database (`finance_smith_test`) is
created automatically by `docker/scripts/init-test-db.sh` on the first run.

**3. Create the database schema and run migrations**

```bash
mix ash.setup
```

**4. (Optional) Enable pre-commit format check**

To block commits when code is not formatted, point git at the repo’s hooks:

```bash
git config core.hooksPath .githooks
```

After that, every commit runs `mix format --check-formatted`; if it fails, fix with
`mix format` and try again.

**5. (Optional) Launch Adminer for a database UI**

```bash
docker compose --profile debug up -d
```

Adminer will be available at [http://localhost:8080](http://localhost:8080).

**6. (Optional) Run Cloudflare Tunnel via Compose**

Set `CLOUDFLARE_TUNNEL_TOKEN` in `.env`, then:

```bash
docker compose --profile tunnel up -d
```

Plain `docker compose up` starts only PostgreSQL — the tunnel daemon is opt-in and matches the `debug` profile pattern used for Adminer.

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
