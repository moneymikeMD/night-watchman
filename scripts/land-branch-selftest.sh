#!/bin/bash
#
# Selftest for land-branch.sh's file-mode completion path. Builds a scratch
# git repo per test case, with config LOCAL to that repo only — never reads
# or writes the operator's global ~/.gitconfig.
#
# INTEGRATION WORKTREE. land-branch.sh merges/lints/completes/pushes in a
# dedicated `<repo>-land` worktree, so every fixture repo ($WORK/<name>) has
# its own bare "origin" at $WORK/<name>.git. A landing's effect is only ever
# visible by reading that bare repo back (`land_bare_of`/`land_fetch`), never
# from the fixture repo's own tree or 'main' ref, which a landing must never
# move. Several tests create, dirty or pre-seed `<name>-land` and
# `<name>-land.lock` by hand to exercise the lifecycle and lock gates.
#
# Usage: scripts/land-branch-selftest.sh [path-to-land-branch.sh] [path-to-issues.py]
# land-branch.sh defaults to this repo's copy; issues.py defaults to the one
# in the work-order plugin this repo depends on, located by
# scripts/work-order-root.sh. Pass an older revision of EITHER to reproduce
# the RED failures below against pre-fix code; pass both when the finding
# spans the two files (test 6 does).

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND_BRANCH="${1:-$HERE/land-branch.sh}"
ISSUES_PY="${2:-}"
[ -n "$ISSUES_PY" ] || ISSUES_PY="$("$HERE/work-order-root.sh" --issues-py)"
KIT="$HERE/lib/kit.sh"
[ -r "$LAND_BRANCH" ] || { echo "cannot read $LAND_BRANCH" >&2; exit 2; }
[ -r "$ISSUES_PY" ] || { echo "cannot read $ISSUES_PY" >&2; exit 2; }
[ -r "$KIT" ] || { echo "cannot read $KIT" >&2; exit 2; }
# land-branch.sh drives ai-toolkit's land-core.sh; each fixture gets this
# repo's resolver, pointed at the checkout it resolves here.
AI_TOOLKIT_ROOT="$("$HERE/ai-toolkit-root.sh")" || { echo "cannot resolve ai-toolkit (set AI_TOOLKIT_ROOT)" >&2; exit 2; }
export AI_TOOLKIT_ROOT
"$HERE/ai-toolkit-root.sh" --land-core >/dev/null || { echo "ai-toolkit at $AI_TOOLKIT_ROOT has no scripts/land-core.sh" >&2; exit 2; }
unset LAND_CORE_LINT_CMD LAND_CORE_HOOK LAND_CORE_TARGET_BRANCH

