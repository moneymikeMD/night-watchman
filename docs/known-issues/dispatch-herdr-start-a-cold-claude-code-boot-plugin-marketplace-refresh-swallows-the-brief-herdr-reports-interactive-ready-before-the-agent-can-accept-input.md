---
title: "dispatch/herdr start: a cold Claude Code boot (plugin marketplace refresh) swallows the brief; herdr reports interactive_ready before the agent can accept input"
heading_raw: "dispatch/herdr start: a cold Claude Code boot (plugin marketplace refresh) swallows the brief; herdr reports interactive_ready before the agent can accept input — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
note: "first start of a session, not under load; the same start retried is clean because the cache is warm"
tickets: ["NWM-113"]
slug: dispatch-herdr-start-a-cold-claude-code-boot-plugin-marketplace-refresh-swallows-the-brief-herdr-reports-interactive-ready-before-the-agent-can-accept-input
---

On the first `herdr agent start` of a session, or any start after a plugin
update, Claude Code boots through a marketplace refresh and plugin clone
while herdr already reports interactive_ready=true and agent_status=idle.
providers/dispatch/herdr/herdr-ticket-start.sh step 3 then sends the brief
into that boot output; Claude Code finishes booting to an empty prompt and
the prompt call fails with:

  agent_prompt_stalled: agent prompt produced no observed working or
  blocked state within 5000 ms; current status is idle

The script dies at step 3, so step 4 never runs: the ticket stays in To Do
while its worktree and agent exist, and the agent sits idle looking healthy.
A retry in the same session succeeds because the cache is warm, which is
what makes the failure look intermittent.

Recovery: re-send the brief with `herdr agent prompt <branch> "<brief>"
--wait --until working --timeout 90000`. The script refuses once a
workspace exists, so the brief text must come from a `--dry-run` taken
before the start or be reconstructed by hand. Printing the exact recovery
command, brief included, in the die message would remove that step.
