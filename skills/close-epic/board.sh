#!/bin/bash
#
# board.sh — the close-epic skill's load-time context: issues.py board and
# lint for the project in the current directory, injected into the skill
# body before the fork reads it. The tracker comes from
# .night-watchman/config.toml ([providers] tracker, [tracker.jira] project);
# file mode reads issues/. Never fails: anything missing prints one line
# saying what, and the skill tells the fork to run the commands itself.
#
# Usage: board.sh            (no arguments; the skill cannot pass its own)
#
# BOARD_ISSUES_PY overrides issues.py resolution (the selftest's stub).

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cfg=.night-watchman/config.toml

issues_py="${BOARD_ISSUES_PY:-$("$root/scripts/work-order-root.sh" --issues-py 2>/dev/null)}"
if [ -z "$issues_py" ] || [ ! -f "$issues_py" ]; then
    echo "(board unavailable: work-order's issues.py did not resolve)"
    exit 0
fi

if grep -q '^tracker *= *"jira"' "$cfg" 2>/dev/null; then
    project="$(sed -n 's/^project *= *"\(.*\)"/\1/p' "$cfg" | head -1)"
    if [ -z "$project" ] || [ -z "${NW_CONFIG:-}" ]; then
        echo "(board unavailable: jira tracker, but no [tracker.jira] project or \$NW_CONFIG is unset)"
        exit 0
    fi
    export ISSUES_JIRA_API="$root/providers/tracker/jira/jira-api.sh"
    set -- --source jira --jira-project "$project"
elif [ -d issues ]; then
    set -- issues/
else
    echo "(board unavailable: file tracker, but no issues/ in $(pwd))"
    exit 0
fi

for cmd in board lint; do
    echo "\$ issues.py $cmd $*"
    python3 "$issues_py" "$cmd" "$@" 2>&1 | head -80
done
exit 0
