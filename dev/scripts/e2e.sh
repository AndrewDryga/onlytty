#!/usr/bin/env bash
# End-to-end: start a fresh relay, run the tagged Go e2e test + the browser tests,
# tear the relay down. Used by `make e2e`.
#
# By default we ALWAYS start our own relay so a stale server left running on the port
# can't make a changed tree look green. Set ONLYTTY_REUSE_SERVER=1 to instead reuse a
# relay that's already up (e.g. an ngrok-exposed dev server for a manual phone pass).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="${ONLYTTY_SERVER:-http://127.0.0.1:4000}"
HEALTH="$BASE/healthz"

started=""
cleanup() {
  if [ -n "$started" ]; then
    kill "$started" 2>/dev/null || true
    wait "$started" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ "${ONLYTTY_REUSE_SERVER:-}" = "1" ]; then
  if curl -fsS "$HEALTH" >/dev/null 2>&1; then
    echo "e2e: reusing relay at $BASE (ONLYTTY_REUSE_SERVER=1)"
  else
    echo "e2e: ONLYTTY_REUSE_SERVER=1 but no relay is answering at $BASE"; exit 1
  fi
else
  # Refuse to silently reuse a server we didn't start — that's the stale-green trap.
  if curl -fsS "$HEALTH" >/dev/null 2>&1; then
    echo "e2e: a server is already running at $BASE — stop it, or set ONLYTTY_REUSE_SERVER=1 to use it"; exit 1
  fi
  # Compile up front, OUTSIDE the readiness window below. A cold CI build (no _build
  # cache) takes longer than the health-wait, which would otherwise look like the relay
  # "never came up"; doing it here also surfaces a real compile error as a compile error.
  echo "e2e: compiling relay…"
  if ! ( cd "$ROOT/portal" && mix deps.get && mix compile ) >/tmp/relay-e2e-server.log 2>&1; then
    echo "e2e: relay failed to compile — log:"; tail -30 /tmp/relay-e2e-server.log; exit 1
  fi
  echo "e2e: starting relay…"
  # ONLYTTY_RATELIMIT_MAX=0 (= :infinity) — the per-IP throttle guards POST /api/sessions
  # AND both WebSocket upgrades, defaulting to 30 per 60s. The whole browser suite is one
  # client IP making 22 sessions' worth of creates, runner upgrades and viewer reconnects
  # in well under a minute, so it trips the limit partway through and the relay 429s the
  # runner's upgrade — the runner never attaches, the viewer sits at "waiting for runner…",
  # and whichever tests land in that window time out. Anti-abuse limits key on client IP;
  # a local harness is inherently one client, so it must opt out or it is nondeterministic.
  # The throttle itself stays covered by rate_limit_test.exs + onlytty_socket_test.exs.
  ( cd "$ROOT/portal" && ONLYTTY_RATELIMIT_MAX=0 exec mix phx.server ) >>/tmp/relay-e2e-server.log 2>&1 &
  started=$!
  for i in $(seq 1 60); do
    if curl -fsS "$HEALTH" >/dev/null 2>&1; then break; fi
    if ! kill -0 "$started" 2>/dev/null; then
      echo "e2e: relay failed to start — log:"; tail -30 /tmp/relay-e2e-server.log; exit 1
    fi
    sleep 0.5
  done
  if ! curl -fsS "$HEALTH" >/dev/null 2>&1; then
    echo "e2e: relay did not become healthy — log:"; tail -30 /tmp/relay-e2e-server.log; exit 1
  fi
  echo "e2e: relay healthy at $BASE"
fi

cd "$ROOT"
echo "e2e: building the runner…"
go build -o onlytty ./runner/cmd/onlytty
echo "e2e: transport (Go viewer ↔ relay ↔ runner)…"
ONLYTTY_SERVER="$BASE" go test -tags e2e -count=1 ./runner/e2e/
echo "e2e: browser (headless Chromium drives the real viewer)…"
ONLYTTY_SERVER="$BASE" node --test dev/test/browser/*.test.js
