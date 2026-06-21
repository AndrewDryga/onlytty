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
  echo "e2e: starting relay…"
  ( cd "$ROOT/portal" && mix deps.get >/dev/null 2>&1 && exec mix phx.server ) >/tmp/relay-e2e-server.log 2>&1 &
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
go build -o onlytty ./runner
echo "e2e: transport (Go viewer ↔ relay ↔ runner)…"
ONLYTTY_SERVER="$BASE" go test -tags e2e -count=1 ./runner/e2e/
echo "e2e: browser (headless Chromium drives the real viewer)…"
ONLYTTY_SERVER="$BASE" node --test dev/test/browser/*.test.js
