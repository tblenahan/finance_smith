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

*(Instructions for setting up the local development environment will be added here as the project progresses.)*

### Prerequisites
* [Elixir](https://elixir-lang.org/install.html)
* [Docker](https://docs.docker.com/get-docker/) & Docker Compose
* API keys for Plaid or SimpleFIN (depending on configured ingestion strategy)
