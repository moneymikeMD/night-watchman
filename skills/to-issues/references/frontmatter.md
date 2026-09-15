# Ticket frontmatter reference

Every ticket is a Markdown file whose YAML frontmatter is machine-read by
`scripts/issues.py`. The directory the file sits in is its status; there is no
status field.

## Fields

| Field | Required | Purpose |
| --- | --- | --- |
| `id` | yes | Stable identifier, never reused. Referenced from commits, docs, other tickets. `PREFIX-NNN` — pick a prefix from the repo or project name |
| `title` | yes | Short imperative phrase. What will be true when it is done |
| `created` | yes | `YYYY-MM-DD` |
| `updated` | yes | `YYYY-MM-DD`, bumped on every stage move |
| `executor` | yes | `agent`, `human`, or `mixed` — see below |
| `tags` | yes | Flat list. Used for filtering; keep the vocabulary small |
| `blocked_by` | yes | List of ids, or `[]`. Empty means startable now |
| `touches` | yes for `agent`/`mixed` | Path globs the ticket will create or modify |
| `appends` | no | Shared files the ticket only appends to or edits locally — logs, registers, changelogs. Collisions here warn instead of blocking |
| `verify` | yes except in `cancelled` | Block scalar. How to prove it is done |
| `human_steps` | yes when `executor: mixed` | The specific steps a person must perform |
| `outcome` | yes in `cancelled` | Why it was dropped. Optional elsewhere |

## `executor`

The field that decides whether a swarm can pick a ticket up.

**`agent`** — an agent can complete it end to end, including verification. Code,
config, docs, tests, refactors, anything driven by files and CLIs.

**`human`** — impossible for an agent. Creating an account, approving a
biometric prompt, paying for something, plugging in a cable, clicking through a
console with no API, deciding something only the owner can decide. These tickets
still belong in the log; they are often what blocks everything else.

**`mixed`** — an agent does the work, a person performs listed steps. The common
shape: the agent prepares config and opens a PR, the human deploys it. Put the
human parts in `human_steps` so the agent knows exactly where to stop, and so
the person knows exactly what is being asked. When `human_steps` exceed a few
actions or capture values (API keys, tokens), the deliverable is a wizard
stages file (`scripts/lib/wizard.sh`, see `night-watchman:shell-scripting`)
the owner runs, not prose alone.

Misclassifying is expensive both ways. An `agent` ticket that secretly needs a
password prompt stalls a worker until it times out. A `human` ticket that an
agent could have done wastes an afternoon.

## `touches`

Path globs, relative to the repo root, that the ticket will create or modify.

This exists so `lint` can prove two tickets in the same wave will not collide,
which is what makes parallel worktrees safe. Two tickets that touch the same
path are serialised by a `blocked_by`, or merged into one ticket.

Be generous. An unlisted file becomes a merge conflict a human untangles. An
over-listed one costs a little unnecessary serialisation, which is cheap by
comparison.

```yaml
touches:
  - docker/alloy.yaml
  - alloy/*.alloy
  - docs/monitoring.md
```

### `touches` vs `appends`

`touches` means "this ticket owns edits to that path" and two startable tickets
sharing one is an error. `appends` is for the files nearly every ticket writes
to anyway — a known-issues register, a decision log, a changelog. Those are
append-mostly and merge trivially, so requiring serialisation on them would
serialise the entire repo and defeat the point of parallelising at all.

Rule of thumb: if two agents editing it at once would produce a conflict a human
has to reason about, it is `touches`. If it would produce two paragraphs in
different places, it is `appends`.

Tickets that touch nothing in the repo — a console change, a credential — should
declare `touches: []` and almost certainly have `executor: human`.

## `verify`

A block scalar giving the command that proves the work is done, and the result
that counts as passing.

```yaml
verify: |
  ./scripts/lint.sh --quiet && echo PASS
  # exit 0 and no findings
```

The reason this is strict: work gets marked done on the basis that it *should*
work far more often than anyone admits. A service that starts, reports healthy
and does nothing is the normal failure, not an exotic one. A command with a
deterministic result is what separates "finished" from "probably finished".

Where a human genuinely must look — a rendered page, a physical LED — write that
as the verification and set `executor` to `human` or `mixed`. An honest manual
check beats a command that pretends to test something it does not.

**`verify` must be red at the base commit.** A check that already passes
before any work starts grades nothing — it will read as done on day one. Name
the specific observation that fails today, so the same command turning green
is evidence the ticket actually changed something.
Adapted from mattpocock/skills to-tickets, triage, 2026-09-14.

## `outcome`

Required in `cancelled/`. Explains why the work was dropped, in enough detail
that nobody re-proposes it.

State what changed: a better option was found, the premise turned out to be
false, the cost exceeded the benefit. Name the replacement if there is one.

```yaml
outcome: >-
  Superseded by the vendor's built-in exporter, which covers the same signal
  with no extra container and no credential. Revisit only if per-port PoE data
  is ever actually needed.
```

An empty `outcome` on a cancelled ticket is worse than no ticket at all: the
reader learns the idea was considered but not why it lost, so they re-derive it.

## Body

Sections in this order, omitting any that would be empty:

- **Problem** — from the operator's or user's point of view
- **Solution** — what will be done
- **Decisions** — non-obvious choices and their reasoning, especially "why not
  the obvious approach"
- **Out of scope** — what this deliberately does not cover, with pointers to the
  tickets that do

Keep it short. Detailed rationale belongs in the repo's decision log; link to it.
