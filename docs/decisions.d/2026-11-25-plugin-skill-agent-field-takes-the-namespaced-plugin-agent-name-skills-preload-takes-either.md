---
date: 2026-11-25
slug: plugin-skill-agent-field-takes-the-namespaced-plugin-agent-name-skills-preload-takes-either
title: "plugin skill agent field takes the namespaced plugin agent name; skills preload takes either"
---

# plugin skill agent field takes the namespaced plugin agent name; skills preload takes either

## Decision

Answers NWM-236 (label avs-n03), measured on Claude Code 2.1.332 with a throwaway plugin `nwprobe` loaded through `claude -p --plugin-dir`. (1) A forked skill selects a plugin agent only by its namespaced name: `context: fork` plus `agent: nwprobe:probe-agent` ran the fork under that agent, on its `model: haiku`, with only its `tools: Read`, and with its body in the system prompt. `agent: probe-agent` (bare) fails silently: no error on stderr or in the transcript, and the fork runs as the default agent on the session model with the full tool set. So write `agent: night-watchman:spec-reviewer`, never `agent: spec-reviewer`. (2) A plugin agent's `skills:` preload finds a skill of its own plugin under both `skills: [secret-skill]` and `skills: [nwprobe:secret-skill]`. Either way the skill body reached the subagent as an injected user message tagged `<command-name>` before its first turn, with no Skill-tool call (the agent had only Read). A control agent with no `skills:` saw no skill text. Prefer the namespaced form for symmetry with `agent:`.

## Why

The conversion tickets under NWM-233 cannot write frontmatter on a guess. The silent fallback in (1) means a wrong `agent:` value would ship a plugin release whose forked skill runs as a general-purpose agent on the wrong model and tools, and nothing would report it.

## Cost

Measured on one Claude Code version only. A later release could change how a bare `agent:` name resolves or where preloaded skill text is injected. Re-run the probe after a Claude Code upgrade before relying on the bare `skills:` form.
