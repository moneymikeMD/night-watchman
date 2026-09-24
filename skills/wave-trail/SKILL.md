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
a new row, never an edit to an earlier one.

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

## The run record

The report is the owner's **only** channel into a wave they did not watch.
Under an in-process dispatch tool there is no pane to look into and no way
to intervene mid-run, so anything the report omits is simply lost. Do not
offer a live view as the remedy — observation without a control surface is
declined on principle, not on effort.

Build the run record at wrap-up, before the Attention reviewer runs.

**Every agent declares its outcome in a structured result.** The dispatch
brief's result schema must carry at least these fields. A wave whose schema
drops one cannot report on it, so this is a contract, not a convention:

| field | what it is for |
| --- | --- |
| `ticket`, `status` | which unit, and how it ended |
| `assumed` | every `ASSUMED:` escalation taken, with its reasoning |
| `denials` | permission refusals hit, and whether the agent routed around or stopped |
| `failures` | what it could not do |
| `verify_weakness`, `verify_could_have_failed_before` | whether the verify proved anything |
| `commits`, `pr_urls`, `worktrees` | where the work landed |

**One row per agent, and stalls are found by absence.** The dispatch tool's
journal is append-only, one line per event. For the Workflow tool it is
`<projects-dir>/<slug>/<session-id>/subagents/workflows/wf_*/journal.jsonl`,
carrying `launched`, then per agent a `started` (`agentId`, `key`, `label`,
`phase`) and a `result` (`agentId`, `key`, `result`). The per-agent
conversation sits beside it as `agent-*.jsonl`.

**An agent with a `started` and no matching `result` stalled.** That is the
single most important thing the owner gave up by not watching, and it stays
invisible unless the two event streams are joined on `agentId`. Report it by
label and phase. Never let it show up as a silent absence from the list.

## The Attention section

Once the log is audited and the run record is built, dispatch one
`sonnet`-model agent (not the model that ran the wave, and one reviewer
only) with read access to the trail, the transcript and the run record. It is not redoing the work; it scans for what the human
should look at:

- an agent that started and never returned a result
- every `ASSUMED:` escalation, quoted. A decision taken without the owner
  because stopping to ask would have cost hours is precisely what they would
  have interrupted, had they been able to
- a `denials` entry, especially one the agent routed around rather than
  stopped on
- a verify flagged `verify_weakness`, or one whose
  `verify_could_have_failed_before` is false — it proved nothing
- decisions logged with weak or absent evidence
- a verify step skipped or claimed without proof in the transcript
- a choice that looks risky in hindsight (premature, scope-creeping,
  papering over a symptom rather than fixing it)
- a gap the owner would miss on a casual skim

The wrap-up report ends with an Attention section: `reviewed by sonnet` on
its own line, then each flag pointing at a specific row or agent label. "No
flags" is a valid value; omitting the section is not. An empty `assumed`
list across a whole wave is itself worth a flag — report it as suspicious
rather than as agreement.

## Reviewing the trail

`column -s$'\t' -t .night-watchman/wave-trail.tsv` renders it in a terminal.
Read top to bottom, follow the evidence pointers, spot-check a few.

Ported from pstack show-me-your-work, 2026-09-14.
