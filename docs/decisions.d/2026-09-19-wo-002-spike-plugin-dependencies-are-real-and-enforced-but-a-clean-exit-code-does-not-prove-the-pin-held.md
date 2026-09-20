---
seq: 13
date: 2026-09-19
level: 3
slug: 2026-09-19-wo-002-spike-plugin-dependencies-are-real-and-enforced-but-a-clean-exit-code-does-not-prove-the-pin-held
title: "WO-002 spike: plugin dependencies are real and enforced, but a clean exit code does not prove the pin held"
---

Supersedes the `UNVERIFIED and load-bearing for decision 12` paragraph in the
entry above. That paragraph flagged three agent-reported claims as unspiked.
All three were measured first-hand on the Mac against Claude Code 2.1.278,
using two throwaway local-folder marketplaces and four scratch plugins. No real
marketplace was touched and night-watchman's own `plugin.json` was not
modified. Both scratch marketplaces were removed afterwards and the plugin
registry diffs clean against its pre-spike state.

**All three claims hold.** `.claude-plugin/plugin.json` takes a `dependencies`
array whose entries are either a bare plugin name or an object of `name`,
`version` and `marketplace`. Installing a dependent plugin alone does install
its dependency: `claude plugin install wo-spike-binding` reported
`(+ 1 dependency: wo-spike-core)`. One repository does publish several plugins
on independent version lines through one `marketplace.json`, tagged
`{plugin-name}--v{version}`; `claude plugin tag` derives the tag from the
manifest and refuses when `plugin.json` and the marketplace entry disagree,
reporting that `plugin.json` wins at install time.

**The semver constraint is enforced, not decorative.** This was the question
most likely to have been assumed wrong, so it was measured against a case where
enforcement and convenience disagree. The scratch marketplace's current entry
for `wo-spike-core` said `2.0.0`, and tags existed at `1.0.0`, `1.1.0` and
`2.0.0`. The dependent plugin pinned `^1.0`. The install resolved to `1.1.0` —
the highest tag satisfying the range — and skipped the newer copy the
marketplace was advertising. The recorded version carried a commit-SHA suffix
(`1.1.0-767ec7e66eeb`), so a force-moved tag gets a fresh cache directory
rather than stale content.

**Disable is refused, and the refusal is machine-readable.** Disabling
`wo-spike-core` while `wo-spike-binding` was enabled failed with exit 1,
`failureCode: "required_by_dependents"`, a `reverseDependents` array, and a
chained command that disables the pair in the correct order. Nothing was
mutated by the attempt. Enabling is symmetric: enabling the dependent alone
re-enabled the dependency and said so. `claude plugin prune` tracks
auto-install provenance, lists only orphans, and leaves manually installed
plugins alone.

**The trap, and the reason this spike earned its keep.** An unsatisfiable
constraint does not reliably fail the install. There are two distinct paths and
only one of them is loud.

When another *installed* plugin already constrains the same dependency and the
ranges do not intersect, the install hard-fails: exit 1,
`failureCode: "dependency_version_conflict"`, message naming both ranges.

When nothing else constrains it and no tag satisfies the range, a plugin the
marketplace references by relative path installs the marketplace's *current
copy* instead and reports `outcome: "ok"` with exit 0. Pinning `^9.0` against
tags of `1.0.0`, `1.1.0` and `2.0.0` produced a successful install of `2.0.0`.
The violation appeared nowhere in the install result — only in the `errors`
field of `claude plugin list --json`:
`Requires "wo-spike-core@wo-002-spike" ^9.0, installed 2.0.0`.

The same pattern holds for a blocked cross-marketplace dependency: install
returned `outcome: "ok"` and exit 0 while simply not installing the dependency,
with `dependency-unsatisfied` visible only in the `errors` field.

So a zero exit from `claude plugin install` is not evidence that a version pin
was honoured or that a dependency arrived. Anything gating on dependency
resolution must assert on the `errors` field, not on the exit code. A failed
install also leaves an entry behind with `enabled: true` and `errors`
populated; `enabled` is the configured flag, not the effective load state.

**Cross-marketplace dependencies need an allowlist, which decision 12 will
hit.** night-watchman and `work-order` will ship from different repositories and
therefore different marketplaces, so the dependency in decision 12 is a
cross-marketplace one. By default it is blocked. It works only when the root
marketplace — the one hosting the plugin being installed, so night-watchman's —
carries `allowCrossMarketplaceDependenciesOn` naming the target marketplace.
Measured both ways: without the field the dependency silently did not install;
with `"allowCrossMarketplaceDependenciesOn": ["wo-002-spike-b"]` the
cross-marketplace dependency installed cleanly with no errors. The field passes
`claude plugin validate --strict`.

**Two validator limits worth knowing.** `claude plugin validate --strict` does
recognise `dependencies` — it proposes it as the correction for a typo'd field
name, which is how the field's existence was confirmed independently of the
docs. It does *not* check that a `version` string is valid semver: a range of
`"not a semver range !!"` passed strict validation without comment. Range
syntax errors surface at install or load, not in CI.

**WO-002's own verify command is wrong and must not be copied.** It asserts on
`[.[].name]`, but `claude plugin list --json` has no `name` field; entries key
on `.id`, formatted `plugin@marketplace`. As written the assertion returns
`false` and exit 1 even when the dependency installed correctly — a false
negative that would have read as the mechanism not existing. The working form
is:

```bash
claude plugin list --json | jq -e '[.[].id | split("@")[0]] | contains(["wo-spike-core"])'
```

**Not measured, and left open for WO-010.** Whether a plugin carrying a
dependency error actually fails to load in a live session — the docs say it is
disabled at load, but that is a session-start behaviour this spike did not
exercise, and the `enabled` flag stays `true` meanwhile. Also untested:
dependency resolution from a real remote GitHub marketplace, as both scratch
marketplaces were local folders. Local-folder marketplaces resolve tags only
when the folder is a git repository, which is why both scratch marketplaces
were initialised as one.

**Consequence for decision 12: it stands, and vendoring is not needed.** The
mechanism exists and enforces what it claims. WO-005, WO-008 and WO-010 are
unblocked, with two obligations: night-watchman's `marketplace.json` must carry
`allowCrossMarketplaceDependenciesOn` for the `work-order` marketplace, and any
check that "the dependency resolved correctly" must read the `errors` field
rather than trust an exit code.
