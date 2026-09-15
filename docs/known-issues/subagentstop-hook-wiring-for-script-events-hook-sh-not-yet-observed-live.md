---
title: "SubagentStop hook wiring for script-events-hook.sh not yet observed live"
heading_raw: "SubagentStop hook wiring for script-events-hook.sh not yet observed live — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
note: "matcher script-author|script-reviewer never fired through real Claude Code hook dispatch"
tickets: []
slug: subagentstop-hook-wiring-for-script-events-hook-sh-not-yet-observed-live
---

hooks/script-events-hook.sh is wired in .claude-plugin/plugin.json under a
SubagentStop hook with matcher "script-author|script-reviewer". Every
selftest assertion drives the script directly via crafted stdin — none of
them go through Claude Code's actual SubagentStop dispatch, so the matcher
semantics for agent-type-based SubagentStop matching (as opposed to the
well-established tool-based PreToolUse matcher semantics already used
elsewhere in this repo) have not been exercised end-to-end.

Failure mode if the wiring is silently broken is inert (fail-open, no
events ever appended to docs/script-events.jsonl) rather than destructive,
so this does not block landing.

Fix: after landing, watch for the first real script-author or
script-reviewer subagent to finish and confirm a row lands in
docs/script-events.jsonl without manual intervention. Resolve this entry
once that is observed.
