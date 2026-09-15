#!/bin/bash
#
# Selftest for land-branch.sh's file-mode completion path. Builds a scratch
# git repo per test case, with config LOCAL to that repo only (never reads
# or writes the operator's global ~/.gitconfig — commit.gpgsign, hooksPath,
# and identity are all set via `git config`, not `--global`), and exercises
# the four defects review round 1 found in the sed-based frontmatter rewrite
# this file replaced:
#
#   1. A default (or user-supplied) outcome containing an apostrophe,
#      emitted into a single-quoted YAML scalar, produced invalid YAML.
#   2. A `/` or `&` in the outcome broke the sed substitution outright (a
#      `/` terminates `s/.../.../`); a multi-line --outcome-file failed
#      with "unescaped newline inside substitute pattern".
#   3. A ticket missing `outcome:`/`updated:` in its frontmatter had those
#      fields appended past the closing `---`, into the ticket body — and
#      the edit had no `|| die_reset`, so a failure there exited via
#      `set -e` without reverting the merge.
#   4. The completion commit was pathspec-limited to the new path only
#      (`git commit ... -- "$DEST"`), so `git mv`'s staged deletion of the
#      old path was never committed — it stayed staged, and the NEXT run's
#      dirty-tree preflight refused on it.
#
# INTEGRATION WORKTREE. land-branch.sh no longer merges/
# lints/completes/pushes in the tree it was invoked from — it does all of
# that in a dedicated `<repo>-land` worktree, synced from a real "origin"
# remote every run. So every fixture repo here ($WORK/<name>) has its own
# bare "origin" at $WORK/<name>.git, pushed once (main) by the fixture
# helper; a landing's actual effect is only ever visible by reading that
# bare repo back (`land_bare_of`/`land_fetch` below), never by inspecting
# the fixture repo's own working tree or its own 'main' ref, which a
# landing must never move. `<name>-land` and `<name>-land.lock` are the
# integration worktree and its lock — several tests below create, dirty, or
# pre-seed them by hand to exercise the lifecycle/lock gates directly.
#
# Usage: scripts/land-branch-selftest.sh [path-to-land-branch.sh] [path-to-issues.py]
# Both default to this repo's current, fixed copies. Pass the path to an
# older revision of EITHER (e.g. via `git show <rev>:...` into a temp file)
# to reproduce the RED failures below against pre-fix code. Passing only
# the first argument (an older land-branch.sh) still checks that revision's
# ticket-writing behavior against the CURRENT issues.py parser — pass both
# together when the finding under test spans both files (test 6 does: it
# needs the SAME-revision issues.py a real checkout of that land-branch.sh
# would have shipped with, not whatever happens to be on disk right now).

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND_BRANCH="${1:-$HERE/land-branch.sh}"
ISSUES_PY="${2:-$HERE/../skills/to-issues/scripts/issues.py}"
KIT="$HERE/lib/kit.sh"
[ -r "$LAND_BRANCH" ] || { echo "cannot read $LAND_BRANCH" >&2; exit 2; }
[ -r "$ISSUES_PY" ] || { echo "cannot read $ISSUES_PY" >&2; exit 2; }
[ -r "$KIT" ] || { echo "cannot read $KIT" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# land_bare_of REPO — path to REPO's origin bare repo, resolved from git
# config (not assumed from REPO's own path) so a test can point origin
# somewhere else without this helper drifting out of sync.
land_bare_of() {
    git -C "$1" config --get remote.origin.url 2>/dev/null
}

# land_fetch REPO REF PATH OUTFILE — writes PATH's content at REF, read from
# REPO's origin bare repo (never REPO's own working tree — a landing never
# touches that), to OUTFILE. Returns non-zero and leaves OUTFILE untouched
# if origin/REF/PATH can't be resolved.
land_fetch() {
    local repo="$1" ref="$2" path="$3" outfile="$4" bare
    bare=$(land_bare_of "$repo") || return 1
    [ -n "$bare" ] || return 1
    git -C "$bare" show "$ref:$path" > "$outfile" 2>/dev/null
}

# fresh_repo NAME TICKET_FRONTMATTER_BODY — a throwaway git repo under
# $WORK/NAME, with a bare "origin" at $WORK/NAME.git it has already pushed
# main to. One ticket in issues/in-progress/ and one commit on a 'work'
# branch touching foo.txt, checked out back to main ready to land. Prints
# the working repo's path.
fresh_repo() {
    local ticket_body="$2" d="$WORK/$1"
    rm -rf "$d" "$d.git" "$d-land" "$d-land.lock"
    git init -q --bare -b main "$d.git" >/dev/null
    mkdir -p "$d/issues/in-progress" "$d/issues/completed" "$d/scripts/lib" "$d/notes" \
             "$d/skills/to-issues/scripts"
    (
        cd "$d"
        git init -q -b main
        git config commit.gpgsign false
        git config gpg.format openpgp
        git config core.hooksPath /dev/null
        git config user.email "test@example.invalid"
        git config user.name "land-branch selftest"
        git config user.signingkey ""
        git remote add origin "$d.git"
        cp "$LAND_BRANCH" scripts/land-branch.sh
        cp "$KIT" scripts/lib/kit.sh
        cp "$ISSUES_PY" skills/to-issues/scripts/issues.py
        chmod +x scripts/land-branch.sh
        printf '%s' "$ticket_body" > issues/in-progress/PROJ-1.md
        # Tracked from the first commit so a later edit to it shows up as an
        # "M " porcelain line at this exact path — used by the dirty-
        # invoking-tree scenario to prove a real, trackable edit survives.
        printf 'placeholder\n' > notes/n.md
        git add -A
        git commit -q -m "init"
        git push -q -u origin main
        git checkout -q -b work
        echo hello > foo.txt
        git add foo.txt
        git commit -q -m "PROJ-1: do the work"
        git checkout -q main
    ) >/dev/null
    printf '%s\n' "$d"
}

TICKET_OK='---
id: PROJ-1
title: Test ticket for land-branch selftest
created: 2026-01-01
updated: 2026-01-01
executor: agent
tags: [test]
blocked_by: []
touches:
  - foo.txt
verify: |
  true
outcome:
---

## Problem
selftest fixture.
'

TICKET_NO_OUTCOME='---
id: PROJ-1
title: Test ticket missing outcome/updated
created: 2026-01-01
executor: agent
tags: [test]
blocked_by: []
touches:
  - foo.txt
verify: |
  true
---

## Problem
selftest fixture with no outcome:/updated: fields.
'

export LAND_BRANCH_COAUTHOR="Test <test@example.invalid>"
export LAND_BRANCH_SESSION="https://example.invalid/session"

valid_yaml_frontmatter() {
    # $1: ticket file. Exits 0 if the frontmatter block parses as YAML.
    python3 -c '
import sys, yaml
text = open(sys.argv[1]).read()
parts = text.split("---", 2)
if len(parts) < 3:
    print("no closed frontmatter block", file=sys.stderr)
    sys.exit(1)
try:
    yaml.safe_load(parts[1])
except Exception as e:
    print(f"YAML parse error: {e}", file=sys.stderr)
    sys.exit(1)
' "$1"
}

# assert_invoking_untouched REPO BEFORE_HEAD BEFORE_STATUS LABEL — a
# landing (successful or refused) never mutates the invoking tree: its HEAD
# and working-tree status must be exactly what they were before the run.
assert_invoking_untouched() {
    local repo="$1" before_head="$2" before_status="$3" label="$4" after_head after_status
    after_head=$(cd "$repo" && git rev-parse HEAD 2>/dev/null) || after_head="(git rev-parse failed)"
    after_status=$(cd "$repo" && git status --porcelain 2>/dev/null) || after_status="(git status failed)"
    if [ "$after_head" != "$before_head" ]; then
        bad "$label: invoking tree's HEAD moved ($before_head -> $after_head) — it must never be mutated"
    elif [ "$after_status" != "$before_status" ]; then
        bad "$label: invoking tree's working-tree status changed:
before:
$before_status
after:
$after_status"
    else
        ok "$label: invoking tree's HEAD and working-tree status are untouched"
    fi
}

# ---- test 1: default outcome (contains an apostrophe) must be valid YAML

REPO=$(fresh_repo t1 "$TICKET_OK")
INVOKE_HEAD=$(cd "$REPO" && git rev-parse HEAD)
INVOKE_STATUS=$(cd "$REPO" && git status --porcelain)
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t1.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test1 (default outcome, apostrophe): land-branch.sh exited $RC:
$(cat "$WORK/t1.out")"
elif ! land_fetch "$REPO" main "issues/completed/PROJ-1.md" "$WORK/t1-completed.md"; then
    bad "test1: issues/completed/PROJ-1.md was not found on origin's main after landing"
elif ! valid_yaml_frontmatter "$WORK/t1-completed.md" 2>"$WORK/t1.yamlerr"; then
    bad "test1: completed ticket's frontmatter is not valid YAML: $(cat "$WORK/t1.yamlerr")"
else
    ok "test1: default outcome (contains an apostrophe) lands as valid YAML"
fi
assert_invoking_untouched "$REPO" "$INVOKE_HEAD" "$INVOKE_STATUS" "test1 invoking-tree"

# ---- test 2: --outcome-file with a slash, an ampersand, and two lines

REPO=$(fresh_repo t2 "$TICKET_OK")
INVOKE_HEAD=$(cd "$REPO" && git rev-parse HEAD)
INVOKE_STATUS=$(cd "$REPO" && git status --porcelain)
OUTCOME_FILE="$WORK/outcome2.txt"
printf 'Fixed the a/b path & the c/d path too.\nSecond line with '"'"'quotes'"'"' and "doubles".\n' > "$OUTCOME_FILE"
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1 --outcome-file "$OUTCOME_FILE") >"$WORK/t2.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test2 (--outcome-file with / & and 2 lines): land-branch.sh exited $RC:
$(cat "$WORK/t2.out")"
elif ! land_fetch "$REPO" main "issues/completed/PROJ-1.md" "$WORK/t2-completed.md"; then
    bad "test2: issues/completed/PROJ-1.md was not found on origin's main after landing"
