---
name: session-start
description: The opening move for a fresh session in a project running this plugin's unattended-operations model — orient from docs/, verify every awaiting-deployment ticket against reality, and fan startable work out to pinned-model subagents in parallel. Load when the user says "start on the next open tickets", "pick up where we left off", "what can be worked on", or opens a session with no specific task.
---

# Session start

Many sessions in an unattended-operations project open the same way: "start
on what can run in parallel, verify what is awaiting deploy, read docs
first." This skill is that routine, so the main model spends its budget on
judgement and the subagents spend theirs on the work.

The main model reads, decides, and dispatches. It does not verify, survey,
or diff anything itself — see the orchestrator/cheap-executor rule in
`templates/CLAUDE.md`.

## 1. Orient (main thread, a handful of cheap reads)

```bash
cat docs/README.md                                                     # if one exists
ISSUES_PY="$(${CLAUDE_PLUGIN_ROOT}/scripts/work-order-root.sh --issues-py)"        # the work-order dependency
python3 "$ISSUES_PY" next  issues/                                     # startable now, tool-as-truth
python3 "$ISSUES_PY" board issues/                                     # what is where
head -60 docs/known-issues.md                                          # severity table only, if it exists
git log -1 --format=%B                                                 # last session's commit body
memorygraph recall --query "<project>" --limit 8                       # if memorygraph is installed as an optional layer; single keyword, multi-word returns 0
```

Swap `issues/` for `--source jira` (or whatever adapter is configured) if
the project has moved its ticket set off the filesystem — see
`tickets-protocol`. An unreachable tracker should stop orientation here,
loudly, rather than partway through a wave: fail before dispatching, not
during it.

