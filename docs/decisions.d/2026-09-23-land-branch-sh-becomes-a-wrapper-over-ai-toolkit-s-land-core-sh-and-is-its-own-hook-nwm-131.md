---
seq: 28
date: 2026-09-23
level: 3
slug: 2026-09-23-land-branch-sh-becomes-a-wrapper-over-ai-toolkit-s-land-core-sh-and-is-its-own-hook-nwm-131
title: "land-branch.sh becomes a wrapper over ai-toolkit's land-core.sh, and is its own hook (NWM-131)"
---

`scripts/land-branch.sh` stays here, at the same plugin-root path, and is now a wrapper: its preflight (argument checks, ticket resolution, tracker status, closing-state gathering, the plan) runs first, and then it hands the merge, the lint gate, the push and the branch cleanup to ai-toolkit's `scripts/land-core.sh`, passing itself as land-core's `--hook`. The four hook points carry the lifecycle: pre-merge does the Awaiting Deployment move, post-merge builds the closing state and re-resolves a file ticket against the merged tree, pre-push commits the file tracker's completion (so it is inside the pushed history), and post-push completes the Jira issue, writes the closing state, notifies, and tears down the herdr workspace. `--already-merged` calls no core and runs the same phase functions inline.

State crosses the process boundary through one mode-600 temp file: the wrapper writes its preflight values as `%q` assignments, each hook sources it and appends what it changed, and the wrapper sources it again once land-core returns. That file is also how land-branch.sh keeps its own exit codes where land-core's differ. A failed Awaiting Deployment POST was exit 1 here, and a pre-merge hook refusal is exit 2 in land-core, so the hook records `WRAPPER_RC` and the wrapper exits with that.

land-core is resolved at run time by `scripts/ai-toolkit-root.sh --land-core`, the same way as known-issue.sh (NWM-128). It is not vendored and not pinned. The cost is an adopter cost: a marketplace installer now needs an ai-toolkit checkout or `$AI_TOOLKIT_ROOT` to land anything, and gets exit 2 naming both when neither resolves. The two `${CLAUDE_PLUGIN_ROOT}/scripts/land-branch.sh` references in `skills/session-start/SKILL.md` keep pointing at the wrapper. The plugin-root check was run, and it found nothing to reroute.

Two behaviour changes come with the move. `LAND_BRANCH_COAUTHOR` and `LAND_BRANCH_SESSION` are gone (decision item 4), so no trailer is ever written. `--lint-cmd` now runs through `bash -c`, which closes the word-split known issue: a word-split `true && false` passes, which means a red lint could land.

One gap remains, and it belongs to land-core's contract: its branch-worktree clean check has no way to exempt `.night-watchman/closing-state.md`. NWM-147 exempted that file here because the worker brief requires it to exist uncommitted. So in any repo that does not gitignore it (every adopter except this one), a closing-state landing is refused with exit 2. land-branch-selftest test33 is red for exactly this reason. It needs a land-core flag, for example `--allow-untracked PATH`, and that change belongs to ai-toolkit, not to this repo.
