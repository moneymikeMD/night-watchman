---
title: "dispatch start and land-branch skip lifecycle statuses (In Progress, Awaiting Deployment), so the NWM previous-status gate on Completed refuses their transitions"
heading_raw: "NWM workflow: previous-status validator on Completed refuses the normal In Progress to Completed path; it counts only statuses before the current one — HIGH"
severity: MEDIUM
status: resolved
resolved: 2026-09-14
qualifiers: []
note: "owner ruling 2026-09-14: the validator is right, the scripts are wrong; until the fix lands, move tickets to In Progress at dispatch and to Awaiting Deployment before land-branch by hand and say so in the ticket"
tickets: []
slug: nwm-workflow-previous-status-validator-on-completed-refuses-the-normal-in-progress-to-completed-path-it-counts-only-statuses-before-the-current-one
---

2026-09-14. A change applied system:previous-status-validator with previousStatusIds 3 (In Progress) and mostRecentStatusOnly false to transition 81 Completed on the tracker workflow. Live behaviour: an issue currently In Progress whose changelog reads To Do then In Progress is refused with 'The issue never transitioned through the desired status: In Progress'. After moving it from In Progress to Awaiting Deployment the same transition succeeded. So the validator evaluates statuses the issue has LEFT, not the one it is in. The intended gate (no shortcut from To Do into Completed) is better expressed structurally: make transition 81 directed from In Progress and Awaiting Deployment instead of GLOBAL, and remove the validator (removal is explicit per the additive-only decision). Workaround until then: transition to Awaiting Deployment (id 61) before land-branch, and to In Progress (id 21) at dispatch.

2026-09-14 update: owner ruled the lifecycle is To Do, In Progress (at dispatch), Awaiting Deployment (before landing), Completed (after landing). The validator behaves as intended under that flow; the defect is in the scripts that skip steps. That removal is cancelled; instead dispatch start and land-branch drive all three transitions.

2026-09-14 resolved: herdr-ticket-start.sh transitions to In Progress after the brief hand-off (--jira-progress-status, resolved by target status, read back); land-branch.sh moves to Awaiting Deployment before the merge and Completed after the push (--jira-progress-status / --jira-awaiting-status / --jira-done-status, all no-default), and refuses a ticket that never reached In Progress. Verified against stubs replaying the recorded transitions list and 400 bodies; the live dispatch and live landing are run by the orchestrator after landing.
