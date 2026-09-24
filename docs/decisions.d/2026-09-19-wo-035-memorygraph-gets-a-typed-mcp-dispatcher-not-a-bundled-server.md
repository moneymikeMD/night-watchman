---
seq: 16
date: 2026-09-19
level: 3
slug: 2026-09-19-wo-035-memorygraph-gets-a-typed-mcp-dispatcher-not-a-bundled-server
title: "WO-035: memorygraph gets a typed MCP dispatcher, not a bundled server"
---

`memorygraph` is the second-highest-volume Bash family in the corpus — 744
`recall` calls averaging 124 characters, 622 `store` calls averaging 1,427
characters (WO-033, memory `c3a3f04e`) — every one a long shell string
wrapping a payload that is already structured data. Two failure modes come
directly from that shape: a multi-word `recall` silently returns nothing
(`--query "jira api auth"` finds zero; `--query "jira"` finds six), and a
`store` with a 1,400+-character payload through `--content` can fail on
shell quoting and succeed on a bare retry of the same content.

Decision: `dotfiles/dot_claude/mcp/memory/` is a thin MCP server dispatching
`recall`/`store`/`link`/`related`/`briefing` to the `memorygraph` CLI as
argv arrays, never a shell string, and holding no graph logic of its own.
`recall` rejects a multi-word `noun` outright instead of returning an empty
result set; `store` validates `type` against the CLI's real 13-value enum
and `link` against the three relationship types that work (`SOLVES`,
`CAUSES`, `CONTRADICTS`), both before the CLI is invoked. Registered per
project through that project's own `.mcp.json`, never in
`~/.claude/settings.json`.

Reasoning: this does not reverse memorygraph's own v0.14 decision to drop
its bundled MCP server for shell invocation — that removed a coupling
*inside the product*; a thin local dispatcher over the published CLI
reintroduces none of it, since the CLI stays the interface and deleting the
server leaves every existing call site working. The guards are the point,
not the typing: converting the multi-word-recall rule from prose a caller
has to remember into something that cannot be got wrong is the enforcement
ladder's top rung applied to a rule that was sitting on its bottom rung.
`store` gains no convenience beyond the schema — no auto-tagging, no
inferred type — because guessing metadata is how a graph fills with entries
nobody trusts. The server never reaches FalkorDB directly: backend
selection, credentials and the off-LAN fail-closed behaviour all live in
the CLI's own environment contract, and duplicating that here is how the
two diverge.

Out of scope, deliberately: changing `memorygraph` itself, or upstreaming
the multi-word-recall behaviour as a fix there; auto-recall on session
start.
