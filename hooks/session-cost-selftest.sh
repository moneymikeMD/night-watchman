#!/bin/bash
#
# Assertions for session-cost.sh.
#
# Structurally offline: scans a hand-authored fixture transcript under
# hooks/fixtures/session-cost/ via NW_COST_PROJECT_SLUG/NW_COST_PROJECTS_DIR
# overrides (never the real ~/.claude/projects tree) and a throwaway
# working directory this script creates and destroys itself (never the
# real repo). Asserts:
#
#   - a real session/ledger: exit 0, correct ledger row, correct
#     last-session-cost.txt content
#   - a duplicate wave: exit 0, ledger unchanged (no-op, not an error)
#   - no ledger file present: exit 0, no state-file regression, ledger
#     step just skipped
#   - no session_id in stdin: exit 0, nothing written
#   - empty stdin: exit 0, nothing written
#   - scanner missing (SESSION_COST_SCANNER_MISSING): exit 0
#   - cwd in a repo subdirectory: state file lands at the repo root
#   - non-git cwd: state file goes to $CLAUDE_PROJECT_DIR, or nowhere
#
# Per this plugin's own name-the-oracle rule (see script-reviewer.md): a
# deliberately broken copy of session-cost.sh (e.g. `exit 0` at the bottom
# changed to `exit 1`, or the TOTAL-row skip removed) is a manual
# demonstration this selftest FAILs on, not something this script checks
# automatically — a selftest never observed failing has only been
# exercised, not tested.
#
# Usage: ./hooks/session-cost-selftest.sh
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

HOOK="${SESSION_COST_SH:-$HERE/session-cost.sh}"
[ -f "$HOOK" ] || { echo "cannot find session-cost.sh at $HOOK" >&2; exit 1; }

FIXTURES="$HERE/fixtures/session-cost"
[ -d "$FIXTURES" ] || { echo "cannot find fixtures dir $FIXTURES" >&2; exit 1; }

FAIL=0
N=0
pass() { N=$((N + 1)); echo "PASS $N: $1"; }
fail() { N=$((N + 1)); echo "FAIL $N: $1" >&2; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/session-cost-selftest.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo" "$WORK/nogit" "$WORK/proj"
unset GIT_DIR GIT_WORK_TREE CLAUDE_PROJECT_DIR
git -C "$WORK/repo" init -q || { echo "git init failed" >&2; exit 1; }

run_hook() {
    local stdin_json="$1" ledger="${2:-}"
    NW_COST_PROJECT_SLUG="-Users-fixture-repoC" \
    NW_COST_PROJECTS_DIR="$FIXTURES/projects" \
    NW_COST_LEDGER="$ledger" \
    bash "$HOOK" <<<"$stdin_json"
}

FIXTURE_STDIN="$(cat "$FIXTURES/stdin.json")"

LEDGER1="$WORK/ledger1.tsv"
STATE1="$WORK/repo/.night-watchman/last-session-cost.txt"
cp "$HERE/../templates/cost-ledger.tsv" "$LEDGER1" 2>/dev/null \
    || printf 'date\twave\tturns\tcost_usd\tmodel_mix\torchestrator_model\torchestrator_effort\torchestrator_turns\torchestrator_usd\tworker_turns\tworker_usd\tnotes\n' > "$LEDGER1"
STDIN1="${FIXTURE_STDIN/\/Users\/fixture\/repoC/$WORK\/repo}"

run_hook "$STDIN1" "$LEDGER1" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ]; then pass "test1: exit 0 on a normal run"; else fail "test1: exit 0 on a normal run (got $STATUS)"; fi

if grep -q "	sess-c" "$LEDGER1" 2>/dev/null || grep -q "-sess-c	" "$LEDGER1" 2>/dev/null; then
    pass "test1: ledger gained a row for this session"
else
    fail "test1: expected a ledger row naming sess-c (got: $(cat "$LEDGER1" 2>&1))"
fi
if grep -q "^cost: \$0.0068, 3 turns$" "$STATE1" 2>/dev/null; then
    pass "test1: last-session-cost.txt has the exact ledger-comment line"
else
    fail "test1: expected 'cost: \$0.0068, 3 turns' in $STATE1 (got: $(cat "$STATE1" 2>&1))"
fi

# NWM-119: the appended row also carries the orchestrator model/effort and
# the orchestrator/worker split, read from the transcript, not typed by hand.
ROW1="$(grep "sess-c" "$LEDGER1" 2>/dev/null | tail -1)"
if printf '%s\n' "$ROW1" | awk -F'\t' '{ print $6"\t"$7 }' | grep -qF "$(printf 'claude-sonnet-5\tmedium')"; then
    pass "test1: ledger row carries orchestrator_model/orchestrator_effort from the transcript"
else
    fail "test1: expected orchestrator_model/effort columns claude-sonnet-5/medium (got: $ROW1)"
fi

LINES_BEFORE=$(wc -l < "$LEDGER1")
run_hook "$STDIN1" "$LEDGER1" >/dev/null 2>&1
STATUS2=$?
LINES_AFTER=$(wc -l < "$LEDGER1")
if [ "$STATUS2" -eq 0 ]; then pass "test2: exit 0 on a duplicate-wave run"; else fail "test2: exit 0 on a duplicate-wave run (got $STATUS2)"; fi
if [ "$LINES_BEFORE" -eq "$LINES_AFTER" ]; then
    pass "test2: duplicate wave did not append a second row (no-op, not an error)"
