---
name: release-and-deploy
description: a tag runs release.yml, which publishes the GitHub release and the GHCR image; verify the artifacts, not the badges; deploying is a human-confirmed Terraform Cloud run
subsystem: release
sources: [.github/workflows/release.yml, .github/workflows/promote-image.yml, .github/workflows/ci.yml, .github/workflows/selfhost-check.yml, Makefile, CHANGELOG.md, install.sh]
updated: 2026-11-17
---
**Cut a release.** Run `make audit` twice. First before you write the changelog: advisories
arrive between releases, and each one means a patch commit that belongs in the notes (v0.4.18
found three). Then again right before tagging, with govulncheck reinstalled at `@latest`,
because the gate installs the newest one and an advisory can follow its fix by minutes (plug's
did). The gate job in `release.yml` reruns check, e2e and audit, and a red gate burns the tag
(v0.4.11 stayed a source-only tag that way). Fix commits don't touch `CHANGELOG.md`; a
`chore(release): prepare vX.Y.Z` commit adds the version's section. Push `main` and wait until
CI, Deploy check and Selfhost check are green on that exact commit. Selfhost check is
path-filtered (`selfhost/**`, `portal/**`, its script and its workflow), so a CHANGELOG-only
push doesn't start it and its last run stands. Then tag the commit `vX.Y.Z` (annotated, with a
one-line summary) and push the tag.
The tag publishes four runner tarballs, `SHA256SUMS` and `VIEWER_HASHES` to the GitHub release,
with build provenance, plus the multi-arch `ghcr.io/andrewdryga/onlytty:X.Y.Z` and `:latest` image.
Nothing else runs the two publish jobs, so an action pin bumped there is first exercised by the
tag. `fail_on_unmatched_files` makes the release step fail before it creates a release with no
binaries.

**Verify the artifacts, not the badges.**
- The release is Latest, and every tarball matches `SHA256SUMS`.
- `VIEWER_HASHES` is byte-identical to `make viewer-hash` on the tagged tree.
- The binary prints the new version.
- `gh attestation verify <tarball or oci://image> --repo AndrewDryga/onlytty --format json`
  verifies. Without `--format json`, gh prints nothing when stdout isn't a terminal.
- `docker buildx imagetools inspect` shows `X.Y.Z` and `latest` on one digest, for linux/amd64
  and linux/arm64.

**Deploy.** `install.sh` always fetches the Latest release, so the runner ships at tag time. The
relay, and the viewer it serves, ship only through Terraform Cloud, the deployment authority.
The `Promote image` workflow (input `version`) pins the workspace's `container_image` variable
and queues a run, and a human confirms the apply in TFC. Runs queue per workspace: an older run
that is waiting for confirmation must be applied or discarded first. Check that the plan deploys
the image you meant before confirming. Production has no version endpoint. Compare the live
viewer assets (served `no-store`) with the release's `VIEWER_HASHES`, or probe a route the
release changed.

## Changelog
- 2026-11-17 — audit before the changelog and again before the tag, Selfhost check's path
  filter, and the publish jobs' first-run risk (from v0.4.18; checked against
  `selfhost-check.yml`, `release.yml` and `softprops/action-gh-release` `src/run.ts` at v3.0.4).
- 2026-10-29 — created from the release LOG entries (v0.4.12 to v0.4.17); checked against
  `release.yml`, `promote-image.yml` and the published v0.4.17 artifacts.