unset HERDR_ENV HERDR_PANE_ID LAND_BRANCH_ORCHESTRATOR_PANE LAND_BRANCH_HANDOFF_FILE

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
# $WORK/NAME with a bare "origin" at $WORK/NAME.git, one ticket in
# issues/in-progress/, and a 'work' branch ready to land. Prints the repo path.
fresh_repo() {
    local ticket_body="$2" d="$WORK/$1"
    rm -rf "$d" "$d.git" "$d-land" "$d-land.lock"
    git init -q --bare -b main "$d.git" >/dev/null
    mkdir -p "$d/issues/in-progress" "$d/issues/completed" "$d/scripts/lib" "$d/notes" \
             "$d/vendor/work-order/reference"
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
        cp "$HERE/ai-toolkit-root.sh" scripts/ai-toolkit-root.sh
        cp "$HERE/land-ack.sh" scripts/land-ack.sh
        cp "$ISSUES_PY" vendor/work-order/reference/issues.py
        chmod +x scripts/land-branch.sh
        printf '%s' "$ticket_body" > issues/in-progress/PROJ-1.md
        # Tracked from the first commit so a later edit shows as "M " at this
        # exact path, which the dirty-invoking-tree scenario asserts on.
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

# ---- test 5: an EXISTING multi-line outcome containing a blank line must be
# fully replaced — the awk skip-loop must not stop at that blank line.

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
# truncate the ticket's frontmatter when read back by issues.py. Parses with
# the issues.py COPIED INTO the fixture repo — the always-current parser
# papers over a pre-fix land-branch.sh and reports GREEN.

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
' "$WORK/t6-completed.md" "$REPO/vendor/work-order/reference")
    if [ "$CHECK" = "OK" ]; then
        ok "test6: an outcome containing a literal '---' line round-trips exactly (issues.py's parser is line-anchored)"
    else
        bad "test6: $CHECK"
    fi
fi

# ---- test 7: a dirty invoking tree must NOT block a landing. Both an
# uncommitted edit to a tracked file and an untracked scratch file must
# survive byte-identical, without land-branch.sh touching the stash stack.

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
# awaiting-deployment/ before land-branch runs. The pre-merge preflight sees
# the old path; the merge is what relocates it.

# worker_moved_repo NAME TICKET_FRONTMATTER_BODY DEST_STAGE — like
# fresh_repo, but the 'work' branch's commit also git-mv's the ticket file
# from in-progress/ to issues/$DEST_STAGE/ before land-branch.sh ever runs,
# simulating a worker (or its librarian) parking its own ticket mid-flight.
worker_moved_repo() {
    local dest_stage="$3" d="$WORK/$1"
    rm -rf "$d" "$d.git" "$d-land" "$d-land.lock"
    git init -q --bare -b main "$d.git" >/dev/null
    mkdir -p "$d/issues/in-progress" "$d/issues/$dest_stage" "$d/issues/completed" \
             "$d/scripts/lib" "$d/vendor/work-order/reference"
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
        cp "$HERE/ai-toolkit-root.sh" scripts/ai-toolkit-root.sh
        cp "$ISSUES_PY" vendor/work-order/reference/issues.py
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

    # $REPO's own 'main' is deliberately NOT fast-forwarded (see header), so
    # catch it up by hand before adding a second ticket on top.
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

# ---- test 13: the file-mode lifecycle. origin/main's first-parent subjects
# must read init, awaiting deployment, merge, complete, in that order, with
# the awaiting commit touching nothing but that one rename.

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

# ---- test 16: a ticket larger than the pipe buffer still lands. Guards the
# `git show | grep -q` SIGPIPE-under-pipefail regression; deterministic at
# this size, not a timing race.

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

# ---- test 17 (NWM-131, decision 4): the trailer env vars are gone. With
# both exported, no commit the landing pushes carries either trailer, and
# neither name survives anywhere in land-branch.sh. RED against a pre-NWM-131
# revision, which honoured both.

REPO=$(fresh_repo t17 "$TICKET_OK")
set +e
(cd "$REPO" && LAND_BRANCH_COAUTHOR="Test <test@example.invalid>" \
    LAND_BRANCH_SESSION="https://example.invalid/session" \
    ./scripts/land-branch.sh work PROJ-1) >"$WORK/t17.out" 2>&1
RC=$?
set -e
BARE=$(land_bare_of "$REPO")
PUSHED_MSGS=$(git -C "$BARE" log --format=%B main 2>/dev/null) || PUSHED_MSGS=""
if [ "$RC" -ne 0 ]; then
    bad "test17 (trailer vars set): land-branch.sh exited $RC:
$(tail -5 "$WORK/t17.out")"
elif ! printf '%s' "$PUSHED_MSGS" | grep -q "PROJ-1: complete"; then
    # An absence check against a history without the landing is vacuous.
    bad "test17: the pushed history has no completion commit — absence check would be vacuous"
elif printf '%s' "$PUSHED_MSGS" | grep -q "Co-Authored-By:\|Claude-Session:"; then
    bad "test17: a pushed commit carries a trailer from the removed env vars:
$PUSHED_MSGS"
elif grep -q "LAND_BRANCH_COAUTHOR\|LAND_BRANCH_SESSION\|Co-Authored-By\|Claude-Session" "$LAND_BRANCH"; then
    bad "test17: land-branch.sh still names a trailer variable:
$(grep -n "LAND_BRANCH_COAUTHOR\|LAND_BRANCH_SESSION\|Co-Authored-By\|Claude-Session" "$LAND_BRANCH")"
else
    ok "test17: the trailer env vars are ignored and gone from land-branch.sh — no pushed commit carries a trailer"
fi

# ---- HERDR_ENV cleanup: exit the worker's Claude session before removing its
# workspace (NWM-117). The stub `herdr` deletes its alive marker on the SECOND
# `send-keys ... enter`, modelling the picker's accept-then-submit;
# STUB_HERDR_NEVER_EXITS=1 leaves it to exercise the bounded wait.
install_stub_herdr_exit() {
    local repo="$1"
    mkdir -p "$repo/bin"
    cat > "$repo/bin/herdr" <<'STUBEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_HERDR_LOG"
case "$1 $2" in
    "agent get")
        if [ -f "$STUB_AGENT_ALIVE" ]; then
            printf '{"result":{"agent":{"pane_id":"p1"}}}\n'
            exit 0
        fi
        echo "stub herdr: agent not found" >&2
        exit 1
        ;;
    "pane send-text")
        if [ "${STUB_ORCH_ACKS:-0}" = 1 ] && [ "$3" = orch1 ]; then
            eval "${4##*Acknowledge with: }" >/dev/null
        fi
        exit 0
        ;;
    "pane send-keys")
        exit 0
        ;;
    "agent send-keys")
        if [ "${STUB_HERDR_NEVER_EXITS:-0}" != 1 ] && [ -f "$STUB_AGENT_ALIVE" ]; then
            COUNT_FILE="$(dirname "$STUB_AGENT_ALIVE")/sendkeys.count"
            n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
            n=$((n + 1))
            echo "$n" > "$COUNT_FILE"
            [ "$n" -ge 2 ] && rm -f "$STUB_AGENT_ALIVE"
        fi
        exit 0
        ;;
    "worktree list")
        printf '{"result":{"worktrees":[{"is_linked_worktree":true,"branch":"work","open_workspace_id":"ws1"}]}}\n'
        ;;
    "worktree remove")
        exit 0
        ;;
    *)
        echo "stub herdr: unexpected call: $*" >&2
        exit 99
        ;;
