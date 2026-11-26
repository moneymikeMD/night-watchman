---
name: land-a-pr
description: Take one finished branch from local green to merged through a pull request — run the checks CI requires before the first push, push, open the PR, watch its required checks, read the failing job's log on red, fix only what is inside the branch's scope, and merge through pr-land.sh when the repo's recorded landing policy lets an agent merge its own PR. Use whenever a session lands a branch through a PR rather than land-branch.sh's direct merge, a PR's required checks went red, or a green PR is waiting to be merged.
---

# Land a PR

Nothing pushed should be red for a reason visible locally, and nothing red is ever merged. A check that ran and
failed is fixed or reported, never bypassed: a bypassed check is a failure nobody reads until it ships.

## Inputs to settle first

- **The branch**: its worktree path, and its ticket id when there is one.
- **Merge authority**: `merge` or `stop at green`, and where the landing policy is recorded (the repo's CLAUDE.md,
  the `ethos.md` default, or the owner's go-ahead in this session). No authority given means `stop at green`.
- **Instructions about long jobs**, if the caller gave any (for example "cancel the benchmark run").

`AIT="$("${CLAUDE_PLUGIN_ROOT}/scripts/ai-toolkit-root.sh")"`; `pr-land.sh` is `$AIT/scripts/pr-land.sh`.

## Procedure

1. **Local gate first.** `"${CLAUDE_PLUGIN_ROOT}/scripts/required-checks.sh" --repo-root <wt>` runs the set the
   branch ruleset requires. Exit 1: fix, rerun, and push only once it exits 0 or 3. Exit 3 means some checks could
   not run here; note them, CI runs them.
2. **Push and open.** `git -C <wt> push -u origin <branch>`, a plain push, never `--force` once a PR exists. If
   `gh pr view <branch>` finds no PR, `gh pr create --head <branch> --base <default branch>`, titled from the
   ticket, with a body saying what changed and how it was checked.
3. **Watch.** `gh pr checks <pr> --watch --required --fail-fast --interval 30` under a 300000 ms Bash timeout,
   rerun while checks are pending.
4. **On red, read before acting.** `gh pr checks <pr> --json name,state,link` gives each failing run id; `gh run
   view <run-id> --log-failed | tail -150` gives the failure. Grep `docs/known-issues/` for the symptom before
   calling anything new; a hit is the answer, cite it. Then sort each failure:
   - **Infrastructure** (runner lost, registry rate limit, network timeout): `gh run rerun <run-id> --failed`,
     once. A deterministic failure is never rerun hoping it goes green.
   - **Inside the branch's scope** (a file the diff touches): reproduce locally, fix, commit, push, back to step 3.
   - **Not the branch's**: if the same check fails on the default branch (`gh run list --branch <default>
     --workflow <workflow> --limit 3`), it is pre-existing. Report it; do not fix unrelated code to get green.
5. **A long job the diff cannot affect** (a benchmark on a docs-only change): name it, its duration, and the
   `paths-ignore` filter on its workflow trigger that would skip it. `gh run cancel <run-id>` only on an explicit
   instruction.
6. **Merge** when every required check is green and you hold authority: `"$AIT/scripts/pr-land.sh" <pr>
   --dry-run`, read its decision, then `"$AIT/scripts/pr-land.sh" <pr>`. It derives any bypass from observed state
   and reads the PR back as MERGED; trust that read-back, not its exit code alone. A `release` MCP server's
   `pr_land` tool runs the same script. Without authority, stop at `ready to merge`.
7. **Ticket lifecycle.** A squash-merged ticket branch still owes its lifecycle. With a jira tracker:
   `"${CLAUDE_PLUGIN_ROOT}/scripts/land-branch.sh" <branch> <id> --already-merged <jira flags>`. In file mode, say
   the ticket move is owed.

## Refusals

- Never `--admin`, `--no-verify`, `--force`, a skipped or disabled check, or a workflow edit whose purpose is to
  turn a failing check green. `pr-land.sh` decides bypasses; nobody asks it for one.
- Never merge red, pending or partially reported checks, and never merge without authority.
- Never fix a failure outside the branch's scope: report it.

## Report

PR url, final head SHA, then the merge SHA, `ready to merge` or `blocked`, then one row per check that was ever red:

| Check | First failure (one line) | Cause | Fix commit or why not fixed |
| --- | --- | --- | --- |