elif ! valid_yaml_frontmatter "$WORK/t2-completed.md" 2>"$WORK/t2.yamlerr"; then
    bad "test2: completed ticket's frontmatter is not valid YAML: $(cat "$WORK/t2.yamlerr")"
else
    GOT=$(python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]).read().split("---", 2)[1])
print(d.get("outcome", ""), end="")
' "$WORK/t2-completed.md")
    WANT=$(cat "$OUTCOME_FILE")
    if [ "$GOT" = "$WANT" ]; then
        ok "test2: --outcome-file with / & and 2 lines round-trips exactly through YAML"
    else
        bad "test2: outcome round-trip mismatch — got:
$GOT
want:
$WANT"
    fi
fi
assert_invoking_untouched "$REPO" "$INVOKE_HEAD" "$INVOKE_STATUS" "test2 invoking-tree"

# ---- test 3: ticket with no outcome:/updated: fields must be REFUSED,
# BEFORE the integration worktree is even created — nothing pushed, nothing
# left on disk for the next run to trip over.

REPO=$(fresh_repo t3 "$TICKET_NO_OUTCOME")
BARE=$(land_bare_of "$REPO")
BEFORE_BARE_HEAD=$(git -C "$BARE" rev-parse main)
INVOKE_HEAD=$(cd "$REPO" && git rev-parse HEAD)
INVOKE_STATUS=$(cd "$REPO" && git status --porcelain)
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t3.out" 2>&1
RC=$?
set -e
AFTER_BARE_HEAD=$(git -C "$BARE" rev-parse main)
if [ "$RC" -eq 0 ]; then
    bad "test3 (ticket missing outcome:/updated:): land-branch.sh exited 0 — should have refused before mutating anything"
