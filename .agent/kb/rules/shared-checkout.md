---
name: shared-checkout
description: other agents commit, push, tag and deploy from this same checkout, so check the index before staging and stage only your own paths
scope: git and release workflow, every agent
sources: [AGENTS.md]
check: none
updated: 2026-10-29
---

# Stage only your own work in the shared checkout

Several agents (Claude, Codex, …) work in this one checkout and may stage, commit, push, tag or
promote a release while you work. Before any `git add`, run `git status`. A staged path you didn't
stage is another agent's in-flight work: leave it alone. Stage explicit paths, never `git add -A`
or `git add .`, and read `git diff --cached --name-only` before committing. Before you push, tag or
deploy, fetch again and check what moved (`git log origin/main`, `gh run list`).

**Why:** on 2026-10-29 a Codex session staged and pushed its own commit in this checkout in the
middle of another agent's review, and a release promotion was dispatched while another release
was in flight.

**How to apply:** when the index is in flux, run the gate in a detached `git worktree` holding
exactly the tree you will commit, and commit only after `git write-tree` matches it. Record
cross-agent state, such as a deploy waiting on a human, in the task's `log.md` or `state.md`.

## Changelog
- 2026-10-29 — created from the concurrency lessons in the old global LOG (coop v12 migration).
