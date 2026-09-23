---
name: to-issues
description: Turn a finished planning, grilling, or design conversation into independently-workable tickets as frontmatter Markdown files on disk, so the session can be closed and the work picked up cold by parallel agents in git worktrees. Use this whenever a grilling session ends, whenever the user says "turn this into tickets/issues/a work log", "write this up so I can start a fresh session", "break this into work I can parallelise", or after any long discussion that settled a bunch of decisions and now needs to survive the context window. Also use it when a plan already exists but the tickets are too coupled or too vague for an agent to execute without asking questions.
---

# to-issues

A planning conversation ends with everything in one place: the decisions, the
rejected options, the facts someone verified, the order things must happen in.
Then the session closes and all of it is gone.

This skill turns that into tickets that survive. The bar is not "a human could
figure this out." The bar is **an agent with no memory of this conversation can
finish the ticket without asking a question**, and several such agents can work
different tickets at the same time in separate git worktrees without colliding.

That bar is higher than it sounds, and most of this skill is about clearing it.

## The three failure modes worth designing against

**Tickets that need the conversation.** "Wire up the collector as discussed" is
useless in March. Every decision reached in the session has to be *inside* the
ticket that depends on it, restated, not referenced. Assume the reader has the
repo and nothing else.

**Tickets that quietly collide.** Two agents in two worktrees editing the same
file produce a merge conflict a human has to untangle, which destroys the point
of parallelising. Declaring what each ticket touches lets that be checked before
anyone starts rather than discovered at merge time.

**Tickets nobody can prove are done.** "Deployed" is not evidence. A service can
start cleanly, report healthy, and do nothing — a collector with a bad
credential is the classic case. If the done state is not a command with a
deterministic result, the ticket will be marked complete while broken.

## When the plan is still foggy

Sometimes the destination is clear but the route to it is not: nobody yet
knows which approach wins, or the decision needs a fact or an owner
conversation before any file can be touched. Forcing that into a build
ticket produces a vague one — "figure out the auth approach" is not
something an agent with no memory of this conversation can finish. The
test: if you can name the destination but not the route, file **decision
tickets** instead of build tickets.

**A decision ticket.** Its title is the question itself, not a task
description. It carries `tags: [decision]`. Its `verify` greps
`docs/decisions.md` for an entry citing the ticket's id — the decision
isn't done until the answer is recorded where future sessions will read
it, not left in a comment thread.

**`executor` follows what resolving it requires.** `human` when it needs
an owner conversation, worked with the `grill` skill. `agent` when it
needs a fact that research can surface, worked by the `researcher` agent.
Never `mixed`; the resolution is the deliverable, not a mix of steps.

**The epic carries the fog.** Give it a "Not yet specified" paragraph for
questions that are in scope but not yet sharp enough to ticket, and an
"Out of scope" paragraph for what the destination rules out. Filing a
decision ticket for every vague hunch defeats the point — write the hunch
into "Not yet specified" instead, and graduate it into a real ticket once
resolving something else makes it specifiable.

**Plan, don't build, until the fog clears.** No build ticket is filed
until every decision ticket it depends on is completed — enforced with
`blocked_by`, the same field that gates any other dependency. This is the
one place a ticket set is deliberately incomplete on purpose: the build
tickets literally cannot be written yet, because the route isn't known.

Adapted from mattpocock/skills wayfinder, 2026-09-14.

## Process

### 1. Find or establish the conventions

Look for `issues/README.md` (or `tickets/`, `specs/`) in the repo. If one
exists, **conform to it** — read its frontmatter schema and stage names and use
those, even where they differ from the defaults below. A second competing
convention in the same repo is worse than an imperfect first one.

If nothing exists, create the structure in §2 and write the README that codifies
it, so the next session inherits it instead of inventing another.

### 2. Default structure

```
issues/
├── README.md
├── open/                  agreed and specified, nobody has started
├── in-progress/           being worked now
├── awaiting-deployment/   committed, but not live
├── completed/             live and verified
└── cancelled/             decided against; outcome explains why
```

**The directory is the status.** No `status:` field — a field and a location
will eventually disagree, and then neither can be trusted.

