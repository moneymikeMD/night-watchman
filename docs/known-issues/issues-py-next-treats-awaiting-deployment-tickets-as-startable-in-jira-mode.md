---
title: "issues.py next treats Awaiting Deployment tickets as startable in jira mode"
heading_raw: "issues.py next treats Awaiting Deployment tickets as startable in jira mode — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
tickets: []
slug: issues-py-next-treats-awaiting-deployment-tickets-as-startable-in-jira-mode
---

issues.py next (jira source) lists tickets whose Jira status is Awaiting Deployment as startable, alongside open ones. Seen 2026-09-12 with two tickets parked there after a --no-complete landing with a verify step owed to the owner. A future session-start that fans out 'next' through herdr-ticket-start.sh would re-dispatch them onto fresh branches (the landed branches were deleted, so the branch-exists refusal does not fire). Workaround: read the board's awaiting-deployment section first and skip those ids. Fix candidate: exclude the awaiting-deployment stage from next/waves, matching the file-mode convention where only open/ is startable.
