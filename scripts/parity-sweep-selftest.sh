#!/bin/bash
#
# Selftest for parity-sweep.sh. Builds two throwaway trees (a fake "source
# project" and a fake "local repo") under $TMPDIR at run time — no
# checked-in fixtures — and drives the script's --source/--map/
# --root flags against them. Nothing here reads or writes outside those
# scratch trees.
#
# Tests 9-11 build their own throwaway "source project" tree (CLAUDE.md +
# scripts/ + .claude/settings.json) under $WORK — never $NW_PARITY_SOURCE and
# never the real source project, so this selftest stays structurally offline.
#
# Usage: scripts/parity-sweep-selftest.sh [path-to-parity-sweep.sh]
# Defaults to the sibling scripts/parity-sweep.sh. Pass an older revision to
# run the NWM-158 diverged-marker cases red against it.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="${1:-$HERE/parity-sweep.sh}"
[ -x "$SWEEP" ] || { echo "cannot execute $SWEEP" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/source-project"
REPO="$WORK/local-repo"
mkdir -p "$SRC/scripts/dev" "$REPO/scripts/dev"

printf 'line one\nline two\n' >"$SRC/scripts/dev/tool.sh"
cp "$SRC/scripts/dev/tool.sh" "$REPO/scripts/dev/tool.sh"

printf 'kept as-is\n' >"$SRC/scripts/dev/skipped.sh"

MAP="$WORK/parity-map.tsv"
{
    printf 'scripts/dev/tool.sh\tscripts/dev/tool.sh\n'
    printf 'scripts/dev/skipped.sh\t-\n'
} >"$MAP"

run_sweep() {
    set +e
    "$SWEEP" --source "$SRC" --map "$MAP" --root "$REPO" >"$WORK/out" 2>"$WORK/err"
    STATUS=$?
    set -e
}

# ---- test 1: clean map, exit 0, all three sections empty.
run_sweep
if [ "$STATUS" -eq 0 ]; then
    ok "a clean map exits 0"
else
    bad "a clean map should exit 0, got $STATUS (see $WORK/err)"
fi
if grep -A1 '== drift' "$WORK/out" | grep -q '(none)' \
    && grep -A1 '== new' "$WORK/out" | grep -q '(none)' \
    && grep -A1 '== vanished' "$WORK/out" | grep -q '(none)'; then
    ok "a clean map reports (none) in all three sections"
else
    bad "a clean map should report (none) everywhere (see $WORK/out)"
fi

# ---- test 2: hand-edit the local copy -> drift, with a line count.
printf 'line one\nline two\nHAND EDIT\n' >"$REPO/scripts/dev/tool.sh"
run_sweep
if [ "$STATUS" -eq 1 ]; then
    ok "a hand-edited local file is reported as drift (exit 1)"
else
    bad "a hand-edited local file should exit 1, got $STATUS"
fi
if grep -q 'scripts/dev/tool.sh.*scripts/dev/tool.sh.*lines' "$WORK/out"; then
    ok "drift line names the pair and a diff line count"
else
    bad "drift section should name scripts/dev/tool.sh with a line count (see $WORK/out)"
fi
cp "$SRC/scripts/dev/tool.sh" "$REPO/scripts/dev/tool.sh"

# ---- test 3: local file missing entirely -> drift, not silently skipped.
rm "$REPO/scripts/dev/tool.sh"
run_sweep
if [ "$STATUS" -eq 1 ] && grep -q 'local file missing' "$WORK/out"; then
    ok "a missing local file is reported as drift, not skipped"
else
    bad "a missing local file should be reported as drift (status=$STATUS, see $WORK/out)"
fi
cp "$SRC/scripts/dev/tool.sh" "$REPO/scripts/dev/tool.sh"

# ---- test 4: a new source file with no map row -> "new", exit 1.
printf 'brand new\n' >"$SRC/scripts/dev/newcomer.sh"
run_sweep
if [ "$STATUS" -eq 1 ] && grep -q 'scripts/dev/newcomer.sh' "$WORK/out"; then
    ok "a new unmapped source file is reported under 'new'"
else
    bad "newcomer.sh should appear under 'new' (status=$STATUS, see $WORK/out)"
fi
rm "$SRC/scripts/dev/newcomer.sh"

# ---- test 5: a map row's source file vanishes -> "vanished", exit 1.
mv "$SRC/scripts/dev/skipped.sh" "$WORK/skipped.sh.bak"
run_sweep
if [ "$STATUS" -eq 1 ] && grep -q 'scripts/dev/skipped.sh' "$WORK/out" \
    && grep -A2 '== vanished' "$WORK/out" | grep -q 'scripts/dev/skipped.sh'; then
    ok "a map row whose source vanished is reported under 'vanished'"
else
    bad "skipped.sh should appear under 'vanished' (status=$STATUS, see $WORK/out)"
fi

# ---- test 6: while vanished, a '-' row is still never treated as drift
# or a missing-local finding (it has no local counterpart to check).
if grep -A2 '== drift' "$WORK/out" | grep -q 'skipped.sh'; then
    bad "a '-' (not-ported) row should never appear under drift"
else
    ok "a '-' (not-ported) row is exempt from drift/missing-local checks"
fi
mv "$WORK/skipped.sh.bak" "$SRC/scripts/dev/skipped.sh"

# ---- test 7: a missing --source directory is could-not-evaluate (exit 2).
set +e
"$SWEEP" --source "$WORK/does-not-exist" --map "$MAP" --root "$REPO" >"$WORK/out7" 2>"$WORK/err7"
STATUS7=$?
set -e
if [ "$STATUS7" -eq 2 ]; then
    ok "a missing --source directory is a could-not-evaluate exit (2)"
else
    bad "a missing --source directory should exit 2, got $STATUS7"
fi

# ---- test 8: a malformed map row is could-not-evaluate (2), distinct
# from a real drift finding (1).
BADMAP="$WORK/bad-map.tsv"
printf 'scripts/dev/tool.sh\tscripts/dev/tool.sh\textra-field\n' >"$BADMAP"
set +e
"$SWEEP" --source "$SRC" --map "$BADMAP" --root "$REPO" >"$WORK/out8" 2>"$WORK/err8"
STATUS8=$?
set -e
if [ "$STATUS8" -eq 2 ]; then
    ok "a malformed map row is a could-not-evaluate exit (2), not a drift exit (1)"
else
    bad "a malformed map row should exit 2, got $STATUS8"
fi
if grep -q "malformed row" "$WORK/err8"; then
    ok "the malformed-row message names the problem"
else
    bad "expected a \"malformed row\" message (see $WORK/err8)"
fi

# ---- test 9: --source-root enumeration finds an unmapped reference.
SRCROOT="$WORK/fixture-source"
mkdir -p "$SRCROOT/scripts/dev" "$SRCROOT/scripts/other"
printf 'line one\n' >"$SRCROOT/scripts/dev/mapped.sh"
printf 'line one\n' >"$SRCROOT/scripts/other/orphan.sh"
{
    printf 'See scripts/dev/mapped.sh for the mapped tool.\n'
    printf 'A second, unmapped one: scripts/other/orphan.sh\n'
} >"$SRCROOT/CLAUDE.md"

ENUMMAP="$WORK/enum-map.tsv"
printf 'scripts/dev/mapped.sh\t-\n' >"$ENUMMAP"

set +e
"$SWEEP" --source "$SRCROOT" --map "$ENUMMAP" --root "$REPO" \
    --source-root "$SRCROOT" >"$WORK/out9" 2>"$WORK/err9"
STATUS9=$?
set -e
if [ "$STATUS9" -eq 1 ]; then
    ok "an unmapped source-root reference exits 1"
else
    bad "an unmapped source-root reference should exit 1, got $STATUS9 (see $WORK/err9)"
fi
if grep -q 'CLAUDE.md:2: scripts/other/orphan.sh' "$WORK/out9"; then
    ok "the unmapped section names the referencing file:line and path"
else
    bad "expected 'CLAUDE.md:2: scripts/other/orphan.sh' under unmapped (see $WORK/out9)"
fi
if grep -A5 '== unmapped' "$WORK/out9" | grep -q 'mapped.sh$'; then
    bad "a mapped reference should never appear under unmapped"
else
    ok "a mapped reference is not reported under unmapped"
fi

# ---- test 10: the same reference, once allowlisted, drops out.
mkdir -p "$REPO/templates"
printf 'scripts/other/orphan.sh\n' >"$REPO/templates/parity-allowlist.txt"
set +e
"$SWEEP" --source "$SRCROOT" --map "$ENUMMAP" --root "$REPO" \
    --source-root "$SRCROOT" >"$WORK/out10" 2>"$WORK/err10"
STATUS10=$?
set -e
if [ "$STATUS10" -eq 0 ]; then
    ok "an allowlisted source-root reference exits 0"
else
    bad "an allowlisted reference should exit 0, got $STATUS10 (see $WORK/err10, $WORK/out10)"
fi
rm -f "$REPO/templates/parity-allowlist.txt"

# ---- test 11: a hook command in settings.json pointing at an unmapped script
# is its own reference class, reported with settings.json:line. Also covers
# Pass 1: an unmapped agent and skill are reported, README.md is not.
mkdir -p "$SRCROOT/.claude/agents" "$SRCROOT/.claude/skills/bar"
printf 'line one\n' >"$SRCROOT/scripts/dev/hookorphan.sh"
printf '# Foo agent\n' >"$SRCROOT/.claude/agents/foo.md"
printf '# Agents\n' >"$SRCROOT/.claude/agents/README.md"
printf '# Bar skill\n' >"$SRCROOT/.claude/skills/bar/SKILL.md"

cat >"$SRCROOT/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "scripts/dev/hookorphan.sh"
          }
        ]
      }
    ]
  }
}
JSON

