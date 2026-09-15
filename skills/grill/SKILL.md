---
name: grill
description: Stress-test a plan, design, or decision by interviewing the owner in rounds until nothing is left assumed, then hand the settled decisions to to-issues. Use when the user says "grill me", "grill this plan", asks to pressure-test an idea before work starts, or a to-issues decision ticket needs an owner conversation.
---

# Grill

Interview the owner in rounds until the plan has no assumption left
unstated, then hand the result to `to-issues` so the work survives past
this session. Runs on the main thread only: a subagent cannot hold this
conversation with the owner.

## Before the first round

- Read `docs/ethos.md`'s defaults and Still-ask list. A default that
  covers a question gets applied and stated, not asked.
- Run one `memorygraph recall` on a single keyword from the topic, if
  memorygraph is configured.
- Scan `cancelled/` (or the tracker's cancelled stage) for a prior
  rejection of the same idea before re-asking it.

## The tree and the frontier

Model the subject as decisions that branch into the decisions that hang
off them. The **frontier** is every decision whose prerequisites are
already settled — the questions answerable right now without guessing at
an answer not yet heard. Ask the whole frontier in one round; a question
whose answer depends on another still-open question belongs to a later
round.

## Round format

Plain markers, no emoji — they render poorly in dictation tools and this
project's instructions avoid them elsewhere. Ask through the harness's
question tool, or the operator's configured dictation tool when one is
wired up, never as bare chat text when a tool exists.

```
Q1 - <question title>: <question body, may be multiple paragraphs or choices>
Recommended: <your recommended answer>

Q2 - <question title>: <question body>
Recommended: <your recommended answer>
```

Full question bodies and every option stay intact in a grill round —
this is one of the few contexts exempt from a compressed chat register,
because a dropped option is a dropped decision.

## Facts are not questions

Anything observable — file contents, versions, live behavior — goes to a
cheap read-only agent (or the `researcher` agent for anything outside the
repo), never to the owner. A running lookup is an unsettled prerequisite:
only the questions downstream of it wait; ask the rest of the frontier
now.

## Someone else's knowledge

When a question only another person can answer, write
`questionnaire-<slug>.md` (purpose, context, questions most-important
first, "I don't know" allowed as an answer) and file an `executor: human`
ticket that blocks the decisions downstream of it. Keep grilling the rest
of the frontier in the meantime.

## Stop condition

The frontier is empty and the owner confirms shared understanding. Do not
start implementation inside this skill.

## Record as you go

- Every owner answer that confirms or moves a repo default becomes an
  `docs/ethos.md` decision-log row.
- A decision passing the three-gate test (costly to reverse, surprising
  without it, real alternatives weighed — see `tickets-protocol`'s
  frontmatter contract) goes to `docs/decisions.md` as a dated append,
  never a rewrite.
- Anything considered and dropped becomes a cancelled ticket recording the
  outcome, not a silently vanished option.

## Hand-off

Once the frontier is empty, call the Skill tool with `to-issues` so the
settled decisions become independently-workable tickets before this
session's context is gone.

Adapted from mattpocock/skills grilling, grill-me, grill-with-docs,
to-questionnaire, 2026-09-14.
