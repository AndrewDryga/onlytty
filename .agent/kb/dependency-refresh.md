---
name: dependency-refresh
description: how a dependency refresh is done here — releases at least 7 days old, one commit per risk class, pins re-resolved from tags, and the checks CI can't run
subsystem: deps
sources: [.tool-versions, .github/workflows/ci.yml, .github/dependabot.yml, portal/Dockerfile, portal/mix.exs, portal/lib/onlytty/cluster/gce.ex, runner/go.mod, infra/versions.tf, package.json, dev/scripts/selfhost-check.sh]
updated: 2026-11-17
---
**Cooldown.** Take the newest release that is at least 7 days old, in every ecosystem: Go, Hex,
npm, GitHub Actions, Terraform providers and base images. Name each release you held back, and the
date it clears, in the commit message. The one exception, a security fix for an advisory, and
how to take exactly the versions you mean are in [dependency-holds](dependency-holds.md).

**One commit per risk class**, so each can be reverted alone:
- libraries within their current majors;
- toolchains, base images and action pins, moved in lockstep (`.tool-versions`, the workflow
  inputs and the Dockerfile ARGs must agree);
- each major upgrade on its own;
- an OS move of the server image on its own.

**Pins.** Re-resolve every GitHub Action pin from its tag, dereferencing annotated tags. A SHA that
doesn't match its version comment is a supply-chain defect, not a nit. Image tags also hide in
scripts: `dev/scripts/selfhost-check.sh` pins Caddy and a curl image.

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
- 2026-11-17 — added the hackney proof and the script image pins, and moved the notes on taking
  or holding a version to `dependency-holds` (from v0.4.18; checked against `hackney_ssl.erl` in
  hackney 4.10.2, `portal/lib/onlytty/cluster/gce.ex` and `selfhost-check.sh`).
- 2026-10-29 — created from the 2026-08-06 and 2026-10-29 refresh LOG entries.
