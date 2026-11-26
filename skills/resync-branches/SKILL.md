---
name: resync-branches
description: Bring an open branch up to date after its base moved — merge the base in with a merge commit and a normal push, never a rebase; resolve conflicts keeping both sides' intent; regenerate lockfiles and generated files instead of hand-merging them; gate on the repo's required checks; report each new head and any contract the incoming commits impose. Use when main moved under open branches, or when land-branch stops on a conflict against the current base, including on your own ticket branch.
---

# Resync branches

You bring one or more open branches up to date with a base that moved under them, and say what the base's new commits now require of each branch. The `branch-resync` agent runs this
for many branches at once; a worker whose `land-branch.sh` stopped on its own branch runs it inline, for that one branch.

## Input

- **Base**: a ref, default `origin/<default branch>`.
- **Branches**: worktree paths (preferred) or branch names, plus any note on what landed ("X merged; it adds a required field Y").

## Per branch

Work in the branch's own worktree with `git -C <wt>`; never check the branch out somewhere else.

1. **Dirty tree → skip.** `git -C <wt> status --porcelain` non-empty is someone's work in progress. Do not stash, reset or commit it; report the branch as skipped.
2. **Fetch and size it.** `git -C <wt> fetch origin`, then `git -C <wt> log --oneline HEAD..<base>` (incoming) and the overlap: paths in both `git -C <wt> diff --name-only <base>...HEAD` and
   `git -C <wt> diff --name-only HEAD...<base>`. Nothing incoming → report `up to date`, next branch.
3. **Read the incoming contract.** For each incoming commit touching an overlap path or a symbol the branch's own changes call (grep the branch's diff for it), read the change. Note every contract
   the branch must now meet: a new required field or argument, a renamed flag or function, a changed return shape, a new required check. A clean merge does not mean no contract: a renamed flag
   merges silently and breaks at run time.
4. **Merge.** `git -C <wt> merge --no-ff --no-edit <base>`. Never rebase, reset or force: an open PR's remote branch must never be rewritten, because reviewers' comments and other clones point at
   its commits.
5. **Resolve conflicts**, reading both sides' commit messages and, when the branches are tickets, both tickets' Decisions and Out of scope first:
   - Keep both intents. Where they cannot both stand, the side already on the base wins and the trade-off goes in your report.
   - A lockfile: take the base's version (`git -C <wt> checkout --theirs -- <lockfile>`; in a merge, `--theirs` is the base), then regenerate it with the package manager that owns it from the
     merged manifest (`bun install`, `npm install`, `uv lock`, ...). A hand-merged lockfile records hashes no resolver produced.
   - A generated file (its header says so, or a generator script names it): take either side, rerun the generator.
   - A conflict whose resolution is a product decision (two behaviours for one input, a removed feature the branch extends): `git -C <wt> merge --abort`, and report both sides' intent in two lines
     each. Choosing for the owner here ships a decision nobody made.
6. **Meet the contract.** Where step 3 found a contract and the fix is mechanical (pass the new field, rename the call), fix every call site in the branch. Anything needing judgement is reported, not
   guessed.
7. **Gate.** Commit the merge with hooks on (never `--no-verify`), then run `"${CLAUDE_PLUGIN_ROOT}/scripts/required-checks.sh" --repo-root <wt>`. Exit 1: fix it when the failure comes from the merge
   or the contract, else report it and do not push. Exit 3: list the checks it could not run.
8. **Push** with a plain `git -C <wt> push` when the branch has an upstream. A local-only branch stays local.
9. **CI.** If a PR is open for the branch, wait with `gh pr checks <branch> --watch --required --fail-fast` (Bash timeout 300000, rerun while pending). Red is reported with the failing check's name;
   `pr-shepherd` owns the fix.

## Report

One row per branch:

| Branch | Old head | New head | Incoming | Conflicts → how resolved | Contracts (fixed / open) | Checks | Pushed |
| --- | --- | --- | --- | --- | --- | --- | --- |

Then each product-decision conflict, two lines per side. Keep the whole return under 30 lines.

## Refusals

- No rebase, no `reset --hard`, no force push, no `--no-verify`, no stash of someone else's work.
- Never push a branch whose required checks failed here.
- Never edit outside the branch's worktree, and never merge the branch into the base: landing is `land-branch.sh`'s or `pr-shepherd`'s.
