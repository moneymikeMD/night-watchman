#!/bin/bash
#
# Selftest for claude-cost.py. Exercises the ledger's own invariants
# against a scratch TSV file: header creation, duplicate-wave refusal,
# stale-schema refusal, the crash-mid-append (missing trailing newline)
# repair-hint path, --dry-run writing nothing, and compare's delta/
# direction math.
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

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