esac
STUBEOF
    chmod +x "$repo/bin/herdr"
}

# ---- test 20: agent alive, exits within the bound -> clean-exit message
# logged, THEN (not instead of) the workspace removal runs.

REPO=$(fresh_repo t20 "$TICKET_OK")
install_stub_herdr_exit "$REPO"
: > "$REPO/bin/alive"
STUB_HERDR_LOG="$WORK/t20.herdr.log"
: > "$STUB_HERDR_LOG"
set +e
(cd "$REPO" && HERDR_ENV=1 PATH="$REPO/bin:$PATH" \
    STUB_HERDR_LOG="$STUB_HERDR_LOG" STUB_AGENT_ALIVE="$REPO/bin/alive" \
    ./scripts/land-branch.sh work PROJ-1) >"$WORK/t20.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test20 (herdr exit, happy path): land-branch.sh exited $RC:
$(tail -15 "$WORK/t20.out")"
elif ! grep -q "worker session on 'work' exited cleanly" "$WORK/t20.out"; then
    bad "test20: no clean-exit confirmation logged:
$(cat "$WORK/t20.out")"
elif [ "$(grep -n "^agent get work$" "$STUB_HERDR_LOG" | head -1 | cut -d: -f1)" -gt "$(grep -n "^worktree remove" "$STUB_HERDR_LOG" | head -1 | cut -d: -f1)" ]; then
    bad "test20: 'agent get' logged after 'worktree remove' — exit step did not run before removal:
$(cat "$STUB_HERDR_LOG")"
else
    ok "test20: a live worker exits cleanly before its workspace is removed"
fi

# ---- test 21: no live agent by the branch name -> exit step is skipped
# outright (no send-text/send-keys calls), removal proceeds unchanged.

REPO=$(fresh_repo t21 "$TICKET_OK")
install_stub_herdr_exit "$REPO"
STUB_HERDR_LOG="$WORK/t21.herdr.log"
: > "$STUB_HERDR_LOG"
set +e
(cd "$REPO" && HERDR_ENV=1 PATH="$REPO/bin:$PATH" \
    STUB_HERDR_LOG="$STUB_HERDR_LOG" STUB_AGENT_ALIVE="$REPO/bin/alive" \
    ./scripts/land-branch.sh work PROJ-1) >"$WORK/t21.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test21 (herdr exit, no live agent): land-branch.sh exited $RC:
$(tail -15 "$WORK/t21.out")"
elif ! grep -q "no live Herdr agent named 'work' — nothing to exit" "$WORK/t21.out"; then
    bad "test21: missing the 'nothing to exit' message:
$(cat "$WORK/t21.out")"
elif grep -q "^pane send-text\|^agent send-keys" "$STUB_HERDR_LOG"; then
    bad "test21: sent exit keys despite no live agent:
$(cat "$STUB_HERDR_LOG")"
else
    ok "test21: no live agent by the branch name — exit step skipped, removal unaffected"
fi

# ---- test 22: a worker that never exits within the bound is logged and
# the workspace is removed anyway — a hung worker must not block landing.

REPO=$(fresh_repo t22 "$TICKET_OK")
install_stub_herdr_exit "$REPO"
: > "$REPO/bin/alive"
STUB_HERDR_LOG="$WORK/t22.herdr.log"
: > "$STUB_HERDR_LOG"
set +e
(cd "$REPO" && HERDR_ENV=1 PATH="$REPO/bin:$PATH" \
    STUB_HERDR_LOG="$STUB_HERDR_LOG" STUB_AGENT_ALIVE="$REPO/bin/alive" \
    STUB_HERDR_NEVER_EXITS=1 LAND_BRANCH_EXIT_WAIT_S=2 \
    ./scripts/land-branch.sh work PROJ-1) >"$WORK/t22.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test22 (herdr exit, hung worker): land-branch.sh exited $RC:
