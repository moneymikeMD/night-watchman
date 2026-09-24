---
seq: 13
date: 2026-09-19
level: 3
slug: 2026-09-19-wo-002-spike-plugin-dependencies-are-real-and-enforced-but-a-clean-exit-code-does-not-prove-the-pin-held
title: "WO-002 spike: plugin dependencies are real and enforced, but a clean exit code does not prove the pin held"
---

Measured first-hand on the Mac against Claude Code 2.1.278, using two
throwaway local-folder marketplaces and four scratch plugins; no real
marketplace was touched.

**Plugin dependencies are real.** `.claude-plugin/plugin.json` takes a
`dependencies` array whose entries are either a bare plugin name or an
object of `name`, `version` and `marketplace`. Installing a dependent plugin
alone installs its dependency (`(+ 1 dependency: ...)`). One repository can
publish several plugins on independent version lines through one
`marketplace.json`, tagged `{plugin-name}--v{version}`; `claude plugin tag`
derives the tag from the manifest and refuses when `plugin.json` and the
marketplace entry disagree.

**The semver constraint is enforced, not decorative.** With the marketplace
advertising `2.0.0` and tags at `1.0.0`, `1.1.0` and `2.0.0`, a dependent
pinning `^1.0` resolved to `1.1.0` — the highest tag satisfying the range —
and skipped the newer copy. The recorded version carries a commit-SHA suffix
(`1.1.0-767ec7e66eeb`), so a force-moved tag gets a fresh cache directory
rather than stale content.

**Disable is refused, and the refusal is machine-readable.** Disabling a
dependency while its dependent is enabled fails with exit 1, `failureCode:
"required_by_dependents"`, a `reverseDependents` array, and a chained
command that disables the pair in the correct order. Enabling is symmetric.
`claude plugin prune` tracks auto-install provenance and lists only orphans.

**The trap.** An unsatisfiable constraint does not reliably fail the
install. When another *installed* plugin already constrains the same
dependency and the ranges do not intersect, the install hard-fails (exit 1,
`failureCode: "dependency_version_conflict"`). When nothing else constrains
it and no tag satisfies the range, a plugin the marketplace references by
relative path installs the marketplace's *current copy* instead and reports
`outcome: "ok"` with exit 0; the violation appears only in the `errors`
field of `claude plugin list --json` (`Requires "core@mkt" ^9.0, installed
2.0.0`). A blocked cross-marketplace dependency behaves the same way:
`outcome: "ok"`, exit 0, dependency not installed,
`dependency-unsatisfied` visible only in `errors`. A failed install also
leaves an entry behind with `enabled: true`; `enabled` is the configured
flag, not the effective load state.

So a zero exit from `claude plugin install` is not evidence that a version
pin was honoured or that a dependency arrived. Anything gating on dependency
resolution asserts on the `errors` field, not on the exit code.

**Cross-marketplace dependencies need an allowlist.** By default they are
blocked. They work only when the root marketplace — the one hosting the
plugin being installed — carries `allowCrossMarketplaceDependenciesOn`
naming the target marketplace. night-watchman and work-order both publish
through `moneymike-plugins`, so the dependency here is not cross-marketplace.

**Two validator limits.** `claude plugin validate --strict` recognises
`dependencies` (it proposes it as the correction for a typo'd field name)
but does not check that a `version` string is valid semver: `"not a semver
range !!"` passes strict validation. Range syntax errors surface at install
or load, not in CI.

Not measured: whether a plugin carrying a dependency error fails to load in
a live session, and dependency resolution from a real remote GitHub
marketplace. Local-folder marketplaces resolve tags only when the folder is
a git repository.
