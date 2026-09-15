<!--
Template. This file is not auto-loaded by the plugin. Copy the rules below
into your own project's CLAUDE.md (merge them in, don't just symlink this
file) and adapt the specifics — agent names, model tiers — to what your
project actually has defined. Delete this comment once you've merged it.
-->

# CLAUDE.md rule templates

## The main model orchestrates; subagents do the work

When the main-thread model is the most expensive model available in the
session, its job is to read context, decide what to do, sequence it, judge
the results, and talk to the user — not to do the work itself. The default
for any task that a defined agent can take is to delegate it off the main
thread to that agent, because the agent already pins the cheapest model
suited to the work (a cheap model for read-only triage, a mid-tier model
for edits and scripts, the most capable model only where review judgement
actually matters).

**Novel work becomes a capability, and a script beats a skill.** If the
main model ends up doing something inline because no existing script,
agent, or skill could take it, that is a gap, not an exception. Before the
task is called done, author the missing piece so the next occurrence is
delegable — in this order of preference: a script, then an agent, then a
skill. A script fired by a cheap model costs a fraction of any model
reasoning through the same steps from a skill, every time it runs, and its
behavior is fixed and reviewable once. See the `capability-ladder` skill
for the full reasoning behind this ordering.

## Delegation and claim rules

- You own every subagent's work: review the diff, write your own summary,
  don't pass through what it said.
- An interrupted-and-resumed agent silently drops directives. Fire a fresh
  one with consolidated scope instead of resuming it.
- Every claim carries its evidence or its label (measured / inferred /
  guess) in the same sentence.
- Never hand the human a check you could run yourself.

(Ported from pstack `poteto-mode`, 2026-09-14.)

## Testing a script never touches a live target

Any script with an apply/POST/write/mutate path must be tested with every
target-system variable pointed at an unroutable or loopback address, or
through a `--dry-run`/`--check` path that stops before the network call. A
comment or a brief saying "do not run this against production" is prose,
not a guard — it relies on every future reader noticing and obeying it. The
test environment itself must be structurally unable to reach the real
target, so the failure mode is "the request goes nowhere," not "someone
forgot to check."

An author once tested a backup-job script exactly this way — by convention,
via a documented isolation flag, not a structural block — and it issued a
real write against production, rejected only because one field on that
particular request happened to be invalid. The isolation was a convention,
not a guarantee, until it was enforced structurally instead.