`awaiting-deployment` earns its place in any repo where shipping is a separate
manual act (a dashboard deploy, an app store review, a DBA running a migration).
If deployment is automatic on merge, drop that stage rather than keep a bucket
nothing ever sits in.

### 3. One ticket per independently completable outcome

Split on **independence**, not on size. The test: could an agent finish this in
its own worktree, open a PR, and have it be reviewable and mergeable on its own?

- If two pieces must land together to work, that is **one** ticket.
- If a piece needs another's output first, that is **two** tickets and a
  `blocked_by`.
- If a piece needs a human to click something in a web console, split the human
  part out — see `executor` below. A swarm that picks up a ticket requiring
  biometric approval burns tokens and fails.

Resist inventing tickets for tidiness. A work log of forty tickets nobody reads
is worse than twelve that are all real.

**Slicing shapes.** *Prefactor first*: if a structural change makes the rest
easy, it is its own ticket and blocks the others. *Wide refactor as
expand-contract*: when one mechanical change fans out across the whole
codebase and no vertical slice can land green, expand (add the new form
beside the old), migrate call sites in batches with disjoint `touches`, each
blocked by the expand so `waves` runs them in parallel, then contract in a
ticket blocked by every batch. If batches cannot stay green alone, they share
an integration ticket where green is promised only there.
Adapted from mattpocock/skills to-tickets, triage, 2026-09-14.

### 4. Write each ticket

Use `assets/ticket-template.md`. Full field reference: work-order's `SPEC.md`
and `bindings/file/BINDING.md` — `scripts/work-order-root.sh` prints their root.

**Assign each new ticket to an epic, or state in the ticket body why it is an orphan.** Every ticket either belongs to exactly one epic or is deliberately epic-less. A new epic needs an `Artifact:` line naming its countable output. See `skills/tickets-protocol/SKILL.md` for epic rules.

The parts people get wrong:

**`verify` must be runnable.** A command, with its expected result stated. Not
"confirm it works". If verification genuinely requires a human eye — a visual
layout, a physical device — say so plainly and set `executor` accordingly; a
fake command is worse than an honest "look at the page".

**`touches` is what makes parallelism safe.** List the paths the ticket owns
edits to, as globs. Be generous — an unlisted file is a merge conflict waiting to
happen; an over-listed one only costs a little serialisation. Shared
append-mostly files that nearly every ticket writes to — a changelog, a decision
log, an issue register — go in `appends` instead, or every ticket in the repo
ends up serialised behind one document.

**`executor` decides who can pick it up.** `agent` means fully automatable.
`human` means it cannot be done by an agent at all — a credential to create in
someone's vault, a payment, a physical cable. `mixed` means an agent does the
work and a human performs specific steps listed in `human_steps`. Getting this
wrong is expensive in both directions: a swarm stalls on a human ticket, and a
human does by hand what an agent could have done in a minute.

**Decisions belong in the body.** Especially the ones that were argued about.
"Why not the obvious approach" is the single most valuable thing a ticket
carries, because without it the obvious approach gets re-proposed.

### 5. Capture what was rejected

Anything the session considered and dropped becomes a ticket in `cancelled/`
with a filled `outcome`. This feels like bookkeeping and is not: an idea with no
recorded objection comes back, and someone spends an afternoon rediscovering why
it was a bad idea.

This includes ideas that turned out to rest on a false premise. Keep the ticket;
the false premise is the useful part.

A request found already built or already implemented is cancelled too, but
its `outcome` points at where the existing behaviour lives — it is not
recorded as a rejected idea, or a future dedup pass will match real requests
against it and re-reject something that already works.

### 5b. Red-team the set

Before validating, turn adversarial on the draft ticket set: assume a wave
shipped and failed a month from now — what's the likely cause, and which
ticket already defends against it? A cause with no defending ticket is a
coverage gap; file one. Check that the riskiest ticket's `verify` would
actually fail if its assumption is wrong, not just touch the same area.
Note what this pass caught (or "no issues found") in the report.
Ported from ptetau/pskills quiz-plan, 2026-09-14.

### 6. Validate before you finish

