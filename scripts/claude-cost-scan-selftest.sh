#!/bin/bash
#
# Selftest for claude-cost-scan.py. Runs entirely against fixture
# transcripts under scripts/fixtures/claude-cost-scan/ — structurally
# offline, never reads the real ~/.claude/projects tree. Exercises the
# --repo/--project-slug filter, the same-message-id dedupe, --since
# filtering, --ledger-line's exact output shape, and both subagent
# transcript shapes — Agent-tool under subagents/ and Workflow-tool under
# subagents/workflows/wf_*/ (NWM-152).
#
# Usage: scripts/claude-cost-scan-selftest.sh [path-to-claude-cost-scan.py]
# Defaults to the sibling scripts/claude-cost-scan.py.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="${1:-$HERE/claude-cost-scan.py}"
[ -r "$SCAN" ] || { echo "cannot read $SCAN" >&2; exit 2; }

FIXTURES="$HERE/fixtures/claude-cost-scan"
[ -d "$FIXTURES" ] || { echo "cannot read fixtures dir $FIXTURES" >&2; exit 2; }
PRICES="$HERE/../templates/claude-prices.tsv"

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

run() { python3 "$SCAN" --projects-dir "$FIXTURES" --prices "$PRICES" "$@"; }

# ---- test 1: --repo derives the right slug and only sees that repo's data.
OUT=$(run --repo /Users/fixture/repoA --format tsv)
if printf '%s\n' "$OUT" | grep -q "^sess-1	claude-haiku-4-5-20251001	1	20"; then
    ok "--repo slugifies the path and finds repoA's subagent turn"
else
    bad "--repo did not find repoA's subagent turn (got: $OUT)"
fi
if printf '%s\n' "$OUT" | grep -q "sess-2"; then
    bad "--repo repoA leaked repoB's session into the report"
else
    ok "--repo scopes to one repo, excluding sibling repoB"
fi

# ---- test 2: same-message-id dedupe keeps one turn, the last values seen.
if printf '%s\n' "$OUT" | grep -q "^sess-1	claude-sonnet-5	2	250"; then
    ok "duplicate message-id lines dedupe into one turn (last values win)"
else
    bad "expected sess-1/claude-sonnet-5 to be 2 turns/250 tokens after dedupe (got: $OUT)"
fi

# ---- test 3: --project-slug reaches repoB directly.
OUT_B=$(run --project-slug=-Users-fixture-repoB --format tsv)
if printf '%s\n' "$OUT_B" | grep -q "^sess-2	claude-opus-5	1	2000"; then
    ok "--project-slug reads repoB's transcript directly"
else
    bad "expected repoB's turn via --project-slug (got: $OUT_B)"
fi

# ---- test 4: --since excludes the earlier turn.
OUT_SINCE=$(run --repo /Users/fixture/repoA --since 2026-09-02T00:00:00Z --format tsv)
if printf '%s\n' "$OUT_SINCE" | grep -q "^TOTAL		1	50"; then
    ok "--since filters out turns before the bound"
else
    bad "expected only the 2026-09-05 turn after --since (got: $OUT_SINCE)"
fi

# ---- test 5: --ledger-line prints exactly the ticket outcome-comment shape.
# 4 turns, not 3: the fourth is the Workflow-tool turn test 7 covers.
LINE=$(run --repo /Users/fixture/repoA --ledger-line)
# literal '$0.0320', not a variable to expand
# shellcheck disable=SC2016
if [ "$LINE" = 'cost: $0.0320, 4 turns' ]; then
    ok "--ledger-line prints the exact ticket outcome-comment shape"
else
    bad "unexpected --ledger-line output: $LINE"
fi

# ---- test 6: an unknown repo/slug is a loud refusal, not empty success.
if run --project-slug=-Users-fixture-does-not-exist >/dev/null 2>"$WORK/err"; then
    bad "an unknown slug should have been refused"
