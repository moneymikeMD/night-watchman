---
title: "script-events-hook.sh resolves the extractor by path only, so a foreign repo's scripts/script-analytics.py would be invoked"
heading_raw: "script-events-hook.sh resolves the extractor by path only, so a foreign repo's scripts/script-analytics.py would be invoked — LOW"
severity: LOW
status: open
qualifiers: []
note: "user-scope SubagentStop hook; fail-open, no writes unless the foreign script writes"
tickets: []
slug: script-events-hook-sh-resolves-the-extractor-by-path-only-so-a-foreign-repo-s-scripts-script-analytics-py-would-be-invoked
---

Found 2026-09-13 by script-reviewer (LAND verdict, follow-up). hooks/script-events-hook.sh is wired at user scope, so its SubagentStop matcher fires in every repo on the machine whenever an agent named script-author or script-reviewer stops. It then invokes $PROJECT_DIR/scripts/script-analytics.py with a fixed argv (extract --agent-id ... --events ... --quiet) with no check that the file is this plugin's extractor. A repo that defines same-named agents and happens to carry an unrelated scripts/script-analytics.py would have that script run with those arguments. Blast radius is bounded: the hook exits 0 on every path, writes nothing itself when the extractor is missing, and the foreign script only sees argv, never transcript content. Fix candidates: a sentinel check (--help must print a known marker) before invoking, or resolve the extractor from ${CLAUDE_PLUGIN_ROOT} and only pass the project dir as an argument.
