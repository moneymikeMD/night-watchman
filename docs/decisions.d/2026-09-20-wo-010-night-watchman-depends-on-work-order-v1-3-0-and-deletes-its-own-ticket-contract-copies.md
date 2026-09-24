---
seq: 21
date: 2026-09-20
level: 3
slug: 2026-09-20-wo-010-night-watchman-depends-on-work-order-v1-3-0-and-deletes-its-own-ticket-contract-copies
title: "WO-010: night-watchman depends on work-order v1.3.0 and deletes its own ticket-contract copies"
---

night-watchman does not carry the ticket contract. `.claude-plugin/plugin.json`
declares `work-order ^1.3.0` from the `moneymike-plugins` marketplace, and
this repo has no copy of `issues.py` or of the frontmatter reference.

**How a dependent finds a dependency's files.** `${CLAUDE_PLUGIN_ROOT}`
names only the plugin that is executing and cannot reach a sibling, so
`scripts/work-order-root.sh` resolves the location at runtime:
`$WORK_ORDER_ROOT`, then the `.installPath` of the `claude plugin list
--json` entry whose `.id` is `work-order@moneymike-plugins` (there is no
`.name` field to key on), then a work-order checkout beside the plugin. The
third is not a nicety — a plugin loaded from a local checkout has no
plugin-list entry at all, so without it every instruction file here breaks
for anyone running from a checkout. Each candidate must actually hold
`reference/issues.py`, so a stale `installPath` is not trusted.

**Exit 0 is not the evidence.** A blocked or unsatisfied dependency still
reports `ok` and exits 0, recording the violation only in `errors` (the
WO-002 entry), so proof of the dependency is the plugin-list entry with
`errors: null` and the installed tree holding `reference/issues.py`. CI
clones the newest `v1.*` tag resolved at run time rather than pinning a
literal that would go stale, and `scripts/land-branch-selftest.sh` takes
its `issues.py` from the same resolver.

Not deleted: `skills/to-issues/assets/ticket-template.md`. work-order ships
`SPEC.md`, `bindings/file/BINDING.md` and example tickets, but no bare
template, so deleting it would remove something the dependency does not
replace. It stays until work-order carries an equivalent.
