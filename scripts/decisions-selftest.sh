#!/bin/bash
#
# Selftest for decisions.sh. Builds a scratch git repo per test case, with
# config LOCAL to that repo only, never the operator's global ~/.gitconfig.
# Entirely offline: no network call anywhere in this script or the one it
# drives.
#
# Usage: scripts/decisions-selftest.sh [path-to-decisions.sh]
# Defaults to the sibling scripts/decisions.sh.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DECISIONS="${1:-$HERE/decisions.sh}"
KIT="$HERE/lib/kit.sh"
AWKLIB="$HERE/lib/decisions-migrate.awk"
[ -r "$DECISIONS" ] || { echo "cannot read $DECISIONS" >&2; exit 2; }
[ -r "$KIT" ] || { echo "cannot read $KIT" >&2; exit 2; }
[ -r "$AWKLIB" ] || { echo "cannot read $AWKLIB" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# count_md DIR [GLOB] — number of matching entry files, GLOB default '*.md'.
count_md() { find "$1" -maxdepth 1 -name "${2:-*.md}" -type f | wc -l | tr -d ' '; }
# first_md DIR GLOB — path of the first matching entry file.
first_md() { find "$1" -maxdepth 1 -name "$2" -type f | head -1; }

# A small fixture, not the real 798-line log: three entries, mixed heading
# depth (## and ###) and one non-dated sub-heading inside an entry — the
# two shapes migrate must not confuse with an entry boundary.
FIXTURE='# Decisions — dated append log of "why"

Some intro prose that migrate replaces with a GENERATED banner.

## Log

### 2026-01-01 — First decision

Body of the first decision.

## 2026-01-02 — Second decision, level two heading

Body two, paragraph one.

### Sub note

Not a dated heading — part of entry two, must stay inside it.

More of body two.

### 2026-01-03 — Third decision

Body three.
'

# fresh_repo NAME — a throwaway git repo under $WORK/NAME, decisions.sh
# installed at scripts/decisions.sh with the fixture as docs/decisions.md.
fresh_repo() {
    local d="$WORK/$1"
    rm -rf "$d"
    mkdir -p "$d/scripts/lib" "$d/docs"
    (
        cd "$d"
        git init -q -b main
        git config commit.gpgsign false
        git config user.email "test@example.invalid"
        git config user.name "decisions selftest"
        cp "$DECISIONS" scripts/decisions.sh
        cp "$KIT" scripts/lib/kit.sh
        cp "$AWKLIB" scripts/lib/decisions-migrate.awk
        chmod +x scripts/decisions.sh
        printf '%s' "$FIXTURE" >docs/decisions.md
        git add -A
        git commit -q -m init --allow-empty
    ) >/dev/null
    printf '%s\n' "$d"
}

# ---- test 1: migrate splits every dated heading into its own file, none
# lost, and the non-dated sub-heading stays inside its parent entry.

REPO=$(fresh_repo t1)
set +e
(cd "$REPO" && ./scripts/decisions.sh migrate) >"$WORK/t1.out" 2>&1
RC=$?
set -e
N_FILES=$(count_md "$REPO/docs/decisions.d")
# Independent oracle: count dated headings in the ORIGINAL fixture text
# with a plain grep, not decisions.sh's own boundary regex.
N_HEADINGS=$(printf '%s' "$FIXTURE" | grep -cE '^#{1,6} [0-9]{4}-[0-9]{2}-[0-9]{2} —')
if [ "$RC" -ne 0 ]; then
    bad "test1 (migrate): exited $RC:
$(cat "$WORK/t1.out")"
elif [ "$N_FILES" -ne "$N_HEADINGS" ]; then
    bad "test1: fixture has $N_HEADINGS dated headings but migrate wrote $N_FILES files"
elif ! grep -q "Sub note" "$REPO"/docs/decisions.d/*second-decision*.md 2>/dev/null; then
    bad "test1: the non-dated 'Sub note' sub-heading did not stay inside the second entry"
else
    ok "test1: migrate splits every dated entry into its own file, none lost, sub-headings stay put"
fi

# ---- test 2: index is idempotent — running it twice with no entry
# changes produces a byte-identical docs/decisions.md.

REPO=$(fresh_repo t2)
(cd "$REPO" && ./scripts/decisions.sh migrate) >/dev/null 2>&1
COPY1="$WORK/t2-first.md"
cp "$REPO/docs/decisions.md" "$COPY1"
(cd "$REPO" && ./scripts/decisions.sh index) >/dev/null 2>&1
if diff -q "$COPY1" "$REPO/docs/decisions.md" >/dev/null; then
    ok "test2: index is idempotent — a second run changes nothing"
else
    bad "test2: a second 'index' run changed docs/decisions.md:
$(diff "$COPY1" "$REPO/docs/decisions.md")"
fi

# ---- test 3: migrate refuses a second run rather than duplicating or
# corrupting entries.

set +e
(cd "$REPO" && ./scripts/decisions.sh migrate) >"$WORK/t3.out" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
    bad "test3 (migrate re-run guard): a second migrate exited 0 — should refuse"
else
    ok "test3: migrate refuses to run a second time"
fi

# ---- test 4: two concurrent adds write two distinct files, no seq
# collision and no corrupted index — the whole point of this ticket.

REPO=$(fresh_repo t4)
(cd "$REPO" && ./scripts/decisions.sh migrate) >/dev/null 2>&1
(cd "$REPO" && ./scripts/decisions.sh add --title "Concurrent one" --body "body one" --date 2026-02-01) >"$WORK/t4a.out" 2>&1 &
P1=$!
(cd "$REPO" && ./scripts/decisions.sh add --title "Concurrent two" --body "body two" --date 2026-02-01) >"$WORK/t4b.out" 2>&1 &
P2=$!
set +e
wait "$P1"; RC1=$?
wait "$P2"; RC2=$?
set -e
N_NEW=$(count_md "$REPO/docs/decisions.d" '2026-02-01-concurrent-*.md')
set +e
(cd "$REPO" && ./scripts/decisions.sh lint) >"$WORK/t4lint.out" 2>&1
RC_LINT=$?
set -e
if [ "$RC1" -ne 0 ] || [ "$RC2" -ne 0 ]; then
    bad "test4: an add exited nonzero (rc1=$RC1 rc2=$RC2):
$(cat "$WORK/t4a.out")
$(cat "$WORK/t4b.out")"
elif [ "$N_NEW" -ne 2 ]; then
    bad "test4: expected 2 new entry files, found $N_NEW"
elif [ "$RC_LINT" -ne 0 ]; then
    bad "test4: lint failed after two concurrent adds (a seq collision or index drift):
$(cat "$WORK/t4lint.out")"
else
    ok "two concurrent adds write two distinct files"
fi

# ---- test 5: lint is a real second oracle — a hand-edit to an entry's
# date field (bypassing add/index entirely) must not pass silently.

REPO=$(fresh_repo t5)
(cd "$REPO" && ./scripts/decisions.sh migrate) >/dev/null 2>&1
ENTRY="$(first_md "$REPO/docs/decisions.d" '*first-decision*.md')"
set +e
(cd "$REPO" && ./scripts/decisions.sh lint) >"$WORK/t5before.out" 2>&1
RC_BEFORE=$?
set -e
sed -i.bak 's/^date: .*/date: not-a-date/' "$ENTRY"
rm -f "$ENTRY.bak"
set +e
(cd "$REPO" && ./scripts/decisions.sh lint) >"$WORK/t5after.out" 2>&1
RC_AFTER=$?
set -e
if [ "$RC_BEFORE" -ne 0 ]; then
    bad "test5 (drift detection): lint failed on the untouched entry before any tampering:
$(cat "$WORK/t5before.out")"
elif [ "$RC_AFTER" -eq 0 ]; then
    bad "test5: lint exited 0 after hand-editing an entry's date field"
elif ! grep -q "not-a-date" "$WORK/t5after.out"; then
    bad "test5: lint failed after the hand-edit but not for the date reason expected:
$(cat "$WORK/t5after.out")"
else
    ok "test5: lint refuses when an entry file was hand-edited after decisions.sh last wrote it"
fi

# ---- test 6: --dry-run prints the entry path it would write and writes
# nothing — no new file, no index change.

REPO=$(fresh_repo t6)
(cd "$REPO" && ./scripts/decisions.sh migrate) >/dev/null 2>&1
BEFORE_COUNT=$(count_md "$REPO/docs/decisions.d")
BEFORE_INDEX=$(cat "$REPO/docs/decisions.md")
DRY_OUT=$(cd "$REPO" && ./scripts/decisions.sh add --title "Never written" --body "x" --date 2026-03-01 --dry-run)
AFTER_COUNT=$(count_md "$REPO/docs/decisions.d")
AFTER_INDEX=$(cat "$REPO/docs/decisions.md")
if [ "$BEFORE_COUNT" -ne "$AFTER_COUNT" ]; then
    bad "test6: --dry-run changed the entry file count ($BEFORE_COUNT -> $AFTER_COUNT)"
elif [ "$BEFORE_INDEX" != "$AFTER_INDEX" ]; then
    bad "test6: --dry-run changed docs/decisions.md"
elif ! printf '%s' "$DRY_OUT" | grep -q 'docs/decisions.d/'; then
    bad "test6: --dry-run output does not name a path under docs/decisions.d/ (got: $DRY_OUT)"
elif printf '%s' "$DRY_OUT" | grep -q 'docs/decisions.md'; then
    bad "test6: --dry-run output names the INDEX file, not just the entry it would write (got: $DRY_OUT)"
else
    ok "test6: --dry-run prints the entry path it would write and touches nothing"
fi

# ---- test 7: missing --title or --body dies naming the problem, and
# writes nothing.

REPO=$(fresh_repo t7)
(cd "$REPO" && ./scripts/decisions.sh migrate) >/dev/null 2>&1
BEFORE_COUNT=$(count_md "$REPO/docs/decisions.d")
set +e
(cd "$REPO" && ./scripts/decisions.sh add --body "no title") >"$WORK/t7a.out" 2>&1
RC_NOTITLE=$?
(cd "$REPO" && ./scripts/decisions.sh add --title "no body") >"$WORK/t7b.out" 2>&1
RC_NOBODY=$?
set -e
AFTER_COUNT=$(count_md "$REPO/docs/decisions.d")
if [ "$RC_NOTITLE" -eq 0 ] || [ "$RC_NOBODY" -eq 0 ]; then
    bad "test7: add with a missing required flag exited 0"
elif ! grep -q "title" "$WORK/t7a.out" || ! grep -q "body" "$WORK/t7b.out"; then
    bad "test7: dying calls did not name which flag was missing"
elif [ "$AFTER_COUNT" -ne "$BEFORE_COUNT" ]; then
    bad "test7: a dying add call still wrote an entry file ($BEFORE_COUNT -> $AFTER_COUNT)"
else
    ok "test7: a missing --title or --body dies naming it, and writes nothing"
fi

echo
echo "$PASS passed, $FAIL failed (against: $DECISIONS)"
[ "$FAIL" -eq 0 ]
