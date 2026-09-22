#!/bin/bash
#
# Assertions for guard-fs-writes-selftest.sh's own summary arithmetic (NWM-137).
#
# The script under test is a selftest, so this file is the selftest of a
# selftest. It exists because the summary line is the number a human or an
# agent reads to decide whether a mutation run proved anything, and that
# number was computed as $((N - FAIL)) where FAIL was a 0/1 flag: twenty
# failures reported as one.
#
# Two kinds of case, both driving the real code:
#
#   - synthetic: the pass()/fail() definitions and the summary block are
#     lifted OUT of the script under test by content anchor and spliced
#     around a known number of forced pass and fail calls. Exact counts,
#     no dependence on which guard assertion breaks, milliseconds per run.
#   - end-to-end: the script under test is run whole, clean and then with
#     two forced failures appended, and the reported numbers are checked
#     against its own clean-run total rather than against a literal. The
#     ticket's historical case ("2 killed out of 110 printed 109 passed")
#     is re-anchored this way, so adding an assertion cannot rot it.
#
# Usage: ./hooks/guard-fs-writes-selftest-selftest.sh [old-guard-fs-writes-selftest.sh]
# With the pre-NWM-137 revision as the argument, every summary assertion
# here fails, which is what makes a clean run mean something.
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

SUT="${1:-$HERE/guard-fs-writes-selftest.sh}"
[ -f "$SUT" ] || { echo "cannot find the selftest under test at $SUT" >&2; exit 1; }

FAIL=0
FAILED_NUMS=""
N=0
pass() { N=$((N + 1)); echo "PASS $N: $1"; }
fail() {
  N=$((N + 1)); echo "FAIL $N: $1" >&2
  FAIL=$((FAIL + 1))
  FAILED_NUMS="${FAILED_NUMS:+$FAILED_NUMS,}$N"
}

assert_eq() {
  desc="$1"; want="$2"; got="$3"
  if [ "$want" = "$got" ]; then
    pass "$desc (want '$want', got '$got')"
  else
    fail "$desc (want '$want', got '$got')"
  fi
}

WORK="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
# shellcheck disable=SC2329  # invoked indirectly by the EXIT trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"

# The script under test resolves both guard-fs-writes.sh and its recorded
# fixtures relative to its own directory, so a mutated copy has to run
# somewhere those still resolve. Symlinking the two neighbours into the
# scratch directory keeps every write inside it.
ln -s "$SUT_DIR/guard-fs-writes.sh" "$WORK/guard-fs-writes.sh" 2>/dev/null
ln -s "$SUT_DIR/fixtures" "$WORK/fixtures" 2>/dev/null
[ -e "$WORK/guard-fs-writes.sh" ] || { echo "no guard-fs-writes.sh beside $SUT" >&2; exit 1; }
[ -e "$WORK/fixtures" ] || { echo "no fixtures/ beside $SUT" >&2; exit 1; }

# The two anchors. Extraction that silently returned nothing would make every
# assertion below vacuous, so each is required to be non-empty before any
# case runs.
HEADER="$(awk '/^FAIL=0$/{f=1} /^assert_exit\(\) \{$/{f=0} f' "$SUT")"
SUMMARY="$(awk '/^echo "\$N assertion\(s\)/{f=1} f' "$SUT")"
[ -n "$HEADER" ] || { echo "no 'FAIL=0'..'assert_exit() {' block found in $SUT" >&2; exit 1; }
[ -n "$SUMMARY" ] || { echo "no summary block found in $SUT" >&2; exit 1; }

# Build a harness with $1 forced passes then $2 forced fails, run it, and
# leave stdout+stderr in $OUT and the exit code in $RC.
OUT=""
RC=0
run_synthetic() {
  np="$1"; nf="$2"
  h="$WORK/harness.sh"
  {
    echo '#!/bin/bash'
    echo 'set -uo pipefail'
    echo "$HEADER"
    i=0
    while [ "$i" -lt "$np" ]; do echo "pass \"synthetic pass\""; i=$((i + 1)); done
    i=0
    while [ "$i" -lt "$nf" ]; do echo "fail \"synthetic failure\""; i=$((i + 1)); done
    echo "$SUMMARY"
  } > "$h"
  chmod +x "$h"
  OUT="$("$h" 2>&1)"; RC=$?
}