$(tail -15 "$WORK/t22.out")"
elif ! grep -q "did not exit its Claude session within 2s — removing its workspace anyway" "$WORK/t22.out"; then
    bad "test22: missing the bounded-wait warning:
$(cat "$WORK/t22.out")"
elif ! grep -q "^worktree remove" "$STUB_HERDR_LOG"; then
    bad "test22: workspace was never removed after the hung worker's wait expired:
$(cat "$STUB_HERDR_LOG")"
else
    ok "test22: a hung worker is logged, not left blocking the landing — its workspace is still removed"
fi

# ---- NWM-120: closing state. The stub logs every herdr call in order; the
# durable write is the completion commit on origin, so "write precedes exit"
# is asserted as: the landed ticket carries the marker AND the orchestrator
# notification (pane orch1) is logged before the worker's /exit and removal.

write_handoff() {
    mkdir -p "$1"
    cat > "$1/closing-state.md" <<'HEOF'
orchestrator-pane: orch1

## Human run list
1. run the migration by hand

## Left undone
- the port, out of scope

## Findings
- probable auth bypass in the caddy site
HEOF
}

closing_run() {
    local name="$1" ticket="$2" handoff="$3"; shift 3
    REPO=$(fresh_repo "$name" "$ticket")
    install_stub_herdr_exit "$REPO"
    : > "$REPO/bin/alive"
    STUB_HERDR_LOG="$WORK/$name.herdr.log"
    : > "$STUB_HERDR_LOG"
    [ -z "$handoff" ] || write_handoff "$WORK/$name.handoff"
    BEFORE_MAIN=$(git -C "$WORK/$name.git" rev-parse main)
    set +e
    (cd "$REPO" && HERDR_ENV=1 PATH="$REPO/bin:$PATH" \
        STUB_HERDR_LOG="$STUB_HERDR_LOG" STUB_AGENT_ALIVE="$REPO/bin/alive" \
        LAND_BRANCH_HANDOFF_FILE="${handoff:+$WORK/$name.handoff/closing-state.md}" \
        env LAND_BRANCH_ACK_WAIT_S=1 "$@" \
        ./scripts/land-branch.sh work PROJ-1) >"$WORK/$name.out" 2>&1
    RC=$?
    set -e
}

first_line() { grep -n "$1" "$2" | head -1 | cut -d: -f1; }

# ---- test 23: agent ticket, notification never acknowledged -> still lands
# (exit 0) with a warning; closing state is in the landed ticket; ordering.

closing_run t23 "$TICKET_OK" yes
land_fetch "$REPO" main issues/completed/PROJ-1.md "$WORK/t23.ticket" || true
NOTIFY_LN=$(first_line "^pane send-text orch1" "$STUB_HERDR_LOG")
EXIT_LN=$(first_line "^pane send-text p1 /exit" "$STUB_HERDR_LOG")
REMOVE_LN=$(first_line "^worktree remove" "$STUB_HERDR_LOG")
if [ "$RC" -ne 0 ]; then
    bad "test23 (closing state, no ack): exit $RC, expected 0:
$(tail -15 "$WORK/t23.out")"
elif ! grep -q "did not acknowledge within 1s" "$WORK/t23.out"; then
    bad "test23: no unacknowledged-notification warning:
$(cat "$WORK/t23.out")"
elif ! grep -q "probable auth bypass" "$WORK/t23.ticket" 2>/dev/null || ! grep -q "Landed: yes, merge commit" "$WORK/t23.ticket"; then
    bad "test23: landed ticket does not carry the closing state:
$(cat "$WORK/t23.ticket" 2>/dev/null)"
elif [ -z "$NOTIFY_LN" ] || [ -z "$EXIT_LN" ] || [ -z "$REMOVE_LN" ] || [ "$NOTIFY_LN" -gt "$EXIT_LN" ] || [ "$EXIT_LN" -gt "$REMOVE_LN" ]; then
    bad "test23: order is not notify($NOTIFY_LN) < exit($EXIT_LN) < remove($REMOVE_LN):
$(cat "$STUB_HERDR_LOG")"
else
    ok "test23: closing state lands with the ticket before notify < exit < remove; an unacknowledged notification only warns"
fi

# ---- test 24: mixed ticket with no run list -> refused, exit 2, nothing
# mutated (origin main unchanged, no herdr call made).

TICKET_MIXED=${TICKET_OK/executor: agent/executor: mixed}
closing_run t24 "$TICKET_MIXED" ""
if [ "$RC" -ne 2 ]; then
    bad "test24 (mixed, no run list): exit $RC, expected 2:
