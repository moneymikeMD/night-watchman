#!/bin/bash
#
# Assertions for provider.sh's `watch` and `stop` verbs (`start` has its own
# selftest, herdr-ticket-start-selftest.sh). The `agent get`/`agent wait`/
# `workspace close` canned responses are the real fixtures under fixtures/,
# recorded live rather than authored — see testing-philosophy.md's "fixture
# provenance" rule and fixtures/README.md. The one exception is scenario
# S1's no-workspace_id agent shape, authored and called out where it is used
# because no live capture of that case exists.
#
# `stop` never calls `herdr pane close` — an agent with no workspace_id is a
# stop2 refusal, not a fallback — so no scenario exercises `pane close`.
#
# Isolation: a stub `herdr` on PATH, installed fresh per scratch dir. Nothing
# here creates a worktree or workspace, or touches a live Herdr server.
#
# Fail-first discipline (name-the-oracle): before this file was trusted, its
# central assertions were run against a deliberately corrupted copy of
# provider.sh (workspace_id lookup hardcoded to empty) and confirmed to FAIL
# scenario S0 specifically, then the corruption was reverted and this file
# was confirmed to pass again in full.
#
# Usage: ./provider-selftest.sh
# Exit 0 if every assertion passes, 1 otherwise.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/provider.sh"
FIXTURES="$HERE/fixtures"
[ -f "$SUT" ] || { echo "cannot find provider.sh next to this selftest" >&2; exit 1; }

FAIL=0

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" != "$got" ]; then
        echo "FAIL: $desc — want [$want] got [$got]" >&2
        FAIL=1
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ;;
        *) echo "FAIL: $desc — expected to find [$needle] in: $haystack" >&2; FAIL=1 ;;
    esac
}

# install_stub_herdr <dir> — a stub speaking only `agent get`, `agent wait` and
# `workspace close`, logging every argv to $STUB_HERDR_LOG and driven by the
# STUB_* env vars read in its body below. Anything else exits 99.
install_stub_herdr() {
    local dir="$1"
    mkdir -p "$dir/bin"
    cat > "$dir/bin/herdr" <<'STUBEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_HERDR_LOG"
case "$1 $2" in
    "agent get")
        [ "${STUB_AGENT_GET_FAIL:-0}" = 1 ] && { echo "error: no such agent" >&2; exit 1; }
        printf '%s\n' "$STUB_AGENT_GET_JSON"
        ;;
    "agent wait")
        [ "${STUB_AGENT_WAIT_FAIL:-0}" = 1 ] && { echo "error: timeout" >&2; exit 1; }
        printf '%s\n' "$STUB_AGENT_WAIT_JSON"
        ;;
    "workspace close")
        [ "${STUB_WORKSPACE_CLOSE_FAIL:-0}" = 1 ] && { echo "stub herdr: simulated 'workspace close' failure" >&2; exit 1; }
        printf '%s\n' "$STUB_WORKSPACE_CLOSE_JSON"
        ;;
    *)
        echo "stub herdr: unexpected call: $*" >&2
        exit 99
        ;;
esac
STUBEOF
    chmod +x "$dir/bin/herdr"
}

call_count() {
    local log="$1" pattern="$2" n
    [ -f "$log" ] || { printf '0'; return 0; }
    n=$(grep -c -- "^$pattern" "$log" 2>/dev/null) || n=0
    printf '%s' "$n"
}

run_sut() {
    local dir="$1"; shift
    ( PATH="$dir/bin:$PATH" "$SUT" "$@" 2>&1 )
}

AGENT_GET_JSON=$(cat "$FIXTURES/agent-get.json")
AGENT_WAIT_JSON=$(cat "$FIXTURES/agent-wait.json")
WORKSPACE_CLOSE_JSON=$(cat "$FIXTURES/workspace-close.json")

# W0 — happy path: one `agent get`, one `agent wait`, no flags forwarded.
scenario_watch_happy() {
    local dir log out rc
    dir=$(mktemp -d) || { echo "FAIL: W0 setup" >&2; FAIL=1; return; }
    install_stub_herdr "$dir"
    log="$dir/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_AGENT_GET_JSON="$AGENT_GET_JSON" \
        STUB_AGENT_WAIT_JSON="$AGENT_WAIT_JSON" run_sut "$dir" watch NWM-48) && rc=0 || rc=$?

    assert_eq "W0 exit code" "0" "$rc"
    assert_eq "W0 one agent get call" "1" "$(call_count "$log" "agent get nwm-48")"
    assert_eq "W0 one agent wait call, no extra flags" "1" "$(call_count "$log" "agent wait nwm-48$")"
    assert_contains "W0 output carries wait JSON" "$out" '"type":"agent_info"'
}

# W1 — --until/--timeout are forwarded verbatim to `herdr agent wait`.
scenario_watch_forwards_flags() {
    local dir log out rc
    dir=$(mktemp -d) || { echo "FAIL: W1 setup" >&2; FAIL=1; return; }
    install_stub_herdr "$dir"
    log="$dir/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_AGENT_GET_JSON="$AGENT_GET_JSON" \
        STUB_AGENT_WAIT_JSON="$AGENT_WAIT_JSON" run_sut "$dir" watch NWM-48 \
        --until idle --until blocked --timeout 60000) && rc=0 || rc=$?

    assert_eq "W1 exit code" "0" "$rc"
    assert_eq "W1 wait call carries both --until and --timeout" "1" \
        "$(call_count "$log" "agent wait nwm-48 --until idle --until blocked --timeout 60000$")"
}

