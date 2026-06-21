# OnlyTTY protocol (v1)

The contract every component agrees on: the Go runner, the Elixir relay, and the
browser viewer. It is the source of truth — change it here first, then the code.

## Roles & trust

```
runner (Go, your machine)  ⇄  relay (Elixir, untrusted)  ⇄  viewer (browser)
```

- The **runner** spawns a command (or your shell) in a PTY and shares it.
- The **relay** pairs a runner with a viewer by session id and forwards bytes.
  It is **untrusted**: it only ever sees ciphertext + metadata, never terminal IO.
- The **viewer** is a browser page that decrypts and renders the terminal.

The runner and viewer share a **session secret S** that the relay never sees. All
terminal IO is end-to-end encrypted under keys derived from S. A compromised relay
can drop/observe-timing/deny, but cannot read or forge terminal IO.

## Identifiers

- **session id** — URL-safe random string (≥120 bits). In the URL *path*; the relay
  sees it (needs it to pair). Knowing the id lets you *connect* as a viewer, but not
  *decrypt* anything. Unguessable, so it doubles as the viewer connect capability.
- **runner token** — separate random string (≥120 bits) returned only to the runner
  at create time, never in any URL. Authorizes the privileged runner socket so a
  viewer cannot impersonate the runner.
- **session secret S** — 32 random bytes the runner generates locally. Lives **only**
  in the URL *fragment* (`#…`), which browsers never send to a server. The root of
  all E2E keys.

## The link

```
https://<host>/s/<id>#<base64url(S)>
```

The runner prints this (and a QR of it) locally. The fragment never leaves the
browser, so the relay only ever learns `<id>`. With a passphrase (optional), the
fragment is `#<base64url(S)>.p` — the trailing `.p` flags that a passphrase must be
mixed in (the passphrase itself is shared out-of-band, never in the link).

## Key derivation

```
ikm  = S                              (32 bytes)
ikm  = S || PBKDF2-HMAC-SHA256(passphrase, salt=id, 600000, 32)   (if passphrase)
salt = utf8(id)
k_r2v = HKDF-SHA256(ikm, salt, info="relay/v1 runner->viewer", 32)   # runner→viewer
k_v2r = HKDF-SHA256(ikm, salt, info="relay/v1 viewer->runner", 32)   # viewer→runner
fp    = base32(HKDF-SHA256(ikm, salt, info="relay/v1 fingerprint", 10))  # short, shown both ends
```

HKDF is RFC 5869 (Go `crypto/hkdf`, WebCrypto `HKDF`). AEAD is **AES-256-GCM** (Go
`crypto/cipher`, WebCrypto `AES-GCM`) — both stdlib on both sides, no dependency.

## Frames

Two kinds of WebSocket message, distinguished by WS opcode:

- **text** frames = relay control plane (JSON). Carry only metadata; the relay reads
  and writes them. **Never** any terminal content.
- **binary** frames = end-to-end payload. The relay forwards them verbatim and cannot
  read them.

### Binary frame (opaque to the relay)

```
| nonce (12 bytes) | ciphertext+tag (GCM) |
```

- **nonce**: 12 cryptographically random bytes, fresh per frame. Random (not a
  counter) so reconnects/reloads can never reuse a (key, nonce) pair. At terminal
  message volumes the 96-bit birthday risk is negligible.
- **ciphertext** = `AES-256-GCM-Seal(key=k_dir, nonce, plaintext, aad=utf8(id))`.
  `aad=id` binds every frame to its session (no cross-session replay).

Plaintext, before sealing:

```
| seq (uint64 BE) | kind (uint8) | payload (kind-specific) |
```

`seq` is a per-direction counter for **replay protection** (it is authenticated, so
the relay cannot alter it). See "Replay" below.

> **JS precision note.** `seq` (and `HELLO.baseline`) are uint64 on the wire. The Go
> runner uses `uint64`; the browser viewer represents them as JS `Number`, which is
> exact only up to 2^53 (`Number.MAX_SAFE_INTEGER`). A session would need ~9
> quadrillion frames to reach that, so the conversion is lossless in every real
> session — the viewer does not use `BigInt` end-to-end. This is asserted by a unit
> test (`dev/test/web/wire.test.js`).

#### Message kinds

runner → viewer (sealed with `k_r2v`):

| kind | name    | payload                                            |
|------|---------|----------------------------------------------------|
| 0x01 | HELLO   | `baseline:uint64 BE`, `cols:uint16 BE`, `rows:uint16 BE` |
| 0x02 | OUTPUT  | raw PTY bytes                                       |
| 0x03 | EXIT    | `code:int32 BE`                                     |
| 0x04 | CONTROL | `state:uint8` (0 = read-only, 1 = control granted) |

