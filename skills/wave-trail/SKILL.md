---
name: wave-trail
description: Keep an append-only decision trail for an unattended or dispatch-provider wave (one row per fork, pivot, revert, or verified unit), audit it against the transcript at wrap-up, and have a second-tier reviewer write an Attention section for the human. Use when a wave is dispatched through a dispatch provider, or any run the owner is not watching live.
---

# Wave trail

`docs/decisions.md` records project "why". The cost ledger records spend.
Neither records what a specific unattended wave decided, on what evidence,
or whether that record matches what actually happened. This skill closes
that gap for waves nobody is watching.

## When to open a trail

Open `.night-watchman/wave-trail.tsv` at the start of any wave dispatched
through a dispatch provider (see `session-start`'s "Dispatching a wave
through a worktree-dispatch tool"), or any run the owner has said they will
not be watching live. A wave worked entirely on the main thread with the
owner present does not need one — `docs/decisions.md` already covers that
case at project grain.

## Where it lives

`.night-watchman/wave-trail.tsv`, gitignored (same file class as
`.night-watchman/last-session-cost.txt`). It is a working artifact for the
wave, not project history — `docs/decisions.md` is where a decision graduates
to if it turns out to matter beyond the wave that made it. Start a fresh
file per wave; copy `templates/wave-trail.tsv` (header row only) to seed it.

## The row contract

One TSV row per decision point. Cells stay single-line; evidence is a
pointer, never a paragraph.

- **ts** — ISO8601 timestamp.
- **phase** — the wave phase or workstream (orient, dispatch, land, ...).
- **decision** — what was chosen or done, one line.
- **why** — the reason, plain words, not a jargon tag.
- **evidence** — a pointer that proves it: commit SHA, ticket ID, `file:line`,
  branch name, or a script's output path. Never a summary.
- **result** — the outcome or predicate state: `verify MET`, `reverted`,
  `PARTIAL`, `INCONCLUSIVE`, `open`.

Log decision points, not every action: a ticket dispatched, a fork taken, a
unit landed with its verify result, a pivot or revert and its trigger, a
blocker surfaced. One row per ticket landed is the minimum bar for a wave
run through `land-branch.sh`. Append with `scripts/decision-log.sh --phase
P --decision D [--why W] [--evidence E] [--result R]` (it writes the header
on first use and keeps cells single-line); append-only — a wrong call gets
a new row that supersedes it, never an edit to history.

## Wrap-up: audit the log against the transcript

Before the wrap-up report goes out, check the log told the truth. Read this
session's transcript under `~/.claude/projects/<slug>/*.jsonl` (the slug for
the active working directory — do not glob across other projects' slugs,
that reads unrelated sessions). Walk the log against what actually happened:

- Every row maps to a real action; cut invented or aspirational rows.
- Each row's evidence pointer resolves and shows what the row claims.
- A fork, pivot, or abandoned approach that shaped the wave but is not
  logged is a gap — add it.
- Drop padding.

Fix the log, not the story: if the wave diverged from what a row claims, the
row is wrong, not the wave.

## The Attention section

Once the log is audited, dispatch one `sonnet`-model agent (not the model
that ran the wave, kept to one reviewer — see the epic's cost note) with
read access to the trail and the transcript. It is not redoing the work; it
scans for what the human should look at:

- decisions logged with weak or absent evidence
- a verify step skipped or claimed without proof in the transcript
- a choice that looks risky in hindsight (premature, scope-creeping,
  papering over a symptom rather than fixing it)
- a gap the owner would miss on a casual skim

The wrap-up report ends with an Attention section: `reviewed by sonnet` on
its own line, then each flag pointing at a specific row. "No flags" is a
valid value; omitting the section is not.

## Reviewing the trail

`column -s$'\t' -t .night-watchman/wave-trail.tsv` renders it in a terminal.
Read top to bottom, follow the evidence pointers, spot-check a few.

Ported from pstack show-me-your-work, 2026-09-14.
