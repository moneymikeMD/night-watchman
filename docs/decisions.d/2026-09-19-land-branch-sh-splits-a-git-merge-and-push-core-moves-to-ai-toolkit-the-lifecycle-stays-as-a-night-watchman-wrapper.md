---
seq: 9
date: 2026-09-19
level: 2
slug: 2026-09-19-land-branch-sh-splits-a-git-merge-and-push-core-moves-to-ai-toolkit-the-lifecycle-stays-as-a-night-watchman-wrapper
title: "land-branch.sh splits: a git merge-and-push core moves to ai-toolkit, the lifecycle stays as a night-watchman wrapper"
---

NWM-127 asked whether `scripts/land-branch.sh` is generic enough to move to
`ai-toolkit`. Outcome: **split**. A generic core (integration worktree,
lock, `merge --no-ff` with ORIG_HEAD revert, lint gate, push, branch
cleanup) moves; the ticket lifecycle, both tracker backends and the herdr
teardown stay here as a wrapper that calls it. NWM-131 is the extraction.

Two premises in the ticket did not survive reading the script. It does not
call the tracker provider seam: it takes a wrapper path (`--jira-api`) and
never invokes `providers/lib/provider.sh`. It has no `issues.py lint` hook:
the lint step runs `--lint-cmd` or `./scripts/lint.sh` in the target repo,
and this repo has no `scripts/lint.sh`, so here the step is skipped with a
warning. The lint hook is already generic.

### Why split, not the other two

**Move whole, parameterised.** Rejected. Making the lifecycle configurable
means three Jira status ids, a five-directory file layout, a frontmatter
schema and a herdr teardown all become flags of a public tool. The operating
model would ride in as configuration, which is the outcome the ticket set
out to avoid, and every consumer would carry flags for trackers it does not
have.

**Keep here, strike from the migration list.** Rejected on measured evidence
of a second consumer: homelab's `scripts/dev/land-branch.sh` is a
1402-line fork of the same skeleton (integration worktree, lock, merge, Jira
window, herdr exit) that carries the same class of fix independently
(SIGPIPE under pipefail, exit codes on pre-flight refusals). That is the
duplication a shared core removes.

**Split.** Wins because the seams already exist in the control flow: the
script has exactly four points where tracker or dispatch code runs (before
the merge, after the merge, before the push, after the push), and the
failure semantics at each are already different and well defined (nothing
to revert; revert the merge; landing stands, report exit 1).