elif [ "$BEFORE_BARE_HEAD" != "$AFTER_BARE_HEAD" ]; then
    bad "test3: origin's main moved ($BEFORE_BARE_HEAD -> $AFTER_BARE_HEAD) even though the run was refused"
elif [ -e "$REPO-land" ]; then
    bad "test3: integration worktree '$REPO-land' was created even though the ticket precheck should refuse before ever touching it"
elif ! grep -qi "outcome\|updated" "$WORK/t3.out"; then
    bad "test3: refusal message doesn't mention the missing field:
$(cat "$WORK/t3.out")"
else
    ok "test3: ticket missing outcome:/updated: is refused before the integration worktree is touched, nothing pushed"
fi
assert_invoking_untouched "$REPO" "$INVOKE_HEAD" "$INVOKE_STATUS" "test3 invoking-tree"

# ---- test 4: after a normal completion, the integration worktree must be
# fully clean — no dangling staged deletion of the pre-move path left for
# the NEXT run's dirty-integration-worktree gate to trip on.

REPO=$(fresh_repo t4 "$TICKET_OK")
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t4.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test4 (post-commit cleanliness): land-branch.sh exited $RC:
$(cat "$WORK/t4.out")"
else
    LAND="$REPO-land"
    LEFTOVER=$(git -C "$LAND" status --porcelain)
    OLD_IN_HEAD=$(git -C "$LAND" cat-file -e HEAD:issues/in-progress/PROJ-1.md 2>/dev/null && echo yes || echo no)
    NEW_IN_HEAD=$(git -C "$LAND" cat-file -e HEAD:issues/completed/PROJ-1.md 2>/dev/null && echo yes || echo no)
    if [ -n "$LEFTOVER" ]; then
        bad "test4: integration worktree is not clean after the completion commit (would trip the next run's dirty-worktree gate):
$LEFTOVER"
    elif [ "$OLD_IN_HEAD" = yes ]; then
        bad "test4: HEAD still contains issues/in-progress/PROJ-1.md after completion — the move did not fully land"
    elif [ "$NEW_IN_HEAD" != yes ]; then
        bad "test4: HEAD does not contain issues/completed/PROJ-1.md after completion"
    else
        ok "test4: completion commit is clean — old path gone from HEAD, new path present, nothing left staged in the integration worktree"
    fi
fi

# ---- test 5: an EXISTING multi-line outcome containing a blank line must
# be fully replaced, not partially — the awk skip-loop used to stop at the
# first blank line inside the old block and let every stale line after it
# fall through into the rewritten frontmatter as ordinary top-level content.

TICKET_STALE_OUTCOME='---
id: PROJ-1
title: Test ticket with a stale multi-line outcome
created: 2026-01-01
updated: 2026-01-01
executor: agent
tags: [test]
blocked_by: []
touches:
  - foo.txt
verify: |
  true
outcome: |
  STALE first line

  STALE after blank line
  STALE last line
---

## Problem
selftest fixture.
'
REPO=$(fresh_repo t5 "$TICKET_STALE_OUTCOME")
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1 --outcome "fresh outcome") >"$WORK/t5.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test5 (stale multi-line outcome with a blank line): land-branch.sh exited $RC:
$(cat "$WORK/t5.out")"
elif ! land_fetch "$REPO" main "issues/completed/PROJ-1.md" "$WORK/t5-completed.md"; then
    bad "test5: issues/completed/PROJ-1.md was not found on origin's main after landing"
