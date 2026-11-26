---
date: 2026-11-25
slug: forked-skill-brief
title: "forked skill brief"
---

# forked skill brief

## Decision

NWM-237 (avs-n04), tested on Claude Code 2.1.332. A forked skill takes a multi-line brief intact. Two different forked skills run at the same time when an interactive main thread calls them in one message. Under `claude -p` they run one after the other. So fleet-parity, docs-drift-sweeper, bench-runbook, epic-closer, cost-reviewer and diagnose-and-pr become forked skills, not a skill plus a thin agent. A caller that needs them in parallel must be an interactive session, not `-p`.

What worked. Frontmatter `context: fork` and nothing else, with the brief placed in the body as `$ARGUMENTS`. The caller runs `Skill(skill: "<name>", args: "<brief>")`. A 30-line brief went in through `args`; it held double and single quotes, backticks, a fenced code block, `$HOME`/`${PATH}`/`$(whoami)`/`$ARGUMENTS`, tabs, backslashes, a trailing backslash, Unicode, leading and trailing spaces and two blank lines. In both `-p` and interactive mode the fork transcript received it byte-identical to the `args` value (`cmp`). The fork saw none of the calling conversation: its transcript does not contain the caller's prompt.

Concurrency. From an interactive session (`claude`, not `-p`), two different `context: fork` skills called in one assistant message both showed "Running in the background". Each ran `date; sleep 30; date`, and the two start stamps were 44 ms apart, so the 30 s windows overlapped. Fork metadata recorded `requestShape: "background"`. Under `claude -p`, the same two calls in one message ran back to back: the second started 1.5 s after the first ended. Adding `background: true` to the frontmatter did not change that (2.8 s gap). Fork metadata recorded `requestShape: "foreground"` both times.

## Why

The six agents hold knowledge in their bodies that no other session can read, and the migration exists to remove that. A fork gets only the skill text and its arguments, so the move works only if a whole brief survives `args`. It does, so the fallback of a skill plus a thin agent is not needed. The docs (fetched 2026-11-25) say forks default to `background: true` and say nothing about `-p`. That gap is why concurrency was measured in both modes.

## Cost

A headless (`claude -p`) wave that calls several of these skills runs them one at a time, so its runtime is their sum. Getting them in parallel means calling from an interactive main thread or keeping an Agent-tool dispatch. One risk remains: when a fork copies a brief with its own Write tool, it can drop trailing whitespace (seen in both modes). That is the model rewriting the text; the transport was intact. A skill that needs the brief byte-exact should read it from its prompt, not ask the model to copy it.
