#!/usr/bin/env bash
# Comprehensive pre-deploy check. Builds the PRODUCTION release image, runs it behind a
# Caddy proxy (the deployed topology), smokes the HTTP surface, drives the full encrypted
# e2e against the real artifact, cross-compiles the release binaries, and syntax-checks
# the VM start script. Catches the "passes `make check` but breaks after deploy" class of
# failure (Dockerfile/release config, prod force_ssl behind a proxy, cross-build, etc.).
#
# Needs Docker. Run: make deploy-check
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE="http://localhost:4000"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$1"; exit 1; }
get() { # get URL [extra curl args…] -> /tmp/dc.body, retrying transient proxy/upstream blips
  local url="$1"; shift
  for _ in 1 2 3 4 5; do curl -fsS "$@" -o /tmp/dc.body "$url" 2>/dev/null && return 0; sleep 1; done
  return 1
}

command -v docker >/dev/null || fail "docker is required"
export SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')"

cleanup() {
  ( cd test/deploy && docker compose down -v --remove-orphans >/dev/null 2>&1 || true )
  rm -f onlytty /tmp/dc.body /tmp/onlytty-start.sh
}
trap cleanup EXIT

step "Build the production release image + bring up the deployed topology (onlytty + Caddy)"
( cd test/deploy && docker compose up -d --build )

step "Wait for the release to become healthy (through the proxy)"
ok=""
for i in $(seq 1 90); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ -n "$ok" ] || { ( cd test/deploy && docker compose logs --tail=60 onlytty ); fail "release never became healthy"; }
pass "GET /healthz → 200 behind the proxy"

step "Smoke the production HTTP surface"
get "$BASE/" && grep -q "OnlyTTY" /tmp/dc.body && pass "home page served by the release" || fail "home page"
get "$BASE/sitemap.xml" && grep -q "<urlset" /tmp/dc.body && pass "sitemap.xml" || fail "sitemap"
get "$BASE/robots.txt" && grep -q "Disallow: /s/" /tmp/dc.body && pass "robots.txt" || fail "robots"
get "$BASE/api/sessions" -X POST -H 'content-type: application/json' -d '{}' || fail "session create"
SID="$(grep -oE '"id":"[^"]+"' /tmp/dc.body | cut -d'"' -f4)"
[ -n "$SID" ] && pass "POST /api/sessions → session $SID" || fail "session create (no id in response)"
get "$BASE/s/$SID" && grep -q "xterm" /tmp/dc.body && pass "GET /s/:id → viewer page" || fail "viewer page"

step "force_ssl: a direct http request for a real host must redirect to https"
# Plug.SSL exempts localhost by design, so send a non-localhost Host to exercise the redirect.
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: onlytty.example.com' "http://localhost:4001/healthz" || true)"
[ "$code" = "301" ] && pass "http→https 301 for a real host (force_ssl active; localhost exempt)" || fail "expected 301, got $code"

step "Full encrypted e2e against the production release (runner ↔ release ↔ viewer)"
ONLYTTY_SERVER="$BASE" bash scripts/e2e.sh
pass "e2e green against the deployed artifact"

step "Cross-compile the release binaries (the release.yml matrix)"
for t in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do
  CGO_ENABLED=0 GOOS="${t%/*}" GOARCH="${t#*/}" go build -trimpath -o "/tmp/onlytty-build-$$" ./runner && pass "go build $t"
done
rm -f "/tmp/onlytty-build-$$"

step "Syntax-check the VM cloud-init start script"
if python3 -c "import yaml" 2>/dev/null; then
  python3 - <<'PY'
import yaml
ci = yaml.safe_load(open("infra/templates/cloud-init.yaml"))
sh = next(f["content"] for f in ci["write_files"] if f["path"].endswith("start.sh"))
open("/tmp/onlytty-start.sh", "w").write(sh)
PY
  bash -n /tmp/onlytty-start.sh && pass "infra start.sh: bash syntax ok" || fail "start.sh syntax"
  rm -f /tmp/onlytty-start.sh
else
  printf '  - skipped (python yaml unavailable)\n'
fi

printf '\n\033[1;32m✓ deploy-check passed\033[0m — the release builds, boots, serves, pairs end-to-end, and cross-compiles.\n'