else
    fail "test2: duplicate wave changed the ledger line count ($LINES_BEFORE -> $LINES_AFTER)"
fi

LEDGER3="$WORK/does-not-exist.tsv"
rm -rf "$WORK/repo/.night-watchman"
run_hook "$STDIN1" "$LEDGER3" >/dev/null 2>&1
STATUS3=$?
if [ "$STATUS3" -eq 0 ]; then pass "test3: exit 0 with no ledger configured"; else fail "test3: exit 0 with no ledger configured (got $STATUS3)"; fi
if [ ! -f "$LEDGER3" ]; then
    pass "test3: a missing ledger file is never created"
else
    fail "test3: session-cost.sh created a ledger file that wasn't there"
fi
if grep -q "^cost: \$0.0068, 3 turns$" "$STATE1" 2>/dev/null; then
    pass "test3: state file is still written when only the ledger step is skipped"
else
    fail "test3: expected state file even with no ledger configured"
fi

rm -rf "$WORK/repo/.night-watchman"
BAD_STDIN="{\"cwd\":\"$WORK/repo\"}"
run_hook "$BAD_STDIN" "$LEDGER3" >/dev/null
STATUS4=$?
if [ "$STATUS4" -eq 0 ]; then pass "test4: exit 0 with no session_id"; else fail "test4: exit 0 with no session_id (got $STATUS4)"; fi
if [ ! -f "$STATE1" ]; then
    pass "test4: no state file written without a session_id"
else
    fail "test4: a state file was written despite no session_id"
fi

: | NW_COST_PROJECT_SLUG="-Users-fixture-repoC" NW_COST_PROJECTS_DIR="$FIXTURES/projects" NW_COST_LEDGER="$LEDGER3" bash "$HOOK"
STATUS5=$?
if [ "$STATUS5" -eq 0 ]; then pass "test5: exit 0 on empty stdin"; else fail "test5: exit 0 on empty stdin (got $STATUS5)"; fi

FAKE_ROOT="$WORK/fake-plugin-root"
mkdir -p "$FAKE_ROOT/hooks" "$FAKE_ROOT/scripts"
cp "$HOOK" "$FAKE_ROOT/hooks/session-cost.sh"
# deliberately no claude-cost-scan.py under $FAKE_ROOT/scripts
rm -rf "$WORK/repo/.night-watchman"
run_hook "$STDIN1" "$LEDGER3" 2>/dev/null # sanity: real root still works
OUT6="$(NW_COST_PROJECT_SLUG="-Users-fixture-repoC" NW_COST_PROJECTS_DIR="$FIXTURES/projects" NW_COST_LEDGER="$LEDGER3" bash "$FAKE_ROOT/hooks/session-cost.sh" <<<"$STDIN1" 2>&1)"
STATUS6=$?
if [ "$STATUS6" -eq 0 ]; then pass "test6: exit 0 when the scanner is missing"; else fail "test6: exit 0 when the scanner is missing (got $STATUS6)"; fi
if echo "$OUT6" | grep -q "scanner not found"; then
    pass "test6: warns on stderr when the scanner is missing"
else
    fail "test6: expected a 'scanner not found' warning (got: $OUT6)"
fi

mkdir -p "$WORK/repo/src/deep"
rm -rf "$WORK/repo/.night-watchman"
STDIN7="${FIXTURE_STDIN/\/Users\/fixture\/repoC/$WORK\/repo\/src\/deep}"
run_hook "$STDIN7" "$LEDGER3" >/dev/null 2>&1
if grep -q "^cost: \$0.0068, 3 turns$" "$STATE1" 2>/dev/null; then
    pass "test7: a subdirectory cwd writes the state file at the repo root"
else
    fail "test7: expected $STATE1 from cwd=repo/src/deep"
fi
if [ ! -e "$WORK/repo/src/deep/.night-watchman" ]; then
    pass "test7: no .night-watchman/ created inside the subdirectory"
else
    fail "test7: a stray .night-watchman/ was created under repo/src/deep"
fi

STDIN8="${FIXTURE_STDIN/\/Users\/fixture\/repoC/$WORK\/nogit}"
run_hook "$STDIN8" "$LEDGER3" >/dev/null 2>&1
STATUS8=$?
if [ "$STATUS8" -eq 0 ]; then pass "test8: exit 0 for a non-git cwd"; else fail "test8: exit 0 for a non-git cwd (got $STATUS8)"; fi
if [ ! -e "$WORK/nogit/.night-watchman" ]; then
    pass "test8: no .night-watchman/ created in a non-git cwd without CLAUDE_PROJECT_DIR"
else
    fail "test8: a stray .night-watchman/ was created in the non-git cwd"
fi

CLAUDE_PROJECT_DIR="$WORK/proj" run_hook "$STDIN8" "$LEDGER3" >/dev/null 2>&1
if grep -q "^cost: \$0.0068, 3 turns$" "$WORK/proj/.night-watchman/last-session-cost.txt" 2>/dev/null \
    && [ ! -e "$WORK/nogit/.night-watchman" ]; then
    pass "test9: a non-git cwd falls back to CLAUDE_PROJECT_DIR"
else
    fail "test9: expected the state file under CLAUDE_PROJECT_DIR, not the non-git cwd"
fi

echo
echo "$((N - FAIL))/$N assertions passed"
exit "$FAIL"
