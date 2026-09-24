---
seq: 28
date: 2026-09-23
level: 3
slug: 2026-09-23-land-branch-sh-becomes-a-wrapper-over-ai-toolkit-s-land-core-sh-and-is-its-own-hook-nwm-131
title: "land-branch.sh becomes a wrapper over ai-toolkit's land-core.sh, and is its own hook (NWM-131)"
---

`scripts/land-branch.sh` stays here, at the same plugin-root path, as a
wrapper: its preflight (argument checks, ticket resolution, tracker status,
closing-state gathering, the plan) runs first, and then it hands the merge,
the lint gate, the push and the branch cleanup to ai-toolkit's
`scripts/land-core.sh`, passing itself as land-core's `--hook`. The four
hook points carry the lifecycle: pre-merge does the Awaiting Deployment
move, post-merge builds the closing state and re-resolves a file ticket
against the merged tree, pre-push commits the file tracker's completion (so
it is inside the pushed history), and post-push completes the Jira issue,
writes the closing state, notifies, and tears down the herdr workspace.
`--already-merged` calls no core and runs the same phase functions inline.

State crosses the process boundary through one mode-600 temp file: the
wrapper writes its preflight values as `%q` assignments, each hook sources
it and appends what it changed, and the wrapper sources it again once
land-core returns. That file is also how land-branch.sh keeps its own exit
codes where land-core's differ: a failed Awaiting Deployment POST is exit 1
here while a pre-merge hook refusal is exit 2 in land-core, so the hook
records `WRAPPER_RC` and the wrapper exits with that.

land-core is resolved at run time by `scripts/ai-toolkit-root.sh
--land-core`, the same way as known-issue.sh. It is not vendored and not
pinned. The cost is an adopter cost: a marketplace installer needs an
ai-toolkit checkout or `$AI_TOOLKIT_ROOT` to land anything, and gets exit 2
naming both when neither resolves.

`--lint-cmd` runs through `bash -c`, so a compound lint command is one
command, not word-split into `true && false`, which would let a red lint
land.

land-core's branch-worktree clean check exempts exactly one untracked path
through `--allow-untracked PATH` (an exact `?? PATH` porcelain line; a
staged or modified copy, or any other untracked file, still refuses), and
land-branch.sh passes `--allow-untracked .night-watchman/closing-state.md`
because the worker brief requires that file to exist uncommitted (NWM-147).
