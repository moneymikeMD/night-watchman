---
seq: 17
date: 2026-09-19
level: 3
slug: 2026-09-19-mcp-sits-beside-rung-1-as-a-surface-not-a-fourth-rung-wo-030
title: "MCP sits beside rung 1 as a surface, not a fourth rung (WO-030)"
---

`skills/capability-ladder/SKILL.md`: a script can carry a typed, callable
MCP surface without becoming a new rung. Placed beside rung 1, not above or
below it — above would say MCP holds judgement, which it doesn't; below
would say it replaces the script, which it must not, since a server that
owns behaviour can't be retired without a rewrite. The script stays the
artifact; MCP is only its signature — schema-validated parameters, call by
name, a distinct `tool_name` in tool analytics.

Two premises that would close this question off are false. An MCP server
needs no deployed backend — a local stdio process shelling out to `gh`,
`git`, or `docker` is ordinary. And tool schemas are not a per-turn context
cost in this harness: they're deferred, so an unused tool costs one name in
a list, not a schema; the dominant cost of a crowded tool list is choosing
the wrong tool, not token count.

Breakeven test written into the skill: reach for the surface only when a
coherent family of operations shares a domain model *and* the `Bash` bucket
genuinely isn't enough — analytics need tool-level granularity a shell
command can't produce, or a curated API would replace repeated,
near-identical invocations. Either alone stays a script. One server per
domain, scoped per project via its own registration, never installed
globally, since a global server puts every project's tools in every other
project's name list.

The server holds no logic — every tool is a thin dispatcher over a script
that already works standalone, so exposing it stays reversible. The
laundering hazard is named in the skill itself: a tool that reaches an
action its script can't, or carries a flag bypassing a check the script
enforces, is a permission bypass wearing an interface.
