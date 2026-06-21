# Security

## Reporting a vulnerability

Email **andrew@dryga.com** (or open a private GitHub security advisory). Please
include a description, reproduction steps, and impact. Don't open a public issue for
a vulnerability.

## Reporting abuse

To report misuse of a hosted relay (illegal content, using it as a covert tunnel,
attacks on the infrastructure — see the [Acceptable Use Policy](https://onlytty.com/acceptable-use)),
email **andrew@dryga.com**. Terminal IO is end-to-end encrypted, so we can't read
session contents, but we can drop sessions and block traffic that abuses the service.

## Trust model in one paragraph

`onlytty` end-to-end encrypts terminal IO with AES-256-GCM under keys derived (HKDF,
optional PBKDF2 passphrase) from a 32-byte secret that lives only in the link's URL
fragment. The relay server pairs a runner with a viewer by session id and forwards
opaque, authenticated frames; it can drop, delay, or observe the *timing/size* of
traffic, but it cannot read or forge terminal IO, and it stores nothing. Frames carry
a session-long monotonic sequence so the relay cannot replay or reorder them; a
read-only viewer cannot type or resize the host. The full contract is [PROTOCOL.md](PROTOCOL.md).

## Known limitations (by design)

- **Browser-delivered code.** The viewer is JS served by the relay host, so host
  trust is reduced to *code-delivery time*, not *relay time*. Vendored third-party
  code (xterm) is Subresource-Integrity-pinned; a native viewer would remove this.
  Vendored files carry a content hash in their filename (e.g. `xterm.<hash>.js`) and
  are served `immutable`, so any upgrade changes the URL — a browser can never reuse
  a stale cached copy that would fail the new page's SRI check.
- **The link is a capability.** Anyone with the link is a viewer. Use a short
  `--ttl`, the single-viewer lock (on by default), and `--passphrase` to require a
  second secret shared out-of-band. As defense-in-depth, browser viewer WebSocket
  upgrades are same-origin-checked (host must match, or an `ONLYTTY_ALLOWED_ORIGINS`
  allowlist) so a drive-by page can't occupy the viewer slot with a leaked id — this
  is *not* the boundary (E2E + the fragment secret are); non-browser clients, which
  can omit/spoof `Origin`, are unaffected.
- **TLS is required.** The relay must be served over HTTPS (Web Crypto needs a secure
  context, and the fragment must not travel in cleartext). The prod config enforces
  http→https + HSTS.
- **In-terminal notices are metadata.** Trust the fingerprint (derived from the
  secret), not a "viewer connected" line (relay-delivered, spoofable by a hostile
  relay — which still can't read your session).
- **Release integrity ≠ authenticity.** The installer verifies `SHA256SUMS`, which
  catches a corrupted or truncated download. It does *not* prove the release is
  untampered: the sums ship from the same release as the binary, so an attacker who
  swaps one swaps both. For authenticity, every release publishes keyless SLSA build
  provenance (Sigstore, via the workflow's OIDC identity — no signing keys to manage):

  ```bash
  # a release binary
  gh attestation verify onlytty-<ver>-<os>-<arch>.tar.gz --repo AndrewDryga/onlytty
  # the portal image
  gh attestation verify oci://ghcr.io/andrewdryga/onlytty:<ver> --repo AndrewDryga/onlytty
  ```

## Verifying the served viewer

The viewer is first-party JS the relay host serves, so a hostile host *could* swap
`app.js` to exfiltrate the fragment secret. Until a native viewer exists, you can
verify the bytes you were served against the audited release.

Each tagged release publishes a `VIEWER_HASHES` manifest (SHA-256 of `viewer.html`
and every viewer asset it loads — the first-party JS, including `keys.js`, plus the
SRI-pinned vendored files). Reproduce it from a clean checkout with **`make
viewer-hash`** — the viewer has no build step, so identical files always produce
identical hashes. To check what a live relay actually sent you:

```bash
curl -fsS https://<relay>/assets/app.js | shasum -a 256   # compare to the release manifest
```

Caveat: this is a verifiable **baseline and tripwire**, not a guarantee — a hostile
host can still serve different bytes per request. A native viewer remains the real fix.

## Base-image refresh

`portal/Dockerfile` pins its base images by version (`ELIXIR_VERSION`,
`OTP_VERSION`, `DEBIAN_VERSION`) for reproducible builds. Pinning is correct, but a
pinned-and-forgotten base accrues OS CVEs. **Cadence: bump the base pins every
release, and at least monthly.** `.github/dependabot.yml` opens PRs for the image
refs it can resolve (and for CI action versions); the bare version ARGs are bumped
by hand in lockstep with `.tool-versions` and CI (the toolchain-bump task). After a
bump, rebuild and run `make deploy-check` before shipping.
