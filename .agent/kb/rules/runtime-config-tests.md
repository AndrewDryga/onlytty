---
name: runtime-config-tests
description: tests for documented ONLYTTY_* runtime knobs go through the real env parser with with_runtime_env/2, never Application.put_env
scope: portal tests
sources: [portal/test/support/runtime_env.ex, portal/lib/onlytty/env.ex, portal/config/runtime.exs]
check: none
updated: 2026-10-29
---

# Test runtime knobs through the path deployments use

Tests for operator-facing runtime knobs must drive the same process environment path that
deployments use. Do not set `Application.put_env(:onlytty, key, value)` directly in tests for
settings documented as `ONLYTTY_*` variables. Use `OnlyTTY.Test.RuntimeEnv.with_runtime_env/2`,
which sets and restores the `System` env, runs the shared parser, and applies the resulting app
env for the test.

**Why:** `runtime.exs` parses every `ONLYTTY_*` variable through `Onlytty.Env.runtime_overrides/1`.
A test that writes the app env directly skips that parse and validation, so a misspelled,
renamed or mis-parsed variable still passes the suite while deployments get the default.

**How to apply:** wrap the case, e.g.
`with_runtime_env(%{"ONLYTTY_RATELIMIT_MAX" => "2"}, fn -> … end)`, as `rate_limit_test.exs` and
`client_ip_test.exs` do. The helper restores both the process env and the app env afterwards.

## Changelog
- 2026-10-29 — moved from `.agent/rules/` into the card format (coop v12 migration). Swept
  `portal/test`: the only direct `Application.put_env(:onlytty, …)` calls are inside the helper
  itself, so 0 violations. `check: none` because a grep can't tell a documented knob from other
  app env.
- 2026-07-01 — created with `ead5013`, which centralized the runtime env parsing.
