---
title: "guard-fs-writes.sh false-positives on redirect-looking text inside quoted strings"
heading_raw: "guard-fs-writes.sh false-positives on redirect-looking text inside quoted strings — LOW"
severity: LOW
status: resolved
resolved: 2026-09-18
qualifiers: []
tickets: []
slug: guard-fs-writes-sh-false-positives-on-redirect-looking-text-inside-quoted-strings
---

hooks/guard-fs-writes.sh treats a greater-than sign inside a quoted argument as a shell redirect. Seen three times on 2026-09-12: (1) an agent's `memorygraph store --content` containing `providers/<kind>/<impl>/provider.sh` was blocked with "redirect target has an unresolvable variable: /<impl>/provider.sh"; (2) the orchestrator's `herdr agent prompt` text containing `project = "NWM" -> "PROJ"` was blocked with "redirect target outside worktree and scratchpad: /provider.sh"; (3) the `known-issue.sh add --body` text describing this very issue was blocked the same way. All were prose inside a single quoted argv word, not shell redirects.

Workaround: put long prompt or body text in a scratchpad file and pass it via stdin or `"$(cat file)"`.

Fix candidate: skip redirect detection inside quoted words, or only treat the character as a redirect when it is an unquoted shell token.

Resolved 2026-09-18 (NWM-113). The quote-aware tokenizer (`tokenize_quoted`) landed with the ssh-opacity work; all three commands above now exit 0 against the guard, pinned as fixtures 97-99 in hooks/guard-fs-writes-selftest.sh, with an unquoted-redirect counterpart (100) still blocking. Residual shape not covered here: a quoted `|`/`;`/`&&` next to a `>` is still split before tokenising; see the MEDIUM entry on quoted operators, pinned as known-failing fixture 101.
