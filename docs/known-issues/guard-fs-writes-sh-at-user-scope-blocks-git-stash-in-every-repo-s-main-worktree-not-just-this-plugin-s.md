---
title: "guard-fs-writes.sh at user scope blocks git stash in every repo's main worktree, not just this plugin's"
heading_raw: "guard-fs-writes.sh at user scope blocks git stash in every repo's main worktree, not just this plugin's — LOW"
severity: LOW
status: open
qualifiers: []
tickets: []
slug: guard-fs-writes-sh-at-user-scope-blocks-git-stash-in-every-repo-s-main-worktree-not-just-this-plugin-s
---

Found 2026-09-13 while wiring the second adopter. night-watchman is installed at user scope, so `hooks/guard-fs-writes.sh` runs on every Bash call in every repo. Its rule against `git stash`, `checkout --`, `reset` and `clean` on a main worktree carries no notion of which repo the plugin belongs to, so a subagent asked to stash the second adopter's dirty tree was refused with `guard-fs-writes.sh: blocked on: git stash targets the main worktree`.

Workaround that worked: the owner ran the stash from the Claude Code prompt with the `!` prefix, which bypasses hooks. Not fixed. Options on the table: a carve-out for repos with no linked-worktree relationship, an allowlist in `.night-watchman/config.toml`, or keep as-is and document the `!` route in `docs/adopting.md`. The last is what is done today.