set +e
"$SWEEP" --source "$SRCROOT" --map "$ENUMMAP" --root "$REPO" \
    --source-root "$SRCROOT" >"$WORK/out11" 2>"$WORK/err11"
STATUS11=$?
set -e
if [ "$STATUS11" -eq 1 ]; then
    ok "an unmapped hook command exits 1"
else
    bad "an unmapped hook command should exit 1, got $STATUS11 (see $WORK/err11)"
fi
if grep -q 'settings.json:9: scripts/dev/hookorphan.sh' "$WORK/out11"; then
    ok "the unmapped section names settings.json:line for the hook command"
else
    bad "expected 'settings.json:9: scripts/dev/hookorphan.sh' under unmapped (see $WORK/out11)"
fi
if grep -q '\.claude/agents/foo\.md:1: \.claude/agents/foo\.md' "$WORK/out11" \
    && grep -q '\.claude/skills/bar/SKILL\.md:1: \.claude/skills/bar/SKILL\.md' "$WORK/out11"; then
    ok "an unmapped agent and skill file are reported under unmapped"
else
    bad "expected .claude/agents/foo.md and .claude/skills/bar/SKILL.md under unmapped (see $WORK/out11)"
fi
if grep -q 'agents/README.md' "$WORK/out11"; then
    bad ".claude/agents/README.md should never be reported as an agent"
