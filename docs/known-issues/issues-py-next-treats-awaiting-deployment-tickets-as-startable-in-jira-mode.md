---
title: "issues.py next treats Awaiting Deployment tickets as startable in jira mode"
heading_raw: "issues.py next treats Awaiting Deployment tickets as startable in jira mode — MEDIUM"
severity: MEDIUM
status: resolved
resolved: 2026-09-19
qualifiers: []
note: "fixed in work-order/reference/issues.py (WO-021): WORKABLE is now open/in-progress only, and awaiting-deployment resolves a blocked_by so dependents are not stranded; night-watchman's own copy still has it until WO-010"
tickets: []
slug: issues-py-next-treats-awaiting-deployment-tickets-as-startable-in-jira-mode
---

issues.py next (jira source) lists tickets whose Jira status is Awaiting Deployment as startable, alongside open ones. Seen 2026-09-12 with two tickets parked there after a --no-complete landing with a verify step owed to the owner. A future session-start that fans out 'next' through herdr-ticket-start.sh would re-dispatch them onto fresh branches (the landed branches were deleted, so the branch-exists refusal does not fire). Workaround: read the board's awaiting-deployment section first and skip those ids. Fix candidate: exclude the awaiting-deployment stage from next/waves, matching the file-mode convention where only open/ is startable.

Resolved 2026-09-19 by WO-021, in work-order/reference/issues.py — the reference implementation this file moved to under WO-004, not in night-watchman. night-watchman's own skills/to-issues/scripts/issues.py is still byte-identical to the pre-fix file and still carries this defect; WO-010 deletes it in favour of the work-order dependency.

WORKABLE is now ["open", "in-progress"], so neither `next` nor `waves` will
dispatch an awaiting-deployment ticket. A new RESOLVING = DONE +
["awaiting-deployment"] keeps its dependents startable: the code is merged and
only the deploy is owed. That second half is not optional — the stage was in
WORKABLE precisely because scheduling it into a wave was what unblocked its
dependents as a side effect, and removing it without RESOLVING reproduces the
phantom cycle the constant's comment warned about.

Verified against a fixture derived from a captured /rest/api/3 response, and on
the live file-mode ticket set, where WO-009 was sitting in awaiting-deployment
and `next` was offering it for dispatch. The fix drops WO-009 and promotes
WO-011, which was blocked_by it, from wave 2 into wave 1.
