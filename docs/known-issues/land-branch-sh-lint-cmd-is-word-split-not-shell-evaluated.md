---
title: "land-branch.sh LINT_CMD is word-split, not shell-evaluated"
heading_raw: "land-branch.sh LINT_CMD is word-split, not shell-evaluated — LOW"
severity: LOW
status: resolved
resolved: 2026-09-23
qualifiers: []
tickets: []
slug: land-branch-sh-lint-cmd-is-word-split-not-shell-evaluated
---

scripts/land-branch.sh runs $EFFECTIVE_LINT unquoted with no shell, so LAND_BRANCH_LINT_CMD='a && b' passes '&&' as a literal argument; lint fails and the merge is reverted (safe: nothing pushed). Hit 2026-09-12 landing a ticket. Workaround: a single command (e.g. 'bash scripts/foo-selftest.sh') or an executable ./scripts/lint.sh, which is the documented default. Fix options: run via bash -c, or state the single-command contract in the header.

Resolved 2026-09-23 by NWM-131: land-branch.sh hands the lint gate to ai-toolkit's land-core.sh, which runs --lint-cmd through `bash -c`. The failure direction was worse than this entry first said: word splitting makes `true && false` PASS, so a red lint could land.
