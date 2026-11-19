---
name: dependency-holds
description: taking or holding exactly the version you mean — Hex lifts its cooldown for an advisory fix but not for a parent the fix needs, a named update moves packages you didn't name, the Terraform provider needs an exact pin, and cooldown edges are publish times
subsystem: deps
sources: [portal/mix.lock, portal/mix.exs, infra/versions.tf, infra/.terraform.lock.hcl]
updated: 2026-11-19
---
**A security fix younger than the cooldown.** Hex makes this exception itself: its cooldown
doesn't apply to a package whose locked release has an advisory, nor to that release's direct
dependencies (`mix help hex.config`). So `mix deps.update <pkg>` takes a same-day fix under the
machine's `cooldown: 7d`, with no override. Two things to do by hand:
- Before trusting the young release, compare every file in its tarball from `repo.hex.pm` with
  the same path at the upstream tag, and check that the publisher is the usual one.
- The lifted cooldown lets unrelated young children ride along (telemetry did, with plug). Put
  their lock lines back, run `mix deps.get`, and name them as held.

**When the fix needs a young parent.** Hex's exception stops at the flagged package and its
children. It doesn't reach a parent that has to move to admit the fix: idna 8.0.0 fixed
CVE-2026-117678, but hackney 4.10.2 pins `idna ~> 7.1.0`, and the first hackney to take 8.0 was
six days old. Set `HEX_COOLDOWN` just wide enough to admit the oldest parent release that carries
the fix, here `HEX_COOLDOWN=4d mix deps.update hackney idna h2 quic webtransport`. Then read the
lock diff, vet every young tarball as above and name what the window held back. The window counts
back from now, so it admits more every hour; to regenerate the lock later, widen it or restore the
lock lines. For a rebar3 package, expect each `src/*.app.src` to differ from the tag, because
rebar3_hex re-serializes it, so compare it as a parsed term (`file:consult/1`). Also expect a
`rebar.lock` that is written at publish time.

**Read the lock diff after every `mix deps.update`.** Naming packages doesn't confine the update:
`mix deps.update sentry` also moved websock_adapter, through Sentry's optional Phoenix child. To
keep a package for its own commit, restore its lock line and run `mix deps.get`.

**Holding the Terraform provider below the newest release.** `terraform init -upgrade` takes the
newest match. Pin the exact version in `versions.tf`, run `terraform init -upgrade
-backend=false`, restore the constraint, then put `constraints = "~> 8.0"` back in the lock by
hand: a plain `init` reuses the lock and leaves that line alone.

**Cooldown edges.** Compare registry publish times, not dates. A release often clears its seven
days in the middle of a refresh (Go 1.27.4 and the Google provider 8.11.0 both did).

## Changelog
- 2026-11-19 — a fix that needs a young parent, and rebar3 packages' app.src and rebar.lock
  (from the idna 8.0.0 update for v0.4.20; checked against the Hex resolver's output and the
  vetted hackney, idna, quic, webtransport and h2 tarballs).
- 2026-11-17 — created from the v0.4.18 security patches and refresh (checked against
  `mix help hex.config` and the commands as run).
