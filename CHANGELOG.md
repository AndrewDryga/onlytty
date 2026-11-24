# Changelog

All notable changes to OnlyTTY are recorded here.

## [0.4.22] - 2026-11-23

- Updated the relay to Phoenix 1.8.17, which fixes two denial-of-service issues in Phoenix.
- The phone and browser guides now explain when to press Enter on the host to start a shared terminal. The Neovim guide also shows how to save your edit and check it on the host.

## [0.4.21] - 2026-11-19

The runner and the viewer are the same as in 0.4.20.

### Security

- The relay reads the parameters of `POST /api/sessions` only from a JSON
  body. It used to read the query string too, so a page on another site
  could make a visitor's browser create sessions with a plain cross-origin
  POST, which browsers send without asking the relay first. Those sessions
  lingered until the relay cleared them two minutes later. It also keeps
  runner tokens out of URLs and access logs. The runner always sends a JSON
  body, so nothing that uses the relay changes.

## [0.4.20] - 2026-11-19

The runner and the viewer are the same as in 0.4.19.

### Security

- Update idna to 8.0.0 in the relay. It comes with hackney 4.11.1, the
  relay's HTTP client, and the h2, quic and webtransport versions that
  hackney requires. idna 7.1.0 converted a hostname label longer than 63
  octets in full before rejecting it, in super-linear time, so one long
  label could keep the CPU busy (CVE-2026-117678). hackney calls idna only
  for a non-ASCII hostname, and the relay's own requests, for cluster
  discovery and error reporting, go to hostnames fixed in code or
  configuration, so a client couldn't reach it.

### Changed

- Shorter meta descriptions, the summary a search engine shows under the
  title, for the self-hosting page and the per-tool "Control … from your
  phone" pages.

## [0.4.19] - 2026-11-17

### Security

- The relay parses only JSON request bodies. Form-encoded and multipart bodies
  are no longer read on any path, so bugs in those parsers, like the multipart
  one fixed in 0.4.18 (CVE-2026-120287), can't be reached. A form-encoded or
  multipart post to the session API no longer creates a session.

### Fixed

- When a shared command exits, the runner no longer re-creates its session on
  the relay. It used to dial again while finishing, find the session it had
  just ended and register it anew, printing "relay session was replaced
  (deploy?) — re-establishing" after the command was done. The relay then kept
  a session with no runner for two minutes.
- In the viewer, Take control stays disabled until the runner is connected, and
  again while it is away. A tap or a keystroke before that could end, 3
  seconds later, in "control not granted — host is view-only", which wasn't
  true. The status now reads "connected" only once the runner has answered.
- The relay answers a request to a session's socket address that isn't a
  WebSocket handshake with 400 instead of a server error.

### Changed

- A daily workflow now runs the dependency audit on `main`, so a new advisory
  shows up between releases instead of at the next one.

### Documentation

- The self-hosting guide now says who can read `/metrics`. With the relay in
  Docker, anything outside the container needs `ONLYTTY_METRICS_TOKEN`. With
  host networking, a proxy on the same machine reaches it over loopback, and
  the guide shows how to block it in nginx.

## [0.4.18] - 2026-11-17

The viewer is unchanged from 0.4.17.

### Security

- Update Plug to 1.20.4 in the relay. A crafted multipart request could make
  the relay hold many times the request's size in memory, because the body
  size limit didn't count the framing of each part and header
  (CVE-2026-120287). Self-hosted relays should update.
- Update ssl_verify_fun to 1.1.9 in the relay. A certificate with a
  partial-label wildcard could match a hostname across a label boundary
  (CVE-2026-117666). Erlang/OTP's own hostname check runs first and already
  rejected such certificates on the relay's outbound HTTPS calls.
- Build the runner with Go 1.27.4, which fixes a standard-library
  vulnerability in `net/http` servers reported by the release audit
  (GO-2026-6859). The runner starts no HTTP server.
- Build the relay image with Elixir 1.20.5, which fixes vulnerabilities in
  `URI.parse`, the built-in JSON decoder and Mix (CVE-2026-109821,
  CVE-2026-115274, CVE-2026-97209), on the Debian 13 base image of
  2026-11-04.
- Update Caddy to 2.11.9 in the self-host bundle. Caddy 2.11.8 and 2.11.9
  carry security fixes. For the bundle's reverse proxy they finish the fix for
  CVE-2026-55458, which left hop-by-hop headers on 1xx responses. An existing
  install keeps the Caddy tag in its own copy of `compose.yml` until you
  change it.

### Changed

- Update hackney to 4.10.2 in the relay. It is the HTTP client for cluster
  discovery and error reporting, and 4.10 fixes connection-pool leaks, TLS
  errors on concurrent connects and two HTTP/2 denial-of-service issues.
- Update Sentry to 14.0.1, libcluster to 3.6.0 and websock_adapter to 0.7.2
  in the relay, and `golang.org/x/term` and `golang.org/x/sys` in the runner.
- Update the build and deploy tooling: Node 26.13.0, Playwright 1.65.0,
  Terraform 1.17.1 and the Google provider 8.11.0 in `infra/`, and the
  release workflow's `docker/login-action` and `softprops/action-gh-release`
  pins. The release workflow now fails instead of publishing a release that
  is missing its binaries.

### Documentation

- The Neovim page now links the browser-edit example and says when Neovim in
  Termux, SSH or Mosh is the better fit.
- Reword the "Who can take control of my session?" answer on the home page.
  It now says outright that control requests are approved automatically by
  default.

## [0.4.17] - 2026-10-29

### Fixed

- Starting a command from the installer (`curl … | sh -s -- claude`) no longer
  types the rest of the install script into it. The runner now takes your keys
  from the terminal, in raw mode and at the terminal's size. Before, it read the
  installer's pipe, so your keys were echoed over the command's screen (Ctrl+C
  in Claude Code showed as `^[[99;5u`) and never reached the command.
- Opening a link, or hovering over or focusing the viewer, no longer takes
  control. The browser terminal's automatic replies to the command's terminal
  queries, and its mouse and focus reports, counted as typing, so a viewer
  that was only watching Claude Code took control and resized the host's
  terminal to the browser. Typing or tapping **Take control** still asks.

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
