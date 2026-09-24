---
name: tickets-protocol
description: The docs/ routing table and the ticket workflow — status-is-a-directory-move (or a tracker transition, if one is adopted), the frontmatter/field contract, body-vs-progress-note rules, and the UNVERIFIED discipline. Load for session wrap-up, ticket filing, ticket transitions, or any durable-knowledge capture.
---

# Tickets and docs protocol

Working subset of the conventions this plugin's `to-issues` skill sets up.
Authoritative sources for the tickets themselves: whatever `to-issues` created
(`issues/README.md` by default) and, if adopted, a real tracker.

## Routing new knowledge

| What | Where |
| --- | --- |
| A rule to follow | `CLAUDE.md` |
| A fact about the project | matching `docs/` topic file, updated **in place** |
| A "why" | one entry in the project's decisions log (`scripts/decisions.sh add` here; `docs/decisions.md` is its generated index). Only when all three gates hold: costly to reverse, surprising without it, real alternatives weighed. Template: `templates/decisions.md` |
| A guess | `docs/open-questions.md`, marked `UNVERIFIED` — never a topic file |
| A problem found, not fixed | `"$(${CLAUDE_PLUGIN_ROOT}/scripts/ai-toolkit-root.sh --known-issue)" --root "${CLAUDE_PROJECT_DIR}" add` to create an entry under `docs/known-issues/` with severity (HIGH/MEDIUM/LOW/COSMETIC) by blast radius, not effort. **Never hand-edit the generated index** — it must never drift from the entries it indexes. Template: `templates/known-issues.md` |
| A script doc claim, checked against reality | dated row in `docs/scripts-claims.md`, updated in place on re-check. Template: `templates/scripts-claims.md` |

A known issue whose symptom is gone is closed with
`"$(${CLAUDE_PLUGIN_ROOT}/scripts/ai-toolkit-root.sh --known-issue)" --root "${CLAUDE_PROJECT_DIR}" resolve <slug>`;
its body states the current fact. A confident-sounding guess in `docs/` is
worse than no entry; future sessions read these files as ground truth.
`"$(${CLAUDE_PLUGIN_ROOT}/scripts/ai-toolkit-root.sh --known-issue)" --root "${CLAUDE_PROJECT_DIR}" lint` verifies entries and the
index stay in sync.

Always pass `--root`: without it `known-issue.sh` takes its target repo
from cwd, and an agent running from a worktree writes into the wrong one.
`known-issue.sh` is ai-toolkit's, not this plugin's; `ai-toolkit-root.sh`
resolves a checkout of it (`$AI_TOOLKIT_ROOT`, then a sibling directory)
and exits 1 naming both when there is none.

Rate a claim before routing it, five tiers, reusing the UNVERIFIED marker (Ported from pstack `why/references/epistemics.md`):

| Tier | Routes to |
| --- | --- |
| Direct | topic file or `decisions.md`, citation adjacent |
| Supported | topic file or `decisions.md`, citation adjacent |
| Inferred | `open-questions.md`, UNVERIFIED, inference chain stated |
| Speculative | `open-questions.md`, UNVERIFIED, inference chain stated |
| Unknown | a named gap listing what was searched |

Code is mechanics, not evidence of its own intent. Causal words ("because", "fixes") need a citation next to them.

## Ticket flow

```
open ──> in-progress ──> awaiting-deployment ──> completed
  │
  └────────────────────────────────────────────> cancelled
```

**File mode (the default): the directory is the status.** Moving a ticket is
`git mv issues/<from-stage>/<id>.md issues/<to-stage>/<id>.md` plus the
frontmatter `updated:` bump, committed together (see "Transition commits"
below). There is no separate `status:` field to fall out of sync with the
location — see `to-issues/SKILL.md`.

**Tracker mode (opt-in): a transition call replaces the directory move.** If
this project has adopted a real issue tracker via `issues.py --source jira`
(or an equivalent adapter for another tracker), "moving a ticket" means
calling that tracker's transition API instead of `git mv` — the ticket's
description stays the contract either way (see "Ticket body and progress"
below), and `lint`/`board`/`waves`/`next` run identically against either
source. `awaiting-deployment` is real in either mode, not ceremony — nothing
deploys itself just because code merged, so "committed" and "running" stay
different states until something verifies the deploy.

**The lifecycle is a rule, and scripts drive it.** A ticket is in-progress
from the moment it is dispatched (or a workspace/pane is opened for it),
awaiting-deployment before it lands, and completed after it lands. No step
is skipped, including awaiting-deployment for a ticket with nothing else to
deploy: it is the state "merged but not yet proven", and the landing's own
push is the deploy. Two scripts make the moves:

- `providers/dispatch/herdr/herdr-ticket-start.sh` (the `dispatch start`
  verb) moves the ticket to In Progress once the brief hand-off is observed.