$(tail -10 "$WORK/t24.out")"
elif [ "$(git -C "$WORK/t24.git" rev-parse main)" != "$BEFORE_MAIN" ]; then
    bad "test24: origin main moved although the landing was refused"
elif [ -s "$STUB_HERDR_LOG" ]; then
    bad "test24: herdr was called on a refused landing:
$(cat "$STUB_HERDR_LOG")"
elif ! grep -q "no '## Human run list' was found" "$WORK/t24.out"; then
    bad "test24: refusal does not name the missing run list:
$(cat "$WORK/t24.out")"
else
    ok "test24: a mixed-executor ticket with no run list is refused before anything is mutated (exit 2)"
fi

# ---- test 25: mixed ticket WITH a run list -> the run list is in the landed
# ticket.

closing_run t25 "$TICKET_MIXED" yes
land_fetch "$REPO" main issues/completed/PROJ-1.md "$WORK/t25.ticket" || true
if [ "$RC" -ne 0 ]; then
    bad "test25 (mixed, run list): exit $RC, expected 0:
$(tail -10 "$WORK/t25.out")"
elif ! grep -q "1. run the migration by hand" "$WORK/t25.ticket" 2>/dev/null; then
    bad "test25: run list missing from the landed ticket:
$(cat "$WORK/t25.ticket" 2>/dev/null)"
else
    ok "test25: a mixed-executor ticket lands with its human run list in the durable write"
fi

# ---- test 26: without HERDR_ENV nothing changes — no closing state in the
# outcome, no notification.

REPO=$(fresh_repo t26 "$TICKET_OK")
set +e
(cd "$REPO" && LAND_BRANCH_HANDOFF_FILE=/nonexistent ./scripts/land-branch.sh work PROJ-1) >"$WORK/t26.out" 2>&1
RC=$?
set -e
land_fetch "$REPO" main issues/completed/PROJ-1.md "$WORK/t26.ticket" || true
if [ "$RC" -ne 0 ]; then
    bad "test26 (no HERDR_ENV): exit $RC:
$(tail -10 "$WORK/t26.out")"
elif grep -q "Closing state" "$WORK/t26.ticket" 2>/dev/null; then
    bad "test26: closing state written although HERDR_ENV is unset"
else
    ok "test26: without HERDR_ENV the landing carries no closing state (unchanged)"
fi

# ---- NWM-134 test 27: HERDR_ENV=1 with NO hand-off file must produce the same
# landed ticket, byte for byte, as the same run with HERDR_ENV unset. Dates are
# pinned so both runs mint identical commits.

export GIT_AUTHOR_DATE="2026-01-02T03:04:05Z" GIT_COMMITTER_DATE="2026-01-02T03:04:05Z"
for MODE in complete nocomplete; do
    EXTRA=""
    [ "$MODE" = nocomplete ] && EXTRA="--no-complete --note pinned-note"
    REPO=$(fresh_repo "t27a-$MODE" "$TICKET_OK")
    install_stub_herdr_exit "$REPO"
    STUB_HERDR_LOG="$WORK/t27a-$MODE.herdr.log"; : > "$STUB_HERDR_LOG"
    set +e
    # shellcheck disable=SC2086
    (cd "$REPO" && HERDR_ENV=1 PATH="$REPO/bin:$PATH" STUB_HERDR_LOG="$STUB_HERDR_LOG" \
        STUB_AGENT_ALIVE="$REPO/bin/alive" ./scripts/land-branch.sh work PROJ-1 $EXTRA) >"$WORK/t27a-$MODE.out" 2>&1
    RC_A=$?
    set -e
    REPO_A="$REPO"
    REPO=$(fresh_repo "t27b-$MODE" "$TICKET_OK")
    set +e
    # shellcheck disable=SC2086
    (cd "$REPO" && ./scripts/land-branch.sh work PROJ-1 $EXTRA) >"$WORK/t27b-$MODE.out" 2>&1
    RC_B=$?
    set -e
    TREE_A=$(git -C "$(land_bare_of "$REPO_A")" rev-parse "main^{tree}") || TREE_A=a-unreadable
    TREE_B=$(git -C "$(land_bare_of "$REPO")" rev-parse "main^{tree}") || TREE_B=b-unreadable
    if [ "$RC_A" -ne 0 ] || [ "$RC_B" -ne 0 ]; then
        bad "test27 ($MODE): exits differ from 0 (HERDR_ENV=1: $RC_A, unset: $RC_B):
