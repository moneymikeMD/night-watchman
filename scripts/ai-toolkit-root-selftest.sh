#!/bin/bash
#
# Selftest for ai-toolkit-root.sh. Structurally offline: every case runs
# against a mktemp tree, so no network call and no real clone can happen even
# if an assertion is wrong.
#
# Usage: scripts/ai-toolkit-root-selftest.sh [path-to-ai-toolkit-root.sh]

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${1:-$HERE/ai-toolkit-root.sh}"
[ -x "$SUT" ] || { echo "cannot execute $SUT" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/isolated/night-watchman/scripts/lib"
SUT_COPY="$WORK/isolated/night-watchman/scripts/ai-toolkit-root.sh"
cp "$SUT" "$SUT_COPY"
cp "$HERE/lib/kit.sh" "$WORK/isolated/night-watchman/scripts/lib/kit.sh"
chmod +x "$SUT_COPY"

# make_ai_toolkit DIR — a directory that looks like an ai-toolkit checkout.
make_ai_toolkit() {
    mkdir -p "$1/scripts"
    : > "$1/scripts/known-issue.sh"
    : > "$1/scripts/script-analytics.py"
    : > "$1/scripts/script-retire.sh"
    : > "$1/scripts/land-core.sh"
}

# run_sut [AI_TOOLKIT_ROOT=...] ARGS... — sets RC, OUT and ERR. A leading
# AI_TOOLKIT_ROOT= assignment is passed through; otherwise the variable is
# unset, so only the sibling fallback can resolve.
run_sut() {
    local override=""
    case "${1:-}" in
        AI_TOOLKIT_ROOT=*) override="$1"; shift ;;
    esac
    set +e
    if [ -n "$override" ]; then
        env -u CLAUDE_PLUGIN_ROOT "$override" \
            "$SUT_COPY" "$@" >"$WORK/out" 2>"$WORK/err"
    else
        env -u CLAUDE_PLUGIN_ROOT -u AI_TOOLKIT_ROOT \
            "$SUT_COPY" "$@" >"$WORK/out" 2>"$WORK/err"
    fi
    RC=$?
    set -e
    OUT=$(cat "$WORK/out")
    ERR=$(cat "$WORK/err")
}

REAL_AT="$WORK/real-ai-toolkit"
make_ai_toolkit "$REAL_AT"

run_sut
if [ "$RC" -eq 1 ] && [ -z "$OUT" ] \
    && [[ "$ERR" == *"cannot locate an ai-toolkit checkout"* ]] \
    && [[ "$ERR" == *"AI_TOOLKIT_ROOT"* ]] \
    && [[ "$ERR" == *"git clone https://github.com/moneymikeMD/ai-toolkit.git"* ]]; then
    ok "nothing resolvable: exit 1, stderr names the env var and the clone"
else
    bad "unresolvable: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut "AI_TOOLKIT_ROOT=$REAL_AT"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$REAL_AT" ] && [ -z "$ERR" ]; then
    ok "AI_TOOLKIT_ROOT wins when it holds scripts/known-issue.sh"
else
    bad "env override: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut "AI_TOOLKIT_ROOT=$REAL_AT" --known-issue
if [ "$RC" -eq 0 ] && [ "$OUT" = "$REAL_AT/scripts/known-issue.sh" ]; then
    ok "--known-issue appends the script's path"
else
    bad "--known-issue: rc=$RC out='$OUT' err='$ERR'"
fi

mkdir -p "$WORK/empty-dir"
run_sut "AI_TOOLKIT_ROOT=$WORK/empty-dir"
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"cannot locate"* ]]; then
    ok "an AI_TOOLKIT_ROOT without scripts/known-issue.sh is rejected, not printed"
else
    bad "empty AI_TOOLKIT_ROOT: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut "AI_TOOLKIT_ROOT=$WORK/no-such-directory"
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"cannot locate"* ]]; then
    ok "an AI_TOOLKIT_ROOT naming nothing at all is rejected"
