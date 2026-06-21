#!/usr/bin/env bash
# Soak: drive N concurrent full runner↔viewer sessions through the relay with
# reconnect storms, and report throughput, the session-cap behavior, and the
# relay's RSS over the run. Boots a relay if one isn't already up. Used by
# `make soak`. Override with: N=50 DURATION=60s make soak
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="${ONLYTTY_SERVER:-http://127.0.0.1:4000}"
N="${N:-30}"
DURATION="${DURATION:-30s}"
CHURN="${CHURN:-5s}"

started=""
cleanup() {
  if [ -n "$started" ]; then
    kill "$started" 2>/dev/null || true
    wait "$started" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then
  echo "soak: reusing relay already running at $BASE"
else
  echo "soak: starting relay…"
  ( cd "$ROOT/portal" && mix deps.get >/dev/null 2>&1 && exec mix phx.server ) >/tmp/relay-soak-server.log 2>&1 &
  started=$!
  for _ in $(seq 1 60); do
    curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
    if ! kill -0 "$started" 2>/dev/null; then
      echo "soak: relay failed to start — log:"; tail -30 /tmp/relay-soak-server.log; exit 1
    fi
    sleep 0.5
  done
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 || { echo "soak: relay did not become healthy"; exit 1; }
  echo "soak: relay healthy at $BASE"
fi

cd "$ROOT"
ONLYTTY_SERVER="$BASE" go run ./runner/cmd/soak -n "$N" -duration "$DURATION" -churn "$CHURN"
