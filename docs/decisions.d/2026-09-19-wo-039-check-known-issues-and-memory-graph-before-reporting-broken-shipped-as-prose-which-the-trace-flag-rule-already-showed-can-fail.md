---
seq: 19
date: 2026-09-19
level: 3
slug: 2026-09-19-wo-039-check-known-issues-and-memory-graph-before-reporting-broken-shipped-as-prose-which-the-trace-flag-rule-already-showed-can-fail
title: "WO-039: check known-issues and memory-graph before reporting broken — shipped as prose, which the trace-flag rule already showed can fail"
---

Twice on 2026-09-19, an agent reported something as broken, denied, or
unexplained when the answer was already on disk — a known-issues entry in
night-watchman's own `docs/known-issues/`, and separately a merge status
disproved by the primary source. Neither failure was a diagnosis problem;
both were a lookup-before-reporting problem, and the lookup is one `grep`
and one `memorygraph recall` away. `CLAUDE.md` already told agents to
recall before telling the user something is impossible, unsupported, or
not there, but that trigger list never named `docs/known-issues/`, and no
dispatched agent's brief mentioned either store at all.

Added one precondition, phrased on reporting rather than diagnosing since
the diagnosis was never what failed, to the three places an agent's
working contract actually comes from: `templates/dispatch-brief.md` (the
only one of the three that reaches a dispatched wave worker's own prompt),
`templates/CLAUDE.md` (for sessions that never go through dispatch), and
the owner's dotfiles `CLAUDE.md` (extending its existing memory-graph
trigger list to name `docs/known-issues/` beside it).

This ships as prose, and that is a known-weak choice, not an oversight.
The trace-flag prohibition is the same shape of rule — capitalized, in a
brief, with its exact consequence spelled out — and it failed the same day
this ticket was filed: WO-042's agent had that exact paragraph in its own
brief and ran `zsh -x` anyway while debugging a verify line, leaking
`OP_SERVICE_ACCOUNT_TOKEN` and `MEMORY_FALKORDB_PASSWORD` into the
transcript for the third recorded time (memory-graph, tag `wo-042`). A rule
an agent had read minutes earlier did not survive contact with a debugging
shortcut under time pressure. There is no reason to expect this rule to
fare better for being written more emphatically.

A structural version is the stronger option and is not built here. The
nearest precedent is `guard-fs-writes.sh`, which stops an out-of-worktree
write mechanically rather than asking an agent to remember not to make
one — a hook on the report/hand-back path could `grep docs/known-issues/`
for the reported symptom before a BLOCKED or "reporting broken" status is
accepted, the same shape of guarantee. It is not proposed as a change here
because there is no reliable machine signal yet for "this text is
reporting a failure" comparable to the redirect-target signal
`guard-fs-writes.sh` checks; building that detector well enough to avoid
false positives is its own piece of work. Revisit this decision — including
possibly reverting the prose version — if repeated recurrence shows prose
does not hold here either.
