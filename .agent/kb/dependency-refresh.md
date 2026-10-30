---
name: dependency-refresh
description: how a dependency refresh is done here — releases at least 7 days old, one commit per risk class, pins re-resolved from tags, and the checks CI can't run
subsystem: deps
sources: [.tool-versions, .github/workflows/ci.yml, .github/dependabot.yml, portal/Dockerfile, portal/mix.exs, runner/go.mod, infra/versions.tf, package.json]
updated: 2026-10-29
---
**Cooldown.** Take the newest release that is at least 7 days old, in every ecosystem: Go, Hex,
npm, GitHub Actions, Terraform providers and base images. Name each release you held back, and the
date it clears, in the commit message.

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

## Changelog
- 2026-10-29 — created from the 2026-08-06 and 2026-10-29 refresh LOG entries.
