#!/bin/bash
#
# Selftest for work-order-root.sh. Structurally offline: every case runs
# against a mktemp tree, and the cases that exercise the plugin CLI shim
# `claude` with a PATH-first stub, so no network call and no real plugin
# install can happen even if an assertion is wrong.
#
# Usage: scripts/work-order-root-selftest.sh [path-to-work-order-root.sh]

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${1:-$HERE/work-order-root.sh}"
[ -x "$SUT" ] || { echo "cannot execute $SUT" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# jq is reached by adding its directory to PATH, never by copying the binary:
# a copied macOS system binary loses its code signature and is SIGKILLed.
STUB_PATH="$WORK/stub-bin:/usr/bin:/bin:/usr/sbin:/sbin"
if command -v jq >/dev/null 2>&1; then
    STUB_PATH="$STUB_PATH:$(dirname "$(command -v jq)")"
fi
mkdir -p "$WORK/stub-bin"
mkdir -p "$WORK/isolated/night-watchman/scripts/lib"
SUT_COPY="$WORK/isolated/night-watchman/scripts/work-order-root.sh"
cp "$SUT" "$SUT_COPY"
cp "$HERE/lib/kit.sh" "$WORK/isolated/night-watchman/scripts/lib/kit.sh"
chmod +x "$SUT_COPY"

# make_work_order DIR — a directory that looks like a work-order checkout.
make_work_order() {
    mkdir -p "$1/reference"
    : > "$1/reference/issues.py"
}

# stub_claude ID PATH — a `claude` whose plugin list names ID at PATH.
stub_claude() {
    cat > "$WORK/stub-bin/claude" <<'HEAD'
#!/bin/bash
[ "$1" = "plugin" ] && [ "$2" = "list" ] || { echo "unexpected: $*" >&2; exit 64; }
cat <<'JSON'
HEAD
    printf '[{"id":"caveman@caveman","installPath":"/nope"},{"id":"%s","version":"1.3.0","installPath":"%s"}]\n' \
        "$1" "$2" >> "$WORK/stub-bin/claude"
    echo JSON >> "$WORK/stub-bin/claude"
    chmod +x "$WORK/stub-bin/claude"
}

# run_sut [WORK_ORDER_ROOT=...] ARGS... — sets RC, OUT and ERR. A leading
# WORK_ORDER_ROOT= assignment is passed through; otherwise the variable is
# unset, so only the CLI stub and the sibling fallback can resolve.
run_sut() {
    local override=""
    case "${1:-}" in
        WORK_ORDER_ROOT=*) override="$1"; shift ;;
    esac
    set +e
    if [ -n "$override" ]; then
        env -u CLAUDE_PLUGIN_ROOT PATH="$STUB_PATH" "$override" \
            "$SUT_COPY" "$@" >"$WORK/out" 2>"$WORK/err"
    else
        env -u CLAUDE_PLUGIN_ROOT -u WORK_ORDER_ROOT PATH="$STUB_PATH" \
            "$SUT_COPY" "$@" >"$WORK/out" 2>"$WORK/err"
    fi
    RC=$?
    set -e
    OUT=$(cat "$WORK/out")
    ERR=$(cat "$WORK/err")
}

REAL_WO="$WORK/real-work-order"
make_work_order "$REAL_WO"

run_sut
if [ "$RC" -eq 1 ] && [ -z "$OUT" ] \
    && [[ "$ERR" == *"cannot locate the work-order plugin"* ]] \
    && [[ "$ERR" == *"WORK_ORDER_ROOT"* ]] \
    && [[ "$ERR" == *"claude plugin install work-order@work-order"* ]] \
    && [[ "$ERR" == *"errors"* ]]; then
    ok "nothing resolvable: exit 1, stderr names the env var, the install and the errors field"
else
    bad "unresolvable: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut "WORK_ORDER_ROOT=$REAL_WO"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$REAL_WO" ] && [ -z "$ERR" ]; then
    ok "WORK_ORDER_ROOT wins when it holds reference/issues.py"