elif grep -q "STALE" "$WORK/t5-completed.md"; then
    bad "test5: stale outcome lines survived the rewrite:
$(grep -A5 '^outcome:' "$WORK/t5-completed.md")"
else
    GOT=$(python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]).read().split("---", 2)[1])
print(d.get("outcome", ""), end="")
' "$WORK/t5-completed.md")
    if [ "$GOT" = "fresh outcome" ]; then
        ok "test5: an existing multi-line outcome with a blank line is fully replaced, not partially"
    else
        bad "test5: outcome after rewrite is '$GOT', expected 'fresh outcome'"
    fi
fi

# ---- test 6: an outcome containing a line that is exactly '---' must not
# truncate the ticket's frontmatter when read back by the plugin's own
# parser (skills/to-issues/scripts/issues.py parse_frontmatter) — a
# substring split on "---" would treat the indented '---' inside the block
# scalar as the closing fence and dump the rest of the real frontmatter and
# body into what it thinks is body text.
#
# Parses with the issues.py COPIED INTO THIS REPO by fresh_repo (the
# revision passed as this script's 2nd argument, same-revision as whatever
# land-branch.sh under test would have shipped alongside) — NOT this
# script's own $HERE/../skills/... copy. Importing the outside copy always
# tests today's (already-fixed) parser regardless of which land-branch.sh
# revision produced the file, which is why an earlier version of this test
# reported GREEN even against a pre-fix land-branch.sh: it was land-branch
# that regressed, but the always-current parser papered over the exact
# truncation this test means to catch.
#
# The assertion also checks the FULL outcome text round-trips exactly, not
# just that id/verify/body-marker survive — the old substring split still
# left all three of those intact while truncating outcome down to just
# "first line", so a looser check would have reported this case as fine.

REPO=$(fresh_repo t6 "$TICKET_OK")
OUTCOME_FILE="$WORK/outcome6.txt"
printf 'first line\n---\nlast line\n' > "$OUTCOME_FILE"
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1 --outcome-file "$OUTCOME_FILE") >"$WORK/t6.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test6 (outcome containing a literal '---' line): land-branch.sh exited $RC:
$(cat "$WORK/t6.out")"
elif ! land_fetch "$REPO" main "issues/completed/PROJ-1.md" "$WORK/t6-completed.md"; then
    bad "test6: issues/completed/PROJ-1.md was not found on origin's main after landing"