else
    bad "missing AI_TOOLKIT_ROOT: rc=$RC out='$OUT' err='$ERR'"
fi

make_ai_toolkit "$WORK/isolated/ai-toolkit"
run_sut
if [ "$RC" -eq 0 ] && [ "$OUT" = "$WORK/isolated/ai-toolkit" ]; then
    ok "development fallback: ai-toolkit checked out beside the repo resolves"
else
    bad "sibling fallback: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut "AI_TOOLKIT_ROOT=$REAL_AT"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$REAL_AT" ]; then
    ok "AI_TOOLKIT_ROOT still beats the sibling fallback"
else
    bad "precedence env over sibling: rc=$RC out='$OUT' err='$ERR'"
fi

rm -rf "$WORK/isolated/ai-toolkit"
mkdir -p "$WORK/isolated/ai-toolkit"
run_sut
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"cannot locate"* ]]; then
    ok "a sibling directory without the marker does not resolve"
else
    bad "markerless sibling: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut --help
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"Usage: ai-toolkit-root.sh [--known-issue|--script-analytics|--script-retire|--land-core]"* ]] && [ -z "$ERR" ]; then
    ok "--help prints the header on stdout, exit 0"
else
    bad "--help: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut --known-issue extra
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"got 1 extra arguments"* ]]; then
    ok "an unexpected argument is a usage error"
else
    bad "extra argument: rc=$RC out='$OUT' err='$ERR'"
fi

# ---- NWM-130: the two scripts this repo donated resolve the same way ----
run_sut "AI_TOOLKIT_ROOT=$REAL_AT" --script-analytics
if [ "$RC" -eq 0 ] && [ "$OUT" = "$REAL_AT/scripts/script-analytics.py" ]; then
    ok "--script-analytics appends the extractor's path"
else
    bad "--script-analytics: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut "AI_TOOLKIT_ROOT=$REAL_AT" --script-retire
if [ "$RC" -eq 0 ] && [ "$OUT" = "$REAL_AT/scripts/script-retire.sh" ]; then
    ok "--script-retire appends the retirement script's path"
else
    bad "--script-retire: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut "AI_TOOLKIT_ROOT=$REAL_AT" --land-core
if [ "$RC" -eq 0 ] && [ "$OUT" = "$REAL_AT/scripts/land-core.sh" ]; then
    ok "--land-core appends the merge-and-push core's path"
else
    bad "--land-core: rc=$RC out='$OUT' err='$ERR'"
fi

OLD_AT="$WORK/old-ai-toolkit"
mkdir -p "$OLD_AT/scripts"
: > "$OLD_AT/scripts/known-issue.sh"
run_sut "AI_TOOLKIT_ROOT=$OLD_AT" --land-core
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && [[ "$ERR" == *"has no scripts/land-core.sh"* ]]; then
    ok "--land-core against a checkout that predates land-core.sh exits non-zero naming it"
else
    bad "--land-core on an old checkout: rc=$RC out='$OUT' err='$ERR'"
fi

# A checkout that resolves but predates the move must say so, not print a
# path that does not exist — the caller would otherwise fail much later.
STALE_AT="$WORK/stale-ai-toolkit"
mkdir -p "$STALE_AT/scripts"
: > "$STALE_AT/scripts/known-issue.sh"
run_sut "AI_TOOLKIT_ROOT=$STALE_AT" --script-analytics
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"no scripts/script-analytics.py"* ]] && [ -z "$OUT" ]; then
    ok "a checkout without the donated script is refused, not printed"
else
    bad "stale checkout: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut "AI_TOOLKIT_ROOT=$REAL_AT" --not-a-flag
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"unknown flag"* ]]; then
    ok "an unrecognised flag is refused by name"
else
    bad "unknown flag: rc=$RC out='$OUT' err='$ERR'"
fi

echo
echo "$PASS passed, $FAIL failed (against: $SUT)"
[ "$FAIL" -eq 0 ]
