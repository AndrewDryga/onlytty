---
name: dependency-refresh
description: how a dependency refresh is done here — releases at least 7 days old, one commit per risk class, pins re-resolved from tags, and the checks CI can't run
subsystem: deps
sources: [.tool-versions, .github/workflows/ci.yml, .github/dependabot.yml, portal/Dockerfile, portal/mix.exs, portal/mix.lock, portal/lib/onlytty/cluster/gce.ex, runner/go.mod, infra/versions.tf, package.json]
updated: 2026-11-17
---
**Cooldown.** Take the newest release that is at least 7 days old, in every ecosystem: Go, Hex,
npm, GitHub Actions, Terraform providers and base images. Name each release you held back, and the
date it clears, in the commit message.

**A security fix younger than the cooldown.** Hex makes this exception itself: its cooldown
doesn't apply to a package whose locked release has an advisory, nor to that release's direct
dependencies (`mix help hex.config`). So `mix deps.update <pkg>` takes a same-day fix under the
machine's `cooldown: 7d`, with no override. Two things to do by hand:
- Before trusting the young release, compare every file in its tarball from `repo.hex.pm` with
  the same path at the upstream tag, and check that the publisher is the usual one.
- The lifted cooldown lets unrelated young children ride along (telemetry did, with plug). Put
  their lock lines back, run `mix deps.get`, and name them as held.

**One commit per risk class**, so each can be reverted alone:
- libraries within their current majors;
- toolchains, base images and action pins, moved in lockstep (`.tool-versions`, the workflow
  inputs and the Dockerfile ARGs must agree);
- each major upgrade on its own;
- an OS move of the server image on its own.

**Pins.** Re-resolve every GitHub Action pin from its tag, dereferencing annotated tags. A SHA that
doesn't match its version comment is a supply-chain defect, not a nit.

**What CI can't prove.**
- The Sentry handler attaches only when `SENTRY_DSN` is set, so CI never runs it. Prove a Sentry
  bump by capturing the envelope a deliberate crash sends to a throwaway local intake.
- Check a Terraform provider bump with `terraform init -upgrade -backend=false` and
  `terraform validate`, and never touch the HCP workspace. Its plan must still be reviewed in TFC
  before an apply, and it should be a no-op.
- After a Go bump, `make audit` exiting 126 means govulncheck isn't installed for the new Go
  (asdf installs tool binaries per Go version). It is not a finding.
- hackney carries two production paths that CI never opens over real TLS: cluster discovery
  (`OnlyTTY.Cluster.GCE` calls `compute.googleapis.com`) and the Sentry transport. It checks
  hostnames with `ssl_verify_hostname:verify_fun/3` from ssl_verify_fun. Prove a bump of either
  package with the discovery call itself (`:hackney.request/5` unauthenticated: a 401 means the
  handshake and the hostname check passed), and with `hackney_ssl:connect/4` plus
  `hackney_ssl:ssl_opts/2` against a certificate for another host, which must end in a TLS
  alert. A timeout is not a rejection.

## Changelog
- 2026-11-17 — added the security-fix exception and the hackney hostname check, from patching
  plug 1.20.4 and ssl_verify_fun 1.1.9 for v0.4.18 (checked against `mix help hex.config`,
  `hackney_ssl.erl` in hackney 4.9.1 and `portal/lib/onlytty/cluster/gce.ex`).
- 2026-10-29 — created from the 2026-08-06 and 2026-10-29 refresh LOG entries.