else
    if grep -q "no transcripts found" "$WORK/err"; then
        ok "an unknown slug is refused with a clear message"
    else
        bad "unknown-slug refusal message missing expected text"
    fi
fi

# ---- test 7 (NWM-152): Workflow-tool transcripts are counted too.
# subagents/workflows/wf_*/agent-*.jsonl is two levels deeper than the
# Agent-tool shape. Missing it under-counts silently: the scan completes and
# the total is simply short, by more the wider the fan-out.
if printf '%s\n' "$OUT" | grep -q "^sess-1	claude-opus-5	1	2000"; then
    ok "a Workflow-tool subagent under subagents/workflows/wf_*/ is counted"
else
    bad "the wf_*/agent-*.jsonl turn was not counted (got: $OUT)"
fi
if printf '%s\n' "$OUT" | grep -q "^TOTAL		4	2270"; then
    ok "the session TOTAL includes both subagent shapes"
else
    bad "TOTAL should be 4 turns / 2270 tokens across both shapes (got: $OUT)"
fi

# journal.jsonl sits beside the agent transcripts in every wf_*/ and is not
# one. The fixture's journal carries 18M tokens, so counting it would be
# unmissable.
if printf '%s\n' "$OUT" | grep -q "9000000\|18000000"; then
    bad "journal.jsonl was scanned as a transcript"
else
    ok "journal.jsonl beside the workflow transcripts is not scanned"
fi

# ---- test 8 (NWM-119): --ledger-fields splits orchestrator (main
# transcript) from worker (everything under subagents/), reads effort from
# perTurnEffort when present, and falls back to UNVERIFIED, never a guess,
# when it is absent.
FIELDS=$(run --repo /Users/fixture/repoA --ledger-fields)
if printf '%s\n' "$FIELDS" | grep -q "^orchestrator_model	claude-sonnet-5\$"; then
    ok "--ledger-fields: orchestrator_model is the main transcript's model"
else
    bad "unexpected orchestrator_model (got: $FIELDS)"
fi
if printf '%s\n' "$FIELDS" | grep -q "^orchestrator_effort	high\$"; then
    ok "--ledger-fields: orchestrator_effort reads perTurnEffort when present"
else
    bad "unexpected orchestrator_effort (got: $FIELDS)"
fi
if printf '%s\n' "$FIELDS" | grep -q "^orchestrator_turns	2\$" \
    && printf '%s\n' "$FIELDS" | grep -q "^worker_turns	2\$"; then
    ok "--ledger-fields: orchestrator/worker turns split by transcript position"
else
    bad "unexpected orchestrator/worker turn split (got: $FIELDS)"
fi

FIELDS_B=$(run --project-slug=-Users-fixture-repoB --ledger-fields)
if printf '%s\n' "$FIELDS_B" | grep -q "^orchestrator_effort	UNVERIFIED\$"; then
    ok "--ledger-fields: no perTurnEffort anywhere reads UNVERIFIED, not a guess"
else
    bad "expected UNVERIFIED orchestrator_effort for repoB (got: $FIELDS_B)"
fi
if printf '%s\n' "$FIELDS_B" | grep -q "^worker_turns	0\$"; then
    ok "--ledger-fields: a session with no subagent transcripts reads 0 worker turns"
else
    bad "expected 0 worker_turns for repoB (got: $FIELDS_B)"
fi

# ---- test 9 (NWM-165): the CLI folds "_" as well as "/" and ".".

# Captured, not run bare: without the fix this exits non-zero, and under
# `set -e` that aborts the selftest instead of reporting one failure.
OUT_U=$(run --repo /Users/fixture/repo_with_underscore --format tsv 2>&1) || true
if printf '%s\n' "$OUT_U" | grep -q "^sess-3	claude-haiku-4-5-20251001	1	200"; then
    ok "--repo folds '_' to '-' and finds the underscored repo's session"
else
    bad "--repo did not resolve a path containing '_' (got: $OUT_U)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
