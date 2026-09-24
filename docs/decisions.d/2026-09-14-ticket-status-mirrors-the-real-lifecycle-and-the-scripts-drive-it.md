---
seq: 3
date: 2026-09-14
level: 3
slug: 2026-09-14-ticket-status-mirrors-the-real-lifecycle-and-the-scripts-drive-it
title: "Ticket status mirrors the real lifecycle, and the scripts drive it"
---

Owner rule: a ticket is In Progress from the moment it is dispatched (or a
workspace/pane is created for it), Awaiting Deployment before landing, and
Completed after landing. No step is skipped, ever, and no step is done by
hand except to repair one the scripts missed.

Reasoning: the previous-status validator on Completed refuses a landing that
jumps from In Progress straight to Completed, and it is right to. Awaiting
Deployment is the state "merged but not yet proven", and land-branch's push
is the deploy, so it is a mandatory stop even for tickets with nothing else
to deploy. Dispatch start and land-branch drive the three transitions
through the tracker seam, resolved by target status.
