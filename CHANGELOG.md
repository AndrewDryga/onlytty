# Changelog

All notable changes to OnlyTTY are recorded here.

## [0.4.12] - 2026-08-06

Includes everything in 0.4.11, which was tagged but never published as a release.

### Security

- Refresh the relay image to Elixir 1.20.3 on OTP 29.0.5 and a current Debian
  bookworm base, so it carries the latest base-OS security updates.

### Changed

- Upgrade the browser viewer's vendored xterm.js to 6.0.0 and its fit addon to
  0.11.0. Upstream reimplemented the terminal viewport and scroll bar; the
  vendored bundle is about 196 KB larger, served immutably under a
  content-hashed URL, so it costs one extra first load and nothing after.
- Update the runner's Go modules, the relay's Hex packages, the Terraform
  provider, and the pinned Node, Go and Terraform toolchains.

## [0.4.11] - 2026-07-10

### Security

- Retain each viewer's replay sequence floor for the runner lifetime, including
  across viewer leaves and relay-forced reconnects, so captured input cannot be
  accepted again.
- Bound `multi_viewer` sessions with `ONLYTTY_MAX_VIEWERS` (default `16`) and
  rate-limit runner and viewer WebSocket upgrades per client IP.
- Make the bundled Caddy proxy provide a trustworthy per-client rate-limit key
  through `ONLYTTY_TRUSTED_PROXY_HOPS=edge`.

### Fixed

- Retry a `busy` viewer response after a previously connected tab loses its
  network, allowing its stale relay socket to expire instead of permanently
  locking out that same viewer.
- Make manual release workflow re-runs derive the artifact version, release
  tag, and image tag from the selected tag ref.

### Changed

- Run installer coverage in CI and add a path-filtered self-host bundle check
  for the shipped Compose and Caddy configuration.
