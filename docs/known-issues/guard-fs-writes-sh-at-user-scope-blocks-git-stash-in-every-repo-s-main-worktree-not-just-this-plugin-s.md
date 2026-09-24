---
title: "guard-fs-writes.sh at user scope blocks git stash in every repo's main worktree, not just this plugin's"
heading_raw: "guard-fs-writes.sh at user scope blocks git stash in every repo's main worktree, not just this plugin's — LOW"
severity: LOW
status: open
qualifiers: []
tickets: []
slug: guard-fs-writes-sh-at-user-scope-blocks-git-stash-in-every-repo-s-main-worktree-not-just-this-plugin-s
---

night-watchman is installed at user scope, so hooks/guard-fs-writes.sh runs
on every Bash call in every repo. Its rule against `git stash`, `checkout
--`, `reset` and `clean` on a main worktree carries no notion of which repo
the plugin belongs to: any of those in any repo's main worktree is refused
with `guard-fs-writes.sh: blocked on: git stash targets the main worktree`
(or `git checkout targets the main worktree`). `git apply -R <patch>` and a
WIP commit are the routes that work; the owner can also run the command
from the Claude Code prompt with the `!` prefix, which bypasses hooks.

Open question: should repos with no linked-worktree relationship be carved
out, should `.night-watchman/config.toml` carry an allowlist, or does the
`!` route documented in docs/adopting.md stay the answer?