else
    CHECK=$(python3 -c '
import sys
sys.path.insert(0, sys.argv[2])
import issues
data, body = issues.parse_frontmatter(open(sys.argv[1]).read())
ok = (data.get("id") == "PROJ-1"
      and "true" in (data.get("verify") or "")
      and "## Problem" in body
      and data.get("outcome") == "first line\n---\nlast line")
print("OK" if ok else "BROKEN: id=%r verify=%r outcome=%r body=%r" % (data.get("id"), data.get("verify"), data.get("outcome"), body))
' "$WORK/t6-completed.md" "$REPO/skills/to-issues/scripts")
    if [ "$CHECK" = "OK" ]; then
        ok "test6: an outcome containing a literal '---' line round-trips exactly (issues.py's parser is line-anchored)"
    else
        bad "test6: $CHECK"
    fi
fi

# ---- test 7: a dirty invoking tree must NOT block a landing (port
# — replaces the retired --tolerate-dirty scenario now that the merge runs
# in the integration worktree, not the invoking tree: there is nothing left
# for a dirty-invoking-tree preflight to protect). Both an uncommitted edit
# to a tracked file and an untracked scratch file must survive
# byte-identical, and land-branch.sh must never touch the shared stash
# stack to get there.

REPO=$(fresh_repo t7 "$TICKET_OK")
echo "local edit, never committed" >> "$REPO/notes/n.md"
printf 'untracked scratch content\n' > "$REPO/scratch.txt"
DIRTY_N_BEFORE=$(cat "$REPO/notes/n.md")
DIRTY_SCRATCH_BEFORE=$(cat "$REPO/scratch.txt")
STASH_COUNT_BEFORE=$(git -C "$REPO" stash list | wc -l | tr -d ' ')
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t7.out" 2>&1
RC=$?
set -e
STASH_COUNT_AFTER=$(git -C "$REPO" stash list | wc -l | tr -d ' ')
DIRTY_N_AFTER=$(cat "$REPO/notes/n.md")
DIRTY_SCRATCH_AFTER=$(cat "$REPO/scratch.txt")
if [ "$RC" -ne 0 ]; then
    bad "test7 (dirty invoking tree does not block landing): land-branch.sh exited $RC:
$(cat "$WORK/t7.out")"
elif [ "$DIRTY_N_AFTER" != "$DIRTY_N_BEFORE" ] || [ "$DIRTY_SCRATCH_AFTER" != "$DIRTY_SCRATCH_BEFORE" ]; then
    bad "test7: a dirty path in the invoking tree changed during the landing — it must stay byte-identical"
elif [ "$STASH_COUNT_AFTER" != "$STASH_COUNT_BEFORE" ]; then
    bad "test7: the invoking repo's stash stack changed ($STASH_COUNT_BEFORE -> $STASH_COUNT_AFTER) — land-branch.sh must never stash"
elif ! land_fetch "$REPO" main "issues/completed/PROJ-1.md" "$WORK/t7-completed.md"; then
    bad "test7: PROJ-1 was not completed on origin's main despite a dirty invoking tree"
else
    ok "test7: a dirty invoking tree (uncommitted edit + untracked scratch file) does not block a landing; both dirty paths survive byte-identical, no stash used"
fi

# ---- test 8: the worker's OWN branch already moved the ticket file to
# awaiting-deployment/ (a legitimate mixed-executor move, not a violation of
# "a worker never completes its own ticket") before land-branch runs. The
# pre-merge preflight (1c) still sees the ticket at its old path on
# $TARGET_BRANCH; the merge is what actually relocates it. Before the
# an earlier port, land-branch tried to git-mv the stale pre-merge path
# after the merge, found it gone, and reverted a clean merge.

# worker_moved_repo NAME TICKET_FRONTMATTER_BODY DEST_STAGE — like
# fresh_repo, but the 'work' branch's commit also git-mv's the ticket file
# from in-progress/ to issues/$DEST_STAGE/ before land-branch.sh ever runs,
# simulating a worker (or its librarian) parking its own ticket mid-flight.
worker_moved_repo() {
    local dest_stage="$3" d="$WORK/$1"
    rm -rf "$d" "$d.git" "$d-land" "$d-land.lock"
    git init -q --bare -b main "$d.git" >/dev/null
    mkdir -p "$d/issues/in-progress" "$d/issues/$dest_stage" "$d/issues/completed" \
             "$d/scripts/lib" "$d/skills/to-issues/scripts"
    (
        cd "$d"
        git init -q -b main
        git config commit.gpgsign false
        git config gpg.format openpgp
        git config core.hooksPath /dev/null
        git config user.email "test@example.invalid"
        git config user.name "land-branch selftest"
        git config user.signingkey ""
        git remote add origin "$d.git"
        cp "$LAND_BRANCH" scripts/land-branch.sh
        cp "$KIT" scripts/lib/kit.sh
        cp "$ISSUES_PY" skills/to-issues/scripts/issues.py
        chmod +x scripts/land-branch.sh
        printf '%s' "$2" > issues/in-progress/PROJ-1.md
        git add -A
        git commit -q -m "init"
        git push -q -u origin main
        git checkout -q -b work
        echo hello > foo.txt
        git add foo.txt
        git mv "issues/in-progress/PROJ-1.md" "issues/$dest_stage/PROJ-1.md"
        git commit -q -m "PROJ-1: do the work, park in $dest_stage"
        git checkout -q main
    ) >/dev/null
    printf '%s\n' "$d"
}

REPO=$(worker_moved_repo t8 "$TICKET_OK" awaiting-deployment)
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t8.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test8 (ticket moved to awaiting-deployment/ by the branch being landed): land-branch.sh exited $RC:
$(cat "$WORK/t8.out")"
elif land_fetch "$REPO" main "issues/awaiting-deployment/PROJ-1.md" "$WORK/t8-stale.md"; then
    bad "test8: PROJ-1.md is still in issues/awaiting-deployment/ on origin's main — the post-merge re-resolution didn't pick up the branch's own move"
elif ! land_fetch "$REPO" main "issues/completed/PROJ-1.md" "$WORK/t8-completed.md"; then
    bad "test8: issues/completed/PROJ-1.md was not found on origin's main after landing"
else
    LEFTOVER=$(git -C "$REPO-land" status --porcelain)
    if [ -n "$LEFTOVER" ]; then
        bad "test8: integration worktree not clean after completion:
$LEFTOVER"
    else
        ok "test8: a ticket the branch itself moved to awaiting-deployment/ is still found and completed after the merge"
    fi
fi

# ---- test 9: a second landing against the same repo reuses the same
# integration worktree (worktree count constant, same path) rather than
# creating a duplicate.

REPO=$(fresh_repo t9 "$TICKET_OK")
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t9a.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test9 setup (first landing): land-branch.sh exited $RC:
$(cat "$WORK/t9a.out")"
else
    WT_COUNT_1=$(cd "$REPO" && git worktree list | wc -l | tr -d ' ')
    [ -d "$REPO-land" ] || bad "test9: integration worktree '$REPO-land' was not created by the first landing"

    # The first landing pushed from the integration worktree, not from
    # $REPO — $REPO's own 'main' is deliberately NOT fast-forwarded (see
    # header). Catch it up by hand, exactly as land-branch.sh's own success
    # message tells a caller to, before adding a second ticket on top of it.
    (cd "$REPO" && git pull -q --ff-only) >/dev/null

    TICKET2='---
id: PROJ-2
title: Second ticket for the worktree-reuse test
created: 2026-01-01
updated: 2026-01-01
executor: agent
tags: [test]
blocked_by: []
touches:
  - foo2.txt
verify: |
  true
outcome:
---

## Problem
selftest fixture.
'
    (
        cd "$REPO"
        mkdir -p issues/in-progress
        printf '%s' "$TICKET2" > issues/in-progress/PROJ-2.md
        git add -A
        git commit -q -m "PROJ-2: add ticket"
        git push -q origin main
        git checkout -q -b work2
        echo world > foo2.txt
        git add foo2.txt
        git commit -q -m "PROJ-2: do more work"
        git checkout -q main
    ) >/dev/null

    set +e
    (cd "$REPO" && ./scripts/land-branch.sh work2 PROJ-2) >"$WORK/t9b.out" 2>&1
    RC=$?
    set -e
    WT_COUNT_2=$(cd "$REPO" && git worktree list | wc -l | tr -d ' ')
    if [ "$RC" -ne 0 ]; then
        bad "test9 (second landing reuses the integration worktree): land-branch.sh exited $RC:
$(cat "$WORK/t9b.out")"
    elif [ "$WT_COUNT_2" != "$WT_COUNT_1" ]; then
        bad "test9: worktree count changed ($WT_COUNT_1 -> $WT_COUNT_2) after the second landing — expected the same integration worktree to be reused"
    elif ! land_fetch "$REPO" main "issues/completed/PROJ-2.md" "$WORK/t9-completed2.md"; then
        bad "test9: PROJ-2 was not completed on origin's main after the second landing"
    else
        ok "test9: a second landing reuses the same integration worktree (worktree count constant) rather than creating a duplicate"
    fi
fi

# ---- test 10: an integration-worktree lock held by a live pid refuses a
# concurrent run, naming the holder.

REPO=$(fresh_repo t10 "$TICKET_OK")
LOCKDIR="$REPO-land.lock"
printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" > "$LOCKDIR"
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t10.out" 2>&1
RC=$?
set -e
rm -rf "$LOCKDIR"
if [ "$RC" -eq 0 ]; then
    bad "test10 (lock held by a live pid): land-branch.sh exited 0 despite the integration worktree lock being held — expected a refusal"
elif ! grep -q "locked by pid $$" "$WORK/t10.out"; then
    bad "test10: refusal message doesn't name the holder pid $$:
$(cat "$WORK/t10.out")"
else
    ok "test10: an integration-worktree lock held by a live pid refuses a concurrent run, naming the holder"
fi

# ---- test 11: a lock whose holder pid is no longer running is reclaimed
# automatically, and released again after a successful landing.

REPO=$(fresh_repo t11 "$TICKET_OK")
LOCKDIR="$REPO-land.lock"
printf 'pid=999999\nstarted=%s\n' "$(date +%s)" > "$LOCKDIR"
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t11.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test11 (stale lock reclaim): land-branch.sh exited $RC against a lock held by a non-running pid:
$(cat "$WORK/t11.out")"
elif [ -e "$LOCKDIR" ]; then
    bad "test11: lock file '$LOCKDIR' still exists after a successful landing — release_land_lock did not run"
else
    ok "test11: a lock held by a pid that is no longer running is reclaimed automatically, and released again after landing"
fi

# ---- test 12: a dirty integration worktree refuses the landing BEFORE it
# is ever reset (fail-first — proven against a genuinely dirty worktree, not
# assumed), naming the offending path; --reset-land then discards it on
# request and the landing proceeds.

REPO=$(fresh_repo t12 "$TICKET_OK")
LAND="$REPO-land"
(cd "$REPO" && git worktree add --detach "$LAND" main) >/dev/null
echo "dirty" > "$LAND/dirty.txt"
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t12a.out" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
    bad "test12a (dirty integration worktree, fail-first): land-branch.sh exited 0 despite an uncommitted change in '$LAND' — expected a refusal"
elif ! grep -q "dirty.txt" "$WORK/t12a.out"; then
    bad "test12a: refusal message doesn't name the dirty file:
$(cat "$WORK/t12a.out")"
elif [ ! -f "$LAND/dirty.txt" ]; then
    bad "test12a: dirty.txt was discarded even though --reset-land was not passed"
else
    ok "test12a: a dirty integration worktree refuses the landing before it is ever reset, naming the offending path"
fi

set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1 --reset-land) >"$WORK/t12b.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test12b (--reset-land discards a dirty integration worktree): land-branch.sh exited $RC:
$(cat "$WORK/t12b.out")"
elif [ -f "$LAND/dirty.txt" ]; then
    bad "test12b: dirty.txt still present in '$LAND' after --reset-land — it should have been discarded"
