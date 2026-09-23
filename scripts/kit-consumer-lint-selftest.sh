#!/bin/bash
#
# Assertions for kit-consumer-lint.sh (NWM-173).
#
# Synthetic roots per case, built in a scratch directory: a lint is about text
# in files, so a fixture tree is the honest harness and no case touches the
# real repository except the one that deliberately runs against it.
#
# The case that proves the lint is worth having reverts NWM-171's fix in a
# COPY of the tree and requires the lint to name that file. Without it this
# would only test that the regexes match what they were written against.
#
# Usage: ./scripts/kit-consumer-lint-selftest.sh [path-to-kit-consumer-lint.sh]
# Offline: no network, no credential, nothing written outside the scratch dir.
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SUT="${1:-$HERE/kit-consumer-lint.sh}"
[ -x "$SUT" ] || { echo "cannot execute $SUT" >&2; exit 2; }

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
  if [ "$want" = "$got" ]; then pass "$desc (want '$want', got '$got')"
  else fail "$desc (want '$want', got '$got')"; fi
}

WORK="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
# shellcheck disable=SC2329  # invoked indirectly by the EXIT trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

OUT=""
RC=0

# mkroot NAME BODY — a synthetic root whose one consumer carries BODY.
mkroot() {
    local d="$WORK/$1"
    rm -rf "$d"
    mkdir -p "$d/scripts/lib" "$d/providers" "$d/hooks"
    cp "$REPO/scripts/lib/kit.sh" "$d/scripts/lib/kit.sh"
    { echo '#!/bin/bash'
      # shellcheck disable=SC2016  # written verbatim into the fixture, not expanded here
      echo '. "$(dirname "$0")/lib/kit.sh"'
      cat
    } > "$d/scripts/consumer.sh"
    chmod +x "$d/scripts/consumer.sh"
    printf '%s' "$d"
}
run_lint() { OUT="$("$SUT" --root "$1" 2>&1)"; RC=$?; }

# --- rule 1: a bare exec ------------------------------------------------------
run_lint "$(mkroot r1 <<'B'
exec /bin/echo hi
B
)"
assert_eq "a bare exec in a consumer exits non-zero" "1" "$RC"
case "$OUT" in
  *"scripts/consumer.sh:3"*) pass "and it names the file and line (scripts/consumer.sh:3)" ;;
  *) fail "and it names the file and line — got: $OUT" ;;
esac
case "$OUT" in *kit_exec*) pass "and names kit_exec as the fix" ;; *) fail "and names kit_exec as the fix" ;; esac

# --- rule 2: a raw EXIT trap AFTER the source --------------------------------
run_lint "$(mkroot r2 <<'B'
trap 'rm -rf /tmp/x' EXIT
B
)"
assert_eq "a raw 'trap ... EXIT' after sourcing kit.sh exits non-zero" "1" "$RC"
case "$OUT" in *kit_on_exit*) pass "and names kit_on_exit as the fix" ;; *) fail "and names kit_on_exit as the fix" ;; esac

# A trap BEFORE the source is the other hazard, not this one.
R2B="$WORK/r2b"
mkdir -p "$R2B/scripts/lib" "$R2B/providers" "$R2B/hooks"
cp "$REPO/scripts/lib/kit.sh" "$R2B/scripts/lib/kit.sh"
cat > "$R2B/scripts/consumer.sh" <<'B'
#!/bin/bash
trap 'rm -rf /tmp/x' EXIT
. "$(dirname "$0")/lib/kit.sh"
B
run_lint "$R2B"
assert_eq "a trap set BEFORE the source is not reported" "0" "$RC"

# --- kit.sh itself is never a consumer ---------------------------------------
# It contains `exec "$@"` inside kit_exec. The exemption is structural — it
# does not source itself — and this pins it against a later refactor.
run_lint "$(mkroot r3 <<'B'
echo fine
B
)"
assert_eq "a clean consumer passes" "0" "$RC"
case "$OUT" in
  *"lib/kit.sh"*) fail "kit.sh itself was reported: $OUT" ;;
  *) pass "kit.sh itself is never reported, though it contains exec \"\$@\"" ;;
esac
assert_eq "and the pass states how many consumers it checked, so it cannot pass vacuously" "1" \
  "$(printf '%s' "$OUT" | grep -c '1 kit.sh consumer(s) checked')"

# --- the escape hatch, and its required reason -------------------------------
run_lint "$(mkroot r4 <<'B'
# kit-lint: allow-exec this process is meant to be replaced
exec /bin/echo hi
B
)"
assert_eq "an exemption WITH a reason suppresses the violation" "0" "$RC"

run_lint "$(mkroot r5 <<'B'
# kit-lint: allow-exec
exec /bin/echo hi
B
)"
assert_eq "an exemption with NO reason does not suppress it" "1" "$RC"
case "$OUT" in
  *"no reason"*) pass "and the message says the reason is what is missing" ;;
  *) fail "and the message says the reason is what is missing — got: $OUT" ;;
esac

# --- a root with no consumer at all cannot pass ------------------------------
EMPTY="$WORK/empty"
mkdir -p "$EMPTY/scripts" "$EMPTY/providers" "$EMPTY/hooks"
run_lint "$EMPTY"
assert_eq "a root with no kit.sh consumer is exit 2, not a silent pass" "2" "$RC"

# --- the real repository, and NWM-171 reverted in a copy of it ---------------
run_lint "$REPO"
assert_eq "the real repository passes" "0" "$RC"
REAL_COUNT="$(printf '%s' "$OUT" | sed -n 's/.*OK, \([0-9]*\) kit.sh.*/\1/p')"
if [ -n "$REAL_COUNT" ] && [ "$REAL_COUNT" -gt 20 ]; then
    pass "and it checked a real number of consumers ($REAL_COUNT > 20)"
else
    fail "and it checked a real number of consumers (got '$REAL_COUNT', want > 20)"
fi

# The case this lint exists for: NWM-171, reverted in a copy.
REV="$WORK/reverted"
mkdir -p "$REV"
cp -R "$REPO/scripts" "$REPO/providers" "$REPO/hooks" "$REV/" 2>/dev/null
if [ -f "$REV/providers/lib/provider.sh" ]; then
    # shellcheck disable=SC2016  # a sed script, expanded by nothing
    sed 's/kit_exec "\$entry" "\$verb" "\$@"/exec "$entry" "$verb" "$@"/' \
        "$REPO/providers/lib/provider.sh" > "$REV/providers/lib/provider.sh"
fi
run_lint "$REV"
assert_eq "reverting NWM-171's fix makes the lint fail" "1" "$RC"
case "$OUT" in
  *"providers/lib/provider.sh"*) pass "and it names providers/lib/provider.sh, the file that leaked 706 files" ;;
  *) fail "and it names providers/lib/provider.sh — got: $OUT" ;;
esac

echo
echo "$N assertion(s), $((N - FAIL)) passed, $FAIL failed" >&2
if [ "$FAIL" -ne 0 ]; then
  echo "failing assertion(s): $FAILED_NUMS" >&2
  echo "kit-consumer-lint-selftest.sh: FAILED" >&2
  exit 1
fi
echo "kit-consumer-lint-selftest.sh: all assertions passed" >&2
exit 0
