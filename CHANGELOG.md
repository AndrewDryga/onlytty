# Changelog

All notable changes to OnlyTTY are recorded here.

## [0.4.16] - 2026-10-29

### Fixed

- Serve the browser-edit example's screenshots and test record. The files were
  included in the release but missing from the relay's static-file allowlist.

## [0.4.15] - 2026-10-29

### Security

- Move the relay image to Debian 13 (trixie). Debian 12 handed security
  maintenance to Debian LTS in June 2026; the image now runs on the current
  stable release, with Elixir 1.20.4 and OTP 29.1.2.

### Added

- The Neovim and K9s pages now include a short walkthrough: the launch
  command, the keys to use from a phone, how to exit, and what view-only mode
  and `k9s --readonly` do and don't protect.

### Changed

- Count successful copies of an install or share command on the public pages,
  as a measure of interest rather than of installs. The event never includes
  the copied text, honors Do Not Track, and is disclosed on the privacy page.
- Load marketing analytics only on onlytty.com, so self-hosted relays and local
  previews no longer report to OnlyTTY's analytics.
- Copy buttons now say when the browser blocks the clipboard, and are hidden
  when JavaScript is off. Dimmed text on the marketing site has more contrast.
- Build the runner with Go 1.27.3 and move the relay to Sentry 14. Also update
  the Go, Hex and npm dependencies, the Terraform Google provider (now 8.x),
  Caddy 2.11.7 in the self-host bundle, and the CI action pins.

## [0.4.14] - 2026-10-29

Includes the documentation changes in 0.4.13. That tag remains source-only: its
release audit stopped publication because the pinned Go toolchain was outdated.

### Security

- Build the runner with Go 1.26.10, which fixes the standard-library
  vulnerabilities reported by the release audit. Keep the workspace, runner
  module and contributor toolchain pins together.
- Update Bandit, Hackney and PlugCrypto, with their required dependencies,
  to clear the server packages reported by the release audit.

## [0.4.13] - 2026-10-29

### Documentation

- Add a real browser-edit and view-only example, with original screenshots,
  reproduction steps, and clear device/build limits.
- Explain separate build-provenance verification in the installer comments.
  The installer's checksum check and behavior are unchanged.

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
