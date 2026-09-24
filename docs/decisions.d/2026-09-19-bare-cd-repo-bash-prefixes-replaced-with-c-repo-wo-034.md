---
seq: 15
date: 2026-09-19
level: 2
slug: 2026-09-19-bare-cd-repo-bash-prefixes-replaced-with-c-repo-wo-034
title: "Bare `cd <repo> &&`/`;` Bash prefixes replaced with `-C`/`--repo` (WO-034)"
---

Baseline measured over the full transcript corpus on 2026-09-19 (WO-033,
memory `c3a3f04e`): 3,561 Bash calls carried a leading `cd` that no tool
needed — `cd .../homelab && …` (2,349 calls, avg 682 chars), `cd
.../homelab; …` (1,212 calls, avg 580 chars), and `cd .../night-watchman &&
…` (425 calls, avg 892 chars). 199 `git -C …` calls already existed in the
same corpus, so the alternative was in use, just not by default.

The owner's `~/.claude/CLAUDE.md` states a substitution table (`git -C`, `gh
--repo`, a script's own path argument, or `( cd … )` as the catch-all
subshell) instead of a bare prohibition — a prohibition with no named
alternative gets ignored — and states the cost inline: a bare `cd` mutates
the session's cwd for every later call, and that drift causes
`guard-fs-writes.sh` false positives on writes that resolve outside the
current worktree.

A PreToolUse hook that rewrote the `cd` prefix automatically was considered
and deferred: it would sit beside `rtk-rewrite.sh`, which already rewrites
every Bash command, and a rewriter on that seam has already produced guard
false positives. A second rewriter there is something to earn with evidence
from a re-run of the WO-033 report against this baseline, not assume up
front.