else
    bad "env override: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut "WORK_ORDER_ROOT=$REAL_WO" --issues-py
if [ "$RC" -eq 0 ] && [ "$OUT" = "$REAL_WO/reference/issues.py" ]; then
    ok "--issues-py appends the reference implementation's path"
else
    bad "--issues-py: rc=$RC out='$OUT' err='$ERR'"
fi

mkdir -p "$WORK/empty-dir"
run_sut "WORK_ORDER_ROOT=$WORK/empty-dir"
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"cannot locate"* ]]; then
    ok "a WORK_ORDER_ROOT without reference/issues.py is rejected, not printed"
else
    bad "empty WORK_ORDER_ROOT: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut "WORK_ORDER_ROOT=$WORK/no-such-directory"
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"cannot locate"* ]]; then
    ok "a WORK_ORDER_ROOT naming nothing at all is rejected"
else
    bad "missing WORK_ORDER_ROOT: rc=$RC out='$OUT' err='$ERR'"
fi

make_work_order "$WORK/isolated/work-order"
run_sut
if [ "$RC" -eq 0 ] && [ "$OUT" = "$WORK/isolated/work-order" ]; then
    ok "development fallback: work-order checked out beside the plugin resolves"
else
    bad "sibling fallback: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut "WORK_ORDER_ROOT=$REAL_WO"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$REAL_WO" ]; then
    ok "WORK_ORDER_ROOT still beats the sibling fallback"
else
    bad "precedence env over sibling: rc=$RC out='$OUT' err='$ERR'"
fi

if command -v jq >/dev/null 2>&1; then
    CLI_WO="$WORK/cli-work-order"
    make_work_order "$CLI_WO"

    stub_claude "work-order@work-order" "$CLI_WO"
    run_sut
    if [ "$RC" -eq 0 ] && [ "$OUT" = "$CLI_WO" ]; then
        ok "the plugin CLI's installPath for id work-order@work-order beats the sibling fallback"
    else
        bad "plugin CLI: rc=$RC out='$OUT' err='$ERR'"
    fi

    stub_claude "work-order-jira@work-order" "$CLI_WO"
    run_sut
    if [ "$RC" -eq 0 ] && [ "$OUT" = "$WORK/isolated/work-order" ]; then
        ok "a near-miss id does not match: resolution falls through to the sibling checkout"
    else
        bad "id keying: rc=$RC out='$OUT' err='$ERR'"
    fi

    stub_claude "work-order@work-order" "$WORK/uninstalled"
    run_sut
    if [ "$RC" -eq 0 ] && [ "$OUT" = "$WORK/isolated/work-order" ]; then
        ok "an installPath that no longer holds reference/issues.py is not trusted"
    else
        bad "stale installPath: rc=$RC out='$OUT' err='$ERR'"
    fi

    rm -rf "$WORK/isolated/work-order"
    stub_claude "nothing@nowhere" "$CLI_WO"
    run_sut
    if [ "$RC" -eq 1 ] && [[ "$ERR" == *"cannot locate"* ]]; then
        ok "a plugin list with no work-order entry and no sibling exits 1"
    else
        bad "no entry anywhere: rc=$RC out='$OUT' err='$ERR'"
    fi

    make_work_order "$WORK/isolated/work-order"
    rm -f "$WORK/stub-bin/claude"
else
    echo "skip - plugin CLI cases need jq on PATH"
fi

run_sut --help
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"Usage: work-order-root.sh [--issues-py]"* ]] && [ -z "$ERR" ]; then
    ok "--help prints the header on stdout, exit 0"
else
    bad "--help: rc=$RC out='$OUT' err='$ERR'"
fi

run_sut --issues-py extra
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"got 1 extra arguments"* ]]; then
    ok "an unexpected argument is a usage error"
else
    bad "extra argument: rc=$RC out='$OUT' err='$ERR'"
fi

echo
echo "$PASS passed, $FAIL failed (against: $SUT)"
[ "$FAIL" -eq 0 ]
