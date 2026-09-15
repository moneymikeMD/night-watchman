#!/bin/bash
#
# session-cost.sh — Claude Code SessionEnd hook.
#
# Makes the ticket outcome comment's `cost: <$ or tokens>, <turns>` line a
# by-product of ending a session instead of a thing a human remembers (see
# docs/cost.md). Reads the hook's stdin JSON
# (`.session_id`, `.cwd`, `.transcript_path`), scans this session's local
# transcripts with `scripts/claude-cost-scan.py`, appends a row to the
# project's cost ledger if one is configured, and writes
# `.night-watchman/last-session-cost.txt` with the exact ledger line for a
# ticket outcome comment.
#
# A SessionEnd hook must never stop a session from ending: every failure
# path here — no scanner, no python3, no ledger, an unparsable transcript —
# is a one-line stderr warning, and this script always exits 0.
#
# Env overrides (mainly for the selftest): NW_COST_LEDGER (default
# <cwd>/docs/cost-ledger.tsv — only appended to if it already exists),
# NW_COST_PROJECTS_DIR (default: claude-cost-scan.py's own
# ~/.claude/projects), NW_COST_PROJECT_SLUG (scan by this fixed slug
# instead of deriving one from cwd).
#
# Usage: fed the SessionEnd hook JSON on stdin, no arguments.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"

warn() { echo "session-cost.sh: $1" >&2; }

# Never lets a failure below this point stop the session from ending.
trap 'exit 0' EXIT

command -v jq >/dev/null 2>&1 || { warn "jq not found on PATH — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { warn "python3 not found on PATH — skipping"; exit 0; }

INPUT="$(cat)"
[ -n "$INPUT" ] || { warn "empty stdin — skipping"; exit 0; }

SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$CWD" ] || CWD="$(pwd -P)"

if [ -z "$SESSION_ID" ]; then
    warn "no session_id in hook input — skipping"
    exit 0
fi

SCANNER="$PLUGIN_ROOT/scripts/claude-cost-scan.py"
if [ ! -f "$SCANNER" ]; then
    warn "scanner not found at $SCANNER — skipping"
    exit 0
fi

if [ -n "${NW_COST_PROJECT_SLUG:-}" ]; then
    SCAN_ARGS=(--project-slug="$NW_COST_PROJECT_SLUG" --session "$SESSION_ID" --format json)
else
    SCAN_ARGS=(--repo "$CWD" --session "$SESSION_ID" --format json)
fi
[ -n "${NW_COST_PROJECTS_DIR:-}" ] && SCAN_ARGS+=(--projects-dir "$NW_COST_PROJECTS_DIR")
SCAN_JSON="$(python3 "$SCANNER" "${SCAN_ARGS[@]}")"
SCAN_STATUS=$?
if [ "$SCAN_STATUS" -ne 0 ] || [ -z "$SCAN_JSON" ]; then
    warn "claude-cost-scan.py failed or produced no output (exit $SCAN_STATUS) — skipping"
    exit 0
fi

# Fold the per-(session,model) rows into total cost/turns and a model-mix
# string, and print the three as tab-separated fields on one line — the
# only interface between the scan JSON and the rest of this bash script.
SUMMARY="$(python3 - "$SCAN_JSON" <<'PYEOF'
import json
import sys

try:
    rows = json.loads(sys.argv[1])
except (ValueError, IndexError):
    sys.exit(1)

total_turns = 0
total_cost = 0.0
by_model = {}
for row in rows:
    if row.get("session") == "TOTAL":
        continue
    turns = int(row.get("turns", 0))
    cost = float(row.get("cost_usd", 0) or 0)
    total_turns += turns
    total_cost += cost
    model = row.get("model") or "unknown"
    by_model[model] = by_model.get(model, 0) + turns

if total_turns > 0:
    mix = ",".join(
        "%s:%d" % (m, round(100.0 * t / total_turns))
        for m, t in sorted(by_model.items(), key=lambda kv: -kv[1])
    )
else:
    mix = ""

print("%.4f\t%d\t%s" % (total_cost, total_turns, mix))
PYEOF
)"
if [ -z "$SUMMARY" ]; then
    warn "could not parse scan output — skipping"
    exit 0
fi

COST="$(echo "$SUMMARY" | cut -f1)"
TURNS="$(echo "$SUMMARY" | cut -f2)"
MODEL_MIX="$(echo "$SUMMARY" | cut -f3)"

# Step 2: append to the project's cost ledger, if one is configured.
LEDGER="${NW_COST_LEDGER:-$CWD/docs/cost-ledger.tsv}"
LEDGER_SCRIPT="$PLUGIN_ROOT/scripts/claude-cost.py"
if [ -f "$LEDGER" ] && [ -f "$LEDGER_SCRIPT" ]; then
    WAVE="$(date -u +%Y-%m-%d)-${SESSION_ID:0:8}"
    APPEND_ERR="$(python3 "$LEDGER_SCRIPT" append --ledger "$LEDGER" --wave "$WAVE" \
        --cost "$COST" --turns "$TURNS" --model "$MODEL_MIX" 2>&1 >/dev/null)"
    APPEND_STATUS=$?
    if [ "$APPEND_STATUS" -ne 0 ]; then
        case "$APPEND_ERR" in
            *"already has a row"*) : ;; # duplicate wave — no-op, not an error
            *) warn "ledger append failed: $APPEND_ERR" ;;
        esac
    fi
fi

# Step 3: write the untracked state file the outcome comment reads.
# State lives at the repo's MAIN worktree, never a linked one: a
# .night-watchman/ written inside a dispatched worktree used to trip
# land-branch's dirty-tree preflight (handoff 2026-09-14). git lists the
# main worktree first; fall back to cwd outside a repo.
# Only when cwd is itself a worktree top (a dispatched worktree, or the
# main checkout); a plain subdirectory of some repo keeps cwd, so a
# scratch tree nested inside a real repo never writes into that repo.
ROOT=""
if [ "$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$CWD" 2>/dev/null && pwd -P)" ]; then
    ROOT="$(git -C "$CWD" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
fi
[ -n "$ROOT" ] || ROOT="$CWD"
STATE_DIR="$ROOT/.night-watchman"
mkdir -p "$STATE_DIR" 2>/dev/null || { warn "could not create $STATE_DIR — skipping state file"; exit 0; }
{
    printf 'cost: $%s, %s turns\n' "$COST" "$TURNS"
    printf '# session %s, %s\n' "$SESSION_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STATE_DIR/last-session-cost.txt" 2>/dev/null || warn "could not write $STATE_DIR/last-session-cost.txt"

exit 0
