#!/bin/bash
# Production entrypoint for the Finance Smith release.
#
# SOPS decrypts secrets.enc.env and injects env vars into the child process
# environment. The age decryption key is mounted via Docker Secrets at
# /run/secrets/age_key and is never baked into the image.
#
# Sequence:
#   1. Run pending Ecto migrations (synchronous — exits on failure, which
#      prevents a half-migrated app from starting).
#   2. exec into the release start command, making the BEAM PID 1 so the
#      container runtime can deliver SIGTERM for graceful shutdown.
set -euo pipefail

export SOPS_AGE_KEY_FILE="/run/secrets/age_key"

# Step 1: migrate (not exec — must return so step 2 runs)
sops exec-env /app/secrets.enc.env "/app/bin/finance_smith eval 'FinanceSmith.Release.migrate()'"

# Step 2: start (exec hands PID 1 to sops -> BEAM)
exec sops exec-env /app/secrets.enc.env "/app/bin/finance_smith start"
