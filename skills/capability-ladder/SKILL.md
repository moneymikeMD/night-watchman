---
name: capability-ladder
description: Decide where repeated work's knowledge is kept and where it runs, as two separate questions. Use when someone proposes adding a new agent, when asked "should this be a script, an agent or a skill", or when the main thread does the same work inline a second time with no fixed home for it.
---

# The capability ladder

Novel work becomes a capability, not a one-off. When the main thread does
something inline because no existing script, skill or agent could take it,
author the missing piece before the task is called done, so the next
occurrence has a home.

Answer two questions, separately. One answer never settles the other: a
script can run in a fork, and a skill can be loaded by a named agent.

## Question 1: Where is the knowledge kept?

- **In a script** when every run does the same thing. A script fired by a
  cheap model costs a fraction of any model reasoning through the same
  steps, and its behaviour is fixed and reviewable once. Use a script also
  when the operator must run it (sudo, or a host the agent cannot reach),
  or when it touches a credential or a host and needs guardrails.
- **In a skill** otherwise: whenever the work needs judgement over what it
  finds. A skill is read by the main thread, by a fork and by any agent
  that loads it, so the knowledge reaches every place the work happens.
- **Not in an agent body.** Only that agent reads its body. Knowledge kept
  there is unavailable to the main thread or a worker doing the same job.

A skill that could be a script is a smell. If every run of it produces the
same sequence of actions regardless of what it finds, it is a procedure:
move it into a script.

### Building a script

Build the script from a proven run. Do the first unit by hand, rerun the
script on that same unit, and diff its result against the hand-done one
before trusting it on the rest. When one script can process every unit in
a single pass, run it instead of briefing several agents to hand-apply
what the script would do. (Ported from pstack `principle-build-the-lever`,
2026-09-14.)

### MCP: a surface over a script, not a third place

A script can also be given a typed, callable surface: a local MCP server —
an ordinary stdio process, no deployed backend required — whose tools shell
out to `gh`, `git`, or `docker`. The script stays the artifact: it runs
from a bare terminal, in CI and from a cheap model, and is reviewed once.
MCP is only its signature: schema-validated parameters, call by name, a
distinct `tool_name` in tool analytics.

Tool schemas are deferred in this harness, so an unused tool costs one
name in a list, not a schema in context. The dominant cost of a crowded
tool list is picking the wrong one, not tokens — an argument for narrow,
per-domain servers, not against surfacing at all.

Add the surface only when *both* hold; otherwise keep a plain script:

- A coherent family of operations shares a domain model — not one script,
  one call.
- The `Bash` bucket genuinely isn't good enough: analytics need per-tool
  granularity a shell command can't produce, or a curated API would
  replace repeated, near-identical invocations.

Scope one server per domain, enabled per project, never installed
globally — a global server puts every project's tools in every other
project's name list. Every tool is a thin dispatcher over a script that
already works standalone, so exposing it stays reversible. A tool that
reaches an action its underlying script can't, or carries a flag that
bypasses a check the script enforces, is a permission bypass wearing an
interface.

## Question 2: Where does it run?

- **In the session that needs it** when the work depends on the
  conversation, or the owner steers each step.
- **In a fork** when the input is small, the reading is large, and one run
  at a time is enough.
- **In a named agent** only when at least one of these holds:
  1. Several run at once.
  2. The output is long and not needed afterwards.
  3. The reviewer must not have seen the work.
  4. A tool limit has to be enforced.
  5. A cheaper model does simple, noisy work.
  6. It is a background loop resumed later.
  7. Each deploy stage needs a fresh context.

Name the condition that holds when you propose an agent. If none holds,
run the work in the session or a fork, and keep its knowledge in a skill.

## Checking an agent body

For each paragraph in an agent body, ask: would the main thread, or a
worker doing the same job, need this? If yes, the paragraph is in the
wrong file. Move it into a skill the agent loads, and leave the agent body
with its role, its tool limits and its output contract.

## When the answer is in doubt

Fold the subagent into a skill and run both versions against the same
evals. Keep the subagent only if the folded version scores worse.

## Second ladder: enforcing a rule

The questions above place *work*. This ladder ranks mechanisms for
enforcing a *rule*, strongest first. When a rule can be encoded at more
than one rung, use the strongest one the situation allows: agents copy
whatever the surrounding code already does, and a weaker guard becomes the
next template. When the fix is structural, use only the structural fix.

1. **Unrepresentable** — make the wrong state impossible to produce,
   for example a wrapper that exposes only the allowed operations.
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
`verify` that came back NOT MET — and the memory provider can store the
fact, but the skill that caused it stays wrong unless something closes the
loop. At session wrap-up, if the session had a correction worth
generalizing (not a one-off), dispatch `agents/reflector.md` over the
session's corrections. Anything a lint, hook, or helper could enforce
instead moves to a ticket, not a prose edit. The owner approves before any
file changes. One reviewer, one model — this is a wrap-up step, not a
research spend.

Ported from pstack `reflect`, 2026-09-14.
