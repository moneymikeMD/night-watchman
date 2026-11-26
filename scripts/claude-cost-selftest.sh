#!/bin/bash
#
# Selftest for claude-cost.py. Exercises the ledger's own invariants
# against a scratch TSV file: header creation, duplicate-wave refusal,
# stale-schema refusal, the crash-mid-append (missing trailing newline)
# repair-hint path, --dry-run writing nothing, compare's delta/
# direction math, and review's append-then-report in one command.
#
# Usage: scripts/claude-cost-selftest.sh [path-to-claude-cost.py]
# Defaults to the sibling scripts/claude-cost.py.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_COST="${1:-$HERE/claude-cost.py}"
[ -r "$CLAUDE_COST" ] || { echo "cannot read $CLAUDE_COST" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

run() { python3 "$CLAUDE_COST" "$@"; }

# ---- test 1: --dry-run prints the row but writes nothing.
LEDGER="$WORK/dryrun.tsv"
OUT=$(run append --ledger "$LEDGER" --wave test --cost 1.23 --turns 10 --dry-run)
if [ ! -e "$LEDGER" ] && printf '%s\n' "$OUT" | grep -q $'test\t10\t1.2300'; then
    ok "dry-run prints the row and writes nothing"
else
    bad "dry-run should print the row without creating $LEDGER (got: $OUT)"
fi

# ---- test 2: a real append creates the ledger with header + row.
LEDGER="$WORK/ledger.tsv"
run append --ledger "$LEDGER" --wave wave-1 --cost 12.5 --turns 100 --notes "baseline" >/dev/null
if [ -f "$LEDGER" ] && [ "$(wc -l <"$LEDGER" | tr -d ' ')" = "2" ]; then
    ok "append creates a 2-line ledger (header + row)"
else
    bad "expected a 2-line ledger after first append"
fi

# ---- test 3: appending the same wave twice is refused.
if run append --ledger "$LEDGER" --wave wave-1 --cost 1 --turns 1 >/dev/null 2>"$WORK/err"; then
    bad "duplicate wave should have been refused"
else
    if grep -q "already has a row for wave 'wave-1'" "$WORK/err"; then
        ok "duplicate wave is refused with a clear message"
    else
        bad "duplicate wave refusal message missing expected text"
    fi
fi

# ---- test 4: a second, later wave appends cleanly.
run append --ledger "$LEDGER" --wave wave-2 --cost 25.0 --turns 150 --notes "adopted: cut subagent fanout" >/dev/null
if [ "$(wc -l <"$LEDGER" | tr -d ' ')" = "3" ]; then
    ok "second append grows the ledger to 3 lines"
else
    bad "expected a 3-line ledger after second append"
fi

# ---- test 5: a stale/mismatched header is refused, not silently appended to.
STALE="$WORK/stale.tsv"
printf 'wave\tcost\n' > "$STALE"
if run append --ledger "$STALE" --wave x --cost 1 --turns 1 >/dev/null 2>"$WORK/err"; then
    bad "stale header should have been refused"
else
    if grep -q "unexpected header line" "$WORK/err"; then
        ok "stale/mismatched header is refused, not silently appended to"
    else
        bad "stale header refusal message missing expected text"
    fi
fi

# ---- test 5b: the actual pre-NWM-119 6-column header (not a generic
# mismatch) is refused the same way, so an old real ledger is never
# silently widened instead of migrated.
OLDREAL="$WORK/old-real-header.tsv"
printf 'date\twave\tturns\tcost_usd\tmodel_mix\tnotes\n' > "$OLDREAL"
if run append --ledger "$OLDREAL" --wave x --cost 1 --turns 1 >/dev/null 2>"$WORK/err"; then
    bad "old real 6-column header should have been refused"
else
    if grep -q "unexpected header line" "$WORK/err"; then
        ok "old real 6-column header is refused, not silently widened"
    else
        bad "old real header refusal message missing expected text"
    fi
fi

# ---- test 6: a ledger truncated mid-append (no trailing newline) is
# refused with a repair hint naming the line number, not silently parsed.
TRUNCATED="$WORK/truncated.tsv"
printf 'date\twave\tturns\tcost_usd\tmodel_mix\tnotes\n2026-09-12\twave-1\t10\t1.0000\t-\t-' > "$TRUNCATED"
if run list --ledger "$TRUNCATED" >/dev/null 2>"$WORK/err"; then
    bad "truncated ledger (no trailing newline) should have been refused"
else
    if grep -q "truncated (no trailing newline)" "$WORK/err"; then
        ok "truncated ledger is refused with a repair hint"
    else
        bad "truncated-ledger refusal message missing expected text"
    fi
fi

# ---- test 7: compare reports direction correctly (up beyond +-5%, flat
# within it) between the two real rows appended above (wave-1 -> wave-2:
# cost 12.5 -> 25.0 is +100%, comfortably "up").
OUT=$(run compare --ledger "$LEDGER" --wave wave-2 --format tsv)
if printf '%s\n' "$OUT" | awk -F'\t' '$1 == "cost_usd" { print $6 }' | grep -q '^up$'; then
    ok "compare flags a >5% cost increase as 'up'"
else
    bad "compare should flag wave-1 -> wave-2 cost_usd as up (got: $OUT)"
fi

# ---- test 8: compare against the ledger's first row is refused (nothing
# earlier to compare against).
if run compare --ledger "$LEDGER" --wave wave-1 >/dev/null 2>"$WORK/err"; then
    bad "comparing the first row should have been refused"
else
    if grep -q "nothing to compare against" "$WORK/err"; then
        ok "comparing the ledger's first row is refused"
    else
        bad "first-row compare refusal message missing expected text"
    fi
fi

# ---- test 9: a --date containing a tab is refused, same as --wave/
# --notes/--model.
if run append --ledger "$WORK/dateled.tsv" --wave x --cost 1 --turns 1 \
    --date "$(printf '2026-09-12\tbad')" >/dev/null 2>"$WORK/err"; then
    bad "--date with a tab should have been refused"
else
    if grep -q "\-\-date must not contain a tab or newline" "$WORK/err"; then
        ok "--date with a tab is refused"
    else
        bad "--date tab refusal message missing expected text"
    fi
fi

# ---- test 10: each append also writes the same row to a sibling
# <ledger>.jsonl, one JSON object per line with the tsv header's field
# names, and a missing jsonl is created without touching existing tsv rows.
JSONL="$WORK/ledger.jsonl"
if [ -f "$JSONL" ] && [ "$(wc -l <"$JSONL" | tr -d ' ')" = "2" ]; then
    ok "append also wrote a 2-line sibling ledger.jsonl (created on first append)"
else
    bad "expected $JSONL to exist with 2 lines (one per append), got: $(cat "$JSONL" 2>&1)"
fi
JSONL_CHECK=$(python3 - "$JSONL" "$LEDGER" <<'PYEOF'
import json
import sys

jsonl_path, tsv_path = sys.argv[1], sys.argv[2]
with open(jsonl_path) as f:
    jsonl_rows = [json.loads(line) for line in f if line.strip()]
with open(tsv_path) as f:
    lines = [l.rstrip("\n") for l in f if l.strip()]
header = lines[0].split("\t")
tsv_rows = [dict(zip(header, l.split("\t"))) for l in lines[1:]]

if [r.get("wave") for r in jsonl_rows] != ["wave-1", "wave-2"]:
    print("bad waves: %r" % ([r.get("wave") for r in jsonl_rows],))
    sys.exit(1)
if set(jsonl_rows[0].keys()) != set(header):
    print("field names differ: jsonl=%r tsv-header=%r" % (sorted(jsonl_rows[0]), header))
    sys.exit(1)
if jsonl_rows != tsv_rows:
    print("jsonl rows do not match tsv rows: %r vs %r" % (jsonl_rows, tsv_rows))
    sys.exit(1)
print("ok")
PYEOF
)
if [ "$JSONL_CHECK" = "ok" ]; then
    ok "ledger.jsonl rows match ledger.tsv rows, same field names as the header"
else
    bad "ledger.jsonl/ledger.tsv mismatch: $JSONL_CHECK"
fi

# ---- test 11 (NWM-119): --orchestrator-effort defaults to UNVERIFIED
# when the caller does not pass one, never a guessed value.
run append --ledger "$WORK/unverified.tsv" --wave w --cost 1 --turns 1 \
    --orchestrator-model claude-opus-5 --orchestrator-turns 1 --orchestrator-cost 0.5 >/dev/null
ROW=$(tail -1 "$WORK/unverified.tsv")
if printf '%s\n' "$ROW" | awk -F'\t' '{ print $7 }' | grep -q '^UNVERIFIED$'; then
    ok "orchestrator_effort defaults to UNVERIFIED, not a guess"
else
    bad "expected orchestrator_effort column (7th) to be UNVERIFIED (got: $ROW)"
fi

# ---- test 12 (NWM-119): the orchestrator/worker split round-trips
# through append -> the on-disk row, columns 6-11.
run append --ledger "$WORK/split.tsv" --wave w1 --cost 10 --turns 40 \
    --orchestrator-model claude-fable-5-1 --orchestrator-effort high \
    --orchestrator-turns 15 --orchestrator-cost 6.5 \
    --worker-turns 25 --worker-cost 3.5 >/dev/null
ROW=$(tail -1 "$WORK/split.tsv")
EXPECTED=$'claude-fable-5-1\thigh\t15\t6.5000\t25\t3.5000'
if printf '%s\n' "$ROW" | awk -F'\t' '{ print $6"\t"$7"\t"$8"\t"$9"\t"$10"\t"$11 }' | grep -qF "$EXPECTED"; then
    ok "orchestrator/worker model, effort, turns and cost round-trip through append"
else
    bad "expected columns 6-11 to be $EXPECTED (got: $ROW)"
fi

# ---- test 13 (NWM-119): model-compare finds the most recent earlier row
# with a different orchestrator_model and says so plainly when none exists.
MCLEDGER="$WORK/modelcompare.tsv"
run append --ledger "$MCLEDGER" --wave m1 --cost 1 --turns 1 \
    --orchestrator-model claude-fable-5-1 --orchestrator-effort medium \
    --orchestrator-turns 1 --orchestrator-cost 1 >/dev/null
OUT=$(run model-compare --ledger "$MCLEDGER" --wave m1 2>&1)
if printf '%s\n' "$OUT" | grep -q "no EARLIER wave"; then
    ok "model-compare says plainly when only one orchestrator model has been measured"
else
    bad "expected an explicit no-earlier-model message (got: $OUT)"
fi

run append --ledger "$MCLEDGER" --wave m2 --cost 2 --turns 2 \
    --orchestrator-model claude-opus-5 --orchestrator-effort xhigh \
    --orchestrator-turns 2 --orchestrator-cost 2 >/dev/null
OUT=$(run model-compare --ledger "$MCLEDGER" --wave m2 --format tsv 2>&1)
if printf '%s\n' "$OUT" | grep -q "^m1	claude-fable-5-1" && printf '%s\n' "$OUT" | grep -q "^m2	claude-opus-5"; then
    ok "model-compare finds the most recent earlier row on a different orchestrator model"
else
    bad "expected m1/fable vs m2/opus rows in model-compare output (got: $OUT)"
fi

# ---- test 14 (NWM-245): review on an empty ledger appends and says there is nothing to compare.
RV="$WORK/review.tsv"
OUT=$(run review --ledger "$RV" --wave r1 --cost 10 --turns 100 --orchestrator-model opus 2>&1)
if [ "$(wc -l <"$RV" | tr -d ' ')" = "2" ] && printf '%s\n' "$OUT" | grep -q "is the first row" \
    && printf '%s\n' "$OUT" | grep -q "no EARLIER wave"; then
    ok "review appends the first row and reports nothing to compare"
else
    bad "expected a first-row review (got: $OUT)"
fi

# ---- test 15: review's spread flags a delta beyond every earlier adjacent pair.
run review --ledger "$RV" --wave r2 --cost 11 --turns 90 --orchestrator-model opus >/dev/null
run review --ledger "$RV" --wave r3 --cost 12 --turns 95 --orchestrator-model opus >/dev/null
OUT=$(run review --ledger "$RV" --wave r4 --cost 6 --turns 96 --orchestrator-model sonnet --format tsv 2>&1)
if printf '%s\n' "$OUT" | grep -q $'^cost_usd\t2\t9.55\t10.00\t50.00\tyes$' \
    && printf '%s\n' "$OUT" | grep -q $'^turns\t2\t7.78\t10.00\t1.05\tno$' \
    && printf '%s\n' "$OUT" | grep -q $'^cost_usd\t12.0000\t6.0000\t-6.0000\t-50.00\tdown$' \
    && printf '%s\n' "$OUT" | grep -q "^# model-compare: r3 (opus) -> r4 (sonnet)"; then
    ok "review prints compare, spread with outside_spread, and model-compare"
else
    bad "expected compare/spread/model-compare rows for r4 (got: $OUT)"
fi

# ---- test 16: review --dry-run reports against the held row and writes nothing.
BEFORE=$(cat "$RV")
OUT=$(run review --ledger "$RV" --wave r5 --cost 6 --turns 96 --dry-run --format tsv 2>&1)
if [ "$(cat "$RV")" = "$BEFORE" ] && printf '%s\n' "$OUT" | grep -q "^# compare: r4 -> r5"; then
    ok "review --dry-run reports and leaves the ledger untouched"
else
    bad "review --dry-run should not write (got: $OUT)"
fi

# ---- test 17: a ledger review cannot compare is not appended to.
BADRV="$WORK/review-bad.tsv"
run append --ledger "$BADRV" --wave b1 --cost 1 --turns 1 >/dev/null
sed -i.bak $'2s/\t1\t1.0000\t/\tx\t1.0000\t/' "$BADRV"
BEFORE=$(cat "$BADRV")
if run review --ledger "$BADRV" --wave b2 --cost 2 --turns 2 >/dev/null 2>"$WORK/err"; then
    bad "review over a non-numeric earlier row should fail"
elif [ "$(cat "$BADRV")" = "$BEFORE" ] && grep -q "non-numeric 'turns'" "$WORK/err"; then
    ok "review that cannot compare refuses before writing the row"
else
    bad "review wrote a row or gave the wrong error ($(cat "$WORK/err"))"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
