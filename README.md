<div align="center">

# relay

**Run a command anywhere, get a link, drive it from your phone — end-to-end encrypted, so the server in the middle only ever sees ciphertext.**

</div>

```bash
onlytty -- claude          # share one command
onlytty                  # share your whole shell
# → prints a link + QR.  Scan it, and an xterm in your browser is the same session.
```

`onlytty` wraps a command (or your shell) in a PTY on your machine, mirrors it locally
so your terminal stays live, and streams an **end-to-end-encrypted** copy to a browser
through a small relay server. The session secret lives only in the link's `#fragment`,
which never reaches the server — so a compromised or curious relay sees only opaque
bytes, never your terminal.

- **No inbound ports.** The runner dials out over WebSocket/TLS; nothing listens on your machine.
- **E2E by default.** AES-256-GCM under keys derived from a secret the relay never sees ([PROTOCOL.md](PROTOCOL.md)).
- **Mobile-first viewer.** xterm.js with a touch key bar, paste guard, reconnect, and wake lock.
- **Command-only or whole-shell.** Share just `claude`, or your `$SHELL`. Read-only by default; take control with a tap.
- **Minimal & boring.** A Go runner (stdlib crypto), an Elixir relay that stores nothing, a dependency-light vanilla-JS viewer.

---

## How it works

```
your machine                      relay (untrusted)             browser (phone / desktop)
┌────────────────────┐   wss/TLS  ┌──────────────────┐  wss/TLS ┌────────────────────────┐
│ onlytty (Go)       │◄──────────►│ Elixir/Phoenix   │◄────────►│ xterm.js viewer        │
│  PTY(cmd | $SHELL) │  ciphertext│  pairs by id     │ciphertext│  key from #fragment    │
│  mirror → terminal │  only      │  forwards opaque │  only    │  AES-GCM open/seal     │
│  AES-GCM seal/open │            │  frames; stores  │          │  read-only ↔ control   │
│  prints link + QR  │            │  nothing         │          │  reconnect / resume    │
└────────────────────┘            └──────────────────┘          └────────────────────────┘
        the QR carries a URL whose #fragment holds the session secret — the fragment
        never leaves the browser, so the relay only ever learns the session id.
```

The runner generates a 32-byte secret, derives directional AES-256-GCM keys from it
(HKDF; optional PBKDF2 passphrase), and prints `https://<relay>/s/<id>#<secret>`. The
browser reads the secret from the fragment and derives the same keys. Everything in
between is ciphertext. See [PROTOCOL.md](PROTOCOL.md) for the exact wire format.

## Install

**Runner** (the `onlytty` CLI) — a single Go binary:

```bash
go install github.com/AndrewDryga/onlytty/runner@latest     # with Go
# or, from a clone:
make install                                       # → ~/.local/bin/onlytty
```