# W2 — no running agent: dies WITHOUT ever calling `agent wait`.
scenario_watch_no_agent() {
    local dir log out rc
    dir=$(mktemp -d) || { echo "FAIL: W2 setup" >&2; FAIL=1; return; }
    install_stub_herdr "$dir"
    log="$dir/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_AGENT_GET_FAIL=1 run_sut "$dir" watch NWM-99) && rc=0 || rc=$?

    assert_eq "W2 exit code" "1" "$rc"
    assert_contains "W2 error names the missing agent" "$out" "no herdr agent named 'nwm-99'"
    assert_eq "W2 never calls agent wait" "0" "$(call_count "$log" "agent wait")"
}

# W3 — `agent wait` fails: surfaced, not a silent empty print.
scenario_watch_wait_fails() {
    local dir log out rc
    dir=$(mktemp -d) || { echo "FAIL: W3 setup" >&2; FAIL=1; return; }
    install_stub_herdr "$dir"
    log="$dir/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_AGENT_GET_JSON="$AGENT_GET_JSON" \
        STUB_AGENT_WAIT_FAIL=1 run_sut "$dir" watch NWM-48 --timeout 5000) && rc=0 || rc=$?

    assert_eq "W3 exit code" "1" "$rc"
    assert_contains "W3 error names the failed wait" "$out" "agent wait"
}

# S0 — happy path: the agent's workspace_id is used for `workspace close`.
scenario_stop_happy() {
    local dir log out rc
    dir=$(mktemp -d) || { echo "FAIL: S0 setup" >&2; FAIL=1; return; }
    install_stub_herdr "$dir"
    log="$dir/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_AGENT_GET_JSON="$AGENT_GET_JSON" \
        STUB_WORKSPACE_CLOSE_JSON="$WORKSPACE_CLOSE_JSON" run_sut "$dir" stop NWM-48) && rc=0 || rc=$?

    assert_eq "S0 exit code" "0" "$rc"
    assert_eq "S0 workspace close called with the agent's workspace_id" "1" \
        "$(call_count "$log" "workspace close w2T$")"
    assert_contains "S0 output carries close JSON" "$out" '"type":"ok"'
}

# S1 — no workspace_id: exit 2, never calls close. No fixture exists for the
# paneless case, so `stop` must refuse rather than guess at `pane close`.
scenario_stop_no_workspace_id() {
    local dir log out rc noworkspace_json
    dir=$(mktemp -d) || { echo "FAIL: S1 setup" >&2; FAIL=1; return; }
    install_stub_herdr "$dir"
    log="$dir/herdr.log"; : > "$log"
    noworkspace_json='{"id":"cli:agent:get","result":{"agent":{"pane_id":"w9:p1","name":"nwm-48"},"type":"agent_info"}}'

    out=$(STUB_HERDR_LOG="$log" STUB_AGENT_GET_JSON="$noworkspace_json" \
        run_sut "$dir" stop NWM-48) && rc=0 || rc=$?

    assert_eq "S1 exit code is 2 (stop2, not a plain check failure)" "2" "$rc"
    assert_contains "S1 error names the unrecorded paneless case" "$out" "no workspace_id"
    assert_eq "S1 never calls a close verb" "0" "$(call_count "$log" "close")"
}

# S2 — ticket has no running agent: dies without calling close at all.
scenario_stop_no_agent() {
    local dir log out rc
    dir=$(mktemp -d) || { echo "FAIL: S2 setup" >&2; FAIL=1; return; }
    install_stub_herdr "$dir"
    log="$dir/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_AGENT_GET_FAIL=1 run_sut "$dir" stop NWM-99) && rc=0 || rc=$?

    assert_eq "S2 exit code" "1" "$rc"
    assert_contains "S2 error names the missing agent" "$out" "no herdr agent named 'nwm-99'"
    assert_eq "S2 never calls a close verb" "0" "$(call_count "$log" "close")"
}

# S3 — `workspace close` itself fails: surfaced, not swallowed.
scenario_stop_close_fails() {
    local dir log out rc
    dir=$(mktemp -d) || { echo "FAIL: S3 setup" >&2; FAIL=1; return; }
    install_stub_herdr "$dir"
    log="$dir/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_AGENT_GET_JSON="$AGENT_GET_JSON" \
        STUB_WORKSPACE_CLOSE_FAIL=1 run_sut "$dir" stop NWM-48) && rc=0 || rc=$?

    assert_eq "S3 exit code" "1" "$rc"
    assert_contains "S3 error names the failed close" "$out" "workspace close"
}

scenario_usage() {
    local out rc
    out=$("$SUT" watch 2>&1) && rc=0 || rc=$?
    assert_eq "usage: watch with no ticket exits 1" "1" "$rc"
    assert_contains "usage: watch with no ticket names usage" "$out" "usage: provider.sh watch"

    out=$("$SUT" stop 2>&1) && rc=0 || rc=$?
    assert_eq "usage: stop with no ticket exits 1" "1" "$rc"
    assert_contains "usage: stop with no ticket names usage" "$out" "usage: provider.sh stop"
}

scenario_watch_happy
scenario_watch_forwards_flags
scenario_watch_no_agent
scenario_watch_wait_fails
scenario_stop_happy
scenario_stop_no_workspace_id
scenario_stop_no_agent
scenario_stop_close_fails
scenario_usage

if [ "$FAIL" = 0 ]; then
    echo "OK: all provider.sh watch/stop assertions passed"
    exit 0
else
    echo "FAILURES ABOVE" >&2
    exit 1
fi
