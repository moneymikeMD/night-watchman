#!/bin/bash
#
# work-order-root.sh — print the root of the work-order plugin night-watchman
# depends on, so nothing here needs a second copy of the ticket contract.
#
# Usage: work-order-root.sh [--issues-py]
#   Prints the directory holding work-order's SPEC.md, bindings/file/BINDING.md
#   and reference/issues.py. With --issues-py, prints reference/issues.py
#   inside it instead.
#
#   ${CLAUDE_PLUGIN_ROOT} names only the plugin that is executing and cannot
#   reach a dependency, so the location is resolved at runtime instead, first
#   hit wins:
#
#     1. $WORK_ORDER_ROOT, when it holds reference/issues.py.
#     2. claude plugin list --json — the .installPath of the entry whose .id is
#        work-order@moneymike-plugins. There is no .name field to key on.
#     3. A sibling checkout: work-order beside this plugin, then work-order
#        beside the directory this plugin sits in. A plugin loaded from a local
#        checkout has no plugin-list entry at all, so this is what makes
#        development work.
#
#   Exits 1 naming all three when none of them resolves. Never installs
#   anything and never writes.

set -euo pipefail
# shellcheck source=lib/kit.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/kit.sh"

case "${1:-}" in
    -h|--help) show_help ;;
esac

WANT_ISSUES_PY=0
if [ "${1:-}" = "--issues-py" ]; then
    WANT_ISSUES_PY=1
    shift
fi
[ $# -eq 0 ] || die "usage: work-order-root.sh [--issues-py] (got $# extra arguments)"

HERE="$(cd "$(dirname "$0")" && pwd)"
MARKER="reference/issues.py"
ROOT=""

# is_work_order DIR — 0 when DIR is a work-order tree rather than merely a path.
is_work_order() {
    [ -n "${1:-}" ] && [ -f "$1/$MARKER" ]
}

if is_work_order "${WORK_ORDER_ROOT:-}"; then
    ROOT="$WORK_ORDER_ROOT"
fi

if [ -z "$ROOT" ] && command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    LISTED=""
    set +e
    LISTED="$(claude plugin list --json 2>/dev/null \
        | jq -r 'map(select(.id == "work-order@moneymike-plugins")) | .[0].installPath // empty' 2>/dev/null)"
    set -e
    if is_work_order "$LISTED"; then
        ROOT="$LISTED"
    fi
fi

if [ -z "$ROOT" ]; then
    for CANDIDATE in "$HERE/../../work-order" "$HERE/../../../work-order"; do
        if is_work_order "$CANDIDATE"; then
            ROOT="$(cd "$CANDIDATE" && pwd)"
            break
        fi
    done
fi

if [ -z "$ROOT" ]; then
    die "cannot locate the work-order plugin. Set WORK_ORDER_ROOT to a work-order
checkout, or install the dependency with:
    claude plugin marketplace add moneymikeMD/moneymike-plugins
    claude plugin install work-order@moneymike-plugins
then confirm it arrived — the errors field, not the exit code:
    claude plugin list --json | jq '.[] | select(.id == \"work-order@moneymike-plugins\") | .errors'"
fi

if [ "$WANT_ISSUES_PY" -eq 1 ]; then
    printf '%s\n' "$ROOT/$MARKER"
else
    printf '%s\n' "$ROOT"
fi