**Preflight the configured dispatch provider before touching any ticket.**
Run `${CLAUDE_PLUGIN_ROOT}/providers/lib/provider.sh doctor` and print the
resulting table in the orientation summary. Then run the resolved
`dispatch` implementation's own readiness check — for `herdr`: `command -v
herdr` and `[ -n "$HERDR_ENV" ]`. A configured dispatch provider that is
not ready (not installed, no entry point, or its own readiness check
fails) stops orientation here, loudly, the same way an unreachable
tracker does — do not fall through to in-process subagents silently.

Read topic files in `docs/` only when a ticket points at one. Do not open
an archival handoff-docs directory proactively — see `handoff-docs`: a
handoff doc is written once and then superseded by the tickets and docs it
fed, not re-read as living truth. Open it only if the user says to.

Skip open tickets whose `blocked_by` is non-empty and whose `executor` is
`human`; `next` already filters these.

If `NW_PARITY_SOURCE` is set (an optional layer — this project was forked
from a source project some deployments keep folding generic work in from,
see `docs/parity/`), run
`${CLAUDE_PLUGIN_ROOT}/scripts/parity-sweep.sh --source "$NW_PARITY_SOURCE"`
here. It is read-only against both trees. Exit 2 (could not evaluate) stops
orientation the same way an unreachable tracker does. A non-empty "new"
section — source files under a mapped directory with no row in
`templates/parity-map.tsv` — means file a parity ticket the way a prior sweep did,
one row per CANDIDATE/PORTED-DRIFT item; a non-empty "vanished" section
means the map itself needs a hand-edit to drop the stale row.

## 2. Verify awaiting-deployment (delegate, read-only)

Every ticket in `awaiting-deployment/` (or its tracker equivalent) has a
`verify` block and, if `executor: mixed`, `human_steps`. Hand the whole set
to one read-only-briefed agent (the cheapest model that can follow
instructions and read output — haiku-class): run the verify commands,
report MET / NOT MET / PARTIAL with evidence, name what remains human-only.
It must not deploy, restart, recreate, rotate, or delete anything.

Traps, in order of how often they actually bite:

- A deploy step a ticket's `verify` assumes has not happened yet may have
  happened implicitly as a side effect of unrelated work. Verify against
  the live system, not the ticket's assumption of what has not changed.
- "The process is running" or "the container is Up" is not "verify met". A
  collector with a bad credential starts cleanly and reports healthy while
  doing nothing. Insist on the ticket's stated observation, not a proxy for
  it.
- Sign-in flows, test emails, and console clicks stay human. Report them as
  owed; never mark a ticket completed on the strength of an HTTP 200.

## 3. Fan out startable work (delegate, one message)

For each startable ticket, pick the smallest brief a pinned-model agent can
finish without asking questions, and launch them all in **one** message:

| Ticket shape | Agent | Model |
| --- | --- | --- |
| Verify / probe / "is it up" | a read-only triage agent | cheapest available |
| A survey with a recommendation the user must approve | a general-purpose agent | mid-tier |
| Research a fact outside the repo (a version, a maturity check, a licence) | `researcher` | mid-tier |
| New or changed script | `script-author` → `script-reviewer` | mid-tier / top-tier for review judgement |
| Write up a proven, non-privileged command sequence as a script | `script-author-lite` (refuses and hands back to `script-author` on ssh/op/sudo/live-host) | cheapest available |
| Ticket moves, decisions, known-issues, wrap-up | `librarian` | cheapest available |
| Domain-specific work (infra, deploy, a particular stack) | whatever domain agents the project itself defines — this plugin ships none; a project wires its own | project-specific |

A ticket whose next step is a decision only the user can make is still
startable: the deliverable is the evidence that makes the decision one
glance — a classified diff, a table with a recommendation column, a
numbered plan with UNVERIFIED markers flagged. Touch the ticket body only
if the acceptance criteria moved; put the evidence in a comment/note
instead — see `tickets-protocol`.

Every brief carries: READ-ONLY on live systems unless stated; never print a
secret; do not commit; end with a compact table; plus:

- TIMEBOX — on expiry, return partial findings and stop rather than run on.
- FORBIDDEN — unit-specific bans beyond the global ones above.
- REPORT — status, branch, head SHA, what was actually run, deviations.
- STANDING — this project's standing orders, pasted verbatim into every
  spawn and every resume.

When a dispatch provider starts the ticket, the start verb carries all of
these: it renders `templates/dispatch-brief.md` (the single source of STANDING
and REPORT) and takes the per-ticket lines as `--timebox` and repeatable
`--forbidden`. The orchestrator's job is choosing those lines, not retyping the
brief; a follow-up prompt is for review rounds only.

A brief missing any of these is a refuse-to-spawn condition. Two agents must
not `touches` the same path — `issues.py waves` says so before anyone starts.

Retry by failure mode, two retries then abandon and replan — table moved
to `references/failure-policy.md`.

Live actions the user approves mid-session (a migration, a retirement, a
major upgrade) run on the main thread so approval and action share one
context — but they still go through a script in `scripts/`, reviewed by
`script-reviewer` first if new.

Check the project's `ethos.md` (see `templates/ethos.md`) before asking the
user a question — if a default covers it, apply it and say so instead of
asking. Batch every pending decision into one prompt rather than
interrupting per agent.

## 4. Judge and land (main thread)

Inspect the delegate's artifact — git diff, files in the worktree — not its
summary; a confident report is not evidence. Ported from pstack
prove-it-works, 2026-09-14.

When the reports come back:

- On any agent-executed ticket, run `spec-reviewer` against the ticket and
  its branch before landing. LAND AFTER FIXES or DO NOT LAND stops
  land-branch until the branch's own worker addresses the findings.
- **A spec-review brief carries the ticket-specific concerns only.** The
  repo's required checks are assumed, not listed: `spec-reviewer` discovers
  and runs them itself before any verdict, so enumerating them in the brief
  adds nothing and rots the moment one is forgotten. Reviewing to an
  enumerated list is what let NWM-120 land red on 2026-09-19 — three
  reviewers answered every question asked, and the unasked one turned main
  red. Ask about what is peculiar to this ticket; never about the gates.
- `${CLAUDE_PLUGIN_ROOT}/scripts/land-branch.sh` lands a finished branch:
  moves the ticket to Awaiting Deployment, merges, lints the merged tree,
  pushes, and moves the ticket to Completed (file-mode directory moves, or
  tracker transitions if one is configured) — or stops at the first failure
  and reverts the merge. See the script's own header for the full contract.
- **The ticket lifecycle is the rule, and the scripts drive it** (see
  `tickets-protocol`): In Progress at dispatch
  (`${CLAUDE_PLUGIN_ROOT}/providers/dispatch/herdr/herdr-ticket-start.sh`,
  via `dispatch start`), Awaiting Deployment before landing and Completed
  after (`land-branch.sh`). The orchestrator never moves a ticket by hand
  except to repair a step a script missed, and says so in a dated note on
  the ticket.
- Ticket verify fully MET → `librarian` completes it.
- PARTIAL → post a dated note saying exactly which human steps remain;
  touch the ticket body only if the acceptance criteria moved; it stays put.
- New fact about the project → the matching `docs/` topic file, updated in
  place; new "why" → a dated append to the decisions log; problem found,
  not fixed → `${CLAUDE_PLUGIN_ROOT}/scripts/known-issue.sh add`.
- Run `"$(${CLAUDE_PLUGIN_ROOT}/scripts/work-order-root.sh --issues-py)" lint` before any ticket transition.
- Every user answer this session → a row in `ethos.md`'s decision log, and
  a default adjusted if the pattern moved.

Account for every spawned agent at wave rollup: landed, respawned, or its
scope explicitly absorbed elsewhere. Silently redoing a missing agent's work
hides both the wasted spend and the coverage gap it existed to close. Ported
from pstack orchestrate playbook, 2026-09-14.

### When land-branch stops on a conflict

The worker that wrote the branch resolves it, in its own worktree — it
holds the intent, not the orchestrator. Before touching a hunk, read both
tickets' Decisions and Out of scope sections plus the conflicting commits'
messages.

Keep both intents where compatible. Where they are not, follow whichever
ticket landed first and record the trade-off as a dated progress note —
never invent behaviour neither ticket asked for, and never resolve by
taking one side wholesale.

Re-run both tickets' `verify` and `issues.py lint`, then re-run
`land-branch.sh`. A same-wave conflict means `touches` was under-declared:
file it with `known-issue.sh add`, or fix the ticket's `touches`.

Adapted from mattpocock/skills resolving-merge-conflicts, 2026-09-14.

### Split to a fresh session before the main thread runs too long

**End the orchestrator session at every wave boundary and start a new
orchestrator session for the next wave.** This is a close action, not a
judgement call — the handoff doc written in wrap-up already carries the
state a fresh session needs, which is what makes the split cheap.

Cache-read cost grows with accumulated context, so a long-running main
thread's average per-turn cost creeps up the longer it runs. **Measure that
with cost per orchestrator turn, not with the turn count.** A turn count
moves with how much work a wave contains, so it says nothing on its own,
and where fan-out is dispatched in-process a naive turn count also sweeps
in the agents.

Two waves measured 2026-09-19 and 2026-09-20, one continuous orchestrator
session across both, no split at the boundary:

| | wave 1 | wave 2 |
| --- | --- | --- |
| orchestrator cost | $127.04 | $164.37 |
| orchestrator turns | 824 | 465 |
| **USD per orchestrator turn** | **0.154** | **0.353** |

Turns fell 44% while cost per turn rose 2.29x. Fewer, far more expensive
turns is what an unreset context looks like — and note that the raw turn
count fell, so a turn-count threshold would have read this as improving.

An owner-approved unattended run is not the same decision as whether to
split at the boundary — the two are independent, and the split applies
regardless of whether the run itself was pre-approved.

**Never restart mid-wave.** Where agents are dispatched in-process, a
session restart tears down the orchestrator and every in-process sibling
with it, so a restart cannot be dispatched as a unit of work *inside* the
wave it would kill. The split belongs at the boundary, after the wave has
finished landing.

State the exit predicate as something checkable before the first iteration
of an unattended run. A plateau is not a stop — keep pushing past it, and
never relax the predicate to declare victory. Ported from pstack
autonomous-run playbook, 2026-09-14.

### Wrap-up

Before reporting, audit the wave-trail against this session's transcript
and end the report with its Attention section — see `wave-trail`. Fixed
status tag per unit — `[landed <sha>]`, `[in flight <branch>]`, `[blocked <on>]`, `[abandoned <why>]`, `[owed-human <step>]` — not free text. Hand
the transcript path to the reflector agent (`agents/reflector.md`), if
present, for the correction-to-skill-edit loop.

Report to the user as: verified (moved), verified-partial (what is owed and
by whom), started (what each agent left on disk), and the one or two
decisions only the user can make. When a dispatch provider ran the wave,
name the dispatch tool and carry the **run record** — one row per agent,
plus the collected `ASSUMED:` escalations, `denials` and stalls. See
`wave-trail`.

Do not report "how each agent was watched" under an in-process dispatch
tool. Nobody watched: there is no pane and no way to intervene mid-run, and
a live view is not wanted (offering one has been declined on principle).
The run record is the owner's only channel into that wave, so treat an
omission from it as information destroyed rather than detail spared.

Then run this project's session-end memory-capture step, if one is
configured (see the optional layers in the plugin README).

**Publish the brief** once the wave note is written and committed, if a
`publish` provider is configured (`provider.sh doctor` shows it
`installed` and `[publish.<impl>]` is filled in — in the committed config,
or, for a repo that is published, in the private config `$NW_CONFIG`
points at, where site identifiers live alongside the tracker host). The brief is the note's
owner-facing sections — Recent Wins / Things to be aware of / What We
Have Comin' Next — as markdown, with the H1 and any `harness:` line
stripped (the title is the page title):

```bash
P=$HOME/code/night-watchman/providers/lib/provider.sh
URL=$("$P" publish publish-brief "<date> <project> Update" brief.md)
"$P" publish post-headline default "<headline, under 200 chars>" "$URL"
"$P" publish post-headline <EPIC-KEY> "<headline>" "$URL"   # once per epic with a landed ticket, if mapped
```

Rehearse both with `NW_DRY_RUN=1` first on a wave that publishes for the
first time. Fail soft, per feed: a rejected `post-headline` (exit 1) gets
one line in the wave note naming the feed and the exact error, and the
next feed is still posted. A failed `publish-brief` skips the headlines —
there is no URL to point at — and is noted the same way.

The outcome comment's `cost:` line is read from
`.night-watchman/last-session-cost.txt`, if present — the plugin's
`SessionEnd` hook (`hooks/session-cost.sh`, see `docs/cost.md`) writes it
automatically as the session ends. `cost: UNVERIFIED` only when that file
is absent (the hook isn't wired up, or hasn't run yet for this session) —
say so explicitly rather than silently omitting the line.

If this wave also invokes `cost-reviewer` (the optional per-wave review in
`docs/cost.md`, distinct from the automatic `SessionEnd` ledger row above),
first record the `accepted` event for every script whose ticket reached
completion this wave — `librarian`, or the main thread (this project has
no lab-librarian), runs `script-analytics.py record --event accepted ...`
per script — and confirm each row landed by re-reading
`docs/script-events.jsonl`. Only once that is confirmed, invoke
`cost-reviewer`. A wave where the accepted-event write and cost-reviewer's
`script-analytics.py extract` ran concurrently had the event land after
extract, so a script accepted that wave showed no sign anything raced —
just a quietly missing data point. Fix the ordering, not the symptom:
don't have `cost-reviewer` poll or retry for a late-arriving event.

## Dispatching a wave through a worktree-dispatch tool

If `.night-watchman/config.toml` resolves a `dispatch` provider and the
step-1 preflight's `doctor` says it is installed and ready, provider
dispatch is the rule, not an option: every agent-workable ticket in the
wave MUST be started via
`${CLAUDE_PLUGIN_ROOT}/providers/lib/provider.sh dispatch start
<ticket-id>` (or the resolved implementation's own `provider.sh start`),
one ticket per worktree — no size threshold, regardless of how small the
ticket is. `issues.py lint`, from the work-order dependency,
already guarantees wave siblings touch disjoint paths, so their branches
merge without conflict.

Open `.night-watchman/wave-trail.tsv` at dispatch, before the first ticket
starts — see `wave-trail`. Log the dispatch decision as the first row.

In-process subagents in plain worktrees are the fallback ONLY after a
recorded `start` failure — never a judgement call made in advance. When
`start` fails, put the failure text (verbatim, first line) in the
ticket's progress note with the date, then fall back for that ticket.

Never resume or restart a dispatched agent just to check on it — a resume
restarts an idle agent rather than observing it. Probe read-only instead:
the branch, the ticket's progress note, or `herdr workspace list`
agent_status (a `watch` verb, once it lands). If a dispatched agent
shows no progress for 5 minutes, check in read-only rather than waiting
longer (owner's idle rule, memorygraph 2026-09-14). Ported from pstack
orchestrate playbook, 2026-09-14.

Land each branch on the target branch from the orchestrating thread once
its `verify` passes, via
`${CLAUDE_PLUGIN_ROOT}/scripts/land-branch.sh <branch> <ticket-id>`.

## Why this is a skill and not a script

The reads in step 1 could be scripted, but the value is in step 3: which
brief, to which agent, with which trap list. That is judgement over a
changing ticket set. `issues.py next` is the scriptable part and already
exists — see `capability-ladder` for the general principle this
illustrates.
