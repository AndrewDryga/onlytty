# relay — server (control plane)

The untrusted relay that pairs a runner with a browser viewer and forwards
**end-to-end-encrypted** frames between them. It is an Elixir/Phoenix app with
**no database**: every session lives in memory only, and nothing terminal-related
is ever persisted. See [`../PROTOCOL.md`](../PROTOCOL.md) for the wire contract and
[`../SECURITY.md`](../SECURITY.md) for the trust model.

## Local development

```bash
mix setup            # fetch deps
mix phx.server       # http://localhost:4000  (or: iex -S mix phx.server)
mix test             # the test suite
mix format           # formatter
```

The full gate (run from the repo root) is `make server-check`:
`mix format --check-formatted && mix compile --warnings-as-errors && mix test`.

## What it serves

| Route | Purpose |
|-------|---------|
| `POST /api/sessions` | create a session → `{id, runner_token, expires_at}` |
| `GET /healthz` | liveness probe (`200 ok`) |
| `GET /s/:id` | the static browser viewer page |
| `GET /ws/runner/:id` | runner WebSocket (Bearer `runner_token`) |
| `GET /ws/viewer/:id` | viewer WebSocket (single-viewer lock) |
| `GET /`, `/tools`, `/control/:slug`, `/sitemap.xml` | OnlyTTY marketing site |

WebSocket frames are opaque ciphertext: the relay can pair, drop, or observe
timing/size, but never read or forge terminal IO.

## Configuration (runtime env)

| Var | Default | Meaning |
|-----|---------|---------|
| `PHX_SERVER` | — | set `true` to start the HTTP server in a release |
| `SECRET_KEY_BASE` | — | **required in prod** (`mix phx.gen.secret`) |
| `PHX_HOST` | `example.com` | public hostname (URLs + the https redirect) |
| `PORT` | `4000` | listen port |
| `RELAY_DEFAULT_TTL` | `1800` | default session TTL (s); every TTL is clamped to **60–86400** (24h) |
| `RELAY_IDLE_TIMEOUT` | `600` | close a session after this many seconds with no runner traffic |
| `RELAY_MAX_SESSIONS` | `2000` | cap on concurrent in-memory sessions (bounds create-spam) |
| `DNS_CLUSTER_QUERY` | — | optional DNS-based clustering query |

Session lifecycle: a session is reaped at its (clamped) TTL, after the idle timeout
with no runner, or when the runner disconnects. Creation is unauthenticated, so the
`RELAY_MAX_SESSIONS` cap returns `503` once the pool is full.

## Production

Build and run the release image (from the repo root):

```bash
docker build -t relay-server ./server
docker run -p 4000:4000 \
  -e PHX_SERVER=true \
  -e SECRET_KEY_BASE="$(openssl rand -base64 64)" \
  -e PHX_HOST=relay.example.com \
  -e PORT=4000 \
  relay-server
```

- **TLS is required.** Serve over HTTPS behind a proxy that sets
  `x-forwarded-proto` — the prod config enforces http→https + HSTS, and the viewer
  needs a secure context (Web Crypto + the secret must never travel in cleartext).
- **Bind to loopback behind the proxy** where possible; the relay terminates plain
  HTTP and relies on the proxy for TLS.

## Logging

Logs carry only metadata: an 8-char session-id prefix, the role, and a timestamp —
never IP addresses or terminal content (terminal IO is E2E and never reaches the
server). Keep it that way when adding logs.
