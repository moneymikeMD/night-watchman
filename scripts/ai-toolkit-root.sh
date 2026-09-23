#!/bin/bash
#
# ai-toolkit-root.sh — print the root of the ai-toolkit checkout this repo
# consumes operator scripts from, so nothing here needs a second copy of one.
#
# Usage: ai-toolkit-root.sh [--known-issue|--script-analytics|--script-retire|--land-core]
#   Prints the directory holding ai-toolkit's scripts/. With a flag, prints
#   that script's path inside it instead. Each flag names a script this repo
#   donated and now consumes: known-issue.sh (NWM-128), script-analytics.py
#   and script-retire.sh (NWM-130), and land-core.sh, the merge-and-push
#   core land-branch.sh wraps (NWM-131).
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

WANT=""
case "${1:-}" in
    --known-issue)      WANT="scripts/known-issue.sh"; shift ;;
    --script-analytics) WANT="scripts/script-analytics.py"; shift ;;
    --script-retire)    WANT="scripts/script-retire.sh"; shift ;;
    --land-core)        WANT="scripts/land-core.sh"; shift ;;
    --*)                die "unknown flag: $1 (see --help)" ;;
esac
[ $# -eq 0 ] || die "usage: ai-toolkit-root.sh [--known-issue|--script-analytics|--script-retire|--land-core] (got $# extra arguments)"

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

if [ -n "$WANT" ]; then
    [ -f "$ROOT/$WANT" ] || die "$ROOT is an ai-toolkit checkout but has no $WANT.
It may predate the move that put it there; update the checkout."
    printf '%s\n' "$ROOT/$WANT"
else
    printf '%s\n' "$ROOT"
fi