elif ! land_fetch "$REPO" main "issues/completed/PROJ-1.md" "$WORK/t12-completed.md"; then
    bad "test12b: PROJ-1 was not completed on origin's main after landing with --reset-land"
else
    ok "test12b: --reset-land discards the dirty integration worktree on request and the landing proceeds"
fi

# ---- test 13: the file-mode lifecycle. A ticket in in-progress/
# is moved to awaiting-deployment/ in its OWN commit before the merge, then
# to completed/ in its own commit after it — origin/main's first-parent
# subjects read init, awaiting deployment, merge, complete, in that order,
# and the awaiting commit touches nothing but that one rename.

REPO=$(fresh_repo t13 "$TICKET_OK")
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t13.out" 2>&1
RC=$?
set -e
BARE=$(land_bare_of "$REPO")
SUBJECTS=$(git -C "$BARE" log --first-parent --reverse --format=%s main | tr '\n' '|')
WANT="init|PROJ-1: awaiting deployment|PROJ-1: merge branch 'work' into main|PROJ-1: complete|"
if [ "$RC" -ne 0 ]; then
    bad "test13 (file-mode lifecycle): land-branch.sh exited $RC:
$(cat "$WORK/t13.out")"
elif [ "$SUBJECTS" != "$WANT" ]; then
    bad "test13: origin/main first-parent subjects are '$SUBJECTS', expected '$WANT'"