viewer → runner (sealed with `k_v2r`):

| kind | name      | payload                          |
|------|-----------|----------------------------------|
| 0x10 | INPUT     | raw keystroke bytes              |
| 0x11 | RESIZE    | `cols:uint16 BE`, `rows:uint16 BE` |
| 0x12 | CTRL_REQ  | (empty) — request to take control |
| 0x13 | CTRL_REL  | (empty) — release control         |

`CONTROL.state` stays 0/1 on the wire; the host's `--control` policy (`ask` /
`view-only` / `once`) and the `SIGUSR1` revoke only decide *when* the runner emits
`granted` vs `read-only` — they add no new frame kinds.

`HELLO` is the first frame the runner sends to a newly-joined viewer; `baseline` is
the seq the viewer must start its `k_v2r` counter at (see Replay). The runner then
replays its output ring buffer (as `OUTPUT` frames with fresh seq) so the screen
repaints, then streams live.

### Replay protection

- The runner keeps one session-long monotonic `inSeq` = the highest viewer→runner
  seq it has accepted. It **never resets**. It accepts a v2r frame iff `seq > inSeq`,
  then sets `inSeq = seq`. Replayed old input is therefore rejected — including
  across viewer reconnects, which is the case that matters (re-running keystrokes).
- On each viewer join the runner sends `HELLO.baseline = inSeq + 1`; the viewer
  starts its outgoing counter there. A fresh/reconnected viewer thus always sends
  seq above anything the runner has seen; a relay replaying that viewer's old frames
  uses lower seq and is rejected.
- runner→viewer replay is only cosmetic (stale screen, overwritten live), so the
  viewer just requires output seq to increase within its current connection.

## Relay control plane (text JSON)

relay → client:

```json
{"t":"hello","role":"runner|viewer","viewers":N,"locked":true}
{"t":"peer_join"}     // runner: a viewer connected. viewer: runner is present.
{"t":"peer_left"}
{"t":"busy"}          // viewer slot taken (single-viewer lock); relay then closes
{"t":"bye","reason":"expired|closed|idle|ended"}
```

client → relay: `{"t":"bye"}` closes that client socket. A runner may send
`{"t":"bye","reason":"ended"}` after its command exits; the relay closes the whole
session so viewers see an explicit final state even if the encrypted `EXIT` frame
was missed.

When a viewer connects, the relay sends the runner `{"t":"peer_join"}`; the runner
replies (over the binary channel) with `HELLO` + buffer replay. The relay forwards
binary runner↔viewer verbatim.

## Endpoints

- `POST /api/sessions` → `{"id","runner_token","expires_at"}`.
  Optional body `{"ttl_seconds":int}` (default `0` = no expiry; a positive value is
  floored at 60s and capped by the relay's optional `ONLYTTY_MAX_TTL`). `expires_at`
  is `0` when the session has no expiry.
- `GET  /s/:id` → the viewer HTML page (static; JS reads id from path, S from `#`).
- `GET  /ws/runner/:id` → WebSocket; requires `Authorization: Bearer <runner_token>`.
- `GET  /ws/viewer/:id` → WebSocket; capability is knowing `:id`.
- `GET  /healthz` → `200 ok`.

## Session lifecycle & limits (relay)

- Sessions live **in memory only** — nothing terminal-related is ever persisted.
- TTL: with a positive `ttl_seconds`, the session is closed at `expires_at`; by
  default there is no TTL — the session lives as long as the runner (it ends on
  command exit or runner disconnect).
- Single-viewer lock by default: a second viewer gets `{"t":"busy"}` and is closed.
- Idle timeout: closed after a period with no runner traffic.
- The relay forwards binary frames it cannot decrypt; it stores none of them.

## Trust boundary, stated honestly

E2E means the **relay** never sees terminal IO. It does **not** mean zero trust:

- The viewer runs JS served by the host. A malicious host could serve JS that
  exfiltrates S from the fragment. Mitigation: the first-party JS is served
  `no-store` (always re-fetched, never a stale cached copy) and its SHA-256 is
  published per release in `VIEWER_HASHES`, so served bytes can be checked against
  the audited release; the vendored xterm assets are additionally Subresource-
  Integrity-pinned and content-hashed in their filenames. A native viewer (no
  browser JS) is possible later. So host trust is reduced to *code-delivery time*,
  not *relay time*.
- The link is a capability: anyone you forward it to is a viewer. Mitigations: short
  TTL, single-viewer lock, the optional passphrase (link alone is then insufficient).
