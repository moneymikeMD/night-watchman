---
seq: 21
date: 2026-09-20
level: 3
slug: 2026-09-20-wo-010-night-watchman-depends-on-work-order-v1-3-0-and-deletes-its-own-ticket-contract-copies
title: "WO-010: night-watchman depends on work-order v1.3.0 and deletes its own ticket-contract copies"
---

night-watchman no longer carries the ticket contract. `.claude-plugin/plugin.json`
declares `work-order ^1.3.0` from the `work-order` marketplace, its own
`marketplace.json` carries `allowCrossMarketplaceDependenciesOn: ["work-order"]`
— without that field WO-002 measured the dependency silently not installing —
and this repo's copies of `issues.py` and the frontmatter reference under
`skills/to-issues/` are deleted.

Two blockers had to clear first, and both were checked against the remote
rather than assumed. The published work-order plugin now ships from the
repository root (WO-048), so its installed tree carries `reference/issues.py`;
and the pin is the repository release **v1.3.0**, not the retired
`work-order--vX.Y.Z` per-plugin tag line.

**How a dependent finds a dependency's files.** `${CLAUDE_PLUGIN_ROOT}` names
only the plugin that is executing and cannot reach a sibling, so
`scripts/work-order-root.sh` resolves the location at runtime:
`$WORK_ORDER_ROOT`, then the `.installPath` of the `claude plugin list --json`
entry whose `.id` is `work-order@work-order` (there is no `.name` field to key
on), then a work-order checkout beside the plugin. The third is not a nicety —
a plugin loaded from a local checkout has no plugin-list entry at all, so
without it every instruction file here breaks for anyone running from a
checkout. Each candidate must actually hold `reference/issues.py`, so a stale
`installPath` is not trusted.

**Measured, not assumed.** In an isolated `CLAUDE_CONFIG_DIR` with two
local-folder marketplaces, `claude plugin install night-watchman@night-watchman`
reported `(+ 1 dependency: work-order)`, and `claude plugin list --json` showed
`work-order@work-order` at 1.3.0 with `errors: null`. The installed tree
carries `reference/issues.py`, which lints work-order's own file-binding
examples at 6 tickets, 0 errors. Exit 0 was deliberately not the evidence:
WO-002 measured that a blocked cross-marketplace dependency still reports `ok`
and exits 0, recording the violation only in `errors`. CI clones the newest
`v1.*` tag resolved at run time rather than pinning a literal that would go
stale, and `scripts/land-branch-selftest.sh` now takes its `issues.py` from the
same resolver instead of from a path inside this repo.

Not deleted: `skills/to-issues/assets/ticket-template.md`. work-order v1.3.0
ships `SPEC.md`, `bindings/file/BINDING.md` and example tickets, but no bare
template, so deleting it would remove something the dependency does not
replace. It stays until work-order carries an equivalent.