```bash
ISSUES_PY="$(${CLAUDE_PLUGIN_ROOT}/scripts/work-order-root.sh --issues-py)"
python3 "$ISSUES_PY" lint issues/
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/waves.py" waves issues/
```

`lint` catches the errors that make a ticket unworkable — a missing `verify`, a
`blocked_by` pointing at nothing, a cancelled ticket with no `outcome`, two
parallel tickets touching the same path.

`waves` prints the parallel execution plan: which tickets can be worked
simultaneously, and the worktree commands to do it. If wave 1 has one ticket in
it, the tickets are over-coupled — look for a dependency that is assumed rather
than real.

Fix what lint reports. A ticket that fails lint will fail in an agent's hands
too, just later and more expensively.

**`defer_until: YYYY-MM-DD` snoozes a ticket without lying about its stage.** A
ticket that is genuinely not startable yet — parked pending a date, not blocked
by another ticket — carries this field instead of a fake `blocked_by` or a
premature move to `cancelled`. `next` and `waves` skip it while the date is in
the future; `board` still shows it, marked `deferred until <date>`, in its real
stage directory, because the directory answers "where is this in its
lifecycle" and `defer_until` answers "when should it come back" — conflating
them would lose the fact that a deferred in-progress ticket is still in
progress. A past or absent date is not deferred. `lint` errors if the value
isn't a valid `YYYY-MM-DD`.

**`--source jira` (or `ISSUES_SOURCE=jira`) reads the ticket set from Jira
instead of the filesystem, for repos that migrated the tracker.**
`<dir>` is not needed in this mode. `lint`/`waves`/`board`/`next` all run the
same wave-grouping, glob-overlap collision check, and `defer_until` logic
either way — only where the tickets come from changes. One JQL fetch per
invocation, never per ticket: `project = <PROJECT_KEY> AND status not in
(Completed, Cancelled, Done)` — `Done` is excluded alongside `Completed`
because it's the closed status a template-derived Space (LAB and others)
ships instead of `Completed`, and also maps to the `completed` stage, run
through the repo's own `jira-api.sh`-equivalent
wrapper (path from `--jira-api PATH` or `ISSUES_JIRA_API=PATH`; project key
from `--jira-project KEY` or `ISSUES_JIRA_PROJECT=KEY`, default `PROJ`). A
failed or empty fetch exits non-zero with a loud message rather than silently
proceeding as if there were nothing to do — an outage during a wave dispatch
must fail at the start, not halfway through. A `Triage` status (and a
`Deferred` status distinct from the `defer_until` field) map to stages that
are never in the workable set, so an untriaged issue never appears in `next`
or any wave. A ticket with no executor set (missing, `None`, or empty — e.g.
one captured from a chat with only a title/description) is likewise never
startable: it is excluded from `next` and every wave, and `board` shows it in
its real stage with a `[?]` marker and "not startable: no executor".
`--fixture PATH` reads a captured JSON file (the body of a `GET
/rest/api/3/search/jql` response) instead of calling the API wrapper — use it
for testing, so a fixture can be hand-built from real tickets and the
expected `next`/`waves` output known in advance without touching a live
project.

### 7. Report

Show the board (`issues.py board issues/`), the wave plan, and say plainly which
tickets need a human and why. Then the session can be closed.

## Working the tickets afterwards

The skill's output is meant to be picked up by fresh sessions. Two things make
that work, and both belong in the README you write:

**Moving a ticket between directories is its own commit.** Not folded into the
work. `git mv` plus the frontmatter update, committed alone, so the history
answers "when did this actually ship?" without anyone remembering.

**One worktree per ticket, named for the ticket.** `waves` emits the commands.
Agents working the same wave never touch the same path, which is the property
`lint` enforces.

## Writing style for tickets

Write for someone who has the repo and no memory of the conversation. That
person is usually a model, sometimes the user in three months, and the two need
the same thing.

Be concrete: name files, commands, versions, addresses. State facts that were
*verified* as verified, and mark anything assumed as assumed — a confident guess
in a ticket is worse than an open question, because it gets acted on.

Keep bodies short. Long-form rationale belongs in the repo's decision log, with
the ticket linking to it.
