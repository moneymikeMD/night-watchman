# FAQ

Questions that keep being asked about what this is. Explanation, not
reference — opinion allowed, and the reasoning is the point.

## Is this a Claude Code workflow?

No, and the cleanest proof is that night-watchman has already been run both
ways without noticing the difference.

`providers/dispatch/` is a provider-neutral contract. `herdr` is one
implementation behind it. The 2026-09-19 work-order wave was dispatched through
Claude Code's Workflow tool instead, and nothing above the dispatch seam
changed: the same tickets, the same lifecycle, the same gates, the same
end-of-wave report. A thing that treats "a workflow" and "a herdr pane" as
interchangeable back-ends cannot itself be either of them.

The deeper mismatch is state. A workflow is a script with a thread pool. It
starts, fans out, returns, and the only thing that outlives it is its own
journal. Every night-watchman primitive is durable by design and exists
precisely because there is a next time:

- ticket status is a directory move, or a tracker transition
- `docs/decisions.md` is a dated append, never a rewrite
- `known-issues/` carries per-entry hashes so a silent edit is detectable
- memory-graph holds what would otherwise die with the session
- `docs/handoffs/` is written so the next session can start cold

A workflow has no opinion about any of that, because a workflow has no next
time. That is not a deficiency in workflows. It is a different job.

## Is it an agent team?

No. It ships nine agents and none of them orchestrates.

`librarian`, `script-author`, `script-reviewer`, `spec-reviewer`,
`cost-reviewer`, `reflector`, `researcher`, `diagnose-and-pr` and
`script-author-lite` are leaves. They are dispatched; they do not dispatch. The
orchestration lives in the skills — `session-start`, `tickets-protocol`,
`wave-trail` — and, more tellingly, in the hooks.

The hooks are the part neither a workflow nor an agent roster can reproduce,
because they change the economics of the session they run inside rather than
the plan the session is following:

- `read-shunt.sh` and `bash-result-shunt.sh` keep tool output out of the
  expensive model's context, so a cheap model does the reading
- `guard-fs-writes.sh` is a deterministic control that fires on every Bash call
  regardless of what any agent intends, which is the point — a rule written in
  a `CLAUDE.md` is a rule a fresh subagent can read and still violate
- `session-cost.sh` meters what a run actually cost

An agent team is a roster. A workflow is control flow. Neither can install a
`PreToolUse` hook.

## Then what is it?

An unattended-operations engine, which is a different question rather than a
better answer to the same one.

A workflow and an agent team both answer **"how do I run N agents right now?"**
night-watchman answers **"what has to be true for work to proceed while nobody
is watching?"** Those are orthogonal, and the second decomposes into four
things:

| | What it settles |
| --- | --- |
| **The unit of work** | A ticket is a contract an agent can execute cold — what to touch, how to verify, who finishes. Extracted to [`work-order`](https://github.com/moneymikeMD/work-order) so it can be implemented by tools that are not this one. |
| **The economics** | The capability ladder — script beats agent beats skill — and the orchestrator/cheap-executor split the hooks enforce. |
| **The safety envelope** | The guard, the still-ask list, and `ASSUMED:` escalation: decide, mark the assumption, keep going, surface it in the report. |
| **The record** | Decisions, known issues, handoffs and memory, written so the next session starts from them instead of re-deriving them. |

Roughly: a workflow is a `for` loop with a thread pool, an agent team is an org
chart, and night-watchman is CI/CD plus runbooks plus the on-call rotation. It
defines the unit, the gates, the record and the cost model, then hires whatever
executor is available.

## So the dispatch layer is the overlap?

Yes, and it is the one place the question has teeth.

`providers/dispatch/` was built as a peer implementation rather than a thin
adapter, which meant this repo maintained a dispatch mechanism whose failure
modes the platform had since made unnecessary. Three of the open herdr dispatch
issues — a cold boot swallowing the brief, the reached-working wait failing on
back-to-back starts, a fresh worktree hitting the folder-trust dialog — do not
exist when the same wave runs under the Workflow tool.

WO-026 answered that by adding the Workflow tool as the second implementation
and making it the default; herdr stays as the fallback for a supervised pane, a
session outliving the turn, and anything needing a real terminal. So the seam
now carries two implementations rather than one, which is the only way its
design gets tested by something other than argument. What that surfaced is
written down in `providers/README.md`: the verbs do not map one-to-one, and
`watch` in particular promises a read of a run journal rather than the live
view and blocking wait herdr's offers — declared as a gap instead of
approximated.

The honest reading is still that layer 3, the provider system, is the least
settled of the three, and that the dispatch provider is where it is being
settled first.

## Which parts are actually novel?

Three, and it is worth being precise because "its own framework" is fair for the
whole and over-broad for the parts.

`agents/`, `skills/` and `hooks/` as directories are ordinary Claude Code plugin
surface. What is not ordinary:

1. **The ticket as a cold-executable contract** — being extracted into
   `work-order` precisely because it is the reusable idea rather than a detail
   of this implementation.
2. **The capability ladder** — repeated work climbs down to something cheaper
   than a model re-deriving it, with a named rule for when to stop.
3. **The hook-enforced cheap-reads / expensive-decides split** — a discipline
   the platform will execute whether or not the model cooperates.

The rest is scaffolding around those three.
