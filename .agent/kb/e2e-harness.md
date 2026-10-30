---
name: e2e-harness
description: make e2e boots its own unthrottled relay, the browser suite runs the runner headless, and CLI behaviour that needs a real terminal is tested on a PTY through a TestMain re-exec
subsystem: tests
sources: [dev/scripts/e2e.sh, dev/test/browser/viewer.test.js, portal/config/config.exs, runner/cmd/onlytty/main_test.go]
updated: 2026-10-29
---
**Its own relay, unthrottled.** `make e2e` refuses to run against a relay already listening on
:4000, because a stale server could make a changed tree look green (`ONLYTTY_REUSE_SERVER=1`
opts in). It boots its own with `ONLYTTY_RATELIMIT_MAX=0`. The default per-IP limit (30 per 60 s)
covers session creates and both WebSocket upgrades, and one harness IP running 22 tests' worth
of sessions trips it mid-suite. That was the 2026-08 "headless timing" flake. Any abuse control
keyed on client IP is hostile to a single-IP harness.

**Headless runner.** The browser suite spawns the binary with stdin ignored and stderr piped, so
no launch gate arms and nothing opens `/dev/tty`. Wait for the viewer's "connected" status before
clicking Take control. The verify overlay appears before the socket exists, so a click while the
socket is still connecting is dropped.

**CLI tests on a real terminal.** For behaviour that depends on stdin, the controlling terminal
or termios, `TestMain` in `main_test.go` re-executes the test binary as `onlytty`
(`ONLYTTY_TEST_MAIN=1`) on a `pty.Open` pair (`Setsid`, `Setctty`) against an `httptest` relay.
- Drain the master to EOF before `Wait`: on macOS an exiting process blocks until its terminal
  output has been read.
- Build the command's markers with `printf`, because the banner and the launch prompt echo the
  command line verbatim.

## Changelog
- 2026-10-29 — created from the 2026-08-06 flake fix and the `6702120` PTY regression test.
