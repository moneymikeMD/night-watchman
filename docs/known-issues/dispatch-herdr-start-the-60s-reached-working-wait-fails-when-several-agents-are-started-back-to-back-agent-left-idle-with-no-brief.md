---
title: "dispatch/herdr start: the 60s 'reached working' wait fails when several agents are started back to back; agent left idle with no brief"
heading_raw: "dispatch/herdr start: the 60s 'reached working' wait fails when several agents are started back to back; agent left idle with no brief — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
note: "2 of 10 starts in one wave; re-prompting by hand with the standard brief text recovered both"
tickets: []
slug: dispatch-herdr-start-the-60s-reached-working-wait-fails-when-several-agents-are-started-back-to-back-agent-left-idle-with-no-brief
---

Found 2026-09-14 dispatching a ten-ticket wave sequentially. herdr-ticket-start.sh step 3 runs 'herdr agent prompt --wait --until working --timeout 60000'. Starts 9 and 10 returned "'herdr agent prompt' failed (exit 1) — the worktree and agent were already created" and the agents sat idle with no brief. Root cause not confirmed; likely Claude Code startup under load exceeded 60s before the pane accepted input. Recovery used: 'herdr agent prompt <branch> "<standard brief>" --wait --until working --timeout 90000'. Fix options: (a) retry the prompt once after a short sleep before dying; (b) make the timeout a flag with a 120s default; (c) print the exact recovery command in the die message so the orchestrator does not have to reconstruct the brief text. Per the session-start failure policy, the failure text goes in the ticket progress note and the fallback is a re-prompt, not a plain worktree.
