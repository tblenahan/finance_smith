# Database Schema

## Entity-Relationship Diagram

```mermaid
erDiagram
    households ||--o{ users : "has many"
    users ||--o{ plaid_items : "has many"
    plaid_items ||--o{ accounts : "has many"
    accounts ||--o{ transactions : "has many"
    accounts }o--o| accounts : "duplicate of"

    households {
        uuid id PK
        text name
        timestamp inserted_at
        timestamp updated_at
    }

    users {
        uuid id PK
        uuid household_id FK
        text email UK
        text password_hash
        timestamp inserted_at
        timestamp updated_at
    }

    plaid_items {
        uuid id PK
        uuid user_id FK
        text plaid_item_id UK
        binary encrypted_access_token
        text institution_name
        text next_cursor
        text status "active | error | disconnected"
        timestamp inserted_at
        timestamp updated_at
    }

    accounts {
        uuid id PK
        uuid plaid_item_id FK
        text plaid_account_id UK
        text name
        text mask
        text type
        text subtype
        bigint current_balance "integer cents"
        text status "active | quarantined | hidden"
        uuid duplicate_of_id FK "self-ref, nullable"
        timestamp inserted_at
        timestamp updated_at
    }

    transactions {
        uuid id PK
        uuid account_id FK
        text plaid_transaction_id UK "composite with date"
        bigint amount "integer cents"
        date date "NOT NULL, partition-ready"
        text merchant_name
        text_array category
        boolean is_pending
        timestamp inserted_at
        timestamp updated_at
    }
```

## Domain Organization

| Ash Domain | Resource | Table |
|---|---|---|
| `FinanceSmith.Identity` | Household | `households` |
| `FinanceSmith.Identity` | User | `users` |
| `FinanceSmith.Banking` | PlaidItem | `plaid_items` |
| `FinanceSmith.Banking` | Account | `accounts` |
| `FinanceSmith.Banking` | Transaction | `transactions` |

## Foreign Key Cascade Rules

| FK Column | On Delete | Rationale |
|---|---|---|
| `users.household_id` | RESTRICT | Must explicitly remove users before deleting a household |
| `plaid_items.user_id` | CASCADE | Deleting a user removes all their Plaid connections |
| `accounts.plaid_item_id` | CASCADE | Revoking a Plaid item removes its accounts |
| `accounts.duplicate_of_id` | SET NULL | Removing the primary account clears the link |
| `transactions.account_id` | CASCADE | Transactions live and die with their account |

## Index Summary

| Table | Index | Type | Purpose |
|---|---|---|---|
| `users` | `email` | unique | Identity lookup |
| `users` | `household_id` | btree | FK join performance |
| `plaid_items` | `plaid_item_id` | unique | Identity lookup |
| `plaid_items` | `user_id` | btree | FK join performance |
| `accounts` | `plaid_account_id` | unique | Identity lookup |
| `accounts` | `plaid_item_id` | btree | FK join performance |
| `accounts` | `duplicate_of_id` | btree | FK join performance |
| `accounts` | `(plaid_item_id, status)` | composite | ETL quarantine queries |
| `transactions` | `(plaid_transaction_id, date)` | unique | Identity lookup, partition-ready |
| `transactions` | `account_id` | btree | FK join performance |
| `transactions` | `(account_id, date)` | composite | Date-range analytics |
| `transactions` | `account_id WHERE is_pending` | partial | Sync reconciliation |

## Encryption

The `plaid_items.access_token` field is encrypted at rest using AshCloak + Cloak (AES-256-GCM). The plaintext attribute `access_token` is transparently encrypted/decrypted; the database stores only the `encrypted_access_token` binary column. The encryption key is read from the `CLOAK_KEY` environment variable.

## Partition Readiness

The `transactions` table is structured for future range partitioning by `date`:
- `date` is NOT NULL (required for a partition key)
- The unique constraint includes `date` (required by PostgreSQL for partitioned unique indexes)
- No partitioning is active yet; it can be enabled via `create_table_options: "PARTITION BY RANGE (date)"` when volume warrants it
