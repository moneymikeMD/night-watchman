---
title: "guard-fs-writes.sh: a write into the agent's OWN linked worktree was blocked whenever cwd sat elsewhere"
heading_raw: "guard-fs-writes.sh: a write into the agent's OWN linked worktree was blocked whenever cwd sat elsewhere — MEDIUM"
severity: MEDIUM
status: resolved
resolved: 2026-09-19
qualifiers: []
note: "WORKTREE_ROOTS now resolves the whole worktree set of the repo at cwd, not just cwd's own toplevel"
tickets: ["WO-023"]
slug: guard-fs-writes-sh-a-write-into-the-agent-s-own-linked-worktree-was-blocked-whenever-cwd-sat-elsewhere
---

WORKTREE was resolved from the recorded .cwd of the tool call alone, so a
write into a linked worktree was refused whenever cwd sat somewhere else -
including the main worktree of the very repository that owns that linked
worktree.

Reproduction, appending to a file inside a real linked worktree of the same
repo cwd was in:

    cwd = the worktree itself        exit 0   correct
    cwd = the repo's main worktree   exit 2   FALSE POSITIVE
    cwd = a non-repo directory whose
          fallback happens to be an
          ancestor of the target     exit 0   allowed, but only by accident

The last row is the diagnostic one: it passed because WORKTREE fell back to
cwd itself when no repo was found there, and the target happened to sit
underneath it - the guard was not reasoning about worktree ownership at
all, only comparing the target against whatever directory the call came
from. A sibling agent's tree under that same ancestor would have been
allowed by the identical accident.

An agent that reads its ticket from a non-worktree directory before its
cwd settles, or whose cwd drifts to the repo's main worktree, was refused
every subsequent write into its own linked worktree.

Fixed in WO-023: WORKTREE_ROOTS now resolves the whole worktree set of the
repo at cwd (`git worktree list --porcelain`), and any member of that set
counts as "my own tree", not only the one cwd itself sits in. The existing
broad-root exclusions (/, /tmp, /private/tmp, /var, /private/var, /Users,
/home, /private, a bare $HOME) still apply to every member, and a cwd with
no git repo at all still falls back to the single, narrow cwd-only root -
the no-repo fallback was deliberately NOT widened, so the accident above
is unchanged (out of scope for WO-023, not newly introduced by it).
