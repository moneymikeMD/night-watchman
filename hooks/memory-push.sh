#!/bin/bash
#
# memory-push.sh — Claude Code SessionStart, UserPromptSubmit and
# PostToolUseFailure hook. Pushes recalled memory into the session as
# additionalContext, so a model that does not recall on its own still sees
# what the store knows (homelab LAB-345/LAB-355; payload per LAB-361).
#
# Query per event, raw case:
#   SessionStart        the repo name (origin URL basename) and branch
#   UserPromptSubmit    the prompt's first 1,000 characters
#   PostToolUseFailure  the last 1,000 characters of the failed tool's
#                       `error`, where Bash puts the failing line
# 1,000 is memorygraph's own cap: a longer query fails with
# "Validation error: Query exceeds 1000 characters".
#
# It runs `memorygraph recall --query Q --limit 5 --json`, so any backend
# works. The CLI's markdown output is parsed when --json is ignored (the
# 0.14 fork does). The top 3 results come back as bodies, each cut at 1,250
# characters and fetched with parallel `memorygraph get` calls because
# recall prints only a ~150-character preview. Results 4 and 5 are titles.
#
# Fail open and silent: no memorygraph or python3, a recall error, an empty
# result, or the time budget running out all mean no injection and exit 0.
# The budget covers recall and every get together: NW_MEMORY_PUSH_TIMEOUT
# seconds, default 6, sized from a measured 0.9-5.3 s recall (median about
# 2.3 s) against the Postgres backend over the LAN. plugin.json's 10 s
# timeout is only the outer backstop.
#
# Repeats: a UserPromptSubmit or PostToolUseFailure query already pushed in
# this session is not pushed again (a retry loop re-failing with the same
# error). SessionStart always pushes, since startup, resume, clear and
# compact each begin with context that lacks it. Memory ids are not
# de-duplicated across events, matching the measured M3b arm (LAB-361).
#
# With MEMORY_BACKEND unset and no <cwd>/.memorygraph/, memorygraph would
# create an empty store in the project, so the hook skips instead.
#
# Env:
#   NW_MEMORY_PUSH=0         disable the hook
#   NW_MEMORY_PUSH_TIMEOUT   total seconds per push (default 6)
#   NW_MEMORY_PUSH_STATE     repeat-tracking directory
#                            (default $TMPDIR/night-watchman-memory-push)
#   NW_MEMORY_PUSH_LOG       append one JSON line per push here (event,
#                            ids, seconds, outcome, how many of the top 3
#                            are full bodies; never the query text)
#
# Usage: fed the hook JSON on stdin, no arguments.

[ "${NW_MEMORY_PUSH:-1}" = "0" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0
command -v memorygraph >/dev/null 2>&1 || exit 0
python3 "$(cd "$(dirname "$0")" && pwd)/memory-push.py" 2>/dev/null
exit 0
