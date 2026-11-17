---
name: dependency-holds
description: taking or holding exactly the version you mean — Hex lifts its cooldown for an advisory fix, a named update moves packages you didn't name, the Terraform provider needs an exact pin, and cooldown edges are publish times
subsystem: deps
sources: [portal/mix.lock, portal/mix.exs, infra/versions.tf, infra/.terraform.lock.hcl]
updated: 2026-11-17
---
**A security fix younger than the cooldown.** Hex makes this exception itself: its cooldown
doesn't apply to a package whose locked release has an advisory, nor to that release's direct
dependencies (`mix help hex.config`). So `mix deps.update <pkg>` takes a same-day fix under the
machine's `cooldown: 7d`, with no override. Two things to do by hand:
- Before trusting the young release, compare every file in its tarball from `repo.hex.pm` with
  the same path at the upstream tag, and check that the publisher is the usual one.
- The lifted cooldown lets unrelated young children ride along (telemetry did, with plug). Put
  their lock lines back, run `mix deps.get`, and name them as held.

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
- 2026-11-17 — created from the v0.4.18 security patches and refresh (checked against
  `mix help hex.config` and the commands as run).
