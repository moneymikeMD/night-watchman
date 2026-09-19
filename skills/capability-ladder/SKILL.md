---
name: capability-ladder
description: How to decide whether repeated work should become a script, an agent, or a skill. Use when the main thread catches itself doing something inline for the second time, when asked "should this be a script/agent/skill", or when a task keeps recurring without a fixed home for it.
---

# The capability ladder

Novel work becomes a capability, not a one-off. If the main thread ends up
doing something inline because no existing script, agent, or skill could take
it, that is a gap, not an exception — before the task is called done, author
the missing piece so the next occurrence is delegable.

The ladder, in order of preference:

## 1. A script

Use when the work is reusable, must be run by the operator (sudo, or
interactive on something the agent cannot reach), or touches a credential/host
and needs guardrails regardless of reuse. A script fired by a cheap model
costs a fraction of any model reasoning through the same steps from a skill,
every time it runs, and its behavior is fixed and reviewable once rather than
re-derived on every invocation.

Build the script from a proven run, not from a guess: do the first unit by
hand, then rerun the script on that same unit and diff its result against the
hand-done one before trusting it on the rest. A deterministic script also
beats fan-out — if one script can process every unit in a single pass, run
it; don't brief several agents to hand-apply what the script would do.
(Ported from pstack `principle-build-the-lever`, 2026-09-14.)

## MCP: a surface over rung 1, not a rung of its own

A script can also be given a typed, callable surface: a local MCP server —
an ordinary stdio process, no deployed backend required — whose tools shell
out to `gh`, `git`, or `docker`. This sits *beside* rung 1, never above or
below it. Above would say it holds more judgement than a script; it holds
none. Below would say it replaces a script; it must not, since a server
that owns behaviour can't be retired without a rewrite. The script stays
the artifact — a bare terminal, CI, a cheap model, reviewable once. MCP is
only its signature — schema-validated parameters, call by name, a distinct
`tool_name` in tool analytics.

The premise that used to rule this out is stale: tool schemas are deferred
in this harness, so an unused tool costs one name in a list, not a schema
in context. A 2026-09-19 session observed roughly 230 deferred tool names,
about 100 of them `tokensave_*`, with only five carrying eager schemas. The
dominant cost of a crowded tool list is picking the wrong one, not tokens —
an argument for narrow, per-domain servers, not against surfacing at all.

Reach for the surface only when *both* hold, otherwise stay a script:

- A coherent family of operations shares a domain model — not one script,
  one call.
- The `Bash` bucket genuinely isn't good enough: analytics need per-tool
  granularity a shell command can't produce, or a curated API would
  replace repeated, near-identical invocations.

Scope one server per domain, enabled per project, never installed
globally — a global server puts every project's tools in every other
project's name list. The server holds no logic: every tool is a thin
dispatcher over a script that already works standalone, so exposing it
stays reversible. That also bounds the hazard — a tool that can reach an
action its underlying script can't, or that carries a flag bypassing a
check the script enforces, is a permission bypass wearing an interface,
not an improved one.

## 2. An agent

Use when the work needs judgement but is bounded and repeatable enough to
brief once — a fixed role, a fixed tool subset, and a pinned cheap model. An
agent is the right layer when a script alone can't decide, but the decision
space is still narrow enough to write down in a brief a cheap model can
follow without supervision.

## 3. A skill

Use when the work needs the main thread's judgement over a changing
situation — the value is in *what to do next*, not in executing fixed steps.
A skill that could be a script is a smell: if every run of it would produce
the same sequence of actions regardless of what it finds, it is not judgement,
it is a procedure, and belongs one rung down.

## How to tell which rung

- Could this run unattended with a cheap model and produce a deterministic
  `verify` result? → **script**.
- Does it need a bounded judgement call inside a fixed brief? → **agent**.
- Does it need to read a changing situation and decide what happens next? →
  **skill**, run on the main thread.

## The rule that makes this stick

The default for any task an existing agent can take is to delegate it off the
main thread — the main thread's job is to read context, decide, sequence,
judge results, and talk to the user, not to do the work itself (see the
orchestrator rule in `templates/CLAUDE.md`). When nothing existing can take a
recurring task, climb the ladder from the bottom: try to make it a script
first; only reach for an agent, then a skill, if the work genuinely needs more
judgement than the rung below can hold.

## Second ladder: enforcing a rule

The ladder above ranks mechanisms for doing *work*. A second ladder ranks
mechanisms for enforcing a *rule*, strongest first — when a rule can be
encoded at more than one rung, use the strongest one the situation allows,
because agents copy whatever the surrounding code already does and a weaker
guard becomes the next template. If the fix is structural, only use the
structural fix; prose is the symptom, not the cure.

1. **Unrepresentable** — make the wrong state impossible to produce.
   `guard-fs-writes.sh` blocks a disallowed write before it happens, not
   after.
2. **A lint in CI** — `issues.py lint` rejects overlapping `touches` before
   a wave starts.
3. **A helper that does it right** — `known-issue.sh add` is the only
   sanctioned way to add a known issue; hand-editing the index is not.
4. **A runtime check** — `session-cost.sh` records and checks cost as the
   session ends, not from a rule to remember to do it.
5. **Text in a doc** — `CLAUDE.md` prose, last resort: needs a reader to
   notice, remember, and comply.

Ported from pstack `principle-encode-lessons-in-structure`, 2026-09-14.

## Reflect at wrap-up

Corrections happen inside a session — owner pushback, a retracted claim, a
`verify` that came back NOT MET — and memorygraph can store the fact, but the
skill that caused it stays wrong unless something closes the loop. At
session wrap-up, if the session had a correction worth generalizing (not a
one-off), dispatch `agents/reflector.md` over the session's corrections.
Anything a lint, hook, or helper could enforce instead moves to a ticket,
not a prose edit — that is the point of having two ladders. The owner
approves before any file changes; nothing is applied unapproved. One
reviewer, one model — this is a wrap-up step, not a research spend.

Ported from pstack `reflect`, 2026-09-14.
