---
title: "dispatch/herdr start: a cold Claude Code boot (plugin marketplace refresh) swallows the brief; herdr reports interactive_ready before the agent can accept input"
heading_raw: "dispatch/herdr start: a cold Claude Code boot (plugin marketplace refresh) swallows the brief; herdr reports interactive_ready before the agent can accept input — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
note: "hit on the FIRST start of a session, not under load; second start in the same session was clean because the cache was warm"
tickets: ["NWM-113"]
slug: dispatch-herdr-start-a-cold-claude-code-boot-plugin-marketplace-refresh-swallows-the-brief-herdr-reports-interactive-ready-before-the-agent-can-accept-input
---

Found 2026-09-19 dispatching wave 1 (NWM-113, NWM-127).

The first start of the session failed at herdr-ticket-start.sh step 3 with:

  'herdr agent prompt' failed (exit 1) - the worktree and agent were already
  created; check 'nwm-113' by hand. herdr said: {"error":{"code":
  "agent_prompt_stalled","message":"agent prompt produced no observed working
  or blocked state within 5000 ms; current status is idle"}}

This is NOT the existing "60s reached-working wait fails when several agents
are started back to back" entry: it happened on start 1 of 2, under no load,
and the reported window was 5000 ms rather than 60000. It is also not the
folder-trust dialog entry — no dialog was present.

Root cause, from reading the pane with `herdr agent read nwm-113`: the brief
WAS delivered, but Claude Code was still booting and consumed it. The pane
showed "Refreshing marketplace cache", "Cloning repository ... agento11y",
and a plugin update from a9b03af48165 to f1badad02577, with a fragment of
the brief ("ticket, then stop: stat") interleaved in that output. Claude Code
then finished booting to an EMPTY prompt. herdr had already reported
interactive_ready=true and agent_status=idle before Claude Code was in fact
able to accept a prompt, so the readiness signal is not a readiness signal
for a cold start.

The second dispatch of the same session (NWM-127) succeeded with no
intervention, because the marketplace cache was warm by then. That asymmetry
is the tell: the failure is a first-start race, so it reproduces on a fresh
machine, a fresh day, or any session after a plugin update — and NOT on a
retry, which is what makes it look intermittent.

Two consequences worth separating. First, the brief is lost silently: the
agent sits at an idle prompt looking healthy. Second, because the script
dies at step 3, its step 4 never runs, so the ticket stays in To Do while its
worktree and agent exist — a state no reader would expect, and one the
orchestrator has to repair by hand.

Recovery that worked, first try: re-send the same brief text with
`herdr agent prompt <branch> "<brief>" --wait --until working --timeout 90000`.
Note that herdr-ticket-start.sh is idempotent and refuses once a workspace
exists, so it cannot be used to re-render the brief for the recovery — the
text has to come from a --dry-run taken BEFORE the start, or be reconstructed
by hand. Printing the exact recovery command, with the brief, in the die
message (option (c) on the sibling entry) would fix that and is worth more
here than a longer timeout.