else
    ok ".claude/agents/README.md is excluded from agent enumeration"
fi

# ---- test 12: a scripts/**.sh reference whose file does not exist under
# --source-root is "dangling", not "unmapped", and alone does not flip
# the exit code.
DANGLEMAP="$WORK/dangle-map.tsv"
printf 'scripts/dev/mapped.sh\t-\n' >"$DANGLEMAP"
DANGLESRC="$WORK/dangle-source"
mkdir -p "$DANGLESRC/scripts/dev" "$DANGLESRC/docs/cost"
printf 'line one\n' >"$DANGLESRC/scripts/dev/mapped.sh"
printf 'See scripts/x/y.sh for an example.\n' >"$DANGLESRC/docs/cost/README.md"

set +e
"$SWEEP" --source "$DANGLESRC" --map "$DANGLEMAP" --root "$REPO" \
    --source-root "$DANGLESRC" >"$WORK/out12" 2>"$WORK/err12"
STATUS12=$?
set -e
if [ "$STATUS12" -eq 0 ]; then
    ok "a dangling-only reference does not flip the exit code"
else
    bad "a dangling-only reference should still exit 0, got $STATUS12 (see $WORK/err12, $WORK/out12)"
fi
if grep -A3 '== dangling' "$WORK/out12" | grep -q 'README.md:1: scripts/x/y.sh'; then
    ok "the dangling section names the referencing file:line and path"
else
    bad "expected 'README.md:1: scripts/x/y.sh' under dangling (see $WORK/out12)"
fi
if grep -A3 '== unmapped' "$WORK/out12" | grep -q 'scripts/x/y.sh'; then
    bad "a dangling reference should never appear under unmapped"
else
    ok "a dangling reference is not reported under unmapped"
fi

# ---- NWM-158: the diverged: marker ------------------------------------
# A pair that is known not to converge is marked rather than deleted. The
# marker keeps the row mapped, which is the whole point: a deleted row puts
# its source into 'new', which sets exit 1 exactly as drift does.
DVSRC="$WORK/dv-source"
DVREPO="$WORK/dv-repo"
mkdir -p "$DVSRC/scripts/dev" "$DVREPO/scripts/dev"

printf 'big version\nwith extra lines\n' >"$DVSRC/scripts/dev/forked.sh"
printf 'small version\n' >"$DVREPO/scripts/dev/forked.sh"
printf 'same\n' >"$DVSRC/scripts/dev/agreed.sh"
cp "$DVSRC/scripts/dev/agreed.sh" "$DVREPO/scripts/dev/agreed.sh"

DVMAP="$WORK/dv-map.tsv"
{
    printf 'scripts/dev/forked.sh\tscripts/dev/forked.sh\tdiverged:NWM-129\n'
    printf 'scripts/dev/agreed.sh\tscripts/dev/agreed.sh\n'
} >"$DVMAP"

run_dv() {
    set +e
    "$SWEEP" --source "$DVSRC" --map "$1" --root "$DVREPO" \
        >"$WORK/dvout" 2>"$WORK/dverr"
    DVSTATUS=$?
    set -e
}

