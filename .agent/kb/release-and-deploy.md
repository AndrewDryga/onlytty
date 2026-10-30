---
name: release-and-deploy
description: a tag runs release.yml, which publishes the GitHub release and the GHCR image; verify the artifacts, not the badges; deploying is a human-confirmed Terraform Cloud run
subsystem: release
sources: [.github/workflows/release.yml, .github/workflows/promote-image.yml, .github/workflows/ci.yml, Makefile, CHANGELOG.md, install.sh]
updated: 2026-10-29
---
**Cut a release.** Fix commits don't touch `CHANGELOG.md`; a `chore(release): prepare vX.Y.Z`
commit adds the version's section. Push `main` and wait until CI, Deploy check and Selfhost check
are green on that exact commit. Then tag it `vX.Y.Z` (annotated, with a one-line summary) and
push the tag. Run `make audit` locally before tagging: the gate job in `release.yml` reruns
check, e2e and audit, and a red gate burns the tag (v0.4.11 stayed a source-only tag that way).
The tag publishes four runner tarballs, `SHA256SUMS` and `VIEWER_HASHES` to the GitHub release,
with build provenance, plus the multi-arch `ghcr.io/andrewdryga/onlytty:X.Y.Z` and `:latest` image.

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
- 2026-10-29 — created from the release LOG entries (v0.4.12 to v0.4.17); checked against
  `release.yml`, `promote-image.yml` and the published v0.4.17 artifacts.
