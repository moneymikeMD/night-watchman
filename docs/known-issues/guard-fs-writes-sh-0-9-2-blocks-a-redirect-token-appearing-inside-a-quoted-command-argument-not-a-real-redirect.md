---
title: "guard-fs-writes.sh 0.9.2 blocks a redirect token appearing inside a quoted command ARGUMENT, not a real redirect"
heading_raw: "guard-fs-writes.sh 0.9.2 blocks a redirect token appearing inside a quoted command ARGUMENT, not a real redirect — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
tickets: []
slug: guard-fs-writes-sh-0-9-2-blocks-a-redirect-token-appearing-inside-a-quoted-command-argument-not-a-real-redirect
---

Hit 2026-09-20 orchestrating wave 2. A memorygraph store whose --content text happened to contain the characters for redirect-to-devnull inside a single-quoted argument was refused:

  guard-fs-writes.sh: blocked on: redirect target has an unresolvable variable: /dev/null' - same exit semantics, reads to EOF.

Note the trailing apostrophe in the guard's own message: it parsed past the closing quote of the argument, so it was reading prose as shell. No redirect existed; the characters were payload being written to the memory graph.

SAME CLASS AS WO-023, WHICH IS MARKED RESOLVED. That fix made the segment splitter quote-aware for an operator earlier in a word than a quoted redirect. This case is the inverse: a redirect token wholly inside a quoted argument, in a command whose only operator is that quoted text. 0.9.2 is the running version and still fires.

WORKAROUND used: describe the token in prose rather than writing it. That is a poor workaround because it silently degrades what can be recorded in the memory graph - any finding about shell redirection becomes unwritable.

BLAST RADIUS: any command carrying shell-looking text as data. memorygraph store, gh pr create --body, git commit -F, a heredoc documenting a redirect. All are routine in this workspace.
