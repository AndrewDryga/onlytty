#!/usr/bin/env bash
# Verify the shipped self-host bundle (selfhost/compose.yml + Caddyfile) end-to-end.
#
# It runs the EXACT files a self-hoster copies, only with ONLYTTY_DOMAIN=localhost so
# Caddy serves real HTTPS from its own local CA instead of reaching out to Let's Encrypt
# (no public domain needed). Then it proves, over that real TLS:
#   - the relay is healthy behind Caddy and the whole HTTP surface serves over https
#   - http→https redirect + HSTS (the production force_ssl behavior) actually happen
#   - a runner and a viewer pair end-to-end through the shipped proxy (encrypted wss)
#
# The only thing it cannot exercise locally is a publicly-trusted ACME certificate —
# that needs a real domain and is identical in mechanism to the local-CA path here.
#
# Needs Docker + the Go toolchain. Run: make selfhost-check
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
BUNDLE="$ROOT/selfhost"
BASE="https://localhost"
CA="/tmp/onlytty-selfhost-ca.crt"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗ %s\033[0m\n' "$1"; exit 1; }

command -v docker >/dev/null || fail "docker is required"
command -v go >/dev/null || fail "go is required"

# The shipped compose.yml requires these two; ONLYTTY_DOMAIN=localhost flips Caddy to
# its internal CA. Everything else is exactly what a self-hoster runs.
export ONLYTTY_DOMAIN="localhost"
export SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')"

# Build the relay image from THIS tree for the host's architecture and feed it to the
# bundle via its ONLYTTY_IMAGE override. Building natively tests the current Dockerfile
# + source instead of whatever image tag is currently published.
export ONLYTTY_IMAGE="onlytty:selfhost-check"

dc() { docker compose -f "$BUNDLE/compose.yml" "$@"; }

cleanup() {
  dc down -v --remove-orphans >/dev/null 2>&1 || true
  rm -f "$CA" /tmp/onlytty-selfhost.body
}
trap cleanup EXIT

step "Validate the shipped Caddyfile"
docker run --rm -e ONLYTTY_DOMAIN -v "$BUNDLE/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2.11.4 \
  caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
  && pass "caddy validate ok" || fail "Caddyfile is invalid"

step "Build the relay image for this host ($ONLYTTY_IMAGE)"
docker build -t "$ONLYTTY_IMAGE" "$ROOT/portal" >/dev/null && pass "image built" || fail "image build"

step "Bring up the shipped bundle (the relay image above + caddy:2.11.4)"
dc up -d

step "Wait for the relay to be healthy behind Caddy over HTTPS"
ok=""
for _ in $(seq 1 90); do
  # -k here only to drive Caddy into generating its local CA; real asserts use --cacert.
  if curl -fsSk "$BASE/healthz" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ -n "$ok" ] || { dc logs --tail=60; fail "relay never became healthy behind Caddy"; }
pass "GET /healthz → 200 over https (Caddy → relay)"

step "Trust Caddy's local CA so the rest is verified TLS, not -k"
dc exec -T caddy cat /data/caddy/pki/authorities/local/root.crt >"$CA" 2>/dev/null \
  && [ -s "$CA" ] && pass "exported Caddy local root CA" || fail "could not export Caddy root CA"
get() { curl -fsS --cacert "$CA" -o /tmp/onlytty-selfhost.body "$@"; }

step "The HTTP surface serves over verified HTTPS"
get "$BASE/healthz" && grep -q "ok" /tmp/onlytty-selfhost.body && pass "/healthz" || fail "/healthz over TLS"
get "$BASE/" && grep -q "OnlyTTY" /tmp/onlytty-selfhost.body && pass "/ (marketing page)" || fail "/ over TLS"
sid_id="$(openssl rand -hex 16)"; sid_tok="$(openssl rand -hex 16)"
get "$BASE/api/sessions" -X POST -H 'content-type: application/json' \
  -d "{\"id\":\"$sid_id\",\"runner_token\":\"$sid_tok\"}" || fail "POST /api/sessions over TLS"
SID="$(grep -oE '"id":"[^"]+"' /tmp/onlytty-selfhost.body | cut -d'"' -f4)"
[ "$SID" = "$sid_id" ] && pass "POST /api/sessions → 201 (id echoed)" || fail "session create (id mismatch)"
get "$BASE/s/$SID" && grep -q "xterm" /tmp/onlytty-selfhost.body && pass "GET /s/:id → viewer page" || fail "viewer page over TLS"

step "Production TLS behavior: Caddy redirects http→https"
loc="$(curl -sS -o /dev/null -w '%{redirect_url}' "http://localhost/healthz" || true)"
case "$loc" in https://*) pass "http→https redirect ($loc)";; *) fail "expected https redirect, got '$loc'";; esac

step "Production TLS behavior: the relay sets HSTS for a real host (force_ssl)"
# Plug.SSL exempts localhost by design (no redirect, no HSTS for it), so HSTS can't be
# seen at host=localhost. Hit the relay directly over the compose network with a real
# Host + X-Forwarded-Proto: https — exactly what Caddy sends for relay.example.com — and
# assert the relay emits Strict-Transport-Security without looping (XFP=https ⇒ no redirect).
NET="$(docker inspect -f '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}}{{end}}' "$(dc ps -q onlytty)")"
hdrs="$(docker run --rm --network "$NET" curlimages/curl:8.11.1 -sSI \
  -H 'Host: relay.example.com' -H 'X-Forwarded-Proto: https' http://onlytty:4000/healthz 2>/dev/null || true)"
printf '%s' "$hdrs" | grep -qi '^strict-transport-security:' \
  && pass "HSTS present for a real host (localhost is exempt by design)" \
  || { printf '%s\n' "$hdrs"; fail "relay did not set HSTS for a real host"; }

step "Encrypted end-to-end through the shipped proxy (runner ↔ Caddy/TLS ↔ relay ↔ viewer)"
# SSL_CERT_FILE makes the Go runner + Go viewer trust Caddy's local CA, so this is a real
# wss/TLS pairing through the shipped Caddy — not a plaintext shortcut.
SSL_CERT_FILE="$CA" ONLYTTY_SERVER="$BASE" go test -tags e2e -count=1 ./runner/e2e/ \
  && pass "encrypted runner↔viewer session paired over real TLS" || fail "e2e pairing over TLS"

printf '\n\033[1;32m✓ selfhost-check passed\033[0m — the shipped bundle serves real HTTPS, redirects, and pairs a session end-to-end.\n'
