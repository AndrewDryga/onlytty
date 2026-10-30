# .agent/kb — what the code doesn't obviously carry

Descriptive knowledge an agent needs in this repo: how a subsystem actually works, and its traps.
The normative floor ("do X, not Y") lives in [`rules/`](rules/README.md); read its index at boot too.

## Reading protocol
Read this index at boot. Open a card only when your work touches its subsystem, and never
bulk-load the kb into a prompt.

## Keep it current
When a task teaches you something non-obvious about a subsystem, create or update its card in the
same commit as the work. Every card states when it was `updated`, which `subsystem` it maps and
the `sources` it describes, so a stale card is easy to spot. When you pass through a subsystem,
check its cards against their sources, then fix one (with a changelog line) or delete it. A card
that contradicts the code is worse than no card.

## Card format
One fact per file, under a screen, with a small changelog:

    ---
    name: <kebab-case-slug>          # = the filename
    description: <one line, judged for relevance from this index>
    subsystem: <runner | relay | viewer | release | deps | tests | …>
    sources: [path/to/file, …]       # what it describes; each must exist
    updated: <YYYY-MM-DD>
    ---

    <the fact; name the function, type or file behind a load-bearing claim, never a line number>

    ## Changelog
    - <YYYY-MM-DD> — created / what changed (and what you verified it against)

## Index
- [release-and-deploy](release-and-deploy.md) — a tag runs release.yml; verify the artifacts, not the badges; deploying is a human-confirmed Terraform Cloud run
- [dependency-refresh](dependency-refresh.md) — releases at least 7 days old, one commit per risk class, pins re-resolved from tags, and the checks CI can't run
- [viewer-assets](viewer-assets.md) — the vendored xterm naming and SRI scheme, VIEWER_HASHES, and what xterm's onData carries besides typing
- [e2e-harness](e2e-harness.md) — make e2e's own unthrottled relay, the headless runner, and CLI tests on a real PTY
