# AGENTS.md — the contract every agent in this repo follows.
# CLAUDE.md should symlink here:  ln -s AGENTS.md CLAUDE.md

## BOOT — on a fresh start or after compaction, read in order:
1. this file
2. .agent/LOG.md      (what was done and why)
3. .agent/tasks/      (what's left — one folder per task; `coop tasks list`)

## How we build (the creed)
- **Boring first.** Reach for the dull, proven shape; clever earns its place only when boring can't do the job — and you can say *why* in one sentence.
- **Wear the hats** before coding: PM (the right, smallest thing?), UX (obvious path; empty/error states handled?), Security (what's the abuse case?), Maintainer (clear in six months?).
- **Done means verified, not done-once** — formatted, gated green, tested including the failure path. Never "should work": show the gate, or say what you couldn't check.
- **Readable, no bloat.** Match the surrounding style; delete more than you add; no knobs nobody asked for; comments say *why*, not *what*.
- **Boy-scout rule.** Fix small, safe messes as you pass through; backlog the big ones — never smuggle an unrelated refactor into the commit.

## The gate (adapt to this repo)
`<format-check> && <build --warnings-as-errors> && <tests>`
Here: **`make check`** (runner go + web node + portal elixir) and **`make e2e`**.
CI runs both on every PR as the jobs `runner (go)` / `web (node)` / `portal (elixir)`
/ `e2e (…)`; those four are the required status checks on `main` (see README → CI).

## The contract
- A task is a **folder**, and its state is which directory it sits in under `.agent/tasks/`: `00_todo/` todo · `10_in_progress/` claimed · `xx_done/` done+gated+committed · `50_blocked/` blocked. The numeric prefix just sorts `ls` in lifecycle order. A state change is a folder MOVE — use `coop tasks`, never a manual edit. There is no fifth state.
- Claim a task with `coop tasks claim <id>` (moves it to `10_in_progress/`) BEFORE you start it.
- `coop tasks done <id>` (moves it to `xx_done/`) only when the gate is green, the change is committed, and LOG.md has an entry.
- Blocked? `coop tasks block <id>` moves it to `50_blocked/` and writes a `decision.md` stub; fill it in (the question, options, your recommendation), and `coop tasks unblock <id>` once decided.
- One task = one commit. Spot unrelated work? Put it in .agent/BACKLOG.md and stay on task.
- **Stay on the branch you're given.** Never create, switch, or delete a git branch unless explicitly asked — commit onto the current branch. (Coop checks you out on a branch already; a new one strands your work where the human isn't looking.)
- **Tasks are self-contained.** A task's `task.md` gets read by a fresh agent after a compaction or in a new session — so it can't lean on prior chat, a past review, or memory not in the repo. Each one states: the problem + context, likely files, an implementation direction, and acceptance checks. If it can't stand on its own with just the BOOT files, it isn't ready for the queue.
- Never stop while a task sits in `00_todo/` or `10_in_progress/`.

## The .agent/ working state
Durable working memory the BOOT protocol reads back. Only `rules/` is committed;
the rest is local (git-ignored) so it never creates commit noise or merge churn.
- `tasks/` — the work queue: one folder per task under `00_todo/`/`10_in_progress/`/`50_blocked/`/`xx_done/`
  (the four states above). Each task is `.agent/tasks/<state>/<id>/task.md`, plus optional
  `log.md`/`state.md`, and a `decision.md` for a blocked task. Drive it with `coop tasks`:
  `list` (by state), `add "<title>"`, `claim <id>`, `block <id>`, `unblock <id>`, `done <id>`,
  `decisions`, `lint`, `split <n>`.
- `BACKLOG.md` — work you discover *outside* the current task: dump what you already know about it, stay on
  task, keep going. Not auto-worked, not scanned by the Stop hook; a human
  promotes an item into `00_todo/` (a real task folder via `coop tasks add`) when it's time.
- `LOG.md` — your chain-of-thought: what you did and *why*, so intent survives a
  compaction. Append a short entry per decision/task, newest first.
  **Housekeeping is mandatory, not optional.** When LOG.md exceeds 20 entries,
  trim older entries down to one-liners or remove them entirely in the same
  commit. Never postpone cleanup because the file is large — that is exactly
  when it must happen.
- a blocked task's own `decision.md` — anything needing a human call: the decision, the
  options, your recommendation. `coop tasks block <id>` moves the task to `50_blocked/` and writes
  the stub; `coop tasks decisions` lists the open ones. Never guess on a one-way door.
- `IDEAS.md` — product ideas: dump your current thinking, a sketch or a full spec if you
  have one. Never auto-implemented; a human
  approves and moves one into `00_todo/`. The loop works the first `00_todo`/`10_in_progress` task only.
- `rules/` — the taste knowledge base (the one committed part).

## Skills
Use the workflow skills instead of hand-rolling: `/spec` before a multi-file
change, `/work` to execute a plan step by step against the gate, `/sweep` to
drain `.agent/tasks/` unattended, `/investigate` to root-cause a failure before
fixing, `/verify-api` before calling anything you're not sure exists. They live once in
`.agent/skills/`; each agent's dir (`.claude`, `.codex`, `.gemini`) symlinks to it.

## Taste
Every correction from me becomes a rule the same day: fix it, record it in
.agent/rules/, sweep the codebase for siblings, and graduate it into a lint/hook
when it's mechanically checkable.
