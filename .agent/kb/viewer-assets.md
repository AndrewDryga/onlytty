---
name: viewer-assets
description: the vendored xterm naming and SRI scheme, VIEWER_HASHES, where testable viewer code goes, and what xterm's onData carries besides typing
subsystem: viewer
sources: [portal/priv/static/viewer.html, portal/priv/static/assets/app.js, portal/priv/static/assets/keys.js, portal/test/onlytty_web/http_test.exs, dev/test/web/keys.test.js, Makefile]
updated: 2026-10-29
---
**Vendored xterm.** Files in `assets/vendor/` are named `<name>.<sha256[:8]>.<ext>`, and nothing
else records their version: identify one by hashing it against the npm tarball. An upgrade
renames the files, so it also touches `viewer.html` (the script tags and their SRI `integrity`),
the Makefile's `viewer-hash` list and the immutable-asset test in `http_test.exs`.

**VIEWER_HASHES.** Every release publishes the SHA-256 of each viewer asset (`make viewer-hash`)
so anyone can check what the relay serves. Editing any first-party viewer file changes it.

**Testable code lives outside app.js.** `app.js` touches the DOM when it is imported. Pure helpers
go in `keys.js`, `wire.js` or `crypto.js`, which `make web-check` unit-tests under Node
(`dev/test/web/`).

**onData isn't only typing.** xterm also emits answers to the program's terminal queries (and
answers them again when a join repaint replays them), mouse reports while the program tracks the
mouse, and focus in/out reports. Claude Code turns on all three. `isTerminalReport` in `keys.js`
recognises them, and a read-only viewer drops them instead of treating them as a request for
control.

## Changelog
- 2026-10-29 — created: the xterm notes come from the 2026-08-06 upgrade to 6.0.0, the onData
  notes from `6331c00`.
