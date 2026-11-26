#!/bin/bash
#
# board-selftest.sh — offline checks for board.sh. issues.py is a stub that
# prints its argv and $ISSUES_JIRA_API, so no tracker, network or credential
# is reached in any case.
#
# Usage: board-selftest.sh

set -u
here="$(cd "$(dirname "$0")" && pwd)"
board="$here/board.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

stub="$tmp/issues.py"
cat > "$stub" <<'EOF'
import os, sys
print("STUB " + " ".join(sys.argv[1:]) + " api=" + os.environ.get("ISSUES_JIRA_API", "-"))
EOF

check() {
    local name="$1" dir="$2" want="$3" out rc
    out="$(cd "$dir" && BOARD_ISSUES_PY="${4-$stub}" "$board" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL $name: exit $rc"; fail=1
    elif ! printf '%s\n' "$out" | grep -q -- "$want"; then
        echo "FAIL $name: no '$want' in:"; printf '%s\n' "$out"; fail=1
    else
        echo "ok   $name"
    fi
}

mkdir -p "$tmp/file/issues/open" "$tmp/empty" "$tmp/jira/.night-watchman"
printf '[providers]\ntracker = "jira"\n\n[tracker.jira]\nproject = "EP"\n' > "$tmp/jira/.night-watchman/config.toml"

check file-mode-board "$tmp/file" "STUB board issues/"
check file-mode-lint "$tmp/file" "STUB lint issues/"
check no-issues-dir "$tmp/empty" "board unavailable: file tracker"
check no-issues-py "$tmp/file" "board unavailable: work-order" "$tmp/missing.py"
check jira-needs-nw-config "$tmp/jira" "NW_CONFIG is unset"
NW_CONFIG="$tmp/nw.toml" check jira-mode "$tmp/jira" \
    "STUB lint --source jira --jira-project EP api=.*providers/tracker/jira/jira-api.sh"

[ "$fail" -eq 0 ] && echo "board-selftest: all passed"
exit "$fail"
