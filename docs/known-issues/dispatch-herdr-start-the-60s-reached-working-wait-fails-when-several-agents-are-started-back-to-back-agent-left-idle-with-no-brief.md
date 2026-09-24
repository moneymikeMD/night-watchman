---
title: "dispatch/herdr start: the 60s 'reached working' wait fails when several agents are started back to back; agent left idle with no brief"
heading_raw: "dispatch/herdr start: the 60s 'reached working' wait fails when several agents are started back to back; agent left idle with no brief — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
note: "seen on 2 of 10 sequential starts in one wave; re-prompting by hand recovered both"
tickets: []
slug: dispatch-herdr-start-the-60s-reached-working-wait-fails-when-several-agents-are-started-back-to-back-agent-left-idle-with-no-brief
---

providers/dispatch/herdr/herdr-ticket-start.sh step 3 runs `herdr agent
prompt --wait --until working --timeout 60000`, fixed, with no retry. When
several agents are started back to back, Claude Code startup under load can
exceed 60s before the pane accepts input; the prompt call then fails with
"'herdr agent prompt' failed (exit 1) — the worktree and agent were already
created" and the agent is left idle with no brief.

Recovery: `herdr agent prompt <branch> "<standard brief>" --wait --until
working --timeout 90000`. Fix options: retry the prompt once after a short
sleep before dying; make the timeout a flag with a 120s default; print the
exact recovery command in the die message so the brief need not be
reconstructed. Per the session-start failure policy, the failure text goes
in the ticket progress note and the fallback is a re-prompt, not a plain
worktree.
