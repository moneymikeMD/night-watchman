---
seq: 19
date: 2026-09-19
level: 3
slug: 2026-09-19-wo-039-check-known-issues-and-memory-graph-before-reporting-broken-shipped-as-prose-which-the-trace-flag-rule-already-showed-can-fail
title: "WO-039: check known-issues and memory-graph before reporting broken — shipped as prose, which the trace-flag rule already showed can fail"
---

An agent reporting something as broken, denied, or unexplained when the
answer is already on disk — a `docs/known-issues/` entry, or a merge status
the primary source disproves — is a lookup-before-reporting problem, not a
diagnosis problem, and the lookup is one `grep` and one `memorygraph
recall` away.

One precondition, phrased on reporting rather than diagnosing, lives in the
three places an agent's working contract comes from:
`templates/dispatch-brief.md` (the only one that reaches a dispatched wave
worker's own prompt), `templates/CLAUDE.md` (for sessions that never go
through dispatch), and the owner's dotfiles `CLAUDE.md` (its memory-graph
trigger list names `docs/known-issues/` beside it).

This ships as prose, and that is a known-weak choice. The trace-flag
prohibition is the same shape of rule — capitalized, in a brief, with its
exact consequence spelled out — and an agent with that exact paragraph in
its own brief still ran `zsh -x` while debugging a verify line, leaking
`OP_SERVICE_ACCOUNT_TOKEN` and `MEMORY_FALKORDB_PASSWORD` into the
transcript (memory-graph, tag `wo-042`). A rule read minutes earlier did
not survive a debugging shortcut under time pressure, and there is no
reason to expect this one to fare better for being written more
emphatically.

A structural version is the stronger option and is not built. The nearest
precedent is `guard-fs-writes.sh`, which stops an out-of-worktree write
mechanically — a hook on the report/hand-back path could `grep
docs/known-issues/` for the reported symptom before a BLOCKED or "reporting
broken" status is accepted. It is not built because there is no reliable
machine signal for "this text is reporting a failure" comparable to the
redirect-target signal the guard checks; building that detector well enough
to avoid false positives is its own piece of work. Revisit this, including
possibly reverting the prose version, if recurrence shows prose does not
hold here either.
