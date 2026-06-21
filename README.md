<div align="center">

# OnlyTTY

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
- **Command-only or whole-shell.** Share just `claude`, or your `$SHELL`. The link opens view-only, but anyone who has it can take control with a tap — pass `--control view-only` to lock it to watching.
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

**Runner** (the `onlytty` CLI) — a single Go binary. Quickest, no Go needed:

```bash
curl -fsSL https://raw.githubusercontent.com/AndrewDryga/onlytty/main/install.sh | sh
```

It detects your OS/arch, downloads the matching release binary **and its
`SHA256SUMS`, verifies the SHA-256 before installing** (aborts on mismatch), and
drops `onlytty` in `~/.local/bin` (override with `PREFIX=…`; pin a release with
`sh -s -- --version X.Y.Z`). Piping to a shell is itself a trust decision — to
audit instead, read [`install.sh`](install.sh), or download the
`onlytty-<ver>-<os>-<arch>.tar.gz` + `SHA256SUMS` from
[Releases](https://github.com/AndrewDryga/onlytty/releases), run
`shasum -a 256 -c SHA256SUMS`, then extract and move `onlytty` onto your PATH.

The checksum protects against a corrupted or truncated download, **not** a
compromised release — `SHA256SUMS` ships from the same release as the binary, so an
attacker who can swap one can swap both. For tamper-resistance, every release also
publishes keyless [build provenance](https://docs.github.com/actions/security-guides/using-artifact-attestations);
verify a binary's origin with the GitHub CLI:

```bash
gh attestation verify onlytty-<ver>-<os>-<arch>.tar.gz --repo AndrewDryga/onlytty
```

With Go, or from a clone:

```bash
go install github.com/AndrewDryga/onlytty/runner@latest     # with Go
make install                                                # from a clone → ~/.local/bin/onlytty
```

**Relay server** — `onlytty` connects through a relay you run; see
[Self-host the relay](#self-host-the-relay). Point the runner at it with `--server`
or `ONLYTTY_SERVER`.

## Quickstart

OnlyTTY has two pieces: the `onlytty` runner you just installed, and a **relay** it
connects through. Try it locally first, then [self-host a relay behind
HTTPS](#self-host-the-relay) for real use.

```bash
# 1. Start a local dev relay (from a clone; needs Elixir):
cd portal && mix deps.get && mix phx.server     # dev relay on http://localhost:4000

# 2. In another terminal, point the runner at it and share something:
export ONLYTTY_SERVER=http://localhost:4000
onlytty -- htop
# → a link + QR is printed. Open it (same machine) or scan it (phone).
```

For real use, point the runner at your deployed relay:
`export ONLYTTY_SERVER=https://relay.example.com`.

## CLI reference

```
onlytty [flags]              share your $SHELL
onlytty [flags] -- <cmd>...  share one command

  --server <url>     relay origin (or ONLYTTY_SERVER), e.g. https://relay.example.com
  --control <mode>   viewer control policy: ask (default; auto-grants control to
                     any viewer that requests it — there is no host approval
                     prompt), view-only (never), or once (auto-grant the first
                     request only). Take control back any time (any mode) with:
                     kill -USR1 <onlytty-pid>
  --read-only        deprecated alias for --control view-only
  --ttl <dur>        session lifetime before the link expires. Default: no expiry —
                     the session lives as long as onlytty runs (it ends when the
                     command exits). Set a duration to bound it; the relay you
                     connect to may impose a maximum.
  --passphrase       prompt for a passphrase mixed into the keys; share it
                     out-of-band so the link alone cannot decrypt
  --passphrase-generate
                     generate a strong passphrase host-side and print it; send it
                     in a different channel than the link (never the same message)
  --no-qr            print the link without a QR code
  --allow-insecure   allow a plain http:// relay to a non-local host
                     (development/testing only — production requires https)
  --verbose          always print viewer connect/disconnect/control notices
                     inline. By default they appear only when no full-screen or
                     line-drawing app (editor, Claude Code, …) is active, so
                     notices never corrupt what's on screen.
  --version
```

The terminal shows a **fingerprint**; the browser shows the same one. If they match,
both ends derived the same keys from the same secret. If they differ — usually a
wrong passphrase — the viewer says it can't decrypt and lets you re-enter the
passphrase without reloading, instead of hanging silently.

## The mobile viewer

The browser viewer (xterm.js, no framework, no build step) is built for phones:

- **View-only by default.** Tap **Take control** to type; the host sets the policy with `--control` — `ask` (the default) **auto-grants** control to any viewer who asks, with no host prompt; `view-only` never grants; `once` auto-grants the first request only. The host can take control back any time with `kill -USR1 <onlytty-pid>`.
- **Touch key bar** — Esc, Tab, Ctrl (sticky, for `Ctrl-<key>`), arrows, `^C`, `^D`.
- **Paste guard** confirms before sending a multi-line paste.
- **Reconnect & resume** — drops are repainted from the runner's ring buffer.
- **Wake lock**, font-size controls, and host-driven sizing while watching (your size once you take control).

## Security model

End-to-end encryption means the **relay** never sees terminal IO: it forwards opaque,
authenticated ciphertext and stores none of it. A replayed or reordered frame is
rejected (a session-long sequence floor); a read-only viewer cannot type *or* resize
the host. That is the strong guarantee.

It is **not** zero-trust, and here's the honest residue:

- **The browser runs JS served by the relay host.** A malicious host could serve a
  viewer that exfiltrates the secret from the fragment. So host trust is reduced to
  *code-delivery time*, not *relay time*. The first-party viewer code is served
  `Cache-Control: no-store` (you always fetch the audited bytes; a tampered bundle
  can't be cached), and the third-party code (xterm) is vendored and
  Subresource-Integrity-pinned. A native viewer (no browser JS) would remove this
  caveat entirely.
- **The link is a capability.** Anyone you forward it to becomes a viewer. Mitigate
  with a short `--ttl`, the single-viewer lock (default), and `--passphrase`.
- **Trust the fingerprint, not the prose.** The fingerprint shown at both ends is
  derived from the secret and is trustworthy. A "viewer connected" notice in the
  terminal is relay-delivered metadata and could be spoofed by a hostile relay (which
  still cannot read or inject your terminal).

Found a vulnerability? See [SECURITY.md](SECURITY.md).

## Self-host the relay

The relay is an Elixir release container. Sessions are **in memory only** — nothing
terminal-related is ever persisted, so there is no database. It **scales horizontally**:
run several instances behind the load balancer and they form one BEAM cluster, so a
runner and a viewer that hit different instances still pair (sessions are registered
cluster-wide via `:global`). See [`infra/`](infra/README.md) for the multi-instance setup.

```bash
docker build -t onlytty-server ./portal      # or pull ghcr.io/andrewdryga/onlytty
docker run -p 4000:4000 \
  -e PHX_SERVER=true \
  -e SECRET_KEY_BASE="$(openssl rand -base64 64)" \
  -e PHX_HOST=relay.example.com \
  -e PORT=4000 \
  onlytty-server
```

Put it behind a TLS-terminating proxy (Cloudflare, Fly, Render, Caddy, nginx) that
forwards `x-forwarded-proto`. **TLS is required**: in production the relay redirects
http→https and sets HSTS, and the browser's Web Crypto API only works in a secure
context — without HTTPS the viewer refuses to run.

| Env | Default | Meaning |
|-----|---------|---------|
| `PHX_SERVER` | — | set `true` to start the HTTP server |
| `SECRET_KEY_BASE` | — | required in prod (`mix phx.gen.secret`) |
| `PHX_HOST` | `example.com` | public hostname (URLs + the http→https redirect) |
| `PORT` | `4000` | listen port |
| `ONLYTTY_DEFAULT_TTL` | `0` | TTL (s) for a request that omits one; `0` = no expiry |
| `ONLYTTY_MAX_TTL` | _(unset)_ | optional hard TTL ceiling (s); unset = no ceiling |
| `ONLYTTY_MAX_SESSIONS` | `2000` | cap on concurrent sessions |

Further tuning — `ONLYTTY_IDLE_TIMEOUT`, `ONLYTTY_MAX_FRAME_BYTES`,
`ONLYTTY_ALLOWED_ORIGINS`, `ONLYTTY_RATELIMIT_MAX`/`_WINDOW`, `ONLYTTY_METRICS_TOKEN`,
and `SENTRY_DSN` — is documented in
[`portal/config/runtime.exs`](portal/config/runtime.exs). The relay exposes aggregate,
label-free operator counters at `GET /metrics` (Prometheus text; loopback-only unless
you set `ONLYTTY_METRICS_TOKEN`).

## Contributing

Contributions welcome. `make check` runs the full test gate (Go runner + Elixir relay +
Node viewer) and `make e2e` drives a real session end-to-end; the wire and crypto
contract every component obeys is in [PROTOCOL.md](PROTOCOL.md).

## License

[MIT](LICENSE)
