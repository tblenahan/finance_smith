#!/bin/bash
# Creates the test database on first container initialization.
# Runs automatically via docker-entrypoint-initdb.d — only executes
# when the data directory is empty (i.e. on a fresh volume).
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE "$POSTGRES_TEST_DB";
EOSQL
