# .agent/kb/rules — the taste rules

Normative constraints a change must obey: "do X, not Y", a verdict a review can fail against.
Every rule starts as a correction or a hard lesson and is recorded the same day (AGENTS.md → Taste).
Descriptive background lives one level up, in [`kb/`](../README.md).

## Reading protocol
Read this index at boot. Open a rule only when your change touches its scope. `/review-board`
reads every rule on purpose.

## Card format

    ---
    name: <kebab-case-slug>          # = the filename
    description: <one line>
    scope: <what it governs>
    sources: [path/to/file, …]       # the surfaces it constrains; each must exist
    check: <a command that FAILS on a violation, or none>
    updated: <YYYY-MM-DD>
    ---

    # <the rule as a title>

    <the rule>

    **Why:** <the incident or reasoning behind it>

    **How to apply:** <what to do in practice>

    ## Changelog
    - <YYYY-MM-DD> — created / what changed (and what the sweep found)

`check:` is how a rule stops being prose. When a rule becomes mechanically checkable, write the
test or make target and name its command here. Never name a command that doesn't exist or doesn't
fail on a violation; `none` is the honest value until then. Before committing a rule, sweep the
tree for existing violations and record the count in its changelog.

## Index
- [runtime-config-tests](runtime-config-tests.md) — tests for ONLYTTY_* knobs go through the real env parser with `with_runtime_env/2`, never `Application.put_env`
- [shared-checkout](shared-checkout.md) — other agents commit, push and deploy from this same checkout: check the index before staging and stage only your own paths
