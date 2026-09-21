#!/bin/bash
#
# ai-toolkit-root.sh — print the root of the ai-toolkit checkout this repo
# consumes operator scripts from, so nothing here needs a second copy of one.
#
# Usage: ai-toolkit-root.sh [--known-issue]
#   Prints the directory holding ai-toolkit's scripts/. With --known-issue,
#   prints scripts/known-issue.sh inside it instead.
#
#   ai-toolkit is not a Claude Code plugin, so there is no plugin-list entry
#   to key on the way work-order-root.sh does. Its scripts/ is the UNPINNED
#   surface — consumed by absolute path out of a working checkout, live to
#   every caller the moment a change is on disk — so there is no tag to
#   resolve either. The location is resolved at runtime, first hit wins:
#
#     1. $AI_TOOLKIT_ROOT, when it holds scripts/known-issue.sh.
#     2. A sibling checkout: ai-toolkit beside this plugin, then ai-toolkit
#        beside the directory this plugin sits in.
#
#   Exits 1 naming both when neither resolves. Never clones anything and
#   never writes.

set -euo pipefail
# shellcheck source=lib/kit.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/kit.sh"

case "${1:-}" in
    -h|--help) show_help ;;
esac

WANT_KNOWN_ISSUE=0
if [ "${1:-}" = "--known-issue" ]; then
    WANT_KNOWN_ISSUE=1
    shift
fi
[ $# -eq 0 ] || die "usage: ai-toolkit-root.sh [--known-issue] (got $# extra arguments)"

HERE="$(cd "$(dirname "$0")" && pwd)"
MARKER="scripts/known-issue.sh"
ROOT=""

# is_ai_toolkit DIR — 0 when DIR is an ai-toolkit tree rather than merely a path.
is_ai_toolkit() {
    [ -n "${1:-}" ] && [ -f "$1/$MARKER" ]
}

if is_ai_toolkit "${AI_TOOLKIT_ROOT:-}"; then
    ROOT="$AI_TOOLKIT_ROOT"
fi

if [ -z "$ROOT" ]; then
    for CANDIDATE in "$HERE/../../ai-toolkit" "$HERE/../../../ai-toolkit"; do
        if is_ai_toolkit "$CANDIDATE"; then
            ROOT="$(cd "$CANDIDATE" && pwd)"
            break
        fi
    done
fi

if [ -z "$ROOT" ]; then
    die "cannot locate an ai-toolkit checkout. Set AI_TOOLKIT_ROOT to one, or
clone it beside this repo — it is public, so no credential is needed:
    git clone https://github.com/moneymikeMD/ai-toolkit.git
ai-toolkit's scripts/ is consumed by absolute path out of a working checkout;
it is not pinned, not released, and not installable as a plugin."
fi

if [ "$WANT_KNOWN_ISSUE" -eq 1 ]; then
    printf '%s\n' "$ROOT/$MARKER"
else
    printf '%s\n' "$ROOT"
fi
