#!/usr/bin/env bash
# Concurrent session-create load against a running relay. Exercises the
# unauthenticated POST /api/sessions path (the DoS surface) and the
# ONLYTTY_MAX_SESSIONS cap, reporting a count per HTTP status.
#
#   ONLYTTY_SERVER=https://relay.example.com bash dev/scripts/load.sh [N] [CONCURRENCY]
#
# Deeper soak (WebSocket reconnect storms, memory-bounded long runs, and per-VM
# capacity numbers for deploy sizing) is a follow-up — see .agent/BACKLOG.md.
set -euo pipefail

SERVER="${ONLYTTY_SERVER:-http://127.0.0.1:4000}"
N="${1:-200}"
CONC="${2:-50}"

echo "load: $N session creates at concurrency $CONC against $SERVER"
echo "count  HTTP status"
# Each request claims a fresh random id + token (the runner generates these now), so
# every POST creates a NEW session — that is what exercises the create path + the cap.
export SERVER
seq "$N" | xargs -P "$CONC" -I{} sh -c '
  id=$(openssl rand -hex 16); tok=$(openssl rand -hex 16)
  curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST "$SERVER/api/sessions" \
    -H "content-type: application/json" \
    -d "{\"id\":\"$id\",\"runner_token\":\"$tok\",\"ttl_seconds\":60}"
' | sort | uniq -c

echo "(201 = created, 503 = at ONLYTTY_MAX_SESSIONS cap, 000 = connection error)"