$(tail -8 "$WORK/t27a-$MODE.out")"
    elif [ "$TREE_A" != "$TREE_B" ] || [ "${#TREE_A}" -ne 40 ]; then
        bad "test27 ($MODE): HERDR_ENV=1 with no hand-off changed the landed tree ($TREE_A vs $TREE_B)"
    elif git -C "$(land_bare_of "$REPO_A")" grep -q "Closing state" main -- issues; then
        bad "test27 ($MODE): closing-state block emitted with no hand-off"
    elif grep -q "^pane send-text" "$WORK/t27a-$MODE.herdr.log"; then
        bad "test27 ($MODE): orchestrator notified with no hand-off:
$(cat "$WORK/t27a-$MODE.herdr.log")"
    else
        ok "test27 ($MODE): HERDR_ENV=1 without a hand-off lands byte-identically to HERDR_ENV unset"
    fi
done
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE

# ---- test 28: a real hand-off still emits the block (gate's other direction),
# and the orchestrator running the named consumer acknowledges the landing.

closing_run t28 "$TICKET_OK" yes STUB_ORCH_ACKS=1
land_fetch "$REPO" main issues/completed/PROJ-1.md "$WORK/t28.ticket" || true
if [ "$RC" -ne 0 ]; then
    bad "test28 (ack consumer): exit $RC, expected 0:
$(tail -15 "$WORK/t28.out")"
elif ! grep -q "Closing state (closing-state:PROJ-1:" "$WORK/t28.ticket" 2>/dev/null; then
    bad "test28: hand-off present but no closing-state block in the landed ticket"
elif ! grep -q "orchestrator acknowledged the closing state" "$WORK/t28.out"; then
    bad "test28: consumer ran but the landing did not see the ack:
$(cat "$WORK/t28.out")"
elif grep -q "did not acknowledge" "$WORK/t28.out"; then
    bad "test28: acked landing still warned of no ack"
elif ! grep -q "^pane send-text orch1 .*Acknowledge with: .*/land-ack.sh '" "$STUB_HERDR_LOG"; then
    bad "test28: notification does not name land-ack.sh:
$(cat "$STUB_HERDR_LOG")"
else
    ok "test28: hand-off present -> block emitted; the named land-ack.sh consumer completes the ack round trip"
fi

# ---- test 29: land-ack.sh itself creates only nw-ack-* files.

ACKDIR="$WORK/t29"; mkdir -p "$ACKDIR"
if ! "$HERE/land-ack.sh" "$ACKDIR/nw-ack-PROJ-1-abc" >/dev/null || [ ! -e "$ACKDIR/nw-ack-PROJ-1-abc" ]; then
    bad "test29: land-ack.sh did not create a well-named ack file"
elif "$HERE/land-ack.sh" "$ACKDIR/other-file" >/dev/null 2>&1 || [ -e "$ACKDIR/other-file" ]; then
    bad "test29: land-ack.sh created or accepted a file not named nw-ack-*"
elif "$HERE/land-ack.sh" >/dev/null 2>&1; then
    bad "test29: land-ack.sh with no argument exited 0"
else
    ok "test29: land-ack.sh creates nw-ack-* files and refuses anything else"
fi

# ---- test 30: a worker writing its hand-off file must not dirty its worktree,
# or land-branch.sh's clean-tree precondition refuses before reading it. The
# path is read out of land-branch.sh; a $LAND_BRANCH_HANDOFF_FILE elsewhere is
# the caller's concern.

HANDOFF_REL=$(grep -o '\.night-watchman/closing-state\.md' "$LAND_BRANCH" | head -1)
GI_REPO="$WORK/t30"
git init -q -b main "$GI_REPO"
cp "$HERE/../.gitignore" "$GI_REPO/.gitignore"
git -C "$GI_REPO" add .gitignore
git -C "$GI_REPO" -c user.email=t@example.invalid -c user.name=selftest -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m init
if [ -n "$HANDOFF_REL" ]; then
    mkdir -p "$GI_REPO/$(dirname "$HANDOFF_REL")"
    printf '## Findings\n- x\n' > "$GI_REPO/$HANDOFF_REL"
fi
if [ -z "$HANDOFF_REL" ]; then
    bad "test30: land-branch.sh names no closing-state.md path to check"
elif [ -n "$(git -C "$GI_REPO" status --porcelain)" ]; then
    bad "test30: writing $HANDOFF_REL dirties the worktree:
$(git -C "$GI_REPO" status --porcelain)"
else
    ok "test30: a hand-off file at $HANDOFF_REL leaves git status --porcelain empty"
fi

# ---- NWM-149 test 31: a linked worktree holding the landed branch is removed,
# and the branch with it. RED before the fix: herdr owned the only removal
# path and it only fires when a workspace is still open, so with HERDR_ENV
# unset nothing removed the worktree and `git branch -d` then failed on it.

