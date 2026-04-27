# syntax=docker/dockerfile:1.7
#
# Multi-stage build for Finance Smith.
#
# Stage 1 (build): compiles deps, builds frontend assets, and assembles the
#                  Elixir release.
# Stage 2 (runner): minimal debian-slim image containing the release, SOPS,
#                   and Age. Secrets are injected at runtime via Docker Secrets
#                   + sops exec-env; the decryption key (age.key) is never
#                   baked into the image.
#
# Prerequisites before running `docker compose build`:
#   - secrets.enc.env must exist at the project root (SOPS-encrypted).
#   - Use bin/docker-build.sh for a friendly pre-flight check.
#   - See docs/infrastructure.md "Container deployment with SOPS".

# --------------------------------------------------------------------------
# Stage 1: build
# --------------------------------------------------------------------------
ARG ELIXIR_VERSION=1.19.0
ARG OTP_VERSION=27.1.2
ARG DEBIAN_VERSION=bookworm-20240926-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git curl ca-certificates nodejs npm \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# Fetch and compile dependencies first (separate layer for cache efficiency)
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

# Build frontend assets
COPY assets assets
RUN npm --prefix assets ci

# Compile app and build release
COPY priv priv
COPY lib lib
COPY rel rel
RUN mix assets.deploy
RUN mix compile
RUN mix release

# --------------------------------------------------------------------------
# Stage 2: runner
# --------------------------------------------------------------------------
FROM debian:bookworm-slim AS runner

ARG TARGETARCH
ARG SOPS_VERSION=3.9.1
ARG AGE_VERSION=1.2.0

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates libstdc++6 libncurses6 locales openssl tini curl \
    && rm -rf /var/lib/apt/lists/*

# sops — static Go binary, architecture-aware
RUN curl -fSL \
      "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${TARGETARCH}" \
      -o /usr/local/bin/sops \
    && chmod +x /usr/local/bin/sops

# age — tarball, architecture-aware
RUN curl -fSL \
      "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${TARGETARCH}.tar.gz" \
      | tar -xz -C /tmp \
    && mv /tmp/age/age /tmp/age/age-keygen /usr/local/bin/ \
    && rm -rf /tmp/age

RUN useradd --create-home --uid 1001 app

WORKDIR /app

# Copy the release tree from the build stage.
# rel/overlays/entrypoint.sh lands at the release root: /app/entrypoint.sh
COPY --from=build --chown=app:app /app/_build/prod/rel/finance_smith ./

# Copy the SOPS-encrypted secrets file (committed; decryption key is never
# baked in — it is mounted at runtime via Docker Secrets).
COPY --chown=app:app secrets.enc.env /app/secrets.enc.env

USER app

EXPOSE 4000

ENTRYPOINT ["/app/entrypoint.sh"]
