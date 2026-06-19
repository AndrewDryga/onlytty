<div align="center">

# relay

**Run a command anywhere, get a link, drive it from your phone — end-to-end encrypted, so the server in the middle only ever sees ciphertext.**

</div>

```bash
relay -- claude          # share one command
relay                    # share a whole shell
# → prints a link + QR.  Scan it, and an xterm in your browser is the same session.
```

`relay` wraps a command (or your shell) in a PTY on your machine, mirrors it locally
so your terminal stays live, and streams an **end-to-end-encrypted** copy to a browser
through a small relay server. The session secret lives only in the link's `#fragment`,
which never reaches the server — so a compromised or curious relay sees only opaque
bytes, never your terminal.

- **No inbound ports.** The runner dials out over WebSocket/TLS; nothing listens on your machine.
- **E2E by default.** AES-256-GCM under keys derived from a secret the relay never sees ([PROTOCOL.md](PROTOCOL.md)).
- **Mobile-first viewer.** xterm.js with a touch key bar, paste guard, reconnect, and wake lock.
- **Command-only or whole-shell.** Share just `claude`, or your `$SHELL`. Read-only by default; take control with a tap.
- **Minimal & boring.** Go runner (stdlib crypto), an Elixir relay that stores nothing, a dependency-light vanilla-JS viewer.

## Layout

| Path | What |
|------|------|
| `main.go`, `internal/` | the `relay` runner (Go CLI) |
| `server/` | the relay control plane (Elixir) |
| `server/priv/static/` | the browser viewer (vanilla JS + vendored xterm) |
| `PROTOCOL.md` | the wire + crypto contract every component obeys |

## Develop

```bash
make check        # the gate: runner (go) + web (node) + server (elixir)
```

See [PROTOCOL.md](PROTOCOL.md) for the protocol and the honest trust boundary.