REPO=$(fresh_repo t31 "$TICKET_OK")
WT31="$WORK/t31-wt"
git -C "$REPO" worktree add -q "$WT31" work
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t31.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test31 (worktree removal): exit $RC:
$(tail -10 "$WORK/t31.out")"
elif [ -e "$WT31" ]; then
    bad "test31: worktree '$WT31' still on disk after the landing"
elif git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $WT31"; then
    bad "test31: worktree '$WT31' still registered after the landing:
$(git -C "$REPO" worktree list)"
elif git -C "$REPO" rev-parse --verify --quiet refs/heads/work >/dev/null; then
    bad "test31: branch 'work' survived the landing, so the worktree still held it"
else
    ok "test31: a linked worktree on the landed branch is removed, and the branch with it"
fi

# ---- NWM-149 test 32: a DIRTY worktree is never force-removed. It cannot be
# reached through a landing — the precondition at the top refuses a dirty
# branch worktree — so it is asserted on the refusal itself: the tree survives.

REPO=$(fresh_repo t32 "$TICKET_OK")
WT32="$WORK/t32-wt"
git -C "$REPO" worktree add -q "$WT32" work
printf 'uncommitted\n' > "$WT32/dirty.txt"
git -C "$WT32" add dirty.txt
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t32.out" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
    bad "test32 (dirty worktree): landing exited 0, expected a refusal"
elif [ ! -e "$WT32/dirty.txt" ]; then
    bad "test32: the dirty worktree's uncommitted file was destroyed"
elif ! grep -q "uncommitted changes" "$WORK/t32.out"; then
    bad "test32: refusal does not name the uncommitted changes:
$(tail -5 "$WORK/t32.out")"
else
    ok "test32: a dirty worktree on the branch refuses the landing and is left intact"
fi

# ---- NWM-147 test 33: the file the worker brief REQUIRES uncommitted in its
# worktree must not be the file that makes the landing refuse. Reproduces in a
# repo that does NOT gitignore .night-watchman/, which is every consuming repo
# except this one.

REPO=$(fresh_repo t33 "$TICKET_OK")
WT33="$WORK/t33-wt"
git -C "$REPO" worktree add -q "$WT33" work
mkdir -p "$WT33/.night-watchman"
cat > "$WT33/.night-watchman/closing-state.md" <<'CLOSING'
## Human run list
- nothing, this is a selftest fixture

## Left undone
- nothing

## Findings
- the worktree was not refused for holding this file
CLOSING
set +e
(cd "$REPO" && HERDR_ENV=1 ./scripts/land-branch.sh work PROJ-1) >"$WORK/t33.out" 2>&1
RC=$?
set -e
COMPLETED_T33="$WORK/t33.completed"
land_fetch "$REPO" main "issues/completed/PROJ-1.md" "$COMPLETED_T33" || : > "$COMPLETED_T33"
if [ "$RC" -ne 0 ]; then
    bad "test33 (closing-state does not refuse): landing exited $RC:
$(tail -8 "$WORK/t33.out")"
elif ! grep -q "closing state written to the ticket and read back" "$WORK/t33.out"; then
    bad "test33: the landing succeeded but the closing state was not written and read back:
$(tail -8 "$WORK/t33.out")"
elif ! grep -q "the worktree was not refused for holding this file" "$COMPLETED_T33"; then
    bad "test33: the closing state did not reach the landed ticket:
$(cat "$COMPLETED_T33")"
else
    ok "test33: an uncommitted .night-watchman/closing-state.md lands, and its content reaches the ticket"
fi

# ---- NWM-147 test 34: the exemption is one path, not the directory and not
# the check. A real uncommitted edit still refuses, and so does another
# untracked file under .night-watchman/.

REPO=$(fresh_repo t34 "$TICKET_OK")
WT34="$WORK/t34-wt"
git -C "$REPO" worktree add -q "$WT34" work
mkdir -p "$WT34/.night-watchman"
printf '## Human run list
- none
' > "$WT34/.night-watchman/closing-state.md"
printf 'real uncommitted work
' >> "$WT34/foo.txt"
set +e
(cd "$REPO" && HERDR_ENV=1 ./scripts/land-branch.sh work PROJ-1) >"$WORK/t34a.out" 2>&1
RC_TRACKED=$?
set -e
git -C "$WT34" checkout -q -- foo.txt
printf 'something else the plugin did not put there
' > "$WT34/.night-watchman/scratch.txt"
set +e
(cd "$REPO" && HERDR_ENV=1 ./scripts/land-branch.sh work PROJ-1) >"$WORK/t34b.out" 2>&1
RC_SIBLING=$?
set -e
if [ "$RC_TRACKED" -eq 0 ]; then
    bad "test34: a real uncommitted edit to a tracked file no longer refuses — the exemption is too wide"
