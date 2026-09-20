---
seq: 20
date: 2026-09-20
level: 3
slug: 2026-09-20-wo-010-stays-undone-the-published-work-order-plugin-does-not-carry-issues-py-and-a-dependent-locates-a-dependency-through-claude-plugin-list-json
title: "WO-010 stays undone: the published work-order plugin does not carry issues.py, and a dependent locates a dependency through claude plugin list --json"
---

WO-010 is to delete this repository's own copy of `issues.py`, under
`skills/to-issues/scripts/`, and depend on work-order for it instead. WO-002
cleared the dependency mechanism and WO-004 moved the implementation, so the
ticket looked unblocked. It is not. Measured 2026-09-20 against Claude Code
2.1.278. (This entry deliberately never spells the doomed path as one string,
because WO-010's own verify block greps the tree for it and an append-only
decision log would make that check unsatisfiable forever.)

**A marketplace plugin installs its `source` subtree and nothing else.** The
`claude-plugins-official` marketplace publishes `typescript-lsp` from
`./plugins/typescript-lsp`. That marketplace repository holds 39 plugin
directories plus a root `LICENSE` and `README.md`; the installed copy under
`~/.claude/plugins/cache/claude-plugins-official/typescript-lsp/1.0.0/` holds
exactly the two files that one subdirectory holds, and nothing from the
repository root. `caveman` (source `./`) and `datadog` (source a whole
separate repository URL) each get their entire tree, which is the same rule
seen from the other side. Files outside the `source` path never arrive on the
installing machine.

**So the published work-order plugin does not carry the reference
implementation.** work-order's `marketplace.json` publishes the `work-order`
plugin from `./plugins/work-order`. At `work-order--v0.2.0` (origin/main
3282e90) that directory is five regular files — `.claude-plugin/plugin.json`,
`CHANGELOG.md`, `README.md`, `skills/emit-tickets/SKILL.md`,
`skills/emit-tickets/emit.py` — with no symlink. `reference/issues.py` sits at
the repository root, outside the published subtree. The plugin's own README
already advertises "its reference implementation (`issues.py`)": WO-008
packaged the directory, WO-004 landed the implementation beside it rather than
into it, and nothing has failed loudly because nothing yet depends on it.
Declaring the dependency and deleting the local copy today would delete
working behaviour and put nothing in its place, which is the one outcome
WO-010 exists to avoid.

**The runtime-location question is answered, and it was never the blocker.**
WO-002 proved dependencies resolve and are semver-enforced but never measured
how a dependent's *script* finds a dependency's files. `claude plugin list
--json` returns one object per installed plugin carrying `id`
(`plugin@marketplace`), `version` and `installPath`, and
`~/.claude/plugins/installed_plugins.json` records the same `installPath`
under the same key. A dependent resolves a dependency's root by selecting on
`.id` — there is no `.name` field — and reading `.installPath`.
`${CLAUDE_PLUGIN_ROOT}` names only the plugin currently executing, so it
cannot reach a sibling. One caveat: a plugin loaded from a local checkout
rather than installed from a marketplace has no entry at all, so anything
built on this needs a fallback for development.

**WO-010's caller inventory was wrong, in a way that makes the migration
smaller than it looked.** Neither `scripts/land-branch.sh` nor
`hooks/bash-result-shunt.sh` executes the script; each mentions it only in a
comment, and `hooks/bash-result-shunt-selftest.sh` passes the path as hook
*input text* being classified, not as a command it runs.
`scripts/land-branch-selftest.sh` copies the file into fixture repositories,
so it needs a real file on disk and a dependency reference would not serve it.
The live callers are four Markdown instruction files — `agents/librarian.md`,
`skills/tickets-protocol/SKILL.md`, `skills/session-start/SKILL.md` and
`skills/to-issues/SKILL.md` — each invoking it under `${CLAUDE_PLUGIN_ROOT}`.

WO-010 stays open with the deletion undone. It unblocks when work-order
publishes `issues.py` inside `plugins/work-order/`, or moves that plugin's
`source` to the repository root, and cuts a release carrying it — only then
can a pin here resolve to something that actually holds the file. That is a
work-order change and outside this ticket's declared `touches`, so it is left
for a new ticket rather than taken here.
