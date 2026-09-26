---
seq: 2
date: 2026-09-14
level: 3
slug: 2026-09-14-jira-enforces-the-field-gates-scripts-keep-the-cross-ticket-gates
title: "Jira enforces the field gates; scripts keep the cross-ticket gates"
---

Owner decision: adopt four Jira-native rules — `system:validate-field-value`
for a non-empty `verify` on To Do→In Progress and on every transition into
Completed, the same validator for a non-empty `touches` on To Do→In
Progress, `system:previous-status-validator` (must have been In Progress) on
every transition into Completed, and one Automation scheduled rule that
returns Deferred tickets to To Do once `defer_until` has passed. `touches`
is required for every ticket, not only agent/mixed ones: Jira cannot
condition a validator on another field, and every ticket is created through
the agent anyway.

Reasoning: Jira's workflow capabilities are field, previous-status, parent
and permission validators, field and subtask conditions, webhook
post-functions and GitHub triggers, and no rule at all on linked issues. So
`blocked_by`, `touches` collisions between startable siblings, and `mixed`
needing `human_steps` stay in `issues.py` and land-branch; Jira takes the
two field gates and the status-order gate, which catch a hand-filed ticket
at transition time. Automation is post-hoc and is used only where reacting
late is fine (deferral expiry). Automation execution caps on this plan are
UNVERIFIED.

Implementation: the rules live in the Universal Managed workflows that
work-order provisions (`plugins/work-order-jira/universal-apply.sh`, with
`universal-switch.sh` moving a project onto them). The Automation rule is a UI step.