else
    AWAIT_SHA=$(git -C "$BARE" log --format=%H --grep '^PROJ-1: awaiting deployment$' main | head -1)
    AWAIT_FILES=$(git -C "$BARE" show --name-status --format= -M "$AWAIT_SHA" | tr '\t' ' ')
    if [ "$AWAIT_FILES" != "R100 issues/in-progress/PROJ-1.md issues/awaiting-deployment/PROJ-1.md" ] \
        && ! printf '%s\n' "$AWAIT_FILES" | grep -qE '^R[0-9]+ issues/in-progress/PROJ-1\.md issues/awaiting-deployment/PROJ-1\.md$'; then
        bad "test13: the awaiting-deployment commit is not exactly one rename of the ticket:
$AWAIT_FILES"
    elif [ "$(printf '%s\n' "$AWAIT_FILES" | wc -l | tr -d ' ')" != "1" ]; then
        bad "test13: the awaiting-deployment commit touches more than the ticket:
$AWAIT_FILES"
    elif ! land_fetch "$REPO" main "issues/completed/PROJ-1.md" "$WORK/t13-completed.md"; then
        bad "test13: issues/completed/PROJ-1.md not on origin/main after landing"
    else
        ok "test13: in-progress -> awaiting-deployment (own commit, before the merge) -> completed (own commit, after it)"
    fi
fi

# ---- test 14: a ticket still in open/ (dispatch never moved it)
# is refused before anything happens — exit 2, origin/main untouched.

REPO=$(fresh_repo t14 "$TICKET_OK")
(
    cd "$REPO"
    mkdir -p issues/open
    git mv issues/in-progress/PROJ-1.md issues/open/PROJ-1.md
    git commit -q -m "PROJ-1: back to open for the test"
    git push -q origin main
) >/dev/null
BARE=$(land_bare_of "$REPO")
BEFORE_HEAD=$(git -C "$BARE" rev-parse main)
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t14.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 2 ]; then
    bad "test14 (ticket in open/): exit $RC, expected 2:
$(cat "$WORK/t14.out")"
elif [ "$(git -C "$BARE" rev-parse main)" != "$BEFORE_HEAD" ]; then
    bad "test14: origin/main moved on a refused landing"
elif ! grep -q "lifecycle was skipped" "$WORK/t14.out"; then
    bad "test14: refusal does not name the skipped lifecycle:
$(cat "$WORK/t14.out")"
else
    ok "test14: a ticket still in open/ is refused before the merge, nothing pushed"
fi

# ---- test 15: --no-complete runs only the first move — the ticket
# ends in awaiting-deployment/ on origin/main, never in completed/.

REPO=$(fresh_repo t15 "$TICKET_OK")
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1 --no-complete) >"$WORK/t15.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test15 (--no-complete): land-branch.sh exited $RC:
$(cat "$WORK/t15.out")"
elif ! land_fetch "$REPO" main "issues/awaiting-deployment/PROJ-1.md" "$WORK/t15-await.md"; then
    bad "test15: issues/awaiting-deployment/PROJ-1.md not on origin/main after --no-complete"
elif land_fetch "$REPO" main "issues/completed/PROJ-1.md" "$WORK/t15-done.md"; then
    bad "test15: --no-complete completed the ticket"
else
    ok "test15: --no-complete moves the ticket to awaiting-deployment/ and stops there"
fi

# ---- test 16: a ticket larger than the pipe buffer still lands.
# The outcome-block assertions used to pipe `git show` into `grep -q` under
# pipefail: grep exits on the early frontmatter match, git show takes SIGPIPE
# writing the rest, and the landing was reverted as "does not carry the
# outcome block". Deterministic at this size, not a timing race.

BIG_BODY=$(awk 'BEGIN { for (i = 0; i < 4000; i++) printf "filler line %05d for the large-ticket pipe test, padded to about eighty bytes\n", i }')
REPO=$(fresh_repo t16 "$TICKET_OK$BIG_BODY")
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t16.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test16 (ticket over 300 KB): land-branch.sh exited $RC:
$(tail -5 "$WORK/t16.out")"
elif ! land_fetch "$REPO" main "issues/completed/PROJ-1.md" "$WORK/t16-completed.md"; then
    bad "test16: issues/completed/PROJ-1.md not on origin/main after landing a large ticket"
