---
name: handoff-docs
description: Writing a session wrap-up note for whoever picks this up next — a fresh session, or a different person. Use at session end, when the user says "write up where we left off", or before closing a session that did real work.
---

# Handoff docs

The bar is the same one `to-issues` sets for tickets: a reader with the repo
and no memory of this conversation must be able to continue without asking a
question back.

## What a handoff doc is not

It is not the ticket system, and it is not the decisions log. A handoff doc
is read once, by whoever opens the next session, and then archived — it is
never treated as living truth the way a ticket or a decisions-log entry is.
Anything actionable belongs in a ticket (with `verify`/`touches`/`executor`
per `tickets-protocol`) or a dated decisions-log entry, not only in the
handoff doc. A handoff doc that is the *only* record of a decision is a
decision that will be lost the moment the doc goes stale, because nobody
re-reads an old handoff doc looking for ground truth — they read the current
tickets and the current docs.

Treat the handoff doc as a pointer and a summary, not a container.

## Structure

- **What changed this session** — bullets naming capabilities delivered, not
  internal jargon or ticket ids alone. Someone skimming this should know what
  is different now.
- **Verified vs. assumed** — state facts as verified only if they actually
  were (a command run, an output read); mark anything else as an assumption.
  A confident-sounding guess here is worse than an open question, because the
  next session acts on it without checking.
- **What remains** — as ticket ids/links if tickets exist for the remaining
  work, not prose that duplicates what the ticket already says. If something
  remaining has no ticket yet, that is itself a gap — file one rather than
  leaving it only in prose here.
- **Decisions only a human can make** — surfaced explicitly, not buried in a
  paragraph. If there are none, say so; don't imply there might be by
  omission.
- **Suggested next** — the skills or agents the next session should load
  first.

Redact secrets, tokens, and personal data before writing — the doc is
committed, unlike a temp-dir copy.

A handoff doc stays in the repo. The owner-facing brief of a wave goes to
the external system of record through the `publish` provider — see
`session-start`'s wrap-up ("Publish the brief"); do not paste a handoff
doc there in its place.

## Before writing one: is a handoff the right move?

Decide only at a phase boundary, in order — first yes wins:

1. **Continue** — next phase needs this verbatim and session is under
   session-start's split threshold.
2. **Clear** — nothing here matters to what follows.
3. **Handoff** — work moves to another harness, repo, person, or forked
   side task.
4. **Dispatch** — next unit is ticketed and agent-executable; see the
   project's configured dispatch provider.
5. **Otherwise, compact** with an instruction naming the next phase.

Adapted from mattpocock/skills handoff, ask-matt, 2026-09-14.

## Keep it short

Link out to tickets and the decisions log for detail rather than restating
it. A handoff doc that duplicates a ticket's body is two places that can now
disagree — the ticket is the one that should win, so the handoff doc should
not try to compete with it.

## Pausing mid-wave

This is a mid-phase interruption, not the phase-boundary choice above — the
tree above doesn't apply here. A pause isn't only end-of-session. Stopping
mid-wave — for compaction, a handoff, or the owner going offline — needs
the same discipline: finish or
back out of the current atomic step, start nothing new, take no
irreversible action (no PR, no push, unless one was already out). Commit
uncommitted edits as one `wip:` commit on the branch — `land-branch.sh`
refuses to land a worktree with uncommitted changes, so the `wip:` commit
is what makes the pause safe, not just tidy. Then write the resume note:
what's verified, what's still in flight, and the first action on resume.
Ported from pstack poteto-mode pause-safely, 2026-09-14.
