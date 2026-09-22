---
title: "script-events-hook.sh resolves the extractor by path only, so a foreign repo's scripts/script-analytics.py would be invoked"
heading_raw: "script-events-hook.sh resolves the extractor by path only, so a foreign repo's scripts/script-analytics.py would be invoked — LOW"
severity: LOW
status: open
qualifiers: []
note: "user-scope SubagentStop hook; fail-open, no writes unless the foreign script writes"
tickets: ["NWM-160"]
slug: script-events-hook-sh-resolves-the-extractor-by-path-only-so-a-foreign-repo-s-scripts-script-analytics-py-would-be-invoked
---

Found 2026-09-13 by script-reviewer (LAND verdict, follow-up). hooks/script-events-hook.sh is wired at user scope, so its SubagentStop matcher fires in every repo on the machine whenever an agent named script-author or script-reviewer stops. It then invokes $PROJECT_DIR/scripts/script-analytics.py with a fixed argv (extract --agent-id ... --events ... --quiet) with no check that the file is this plugin's extractor. A repo that defines same-named agents and happens to carry an unrelated scripts/script-analytics.py would have that script run with those arguments. Blast radius is bounded: the hook exits 0 on every path, writes nothing itself when the extractor is missing, and the foreign script only sees argv, never transcript content. Fix candidates: a sentinel check (--help must print a known marker) before invoking, or resolve the extractor from ${CLAUDE_PLUGIN_ROOT} and only pass the project dir as an argument.

Narrowed 2026-09-22 by NWM-156 and NWM-130, not resolved. The second fix
candidate is now partly in place: the hook resolves a five-step chain —
$SCRIPT_EVENTS_EXTRACTOR, then $CLAUDE_PLUGIN_ROOT/scripts/script-analytics.py,
then $PROJECT_DIR/scripts/script-analytics.py, then its own ../scripts/, then
whatever `scripts/ai-toolkit-root.sh --script-analytics` resolves — and it
names every path tried when nothing resolves. In the installed case this entry
is about, $CLAUDE_PLUGIN_ROOT is set, so a foreign repo's copy is never
reached.

What is left, and NWM-160 carries it. $PROJECT_DIR still sits ahead of both
the hook-relative candidate and the ai-toolkit one, so with $CLAUDE_PLUGIN_ROOT
unset the original hazard stands: a repo defining same-named agents and
carrying an unrelated scripts/script-analytics.py still gets it invoked with
the plugin's fixed argv. And no sentinel check was added, so nothing verifies
that the resolved file is an extractor at all. NWM-130 made the second point
sharper rather than softer — since script-analytics.py no longer ships in this
plugin, $PROJECT_DIR is now the FIRST path candidate that can match anything,
and the legitimate answer lives at the end of the chain behind it.
