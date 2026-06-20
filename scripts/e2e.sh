#!/usr/bin/env bash
# End-to-end: boot the relay (unless one is already up), run the tagged Go e2e test,
# tear the relay down. Used by `make e2e`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

if curl -fsS "$HEALTH" >/dev/null 2>&1; then
  echo "e2e: reusing relay already running at $BASE"
else
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
ONLYTTY_SERVER="$BASE" node --test test/browser/*.test.js
