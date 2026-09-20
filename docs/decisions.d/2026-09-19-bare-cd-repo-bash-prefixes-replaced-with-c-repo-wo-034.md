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

`dot_claude/CLAUDE.md` now states a substitution table (`git -C`, `gh
--repo`, a script's own path argument, or `( cd … )` as the catch-all
subshell) instead of a bare prohibition — a prohibition with no named
alternative gets ignored — and states the cost inline: a bare `cd` mutates
the session's cwd for every later call, and that drift causes
`guard-fs-writes.sh` false positives on writes that resolve outside the
current worktree.

Recorded here rather than in the ticket body, per the tickets protocol, so a
re-run of WO-033's report is a comparison against this baseline rather than a
fresh impression. A PreToolUse hook that rewrote the `cd` prefix
automatically was considered and deliberately deferred: it would sit beside
`rtk-rewrite.sh`, which already rewrites every Bash command, and WO-023 has
just spent real time on guard false positives from a rewriter on that same
seam. A second rewriter there is something to earn with evidence from the
re-run, not assume up front.