**Relay server** — see [Deploy the relay](#deploy-the-relay). You point the runner at
it with `--server` or `ONLYTTY_SERVER`.

## Quickstart

```bash
# 1. Run a relay somewhere reachable (or locally for a first try):
cd portal && mix deps.get && mix phx.server     # dev relay on http://localhost:4000

# 2. Point the runner at it and share something:
export ONLYTTY_SERVER=http://localhost:4000
onlytty -- htop
# → a link + QR is printed. Open it (same machine) or scan it (phone).
```

For real use, deploy the relay behind HTTPS and set `ONLYTTY_SERVER=https://relay.example.com`.

## CLI reference

```
onlytty [flags]              share your $SHELL
onlytty [flags] -- <cmd>...  share one command

  --server <url>     relay origin (or ONLYTTY_SERVER), e.g. https://relay.example.com
  --read-only        viewers may watch but never type or resize
  --ttl <dur>        session lifetime before the link expires
                     (default 12h; the relay clamps every TTL to 60s–7d)
  --passphrase       prompt for a passphrase mixed into the keys; share it
                     out-of-band so the link alone cannot decrypt
  --passphrase-generate
                     generate a strong passphrase host-side and print it; send it
                     in a different channel than the link (never the same message)
  --no-qr            print the link without a QR code
  --allow-insecure   allow a plain http:// relay to a non-local host
                     (development/testing only — production requires https)
  --version
```

The terminal shows a **fingerprint**; the browser shows the same one. If they match,
both ends derived the same keys from the same secret.

## The mobile viewer

The browser viewer (xterm.js, no framework, no build step) is built for phones:

- **Read-only by default.** Tap **Take control** to type; the host can run `--read-only` to forbid it.
- **Touch key bar** — Esc, Tab, Ctrl (sticky, for `Ctrl-<key>`), arrows, `^C`, `^D`.
- **Paste guard** confirms before sending a multi-line paste.
- **Reconnect & resume** — drops are repainted from the runner's ring buffer.
- **Wake lock**, font-size controls, and host-driven sizing while watching (your size once you take control).

## Deploy the relay

The relay is an Elixir release. Sessions are **in memory only** — nothing
terminal-related is ever persisted, so there is no database.

```bash
docker build -t onlytty-server ./portal
docker run -p 4000:4000 \
  -e PHX_SERVER=true \
  -e SECRET_KEY_BASE="$(openssl rand -base64 64)" \
  -e PHX_HOST=relay.example.com \
  -e PORT=4000 \
  onlytty-server
```

Put it behind a TLS-terminating proxy (Cloudflare, Fly, Render, Caddy, nginx) that
forwards `x-forwarded-proto`. **TLS is required**: in prod the relay redirects
http→https + sets HSTS, and the browser's Web Crypto API only works in a secure
context. Without HTTPS the viewer refuses to run (and the secret could leak in transit).

| Env | Default | Meaning |
|-----|---------|---------|
| `PHX_SERVER` | — | set `true` to start the HTTP server in a release |
| `SECRET_KEY_BASE` | — | required in prod (`mix phx.gen.secret`) |
| `PHX_HOST` | `example.com` | public hostname (used for URLs + the SSL redirect) |
| `PORT` | `4000` | listen port |
| `ONLYTTY_DEFAULT_TTL` | `1800` | default session TTL in seconds; every requested TTL is clamped to 60s–`ONLYTTY_MAX_TTL` |
| `ONLYTTY_MAX_TTL` | `604800` | hard ceiling on session TTL in seconds (7 days); requested TTLs are clamped to it |
| `ONLYTTY_IDLE_TIMEOUT` | `600` | close after this many seconds with no runner traffic |
| `ONLYTTY_MAX_SESSIONS` | `2000` | cap on concurrent sessions (bounds create-spam) |
| `ONLYTTY_RATELIMIT_MAX` | `30` | max `POST /api/sessions` per window per IP (`0` disables) |
| `ONLYTTY_RATELIMIT_WINDOW` | `60` | rate-limit window in seconds |
| `SENTRY_DSN` | — | backend error reporting; unset disables it (dev/test/CI never report) |
| `SENTRY_RELEASE` | — | optional release tag for Sentry events |

Error reporting is **backend-only**: the server captures crashes via Sentry's logger
handler (no request context attached, so no IPs or bodies; terminal IO is E2E and never
reaches the server). The browser viewer ships **no** Sentry/telemetry by design — a
client SDK would capture the URL fragment that holds the session secret.

Throttling keys on the **direct peer IP** (`conn.remote_ip`), which is correct when the
relay faces clients directly. Behind a reverse proxy that is your proxy's address, so
either rate-limit at the proxy too, or add a trusted-`X-Forwarded-For` plug (e.g.
`remote_ip`) so the real client IP reaches the limiter — don't trust the header blindly.

## Security model — stated honestly

End-to-end encryption means the **relay** never sees terminal IO: it forwards opaque,
authenticated ciphertext and stores none of it. A replayed or reordered frame is
rejected (a session-long sequence floor); a read-only viewer cannot type *or* resize
the host. That is the strong guarantee.

It is **not** zero-trust, and here's the honest residue:

- **The browser runs JS served by the relay host.** A malicious host could serve a
  viewer that exfiltrates the secret from the fragment. So host trust is reduced to
  *code-delivery time*, not *relay time*. The viewer's third-party code (xterm) is
  vendored and Subresource-Integrity-pinned; a native viewer (no browser JS) would
  remove this caveat entirely.
- **The link is a capability.** Anyone you forward it to becomes a viewer. Mitigate
  with a short `--ttl`, the single-viewer lock (default), and `--passphrase`.
- **Trust the fingerprint, not the prose.** The fingerprint shown at both ends is
  derived from the secret and is trustworthy. A "viewer connected" notice in the
  terminal is relay-delivered metadata and could be spoofed by a hostile relay (which
  still cannot read or inject your terminal).

Found a vulnerability? See [SECURITY.md](SECURITY.md).

## Prerequisites

`make check` needs **Go** (with `gofmt`), **Elixir/OTP** (with `mix`), and **Node 22+**
(with `npm`) — versions are pinned in `.tool-versions` (asdf/mise). `make e2e`
additionally needs a Playwright browser:

```bash
npm install                       # Playwright (a dev dependency)
npx playwright install chromium   # the browser binary
npx playwright install-deps       # Linux only: native libs for headless Chromium
```

Run **`make doctor`** to see what's installed and get install hints for anything missing.

## Develop

```bash
make check     # the gate: runner (go) + web (node) + server (elixir)
make e2e       # boots the relay, then a Go viewer and a headless-browser viewer
               # drive a real session end-to-end through it
make audit     # opt-in dependency/security audit (not part of `check`)
make fuzz      # fuzz the protocol decoders (they parse relay-forwarded bytes)
make load      # concurrent session-create load against $ONLYTTY_SERVER
```

`make audit` runs `govulncheck ./...` (Go), `npm audit` (web), and `mix hex.audit`
(retired Hex packages). It is **opt-in** — release CI should run it, but it stays out
of the local `check` gate. Install the Go scanner once with
`go install golang.org/x/vuln/cmd/govulncheck@latest`.

| Path | What |
|------|------|
| `runner/` | the `onlytty` runner (Go CLI) |
| `runner/internal/protocol/` | crypto + wire format (Go); golden vectors pin it to the JS |
| `portal/` | the relay control plane (Elixir/Phoenix, no database) |
| `portal/priv/static/` | the browser viewer (vanilla JS + vendored xterm) |
| `test/` | Node interop, Go transport e2e, headless-browser e2e |
| `PROTOCOL.md` | the wire + crypto contract every component obeys |

## License

[MIT](LICENSE)
