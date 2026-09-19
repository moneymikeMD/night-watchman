#!/bin/bash
#
# Selftest for bash-family-report.py. Runs entirely against fixture
# transcripts under scripts/fixtures/bash-family/ — structurally offline,
# never reads the real ~/.claude/projects tree. Exercises the family
# normalisation rules (cd/VAR= stripping, script-path collapsing, heredoc
# folding, plain grep-shaped fragmentation), --since filtering, --top,
# and both --format renderers.
#
# Usage: scripts/bash-family-report-selftest.sh [path-to-bash-family-report.py]
# Defaults to the sibling scripts/bash-family-report.py.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPORT="${1:-$HERE/bash-family-report.py}"
[ -r "$REPORT" ] || { echo "cannot read $REPORT" >&2; exit 2; }

FIXTURES="$HERE/fixtures/bash-family"
[ -d "$FIXTURES" ] || { echo "cannot read fixtures dir $FIXTURES" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

run() { python3 "$REPORT" --projects-dir "$FIXTURES" "$@"; }

OUT=$(run --format text)

# ---- test 1: cd/&& prefix and script-path collapse into "exe verb".
if printf '%s\n' "$OUT" | grep -q '^jira-api.sh raw	3	'; then
    ok "cd-prefix and ./scripts/ path collapse into 'jira-api.sh raw', counted 3"
else
    bad "expected 'jira-api.sh raw' at count 3 (got: $OUT)"
fi

# ---- test 2: an executable already on PATH (no script path to collapse)
# still families as "exe verb", and the corpus is aggregated across both
# repos and the subagent transcript (3 = 2 in sess-1 + 1 in the subagent).
if printf '%s\n' "$OUT" | grep -q '^memorygraph recall	3	'; then
    ok "'memorygraph recall' aggregates across repos and the subagent file, count 3"
else
    bad "expected 'memorygraph recall' at count 3 (got: $OUT)"
fi

# ---- test 3: a leading VAR=value assignment strips the same way cd does.
if printf '%s\n' "$OUT" | grep -q '^lab-ssh.sh exec	2	'; then
    ok "leading FOO=bar strips, 'lab-ssh.sh exec' counted 2"
else
    bad "expected 'lab-ssh.sh exec' at count 2 (got: $OUT)"
fi

# ---- test 4: heredoc forms fold to their two named families, not by body.
if printf '%s\n' "$OUT" | grep -q '^python3 heredoc	1	'; then
    ok "a python3 <<EOF heredoc folds to 'python3 heredoc'"
else
    bad "expected 'python3 heredoc' (got: $OUT)"
fi
if printf '%s\n' "$OUT" | grep -q '^cat > heredoc	1	'; then
    ok "a cat > file <<EOF heredoc folds to 'cat > heredoc'"
else
    bad "expected 'cat > heredoc' (got: $OUT)"
fi

# ---- test 5: with no special-casing, two grep calls with different
# patterns self-select into two distinct, low-count families rather than
# one dominant "grep" bucket.
GREP_FAMILIES=$(printf '%s\n' "$OUT" | grep -c '^grep ' || true)
if [ "$GREP_FAMILIES" -eq 2 ]; then
    ok "grep calls fragment by first argument instead of forming one bucket"
else
    bad "expected 2 distinct grep families, got $GREP_FAMILIES (out: $OUT)"
fi

# ---- test 6: --since excludes everything before the bound.
OUT_SINCE=$(run --since 2026-09-02T00:00:00Z --format text)
if printf '%s\n' "$OUT_SINCE" | grep -q '^jira-api.sh raw'; then
    bad "--since 2026-09-02 should have excluded the 2026-09-01 jira-api.sh calls"
else
    ok "--since excludes calls before the bound"
fi
if printf '%s\n' "$OUT_SINCE" | grep -q '^lab-ssh.sh exec	2	'; then
    ok "--since keeps calls at/after the bound"
else
    bad "expected 'lab-ssh.sh exec' to survive --since 2026-09-02 (got: $OUT_SINCE)"
fi

# ---- test 7: --top caps the ranked row count (excluding the header).
OUT_TOP=$(run --top 3 --format text)
ROWS=$(($(printf '%s\n' "$OUT_TOP" | wc -l) - 1))
if [ "$ROWS" -eq 3 ]; then
    ok "--top 3 returns exactly 3 ranked rows"
else
    bad "expected 3 rows from --top 3, got $ROWS (out: $OUT_TOP)"
fi

# ---- test 8: --format json is a JSON array a later trend script can load.
OUT_JSON=$(run --format json)
if printf '%s' "$OUT_JSON" | python3 -c 'import json,sys; assert isinstance(json.load(sys.stdin), list)'; then
    ok "--format json is a loadable JSON array"
else
    bad "--format json did not parse as a JSON array"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
