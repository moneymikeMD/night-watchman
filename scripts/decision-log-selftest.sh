#!/bin/bash
#
# Selftest for decision-log.sh. Runs entirely against a scratch TSV under
# $TMPDIR — never touches this repo's own .night-watchman/ directory.
# Structurally offline: no network calls anywhere in this script or the
# one it drives.
#
# Usage: scripts/decision-log-selftest.sh [path-to-decision-log.sh]
# Defaults to the sibling scripts/decision-log.sh.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${1:-$HERE/decision-log.sh}"
[ -x "$LOG" ] || { echo "cannot execute $LOG" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TRAIL="$WORK/wave-trail.tsv"

# ---- test 1: first call writes the header, then the row.
"$LOG" --file "$TRAIL" --phase orient --decision "picked X" --why "faster" \
    --evidence "NWM-77" --result "open" >/dev/null
if [ "$(head -n1 "$TRAIL")" = "$(printf 'ts\tphase\tdecision\twhy\tevidence\tresult')" ]; then
    ok "header written on first use"
else
    bad "expected header row on line 1 (see $TRAIL)"
fi
if [ "$(wc -l <"$TRAIL" | tr -d ' ')" -eq 2 ]; then
    ok "first call writes exactly header + one row"
else
    bad "expected 2 lines after first call, got $(wc -l <"$TRAIL")"
fi

# ---- test 2: columns are ts/phase/decision/why/evidence/result, in order.
ROW2="$(sed -n '2p' "$TRAIL")"
FIELDS=$(printf '%s' "$ROW2" | awk -F'\t' '{print NF}')
if [ "$FIELDS" -eq 6 ]; then
    ok "row has 6 tab-separated fields"
else
    bad "expected 6 fields, got $FIELDS (see: $ROW2)"
fi
PHASE_FIELD="$(printf '%s' "$ROW2" | awk -F'\t' '{print $2}')"
DECISION_FIELD="$(printf '%s' "$ROW2" | awk -F'\t' '{print $3}')"
WHY_FIELD="$(printf '%s' "$ROW2" | awk -F'\t' '{print $4}')"
EVIDENCE_FIELD="$(printf '%s' "$ROW2" | awk -F'\t' '{print $5}')"
RESULT_FIELD="$(printf '%s' "$ROW2" | awk -F'\t' '{print $6}')"
if [ "$PHASE_FIELD" = "orient" ] && [ "$DECISION_FIELD" = "picked X" ] \
    && [ "$WHY_FIELD" = "faster" ] && [ "$EVIDENCE_FIELD" = "NWM-77" ] \
    && [ "$RESULT_FIELD" = "open" ]; then
    ok "columns land in ts/phase/decision/why/evidence/result order"
else
    bad "column order/content mismatch (see: $ROW2)"
fi

# ---- test 3: a second call does not rewrite the header.
"$LOG" --file "$TRAIL" --phase dispatch --decision "picked Y" --why "" \
    --evidence "" --result "" >/dev/null
HEADER_COUNT="$(grep -c "^ts	phase	decision" "$TRAIL")"
if [ "$HEADER_COUNT" -eq 1 ]; then
    ok "header is written only on first use, not on later calls"
else
    bad "expected exactly one header line, got $HEADER_COUNT"
fi

# ---- test 4: embedded tabs and newlines in a cell are stripped.
"$LOG" --file "$TRAIL" --phase land --decision "$(printf 'multi\tline\nvalue')" \
    --why x --evidence y --result z >/dev/null
LAST_ROW="$(tail -n1 "$TRAIL")"
LAST_FIELDS="$(printf '%s' "$LAST_ROW" | awk -F'\t' '{print NF}')"
if [ "$LAST_FIELDS" -eq 6 ] && [ "$(printf '%s' "$LAST_ROW" | wc -l | tr -d ' ')" -eq 0 ]; then
    ok "embedded tabs/newlines in a cell are stripped, row stays single-line"
else
    bad "embedded tab/newline should collapse to spaces, not break the row (see: $LAST_ROW)"
fi

# ---- test 5: a leading = + - @ character gets a quote prefix.
for lead in '=cmd' '+cmd' '-cmd' '@cmd'; do
    "$LOG" --file "$TRAIL" --phase land --decision "$lead" --why x --evidence y --result z >/dev/null
    LAST="$(tail -n1 "$TRAIL" | awk -F'\t' '{print $3}')"
    if [ "$LAST" = "'$lead" ]; then
        ok "leading '$lead' is prefixed with a quote"
    else
        bad "expected '$lead to be quote-prefixed, got: $LAST"
    fi
done

# ---- test 6: missing --phase or --decision dies (nonzero exit), and
# writes nothing to the file.
LINES_BEFORE="$(wc -l <"$TRAIL" | tr -d ' ')"
set +e
"$LOG" --file "$TRAIL" --decision "no phase" >/dev/null 2>"$WORK/err-nophase"
STATUS_NOPHASE=$?
set -e
if [ "$STATUS_NOPHASE" -ne 0 ] && grep -q "phase" "$WORK/err-nophase"; then
    ok "missing --phase dies with a message naming it"
else
    bad "missing --phase should die naming the problem (status=$STATUS_NOPHASE, see $WORK/err-nophase)"
fi

set +e
"$LOG" --file "$TRAIL" --phase orient >/dev/null 2>"$WORK/err-nodecision"
STATUS_NODECISION=$?
set -e
if [ "$STATUS_NODECISION" -ne 0 ] && grep -q "decision" "$WORK/err-nodecision"; then
    ok "missing --decision dies with a message naming it"
else
    bad "missing --decision should die naming the problem (status=$STATUS_NODECISION, see $WORK/err-nodecision)"
fi

LINES_AFTER="$(wc -l <"$TRAIL" | tr -d ' ')"
if [ "$LINES_AFTER" -eq "$LINES_BEFORE" ]; then
    ok "a dying call writes nothing to the file"
else
    bad "file line count changed on a dying call ($LINES_BEFORE -> $LINES_AFTER)"
fi

# ---- test 7: --file defaults to .night-watchman/wave-trail.tsv under
# the repo root (git rev-parse --show-toplevel), not this repo's own.
DEFAULT_REPO="$WORK/fake-repo"
mkdir -p "$DEFAULT_REPO"
(cd "$DEFAULT_REPO" && git init -q)
(cd "$DEFAULT_REPO" && "$LOG" --phase orient --decision "default path" --why x --evidence y --result z >/dev/null)
if [ -f "$DEFAULT_REPO/.night-watchman/wave-trail.tsv" ]; then
    ok "--file defaults to .night-watchman/wave-trail.tsv under the repo root"
else
    bad "expected $DEFAULT_REPO/.night-watchman/wave-trail.tsv to exist"
fi

# ---- test 8: --dry-run prints the row it would append but writes nothing.
LINES_BEFORE_DRY="$(wc -l <"$TRAIL" | tr -d ' ')"
DRY_OUT="$("$LOG" --file "$TRAIL" --dry-run --phase land --decision "test" --why "x" --evidence "y" --result ok)"
LINES_AFTER_DRY="$(wc -l <"$TRAIL" | tr -d ' ')"
if [ "$LINES_AFTER_DRY" -eq "$LINES_BEFORE_DRY" ]; then
    ok "--dry-run writes nothing to the file"
else
    bad "--dry-run should not change the file line count ($LINES_BEFORE_DRY -> $LINES_AFTER_DRY)"
fi
if printf '%s' "$DRY_OUT" | awk -F'\t' '{print NF}' | grep -q '^6$' \
    && printf '%s' "$DRY_OUT" | grep -q 'land' && printf '%s' "$DRY_OUT" | grep -q 'test'; then
    ok "--dry-run prints the 6-field row it would have appended"
else
    bad "--dry-run output should be the would-be row (got: $DRY_OUT)"
fi

echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
    echo "decision-log-selftest.sh: FAILED"
    exit 1
fi
echo "decision-log-selftest.sh: all assertions passed"
exit 0