run_dv "$DVMAP"
if [ "$DVSTATUS" -eq 0 ]; then
    ok "diverged: a marked differing pair does not set the exit code"
else
    bad "diverged: a marked differing pair should exit 0, got $DVSTATUS (see $WORK/dverr, $WORK/dvout)"
fi
if grep -A3 '== diverged' "$WORK/dvout" | grep -q 'scripts/dev/forked.sh.*NWM-129.*lines'; then
    ok "diverged: the section names the pair, its ticket and a diff line count"
else
    bad "diverged: section missing the marked pair with its ticket (see $WORK/dvout)"
fi
if sed -n '/== drift/,/== diverged/p' "$WORK/dvout" | grep -q 'forked.sh'; then
    bad "diverged: a marked pair must not also appear under drift"
else
    ok "diverged: a marked pair is kept out of the drift section"
fi

# The property that makes marking work where deleting does not.
if grep -A3 '== new' "$WORK/dvout" | grep -q 'forked.sh'; then
    bad "diverged: a marked row's source must stay mapped, never fall into 'new'"
else
    ok "diverged: a marked row's source stays mapped and never falls into 'new'"
fi

# ...and the measurement that rejected deleting the row instead.
DELMAP="$WORK/dv-map-deleted.tsv"
printf 'scripts/dev/agreed.sh\tscripts/dev/agreed.sh\n' >"$DELMAP"
run_dv "$DELMAP"
if grep -A3 '== new' "$WORK/dvout" | grep -q 'forked.sh' && [ "$DVSTATUS" -eq 1 ]; then
    ok "diverged: deleting the row instead relocates the noise into 'new' and still exits 1"
else
    bad "diverged: expected the deleted row's source under 'new' with exit 1, got $DVSTATUS (see $WORK/dvout)"
fi

# Deliberately different is not deliberately absent.
MISSMAP="$WORK/dv-map-missing.tsv"
{
    printf 'scripts/dev/forked.sh\tscripts/dev/gone.sh\tdiverged:NWM-129\n'
    printf 'scripts/dev/agreed.sh\tscripts/dev/agreed.sh\n'
} >"$MISSMAP"
run_dv "$MISSMAP"
if [ "$DVSTATUS" -eq 1 ] && sed -n '/== drift/,/== diverged/p' "$WORK/dvout" | grep -q 'local file missing'; then
    ok "diverged: a marked pair whose local file is MISSING is still drift, exit 1"
else
    bad "diverged: a missing local file under a marker should stay drift with exit 1, got $DVSTATUS (see $WORK/dvout)"
fi

# A marker on a pair that turns out identical is a marker that has gone stale.
STALEMAP="$WORK/dv-map-stale.tsv"
{
    printf 'scripts/dev/agreed.sh\tscripts/dev/agreed.sh\tdiverged:NWM-129\n'
    printf 'scripts/dev/forked.sh\tscripts/dev/forked.sh\tdiverged:NWM-129\n'
} >"$STALEMAP"
run_dv "$STALEMAP"
if [ "$DVSTATUS" -eq 0 ]; then
    ok "diverged: a stale marker does not change the exit code"
else
    bad "diverged: a stale marker should leave exit 0, got $DVSTATUS (see $WORK/dvout)"
fi
if grep -A3 '== diverged' "$WORK/dvout" | grep -q 'marker may be stale'; then
    ok "diverged: an identical marked pair is flagged as a possibly stale marker"
else
    bad "diverged: an identical marked pair should be flagged stale (see $WORK/dvout)"
fi

# Malformed markers are a could-not-evaluate, like every other bad map row.
BADMARKMAP="$WORK/dv-map-badmarker.tsv"
printf 'scripts/dev/forked.sh\tscripts/dev/forked.sh\tprobably-fine\n' >"$BADMARKMAP"
run_dv "$BADMARKMAP"
if [ "$DVSTATUS" -eq 2 ]; then
    ok "diverged: a third field that is not diverged:TICKET is a malformed map, exit 2"
else
    bad "diverged: an unrecognised third field should exit 2, got $DVSTATUS (see $WORK/dverr)"
fi

NOTPORTEDMAP="$WORK/dv-map-notported.tsv"
printf 'scripts/dev/forked.sh\t-\tdiverged:NWM-129\n' >"$NOTPORTEDMAP"
run_dv "$NOTPORTEDMAP"
if [ "$DVSTATUS" -eq 2 ]; then
    ok "diverged: a marker on a '-' row is a malformed map, exit 2"
else
    bad "diverged: a marker on a '-' row should exit 2, got $DVSTATUS (see $WORK/dverr)"
fi

echo
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
    echo "parity-sweep-selftest.sh: FAILED"
    exit 1
fi
echo "parity-sweep-selftest.sh: all assertions passed"
exit 0
