# syntax=docker/dockerfile:1
# OnlyTTY relay server — Elixir release image (multi-stage).
#
# Debian (not Alpine): musl's resolver breaks the BEAM's DNS in production. Built from
# the hexpm prebuilt Elixir/Erlang/Debian image; the final image carries only the
# compiled release plus minimal runtime libraries and a tini init.
#
# Refresh cadence: bump the version ARGs each release (and at least monthly) so the base
# OS picks up security updates — see SECURITY.md "Base-image refresh". Dependabot
# (.github/dependabot.yml) opens PRs for the resolvable image refs; the bare version ARGs
# are bumped by hand, in lockstep with .tool-versions / CI.
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.2
ARG DEBIAN_VERSION=bookworm-20260623-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ── Build the release ────────────────────────────────────────────────────────
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y --no-install-recommends build-essential git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV="prod"

# Fetch deps in their own layer (cached until mix.lock changes); a BuildKit cache keeps
# the hex/rebar download cache warm across rebuilds.
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.cache/rebar3 \
    mix deps.get --only $MIX_ENV

RUN mkdir config
# Compile-time config first, so a change here re-compiles deps; runtime.exs comes later.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
RUN mix compile

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ── Runtime ──────────────────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE}

# Minimal runtime libs the BEAM needs, plus tini. tini is PID 1 to reap zombies: the
# release boot script is a shell wrapper that does not reap, so a short-lived child
# (e.g. the rpc healthcheck) would otherwise leak. ca-certificates for outbound TLS.
RUN apt-get update -y && apt-get install -y --no-install-recommends \
      libstdc++6 libncurses6 openssl ca-certificates tini \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 LANGUAGE=C.UTF-8 LC_ALL=C.UTF-8 MIX_ENV="prod"

# Non-root with an explicit uid (clearer than `nobody` for k8s/MIG); the app dir is
# owned by it so the release can write its tmp/.
RUN useradd --create-home --uid 1001 --user-group --shell /bin/sh app
WORKDIR /app
COPY --from=builder --chown=1001:0 /app/_build/${MIX_ENV}/rel/onlytty ./
USER 1001

# BEAM-native liveness: the running node answers RPC and its HTTP endpoint is
# supervised — no curl in the image. (In prod the GCP load balancer runs the real
# GET /healthz check; this HEALTHCHECK is for `docker run`/compose.)
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
  CMD ["/app/bin/onlytty", "rpc", "Process.whereis(OnlyTTYWeb.Endpoint) || raise \"endpoint not running\""]

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/server"]