summary_line() { printf '%s\n' "$OUT" | grep -E '^[0-9]+ assertion\(s\),' | tail -1; }
failing_line() { printf '%s\n' "$OUT" | grep -E '^failing assertion\(s\):' | tail -1; }

# --- synthetic: exact counts -------------------------------------------------

run_synthetic 10 0
assert_eq "a clean run reports every assertion passed and none failed" \
  "10 assertion(s), 10 passed, 0 failed" "$(summary_line)"
assert_eq "a clean run exits 0" "0" "$RC"
assert_eq "a clean run prints no failing-assertion list" "" "$(failing_line)"

run_synthetic 10 1
assert_eq "one failure reports 1 failed, not a flag that happens to equal 1" \
  "11 assertion(s), 10 passed, 1 failed" "$(summary_line)"
assert_eq "one failure exits non-zero" "1" "$RC"
assert_eq "one failure names the assertion number" \
  "failing assertion(s): 11" "$(failing_line)"

# The historical shape: two killed assertions used to print one short of the
# total, which reads as a near-clean run.
run_synthetic 10 2
assert_eq "two failures report 2 failed and 10 passed, not 11 passed" \
  "12 assertion(s), 10 passed, 2 failed" "$(summary_line)"
assert_eq "two failures exit non-zero" "1" "$RC"
assert_eq "two failures name both assertion numbers" \
  "failing assertion(s): 11,12" "$(failing_line)"

run_synthetic 20 5
assert_eq "five failures report 5 failed and 20 passed, not 24 passed" \
  "25 assertion(s), 20 passed, 5 failed" "$(summary_line)"
assert_eq "five failures exit non-zero" "1" "$RC"
assert_eq "five failures name all five assertion numbers" \
  "failing assertion(s): 21,22,23,24,25" "$(failing_line)"

# A run that is nothing but failures: the pass count must be 0, which is the
# case the old arithmetic got furthest wrong.
run_synthetic 0 4
assert_eq "an all-failing run reports 0 passed" \
  "4 assertion(s), 0 passed, 4 failed" "$(summary_line)"

# --- end-to-end against the real assertion body ------------------------------

CLEAN_OUT="$("$SUT" 2>&1)"; CLEAN_RC=$?
BASE_N="$(printf '%s\n' "$CLEAN_OUT" | grep -cE '^PASS [0-9]+:')"
assert_eq "the script under test passes clean, so the counts below mean something" "0" "$CLEAN_RC"
assert_eq "a clean whole-file run reports its own PASS-line count as the total and as passed" \
  "$BASE_N assertion(s), $BASE_N passed, 0 failed" \
  "$(printf '%s\n' "$CLEAN_OUT" | grep -E '^[0-9]+ assertion\(s\),' | tail -1)"

# Two forced failures appended to the real file, so the reported numbers are
# checked against the live total rather than a literal that ages.
MUT="$WORK/two-forced.sh"
awk '/^echo "\$N assertion\(s\)/ && !done { print "fail \"forced failure A\""; print "fail \"forced failure B\""; done=1 } { print }' \
  "$SUT" > "$MUT"
chmod +x "$MUT"
assert_eq "the two-failure mutation really added two fail calls" "2" \
  "$(( $(grep -c '^fail "forced failure' "$MUT") ))"

OUT="$("$MUT" 2>&1)"; RC=$?
assert_eq "two killed assertions in a whole-file run report 2 failed and the clean total passed" \
  "$((BASE_N + 2)) assertion(s), $BASE_N passed, 2 failed" "$(summary_line)"
assert_eq "a whole-file run with two failures exits non-zero" "1" "$RC"
assert_eq "the reported failed count equals the number of FAIL lines actually printed" \
  "2" "$(printf '%s\n' "$OUT" | grep -cE '^FAIL [0-9]+:')"

echo
echo "$N assertion(s), $((N - FAIL)) passed, $FAIL failed" >&2
if [ "$FAIL" -ne 0 ]; then
  echo "failing assertion(s): $FAILED_NUMS" >&2
  echo "guard-fs-writes-selftest-selftest.sh: FAILED" >&2
  exit 1
fi
echo "guard-fs-writes-selftest-selftest.sh: all assertions passed" >&2
exit 0
