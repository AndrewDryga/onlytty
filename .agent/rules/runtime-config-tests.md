# Runtime Config Tests

Tests for operator-facing runtime knobs must drive the same process environment path that
deployments use. Do not set `Application.put_env(:onlytty, key, value)` directly in tests
for settings that are documented as `ONLYTTY_*` variables; use a helper that sets/restores
`System` env, runs the shared parser, and then applies the resulting app env for the test.