elif ! grep -q "foo.txt" "$WORK/t34a.out"; then
    bad "test34: the refusal did not name the file that caused it:
$(tail -5 "$WORK/t34a.out")"
elif [ "$RC_SIBLING" -eq 0 ]; then
    bad "test34: another untracked file under .night-watchman/ no longer refuses — the whole directory was exempted"
elif ! grep -q "scratch.txt" "$WORK/t34b.out"; then
    bad "test34: the refusal did not name the sibling file that caused it:
$(tail -5 "$WORK/t34b.out")"
else
    ok "test34: the exemption is exactly one path — a tracked edit and a sibling file both still refuse"
fi

# ---- NWM-131 test 35: a push that fails AFTER the merge leaves the merge and
# the ticket's completion commit in the integration worktree and exits 1 —
# never reverted. The push URL names a missing path: fetch works, push cannot.

REPO=$(fresh_repo t35 "$TICKET_OK")
BARE=$(land_bare_of "$REPO")
BEFORE=$(git -C "$BARE" rev-parse main)
git -C "$REPO" config remote.origin.pushurl "$WORK/t35-nowhere.git"
set +e
(cd "$REPO" && ./scripts/land-branch.sh work PROJ-1) >"$WORK/t35.out" 2>&1
RC=$?
set -e
LAND_SUBJECTS=$(git -C "$REPO-land" log --first-parent --reverse --format=%s 2>/dev/null | tr '\n' '|') || LAND_SUBJECTS=""
WANT="init|PROJ-1: awaiting deployment|PROJ-1: merge branch 'work' into main|PROJ-1: complete|"
if [ "$RC" -ne 1 ]; then
    bad "test35 (push fails): exit $RC, expected 1:
$(tail -8 "$WORK/t35.out")"
elif [ "$(git -C "$BARE" rev-parse main)" != "$BEFORE" ]; then
    bad "test35: origin/main moved although the push failed"
elif [ "$LAND_SUBJECTS" != "$WANT" ]; then
    bad "test35: the integration worktree reads '$LAND_SUBJECTS', expected '$WANT' — the landing was reverted:
$(tail -8 "$WORK/t35.out")"
elif ! git -C "$REPO" rev-parse --verify --quiet refs/heads/work >/dev/null; then
    bad "test35: branch 'work' was deleted although nothing was pushed"
elif ! grep -q "push failed" "$WORK/t35.out"; then
    bad "test35: the stop message does not name the failed push:
$(tail -5 "$WORK/t35.out")"
else
    ok "test35: a failed push keeps the merge and the completion commit locally, exits 1, and keeps the branch"
fi

# ---- NWM-131 test 36: the wrapper does not merge or push by itself — both
# are land-core.sh's — and with no ai-toolkit to resolve it stops with exit 2
# before anything is mutated: no integration worktree, origin untouched.

REPO=$(fresh_repo t36 "$TICKET_OK")
BARE=$(land_bare_of "$REPO")
BEFORE=$(git -C "$BARE" rev-parse main)
mkdir -p "$WORK/t36-not-ai-toolkit"
set +e
(cd "$REPO" && AI_TOOLKIT_ROOT="$WORK/t36-not-ai-toolkit" ./scripts/land-branch.sh work PROJ-1) >"$WORK/t36.out" 2>&1
RC=$?
set -e
if grep -nE 'git (-C [^ ]+ )?(merge --no-ff|push origin)' "$LAND_BRANCH" | grep -v 'echo "' >"$WORK/t36.grep"; then
    bad "test36: land-branch.sh still merges or pushes by itself:
$(cat "$WORK/t36.grep")"
elif ! grep -q 'ai-toolkit-root.sh" --land-core' "$LAND_BRANCH"; then
    bad "test36: land-branch.sh does not resolve its core through ai-toolkit-root.sh --land-core"
elif [ "$RC" -ne 2 ]; then
    bad "test36 (no ai-toolkit): exit $RC, expected 2:
$(tail -5 "$WORK/t36.out")"
elif [ -e "$REPO-land" ] || [ "$(git -C "$BARE" rev-parse main)" != "$BEFORE" ]; then
    bad "test36: something was mutated before the missing core was reported"
elif ! grep -q "AI_TOOLKIT_ROOT" "$WORK/t36.out"; then
    bad "test36: the refusal does not say how to point at an ai-toolkit checkout:
$(tail -5 "$WORK/t36.out")"
else
    ok "test36: merge and push are delegated to land-core.sh; without it the landing stops at exit 2, nothing mutated"
fi

echo
echo "$PASS passed, $FAIL failed (against: $LAND_BRANCH)"
[ "$FAIL" -eq 0 ]
