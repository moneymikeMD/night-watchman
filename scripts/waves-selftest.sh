#!/bin/bash
#
# Selftest for waves.py. Structurally offline: every case reads from
# scripts/fixtures/waves/ or a synthesized in-memory issues.py copy, never
# the network or a live Jira. Ports the WO-041 preflight/landing checks
# (work-order reference/issues.py's _preflight_selftest) plus a parity check
# against work-order's own committed expected output, and an independence
# check against a stripped issues.py copy that has waves/preflight/
# _plan_waves/_claims deleted — proving this file does not quietly still
# call work-order's planner.
#
# Usage: scripts/waves-selftest.sh [path-to-waves.py]

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${1:-$HERE/waves.py}"
FIXTURES="$HERE/fixtures/waves"

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

[ -f "$SUT" ] || { echo "FAIL - cannot find $SUT" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# strip_wave_fns SRC DST — copy SRC to DST with waves/preflight/_plan_waves/
# _claims removed, for the independence check. Same technique used to
# generate the fixture during authoring: delete each `def NAME(` block up to
# (not including) the next top-level line.
strip_wave_fns() {
    python3 - "$1" "$2" <<'PY'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")

def strip_func(lines, name):
    out, i = [], 0
    while i < len(lines):
        if lines[i].startswith(f"def {name}("):
            i += 1
            while i < len(lines) and (lines[i].startswith(" ") or lines[i] == ""):
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return out

for fn in ("_claims", "_plan_waves", "waves", "preflight"):
    lines = strip_func(lines, fn)
text = "\n".join(lines)
text = re.sub(r'^CMDS = \{.*?\}\n', '', text, flags=re.S | re.M)
open(dst, "w").write(text)
PY
}

# run CMD... — sets RC and OUT (combined stdout+stderr).
run() {
    set +e
    OUT="$("$@" 2>&1)"
    RC=$?
    set -e
}

# --- 1. file-source parity against work-order's committed expected output ---

run python3 "$SUT" waves "$FIXTURES/"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$(cat "$FIXTURES/expected-waves.txt")" ]; then
    ok "waves: file source matches work-order v1.6.0 issues.py byte-for-byte"
else
    bad "waves: file source diverges from expected-waves.txt (rc=$RC)"
fi

run python3 "$SUT" preflight "$FIXTURES/" --landing serial
if [ "$RC" -eq 0 ] && [ "$OUT" = "$(cat "$FIXTURES/expected-preflight-serial.txt")" ]; then
    ok "preflight: serial landing matches expected output, exit 0"
else
    bad "preflight: serial landing diverges or wrong exit (rc=$RC, want 0)"
fi

run python3 "$SUT" preflight "$FIXTURES/" --landing parallel
if [ "$RC" -eq 1 ] && [ "$OUT" = "$(cat "$FIXTURES/expected-preflight-parallel.txt")" ]; then
    ok "preflight: parallel landing matches expected output, exit 1"
else
    bad "preflight: parallel landing diverges or wrong exit (rc=$RC, want 1)"
fi

# --- 2. jira-source parity against a captured fixture ---

run env ISSUES_SOURCE=jira python3 "$SUT" waves --fixture "$FIXTURES/jira-preflight.json"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$(cat "$FIXTURES/expected-jira-waves.txt")" ]; then
    ok "waves: jira source matches expected output byte-for-byte"
else
    bad "waves: jira source diverges from expected-jira-waves.txt (rc=$RC)"
fi

run env ISSUES_SOURCE=jira python3 "$SUT" preflight --fixture "$FIXTURES/jira-preflight.json" --landing parallel
if [ "$RC" -eq 1 ] && [ "$OUT" = "$(cat "$FIXTURES/expected-jira-preflight-parallel.txt")" ]; then
    ok "preflight: jira source, parallel landing matches expected output, exit 1"
else
    bad "preflight: jira source, parallel landing diverges or wrong exit (rc=$RC, want 1)"
fi

# --- 3. WO-041 case: a `touches` overlap is a COLLISION under either
# landing path, not just a warning ---

HARD="$WORK/hard/open"
mkdir -p "$HARD"
cp "$FIXTURES"/open/*.md "$HARD/"
cat > "$HARD/PF-004-a-fourth-ticket.md" <<'EOF'
---
id: PF-004
title: a fourth ticket, touching what PF-001 touches
created: 2026-01-01
updated: 2026-01-01
executor: agent
touches:
  - reference/a.py
verify: |
  true
---

## Problem

WO-041 hard-collision case: PF-004 touches the same file PF-001 does.
EOF

run python3 "$SUT" preflight "$WORK/hard/" --landing serial
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"via touches —"* ]] && [[ "$OUT" == *"COLLISION"* ]]; then
    ok "preflight: a touches overlap is a hard COLLISION under serial landing"
else
    bad "preflight: touches overlap not flagged as a hard collision (rc=$RC): $OUT"
fi

# --- 4. WO-041 case: an unresolvable dependency exits 2, distinct from
# "collisions found" ---

CYC="$WORK/cycle/open"
mkdir -p "$CYC"
cat > "$CYC/CY-001-first.md" <<'EOF'
---
id: CY-001
title: first half of a cycle
created: 2026-01-01
updated: 2026-01-01
executor: agent
touches:
  - reference/a.py
blocked_by:
  - CY-002
verify: |
  true
---
EOF
cat > "$CYC/CY-002-second.md" <<'EOF'
---
id: CY-002
title: second half of a cycle
created: 2026-01-01
updated: 2026-01-01
executor: agent
touches:
  - reference/b.py
blocked_by:
  - CY-001
verify: |
  true
---
EOF

run python3 "$SUT" preflight "$WORK/cycle/"
if [ "$RC" -eq 2 ]; then
    ok "preflight: an unresolvable dependency exits 2, not 1"
else
    bad "preflight: unresolvable dependency exited $RC, want 2"
fi

# --- 5. independence: strip waves/preflight/_plan_waves/_claims out of a
# copy of the resolved issues.py and confirm waves.py's own output is
# unchanged — proves this file does not call back into work-order's planner ---

ISSUES_PY="$(env WAVES_ISSUES_PY= python3 - <<PY
import subprocess
print(subprocess.run(["$HERE/work-order-root.sh", "--issues-py"],
                      check=True, capture_output=True, text=True).stdout.strip())
PY
)"
if [ -n "$ISSUES_PY" ] && [ -f "$ISSUES_PY" ]; then
    STRIPPED="$WORK/issues_no_waves.py"
    strip_wave_fns "$ISSUES_PY" "$STRIPPED"
    if grep -q '^def waves(\|^def preflight(\|^def _plan_waves(\|^def _claims(' "$STRIPPED"; then
        bad "independence: strip_wave_fns left one of the four functions in place"
    else
        run env WAVES_ISSUES_PY="$STRIPPED" python3 "$SUT" waves "$FIXTURES/"
        indep_waves_out="$OUT"
        indep_waves_rc="$RC"
        run python3 "$SUT" waves "$FIXTURES/"
        if [ "$indep_waves_rc" -eq "$RC" ] && [ "$indep_waves_out" = "$OUT" ]; then
            ok "independence: waves output unchanged with work-order's originals deleted"
        else
            bad "independence: waves output changed once work-order's originals were deleted"
        fi

        run env WAVES_ISSUES_PY="$STRIPPED" python3 "$SUT" preflight "$FIXTURES/" --landing parallel
        indep_pf_out="$OUT"
        indep_pf_rc="$RC"
        run python3 "$SUT" preflight "$FIXTURES/" --landing parallel
        if [ "$indep_pf_rc" -eq "$RC" ] && [ "$indep_pf_out" = "$OUT" ]; then
            ok "independence: preflight output unchanged with work-order's originals deleted"
        else
            bad "independence: preflight output changed once work-order's originals were deleted"
        fi
    fi
else
    bad "independence: could not resolve work-order's issues.py via work-order-root.sh --issues-py"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