- `scripts/land-branch.sh` moves it to Awaiting Deployment before the merge
  and to Completed after the push (file mode: `in-progress/` ->
  `awaiting-deployment/` -> `completed/`, one commit per move). It refuses a
  ticket that never reached In Progress.

Every transition is resolved by target status, never by a hard-coded
transition id, and read back afterwards. Nobody moves a ticket by hand
except to repair a step a script missed, and whoever does says so in a
dated note on the ticket. A tracker gate that refuses a script's move is a
script defect to fix, not a gate to weaken.

## Frontmatter contract

Full reference: work-order's `SPEC.md` and `bindings/file/BINDING.md`, in
the installed dependency — `scripts/work-order-root.sh` prints its root.
Summary:

- `verify` — required to reach `completed/`. "Deployed" is not evidence; a
  collector with a bad credential starts cleanly and reports healthy.
- `outcome` — required in `cancelled/`. A cancelled ticket with no outcome
  causes the same idea to be re-proposed and re-litigated later.
- `executor` — `agent` | `human` | `mixed` (with `human_steps`).
- `touches` — paths the ticket owns; two startable tickets sharing one is an
  error. `appends` — shared append-mostly files; collisions warn only.
  Required on every ticket, `human` and `mixed` included: a tracker gate
  (Jira: `touches` non-empty before In Progress) refuses an empty one, so a
  human ticket names what the person changes even outside the repo, e.g.
  `~/.claude/plugins (owner plugin settings, outside the repo)`.
- `blocked_by` — a ticket with blockers is not startable.
- A ticket resting on a false premise is **cancelled, not deleted** — the
  false premise is the useful part.

## Epics

The grouping unit above tickets. Applied literally: "a new delivered
capability or themed improvement effort with a quantifiable artifact as its
output".

- **Title** is a verb phrase, no prefix (`Migrate issue management to a
  tracker`, not `Parent: ...` or `Cost exploration: ...`).
- **Description** opens with an `Artifact:` line naming the countable output,
  then one paragraph of scope. A proposed epic with no countable artifact is
  rejected at filing time; it is a theme, not an epic.
- **Status is derived from children**: all Done/Cancelled → Done; any child
  In Progress or Done → In Progress; otherwise To Do. Recompute when a child
  moves.
- **Every ticket names its epic or its reason for being an orphan.** Orphans
  are fine (a single fix, a rotation); a catch-all "maintenance" epic is not,
  because it has no artifact and never closes.
- Cancelled tickets stay linked to their epic; the false premise is part of
  the epic's history.
- **A foggy epic** carries "Not yet specified" and "Out of scope"
  paragraphs, and files decision tickets (`tags: [decision]`) instead of
  build tickets until the route is clear — see `to-issues`' "When the plan
  is still foggy". Adapted from mattpocock/skills wayfinder, 2026-09-14.

## Transition commits

Move a ticket **in the same commit as the work that moved it — or alone**.
Never batched with unrelated work: stage paths deliberately, since a broad
`git add -A` sweeps a stale ticket into an unrelated commit and forges a false
connection in the history. A lone transition still gets its own message
(`chore(issues): PROJ-006 -> completed`).

## Ticket body and progress

A ticket's description — the Problem/Solution/Decisions/Out of scope sections
— is static once filed and changes only when the acceptance criteria change
(`verify`, `human_steps`, `blocked_by`, `touches`, or Solution itself).
Everything else — progress notes, spike findings, review rounds, learnings,
what remains — goes somewhere else: a dated comment if the tracker supports
one, or a dated append to the project's decisions log if it does not. A
`## Progress` section appended to the ticket body itself is the wrong place
either way. Why: the description is what a fresh agent reads to learn what
"done" means; a body that grows with a progress log per session buries that
contract — an author once let a ticket's own body grow past 11 KB across
three separate "Progress" sections before it closed, and the acceptance
contract a fresh reader needed got buried under session narration. Durable
learnings still go to `docs/` (or a memory tool, if one is installed), not to
the ticket body.

## Tooling

```bash
# issues.py ships in the work-order plugin this one depends on; waves/preflight
# are this plugin's own scripts/waves.py, called through ${CLAUDE_PLUGIN_ROOT}.
ISSUES_PY="$(${CLAUDE_PLUGIN_ROOT}/scripts/work-order-root.sh --issues-py)"

python3 "$ISSUES_PY" lint  issues/   # file mode
python3 "$ISSUES_PY" board issues/
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/waves.py" waves issues/
python3 "$ISSUES_PY" next  issues/

# tracker mode, once adopted:
python3 "$ISSUES_PY" lint  --source jira --jira-project PROJ
python3 "$ISSUES_PY" board --source jira --jira-project PROJ
```

A ticket that fails lint will fail in an agent's hands too, just later and
more expensively. Run `lint` before any ticket change, in either mode.
