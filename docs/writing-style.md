# docs/ writing style

Ported from pstack's `technical-writing` skill (report 5.12). This section
applies to committed `docs/` prose. Skill and agent prose (`skills/`,
`agents/`, `CLAUDE.md`) follows the separate rules below — caveman mode
shapes chat output only, not committed files.

## Diátaxis compass, mapped to this repo

One file, one mode.

- **Tutorial** (learning by doing) — none yet; `docs/adopting.md`'s numbered
  runbook is the closest fit if one is added.
- **How-to** (steps to a goal) — `docs/adopting.md`.
- **Reference** (facts for lookup, no opinion) — the topic files:
  `ethos.md`, `known-issues.md`, `cost.md`, `scripts.md`,
  `testing-philosophy.md`.
- **Explanation** (why, opinion allowed) — `docs/decisions.md`.

Don't mix modes in one file: no reference tables inside a how-to, no
arguing inside reference. Split and link instead.

## Review checklist

1. Is the file one Diátaxis mode, with links where modes meet?
2. Is every instruction a command, with its condition stated first?
3. Does any sentence carry two instructions or two thoughts? Split it.
4. Can any word be cut without losing meaning? Cut it.
5. Does every "it", "this", "only" point at one obvious thing?
6. Does each thing have exactly one name across the docs?
7. Would a developer say these words out loud? Replace invented metaphors.
8. Are all paths, symbols, and counts real at this commit?

## Style summary

Google developer style: write to "you", present tense, active voice,
condition before instruction. STE: one instruction per sentence, split
past ~20-25 words. Global English: keep "only"/"not" next to what they
modify, one name per thing, no slashes.

## Em-dash rule

Existing docs keep their em dashes as written — no rewrite pass. A new
doc prefers a full stop or comma instead of an em dash, but an em dash
in new prose is not a review finding. (Assumption; flag for the owner
to flip if wrong.)

## Skill and agent prose

Adapted from mattpocock/skills `writing-for-agents`, `retro`, 2026-09-14.
Applies to `skills/*/SKILL.md`, `agents/*.md`, and `CLAUDE.md` — anything
an agent reads as steering, not anything a human reads as reference.

- **A description is an always-loaded pointer.** A skill or agent
  description sits in context every turn whether or not it fires. Lead
  with the trigger word. Give one trigger per distinct branch — synonyms
  for the same branch are one trigger written twice, so collapse them.
  Don't restate identity the body already carries.
- **No-op test.** Before adding a line, ask: does this change behavior
  versus the model's default? If not, cut it — whole sentences, not
  trimmed words. Two people disagreeing about a no-op are disagreeing
  about the default; settle it by running the document, not by debate.
- **Steer positively.** A prohibition drags the banned behavior into
  context and makes it more available, not less. State the target
  behavior instead of the thing to avoid. Keep a prohibition only as a
  hard guardrail you cannot phrase positively, and even then pair it with
  the positive target.
- **Completion criteria.** Every step ends on a condition the agent can
  check itself against — done or not done, no judgment call. A demanding
  criterion ("every ticket accounted for") drives more thorough work than
  a soft one ("produce a change list").
- **Disclose by branch.** Material only some runs need goes to
  `references/` (or a sibling doc) behind a pointer, not inline in the
  main file. Inline what every branch needs; push behind a pointer what
  only some branches reach.
- **Single source of truth.** A rule stated in two skills is a drift bug
  waiting to happen — the two will diverge the next time one is edited
  and the other is missed. Point at the other skill/doc instead of
  restating its rule.

This is doc, not lint: a linter can check line count or attribution
format, but cannot judge whether a sentence is a no-op. Treat this
section itself under its own rules — if a future edit here doesn't change
what an agent does, cut it.
