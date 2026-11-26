---
name: close-epic
description: Decide what an epic (or the whole backlog) still needs to reach Completed and drive it there — fill ticket fields derivable from the repo and the ticket's own text, move fully filed tickets out of triage, verify awaiting-deployment tickets against reality with read-only checks from their verify blocks, transition what the evidence supports with the evidence in the comment, and close the epic when no child is left. Ends with the epic closed or a residue list naming the single thing each remaining ticket waits on. Use when asked what is left on an epic, why tickets sit in triage, or to get an epic to Completed.
argument-hint: "<epic id | backlog> [tracker: file <dir> | jira with status and transition ids]"
context: fork
model: sonnet
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/board.sh)
---

# Close an epic

You take an epic to closed, or to a short list of exactly what stops it. `librarian` performs a ticket operation it
is named; you decide which operations an epic still needs and run them, through the same tracker verbs. Read
`${CLAUDE_PLUGIN_ROOT}/skills/tickets-protocol/SKILL.md` first: its "Ticket flow" and "Transition commits" sections
are the lifecycle and commit rules you follow, and they are not repeated here.

## Brief

$ARGUMENTS

The brief names the scope (one epic id, or `backlog` for every open ticket) and the tracker: file mode's issues
directory, or jira with its status ids (In Progress, Awaiting Deployment, Completed) and the transition ids that reach
them. When the brief carries the board, lint output or verify observations, use those instead of re-running them.

## Board and lint at load

!`${CLAUDE_SKILL_DIR}/board.sh`

Output above that is an error, or names a different tracker than the brief, is not the set: run the commands yourself
against what the brief names.

## Process

`ISSUES_PY="$("${CLAUDE_PLUGIN_ROOT}/scripts/work-order-root.sh" --issues-py)"`,
`P="${CLAUDE_PLUGIN_ROOT}/providers/lib/provider.sh"`. Add `--source jira` to every `issues.py` call in jira mode.

1. **The set.** The children are the tickets whose `epic` is the input id; read each one (`"$P" run tracker fetch
   <id>` in jira mode).
2. **Per child not Completed or Cancelled**, by stage:
   - **Triage, or failing lint.** Derive what is missing from evidence, never invention: `touches` from paths the
     ticket names that `git ls-files` confirms, or from the diff of a branch already carrying its id; `verify` from an
     acceptance line that names a runnable observation; `executor` from whether every step is a command. A field
     with no evidence stays empty and becomes residue. File mode: edit the frontmatter and `git mv` the ticket out of
     `triage/` in one commit. Then `python3 "$ISSUES_PY" lint <dir> --scope <id>`.
   - **Open or in progress.** Work already on the default branch (`git log origin/<default> --grep <id>`) whose
     lifecycle never ran: in jira mode `"${CLAUDE_PLUGIN_ROOT}/scripts/land-branch.sh" <branch> <id>
     --already-merged <jira flags>` when the branch still exists, else residue. Work not yet done is residue
     (`needs dispatch`); you do not build.
   - **Awaiting deployment.** Run its `verify` block, read-only. A step that deploys, restarts, writes or signs in is
     not yours to run: residue (`live write` or `hands-on step`). All clauses MET → comment the evidence per clause,
     then transition to Completed. PARTIAL or NOT MET → comment which clause and what was observed; residue.
3. **Transitions** go through `"$P" run tracker transition <id> <transition id>` and `"$P" run tracker comment <id>
   -` (evidence on stdin), always the comment first.
4. **The epic.** When every child is Completed or Cancelled, close the epic with a comment listing each child and its
   final state. In jira, an Epic with required fields it cannot carry is residue, named as such.

The shipped `tracker` contract has no verb that sets a field or lists a ticket's transitions. In jira mode a derived
field value and a missing transition id are residue, carrying the exact value to set; never reach around the provider
to the tracker's API.

## Report

`epic <id>: closed` or `epic <id>: <n> open`, then what you moved:

| Ticket | From → to | Evidence |
| --- | --- | --- |

Then the residue, one line per ticket and only one thing each: `<id> — waiting on <a hands-on step | an owner
decision | a live write | dispatch | field <name> = <value>>`.

## Refusals

- Never mark a ticket done on a proxy ("deployed", "container is Up", HTTP 200) instead of its verify clause.
- Never write a `verify` block the ticket's text does not support, and never edit a description to fit the evidence.
- Never run a verify step that mutates a live system.
- No `dispatch` or `secrets` provider, no direct tracker API call.
