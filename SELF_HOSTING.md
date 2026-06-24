# Self-hosting the OnlyTTY relay

Run your own relay instead of the hosted one at `onlytty.com`. The breeze path is
one `docker compose up -d`: a single stateless container behind Caddy, which fetches
and renews a TLS certificate for your domain on its own. Twenty minutes, start to a
working `https://relay.example.com`.

## Do you actually need to self-host?

Probably not for privacy. The relay is **end-to-end encrypted by design** — it pairs a
runner with a viewer and forwards opaque ciphertext, and it stores nothing. The hosted
relay at `onlytty.com` already cannot read your terminal; neither can yours. Self-hosting
does not make the *contents* more private than the math already does.

Self-host when you want one of these instead:

- **Your own domain in the link.** `https://relay.example.com/s/…` rather than `onlytty.com`.
- **Your own limits.** Cap session lifetime (`ONLYTTY_MAX_TTL`), concurrency, frame size,
  and create-rate to your policy.
- **A network you control.** Keep the relay inside a VPC, behind a VPN, or air-gapped so
  links only resolve on your network.
- **To be the code-delivery trust anchor.** The browser viewer is JavaScript the relay
  host serves. On the hosted relay you trust `onlytty.com` to serve the audited bytes; on
  your own relay, that trust is yours. (See [Security when you self-host](#security-when-you-self-host).)

If none of those apply, the hosted relay is a fine default and there is nothing to run.

## What you're running

One Elixir/Phoenix container. **No database** — every session lives in memory on the
node, and nothing terminal-related is ever persisted, so there is nothing to back up.
It needs exactly one thing in front of it: **TLS**. The browser viewer uses the Web
Crypto API, which only runs in a [secure context](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts),
and the relay redirects `http→https` and sets HSTS in production. No HTTPS, no viewer.

```
DNS A/AAAA ─► your host ─► Caddy (:443, TLS) ─► relay (:4000, plain HTTP, private)
                            auto Let's Encrypt    in-memory sessions, no DB
```

You need: a 64-bit Linux host (x86-64 or arm64) with a public IP, a domain whose DNS you
can point at it, ports 80 and 443 reachable, and Docker. That's the whole prerequisite
list.

## The breeze path: Docker Compose + automatic HTTPS

The [`selfhost/`](selfhost/) directory has everything — a `compose.yml`, a `Caddyfile`,
and a `.env.example`. Caddy terminates TLS and reverse-proxies to the relay; it sets
`X-Forwarded-Proto`, preserves `Host`, upgrades WebSockets, and redirects `:80→:443`
without any extra configuration.

```bash
# 1. Get the bundle (clone the repo, or copy the three files from selfhost/).
git clone https://github.com/AndrewDryga/onlytty
cd onlytty/selfhost

# 2. Configure: your domain + a signing secret.
cp .env.example .env
$EDITOR .env
#   ONLYTTY_DOMAIN=relay.example.com
#   SECRET_KEY_BASE=…            # openssl rand -base64 64 | tr -d '\n'

# 3. Point DNS at this host, then bring it up.
#   relay.example.com.  A   <this host's IPv4>
docker compose up -d
```

On first boot Caddy requests a Let's Encrypt certificate for `ONLYTTY_DOMAIN` over the
:80 challenge — so DNS must resolve to this host and :80/:443 must be reachable. Once the
certificate is issued (seconds, after DNS propagates), the relay is live:

```bash
curl https://relay.example.com/healthz      # → ok
```

Pin a release instead of `:latest` for repeatable deploys — set `ONLYTTY_IMAGE` in
`.env` (e.g. `ONLYTTY_IMAGE=ghcr.io/andrewdryga/onlytty:0.2.5`). To build from source
instead of pulling, swap the `image:` line in `compose.yml` for `build: ../portal` — do
this on an **arm64** host if the published image you pull is x86-64-only (see
[Troubleshooting](#troubleshooting)).

## Point your runner at it

Per-invocation:

```bash
onlytty --server https://relay.example.com -- claude
```

Or set it once:

```bash
export ONLYTTY_SERVER=https://relay.example.com
onlytty -- htop
```

The link the runner prints — and the QR it shows — now carries your host. The session
secret still lives only in the URL `#fragment` and never reaches your relay; it pairs the
runner and viewer and forwards ciphertext, exactly as the hosted one does.

## Verify it end-to-end

```bash
# 1. The relay answers behind TLS.
curl https://relay.example.com/healthz                      # → ok

# 2. http is redirected, not served.
curl -sI http://relay.example.com/healthz | grep -i location  # → https://…

# 3. A real session, start to finish — pick something that stays open.
onlytty --server https://relay.example.com -- top
#   Open the printed link in a browser (or scan the QR on your phone); you should see
#   `top` live. The terminal and the browser show the SAME fingerprint — that proves both
#   ends derived the same keys from the same secret, through your relay.
```

If the fingerprints match, end-to-end encryption is working through your own relay.

## Configuration

Set these in `.env` (Compose reads it automatically) or as container environment.
`PHX_SERVER`, `SECRET_KEY_BASE`, and `PHX_HOST` are the only ones you must set; the rest
have working defaults. The source of truth is
[`portal/config/runtime.exs`](portal/config/runtime.exs).

| Variable | Default | What it does |
|----------|---------|--------------|
| `PHX_SERVER` | — | set `true` to start the HTTP server (the bundle sets it) |
| `SECRET_KEY_BASE` | — | **required**; `openssl rand -base64 64`. Keep it stable; share it across cluster nodes |
| `PHX_HOST` | `example.com` | your public hostname — goes into links and the http→https redirect |
| `PORT` | `4000` | port the relay listens on (behind the proxy) |
| `ONLYTTY_DEFAULT_TTL` | `0` (no expiry) | TTL in seconds for a session that doesn't request one |
| `ONLYTTY_MAX_TTL` | _(unset = no ceiling)_ | hard ceiling on session lifetime (s); a requested TTL is clamped to it |
| `ONLYTTY_IDLE_TIMEOUT` | `600` | close a session after this many seconds with no runner traffic |
| `ONLYTTY_MAX_SESSIONS` | `2000` | cap on concurrent in-memory sessions (bounds create-spam) |
| `ONLYTTY_MAX_FRAME_BYTES` | `1048576` | max size of one WebSocket frame (1 MiB); over-cap closes the socket |
| `ONLYTTY_ALLOWED_ORIGINS` | _(same host)_ | comma-separated **extra** browser-viewer origins; the relay's own host is always allowed |
| `ONLYTTY_RATELIMIT_MAX` | `30` | max `POST /api/sessions` per window per IP (`0` disables) |
| `ONLYTTY_RATELIMIT_WINDOW` | `60` | rate-limit window length (seconds) |
| `ONLYTTY_METRICS_TOKEN` | — | bearer token for `GET /metrics` from off-host; unset → loopback-only |
| `SENTRY_DSN` | — | optional backend-only error reporting; no-op unless set |

TTL is opt-in: by default a session has no expiry and lives as long as `onlytty` runs (it
ends when the command exits or the runner disconnects). A runner can request a bound with
`--ttl 30m`; a positive request is floored at 60s. Set `ONLYTTY_MAX_TTL` to impose a
ceiling on a shared relay — it forces even no-expiry sessions down to that bound.

## Operating it

- **Update:** `docker compose pull && docker compose up -d`. Sessions are in memory, so a
  restart drops live ones — but the runner re-creates its session and the viewer
  reconnects and repaints from the runner's buffer, so an interrupted session comes back
  on its own.
- **Logs:** `docker compose logs -f onlytty`. They carry only metadata — an 8-character
  session-id prefix, the role, a timestamp. Never IP addresses, never terminal content
  (it's E2E and never reaches the relay).
- **Metrics:** `GET /metrics` is Prometheus text — aggregate, label-free counters. It's
  loopback-only until you set `ONLYTTY_METRICS_TOKEN`, then a scraper carrying
  `Authorization: Bearer <token>` can read it through the proxy.
- **Backups:** none. There is no database and no terminal state. Keep `SECRET_KEY_BASE`
  somewhere safe; everything else is reproducible from the image.
- **Scaling out:** one container handles a lot — sessions are cheap and hold no terminal
  bytes. If you outgrow a single node, the relay clusters: every session is registered
  cluster-wide via `:global`, so a runner and a viewer on different nodes still pair. The
  production multi-node setup (a GCP Managed Instance Group that forms the BEAM cluster
  via libcluster) is in [`infra/`](infra/README.md).

## Bring your own proxy

Already run nginx, Cloudflare, Fly, or Render? Skip Caddy and point your proxy at the
relay container's `:4000`. The relay terminates plain HTTP and trusts the proxy for TLS,
so the proxy must do four things — all four, or the viewer breaks:

1. **Terminate TLS** and serve the relay over `https://` (the viewer needs a secure context).
2. **Forward `X-Forwarded-Proto: https`.** The relay's `force_ssl` trusts this header; if
   it's missing, the relay thinks the request is plaintext and redirects — an infinite
   loop behind a TLS proxy.
3. **Allow WebSocket upgrades** to `/ws/runner/:id` and `/ws/viewer/:id`. These are
   long-lived connections; don't set an aggressive idle/read timeout (the runner
   reconnects, but you don't want it churning).
4. **Preserve the `Host` header.** The viewer's WebSocket `Origin` must match the relay's
   host; a proxy that rewrites `Host` will trip the origin check.

A minimal nginx `location` block:

```nginx
location / {
    proxy_pass http://127.0.0.1:4000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;       # WebSocket
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;                  # origin check
    proxy_set_header X-Forwarded-Proto https;     # force_ssl
    proxy_read_timeout 86400s;                    # long-lived sockets
}
```

The bare `docker run` form (no proxy bundled — you supply TLS):

```bash
docker run -p 4000:4000 \
  -e PHX_SERVER=true \
  -e SECRET_KEY_BASE="$(openssl rand -base64 64)" \
  -e PHX_HOST=relay.example.com \
  ghcr.io/andrewdryga/onlytty:latest
```

## Security when you self-host

End-to-end encryption holds on your relay exactly as it does on the hosted one: it
forwards authenticated ciphertext and stores none of it, a replayed or reordered frame is
rejected, and a read-only viewer can't type or resize the host. What self-hosting *moves*
is **code-delivery trust**. The browser viewer is JavaScript your relay serves, so a
tampered relay could serve a viewer that leaks the secret from the fragment. On your own
relay you are the one serving those bytes — which is the point, but it's now your
responsibility.

To keep it honest:

- The first-party viewer JS is served `Cache-Control: no-store`, so a browser always
  fetches the current bytes — there's no stale cached bundle to exploit.
- Each release publishes the SHA-256 of every viewer asset (`VIEWER_HASHES` / `make
  viewer-hash`). Pin a release tag rather than `:latest` and you can check the bytes your
  relay serves against the audited release.
- The link is a capability — anyone you forward it to becomes a viewer. Bound it with a
  short `--ttl`, the single-viewer lock (on by default), or a `--passphrase` shared
  out-of-band.

The full model, stated with its limits, is in [SECURITY.md](SECURITY.md) and
[PROTOCOL.md](PROTOCOL.md).

## Troubleshooting

| Symptom | Cause → fix |
|---------|-------------|
| Caddy can't get a certificate | DNS isn't pointing at this host yet, or :80/:443 aren't reachable. Confirm `dig relay.example.com` resolves here and the ports are open, then `docker compose restart caddy`. |
| Browser: "can't use a secure feature" / viewer won't start | The page isn't on HTTPS. The viewer needs a secure context — serve it over TLS (the bundle does; a custom proxy must terminate TLS). |
| Endless redirects to https | Your proxy isn't sending `X-Forwarded-Proto: https`. The relay thinks the request is plaintext and redirects forever. Add the header. |
| Runner: *"plain http to a non-local host; use https"* | You pointed `--server` at an `http://` URL on a real host. Use `https://`. (`--allow-insecure` exists for local testing only.) |
| Viewer connects but never paints | WebSocket upgrades aren't getting through the proxy, or `Host` is being rewritten. Pass `Upgrade`/`Connection` headers and preserve `Host`. |
| `POST /api/sessions` returns 503 | `ONLYTTY_MAX_SESSIONS` is reached, or you're hitting the per-IP create rate limit. Raise the cap, or `ONLYTTY_RATELIMIT_MAX`/`_WINDOW`. |
| `SECRET_KEY_BASE is missing` on boot | It isn't set (or `.env` isn't being read). Generate one: `openssl rand -base64 64`. |
| Relay exits on boot with `prim_tty` / `nif_error`, or `exec format error` | The image's CPU architecture doesn't match the host (e.g. an x86-64 image under emulation on arm64). Pull a tag built for your arch, or build from source: set `build: ../portal` in `compose.yml`. |

Verify the whole bundle yourself, end-to-end, with `make selfhost-check` (needs Docker +
Go): it brings the shipped files up over real HTTPS and pairs a session through them.
