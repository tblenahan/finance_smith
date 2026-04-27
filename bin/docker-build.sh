#!/usr/bin/env bash
# Build the Finance Smith Docker image via docker compose.
#
# Pre-flight: verifies that secrets.enc.env exists at the project root before
# invoking docker compose build. The Dockerfile COPYs this file into the image,
# so a missing file produces a confusing low-level Docker error without this check.
#
# Usage:
#   bin/docker-build.sh              # builds the app service
#   bin/docker-build.sh --no-cache   # forces a full rebuild
#   bin/docker-build.sh --push       # build + push (requires registry config)
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f secrets.enc.env ]; then
  cat >&2 <<'MSG'
error: secrets.enc.env is missing from the project root.

This is the SOPS-encrypted env file baked into the image. It must exist before
running docker compose build. To create it:

  1. Generate an Age key:
       age-keygen -o age.key && chmod 600 age.key

  2. Copy the template and fill in values:
       cp secrets.enc.env.example secrets.dec.env
       $EDITOR secrets.dec.env

  3. Encrypt:
       sops -e --age "$(grep -oP 'public key: \K.*' age.key)" \
            secrets.dec.env > secrets.enc.env

  4. Shred the plaintext:
       shred -u secrets.dec.env

See docs/infrastructure.md "Container deployment with SOPS" for the full workflow.
MSG
  exit 1
fi

exec docker compose build app "$@"