elif [ "$(wc -c < "$WORK/t16-completed.md" | tr -d ' ')" -lt 300000 ]; then
    bad "test16: completed ticket is $(wc -c < "$WORK/t16-completed.md" | tr -d ' ') bytes — the body did not survive"
else
    ok "test16: a ticket larger than the pipe buffer lands and completes (no SIGPIPE false assertion)"
fi

# ---- test 17: LAND_BRANCH_COAUTHOR / LAND_BRANCH_SESSION are
# optional. Unset means the completion commit carries no trailer for that
# var (owner decision 2026-09-15: attribution defaults to the owner alone),
# not a refusal — and landing still succeeds.

REPO=$(fresh_repo t17 "$TICKET_OK")
set +e
(cd "$REPO" && env -u LAND_BRANCH_COAUTHOR -u LAND_BRANCH_SESSION ./scripts/land-branch.sh work PROJ-1) >"$WORK/t17.out" 2>&1
RC=$?
set -e
BARE=$(land_bare_of "$REPO")
COMMIT_MSG=$(git -C "$BARE" log -1 --format=%B main 2>/dev/null) || COMMIT_MSG=""
if [ "$RC" -ne 0 ]; then
    bad "test17 (both trailer vars unset): land-branch.sh exited $RC — should have landed with no trailers:
$(tail -5 "$WORK/t17.out")"
elif [ -z "$COMMIT_MSG" ]; then
    # An absence check against an empty string passes vacuously; a failed
    # log lookup must not read as "no trailer" (script-reviewer finding).
    bad "test17: could not read the completion commit message from $BARE (main) — absence check would be vacuous"
elif printf '%s' "$COMMIT_MSG" | grep -q "Co-Authored-By:\|Claude-Session:"; then
    bad "test17: completion commit carries a trailer even though both vars were unset:
$COMMIT_MSG"
else
    ok "test17: both trailer vars unset — landing succeeds, completion commit carries no trailer"
fi

# ---- test 18: both vars set (the selftest's default exports)
# still produce BOTH trailers, byte-for-byte the pre-change shape. Spec
# review found no assertion had ever checked trailer PRESENCE.

REPO=$(fresh_repo t18 "$TICKET_OK")
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t18.out" 2>&1
RC=$?
set -e
BARE=$(land_bare_of "$REPO")
COMMIT_MSG=$(git -C "$BARE" log -1 --format=%B main 2>/dev/null) || COMMIT_MSG=""
if [ "$RC" -ne 0 ]; then
    bad "test18 (both trailer vars set): land-branch.sh exited $RC:
$(tail -5 "$WORK/t18.out")"
elif ! printf '%s' "$COMMIT_MSG" | grep -q "^Co-Authored-By: $LAND_BRANCH_COAUTHOR\$"; then
    bad "test18: completion commit is missing the Co-Authored-By trailer although LAND_BRANCH_COAUTHOR is set:
$COMMIT_MSG"
elif ! printf '%s' "$COMMIT_MSG" | grep -q "^Claude-Session: $LAND_BRANCH_SESSION\$"; then
    bad "test18: completion commit is missing the Claude-Session trailer although LAND_BRANCH_SESSION is set:
$COMMIT_MSG"
else
    ok "test18: both trailer vars set — completion commit carries both trailers as before"
fi

# ---- test 19: only ONE var set -> only that trailer, no refusal.
# Guards against a regression to the old all-or-nothing check.

REPO=$(fresh_repo t19 "$TICKET_OK")
set +e
(cd "$REPO" && env -u LAND_BRANCH_SESSION ./scripts/land-branch.sh work PROJ-1) >"$WORK/t19.out" 2>&1
RC=$?
set -e
BARE=$(land_bare_of "$REPO")
COMMIT_MSG=$(git -C "$BARE" log -1 --format=%B main 2>/dev/null) || COMMIT_MSG=""
if [ "$RC" -ne 0 ]; then
    bad "test19 (only LAND_BRANCH_COAUTHOR set): land-branch.sh exited $RC — should have landed with one trailer:
$(tail -5 "$WORK/t19.out")"
elif ! printf '%s' "$COMMIT_MSG" | grep -q "^Co-Authored-By: $LAND_BRANCH_COAUTHOR\$"; then
    bad "test19: completion commit is missing the Co-Authored-By trailer although LAND_BRANCH_COAUTHOR is set:
$COMMIT_MSG"
elif printf '%s' "$COMMIT_MSG" | grep -q "Claude-Session:"; then
    bad "test19: completion commit carries a Claude-Session trailer although LAND_BRANCH_SESSION was unset:
$COMMIT_MSG"
else
    ok "test19: only LAND_BRANCH_COAUTHOR set — landing succeeds, exactly that one trailer appears"
fi

echo
echo "$PASS passed, $FAIL failed (against: $LAND_BRANCH)"
[ "$FAIL" -eq 0 ]
