---
seq: 9
date: 2026-09-19
level: 2
slug: 2026-09-19-land-branch-sh-splits-a-git-merge-and-push-core-moves-to-ai-toolkit-the-lifecycle-stays-as-a-night-watchman-wrapper
title: "land-branch.sh splits: a git merge-and-push core moves to ai-toolkit, the lifecycle stays as a night-watchman wrapper"
---

NWM-127 asked whether `scripts/land-branch.sh` (973 lines) is generic enough
to move to `ai-toolkit`. Outcome: **split**. A generic core moves; the ticket
lifecycle, both tracker backends and the herdr teardown stay here as a wrapper
that calls it. The split itself is a follow-up ticket, not this one.

Two premises in the ticket body did not survive reading the script. It does
not call the tracker provider seam: it takes a wrapper path (`--jira-api`,
`ISSUES_JIRA_API`) and never invokes `providers/lib/provider.sh` (measured:
`grep provider.sh` matches only a help string, line 257). It has no
`issues.py lint` hook: the lint step runs `--lint-cmd` or `./scripts/lint.sh`
in the target repo (line 699), and `grep issues.py` matches one comment.
This repo has no `scripts/lint.sh`, so here the step is skipped with a warning.
The hook is already generic, which shrinks the extraction work.

### Assumption inventory

Line numbers are `scripts/land-branch.sh` at `18a5981`. Classes: **generic**
(moves as written), **param** (generic once a flag or env var names it),
**extract** (separable, but only behind a hook contract), **product**
(night-watchman's operating model, stays).

| # | Assumption | Lines | Class |
| --- | --- | --- | --- |
| 1 | Integration worktree at `<parent>/<repo>-land`, reset to `origin/<target>`, `--reset-land` for a dirty one | 525-582 | generic |
| 2 | Lock file, stale-pid reclaim, never waits | 118-176 | generic |
| 3 | `merge --no-ff`, conflict abort, ORIG_HEAD revert on any later failure, exit 1/2 contract | 646-668, 98-116 | generic |
| 4 | Lint gate on the merged tree, `--lint-cmd` or `./scripts/lint.sh` | 699-711 | generic (default path is a repo convention; word-splitting bug carries over, see known-issue) |
| 5 | `git push origin HEAD:<target>`, main worktree not fast-forwarded | 837-855 | generic |
| 6 | Branch's own worktree must be clean; `git branch -d` afterwards | 293-306, 951-955 | generic |
| 7 | Optional Co-Authored-By / Claude-Session trailers | 443-450 | param (NWM-115 removes it; drop rather than move) |
| 8 | `TARGET_BRANCH` default `main`, ticket id shape `PREFIX-nnn` | 83, 267-271 | param (id shape is only a tracker concern; core takes an opaque label) |
| 9 | Lifecycle: Awaiting Deployment before merge, Completed after push, In Progress required on entry | 584-645, 860-882 | product |
| 10 | File tracker: `issues/{open,in-progress,awaiting-deployment,completed,cancelled}/`, `outcome:`/`updated:` frontmatter rewrite, `.notes.md`, staged-rename assertions, completion commit inside the pushed history | 321-361, 672-697, 713-800 | extract (needs a pre-push hook that may add commits) |
| 11 | Jira tracker: transition resolved by target status id, read-back, comment via wrapper, three required status ids | 363-440, 824-835, 860-882 | extract (pre-merge and post-push hooks) |
| 12 | `--no-complete` and `--note`: land without finishing the ticket | 180-250, 713-800 | extract (meaningless without a ticket) |
| 13 | herdr teardown: `/exit` the worker pane, poll, `herdr worktree remove`, gated on `HERDR_ENV=1` | 884-950 | extract (post-landing hook); product in content (NWM-117) |
| 14 | `--dry-run` plan text narrates lifecycle steps | 471-523 | extract (core prints its own plan, hooks append theirs) |
| 15 | `lib/kit.sh` (`die`, `warn`, `need`, `show_help`, `tmpfile`; 56 lines), shared with other scripts here | 80-81 | param (vendor a copy into the core, or ai-toolkit gains a lib) |

Rough weight, inferred from the ranges: rows 1-6 and 8 are about a third of
the file; rows 9-14 are about half. The lifecycle is the larger half.

### Why split, not the other two

**Move whole, parameterised.** Rejected. Making rows 9-14 configurable means
three Jira status ids, a five-directory file layout, a frontmatter schema and a
herdr teardown all become flags of a public tool. `ai-toolkit`'s rule is that a
repo calls it; nothing here stops that, but the operating model would ride in
as configuration, which is the outcome the ticket set out to avoid. Every
consumer would carry flags for trackers it does not have.

**Keep here, strike from the migration list.** Rejected on measured evidence of
a second consumer. `~/code/homelab/scripts/dev/land-branch.sh` is a 1402-line
fork of the same skeleton (integration worktree, lock, merge, Jira window,
herdr exit); `diff` against this file reports 1719 differing lines. Both carry
the same class of fix independently (SIGPIPE under pipefail, exit codes on
pre-flight refusals; see each repo's `docs/known-issues/`). That is the
duplication a shared core removes. Keeping the script here leaves the fork
diverging.

**Split.** Wins because the seams already exist in the control flow: the
script has exactly four points where tracker or dispatch code runs (before the
merge, after the merge, before the push, after the push), and the failure
semantics at each are already different and well defined (nothing to revert;
revert the merge; landing stands, report exit 1).

### What the follow-up ticket must settle

1. The hook contract: four points, each hook's exit code mapped to the core's
   existing semantics. The pre-push hook is the hard one, because the file
   tracker's completion commit must land inside the pushed history and inside
   the integration worktree.
2. Where the lifecycle wrapper lives (this repo, `scripts/`) and whether the
   core is consumed by path, by a pinned checkout, or vendored. `ai-toolkit`'s
   README defines consumption as CI actions and repo-scoped calls; a script a
   local orchestrator runs is new ground for it.
3. `land-branch-selftest.sh` (916 lines) and `land-branch-jira-selftest.sh`
   split along the same line; the core's selftest uses local bare repos only.
4. Whether homelab's fork is retired onto the core (its own ticket).
5. Drop the trailer env vars (NWM-115) before the move, not after.

Owner call needed: this recommends the split; it does not start it. The move is
the more expensive path in engineering time, and the decision above rests on
one measured second consumer.
