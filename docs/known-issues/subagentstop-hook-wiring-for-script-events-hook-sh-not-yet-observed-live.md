---
title: "SubagentStop hook wiring for script-events-hook.sh not yet observed live"
heading_raw: "SubagentStop hook wiring for script-events-hook.sh not yet observed live — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
note: "matcher script-author|script-reviewer has never fired through real Claude Code hook dispatch; docs/script-events.jsonl does not exist"
tickets: []
slug: subagentstop-hook-wiring-for-script-events-hook-sh-not-yet-observed-live
---

hooks/script-events-hook.sh is registered in .claude-plugin/plugin.json as
a SubagentStop hook with matcher "script-author|script-reviewer". Every
selftest assertion drives the script directly on stdin, and the hook run by
hand with a synthetic payload resolves and invokes the extractor, but no
row has ever appeared in docs/script-events.jsonl from Claude Code's own
SubagentStop dispatch: the file does not exist in this checkout. Failure
if the wiring is broken is inert (fail-open, no events), not destructive.

Open question: does Claude Code's SubagentStop matcher match on agent type
the way PreToolUse matches on tool name? The proof is one real
script-author or script-reviewer subagent finishing and a row landing in
docs/script-events.jsonl with no manual step.
