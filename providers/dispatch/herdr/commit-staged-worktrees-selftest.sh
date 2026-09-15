#!/bin/bash
#
# Assertions for commit-staged-worktrees.sh's core safety claims: a staged
# worktree gets committed with its own .commit-msg.txt, a clean worktree is
# left alone, a gpgsign-lock failure is recovered by a later, successful
# run without this script ever touching signing configuration, and the
# repository's primary worktree is never committed regardless of what is
# staged there.
#
# Builds and destroys its own scratch git repos + worktrees under
# `mktemp -d` (never under a fixed /tmp path) for every scenario, all with
# commit.gpgsign explicitly set in the FIXTURE (never by the script under
# test — it never touches that setting; see commit-staged-worktrees.sh's
# own header). Never touches this checkout, never touches a real remote,
# never a real host, and never a real `herdr` binary — this script has no
# herdr dependency of its own, so none is stubbed.
#
# Usage: ./commit-staged-worktrees-selftest.sh
# Exit 0 if every assertion passes, 1 otherwise.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

SRC="$HERE/commit-staged-worktrees.sh"
[ -f "$SRC" ] || die "cannot find commit-staged-worktrees.sh next to this selftest"

FAIL=0
SCRATCH_DIRS=""

# shellcheck disable=SC2329  # called indirectly via the EXIT trap below
cleanup_all() {
    local d
    for d in $SCRATCH_DIRS; do
        rm -rf "$d"
    done
}
trap cleanup_all EXIT

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc" >&2
        echo "  want: $want" >&2
        echo "  got:  $got" >&2
        FAIL=1
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) echo "ok: $desc" ;;
        *)
            echo "FAIL: $desc" >&2
            echo "  expected to find: $needle" >&2
            echo "  in:" >&2
            printf '%s\n' "$haystack" | sed 's/^/    /' >&2
            FAIL=1
            ;;
    esac
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*)
            echo "FAIL: $desc" >&2
            echo "  expected NOT to find: $needle" >&2
            echo "  in:" >&2
            printf '%s\n' "$haystack" | sed 's/^/    /' >&2
            FAIL=1
            ;;
        *) echo "ok: $desc" ;;
    esac
}

# row_field <branch> <field-number> <table-text> — pulls a field out of the
# rendered table by column *position*, via awk, rather than matching a
# literal tab: `table()` pipes through `column -t`, which re-pads with
# spaces, so a substring check for "branch\tSTATUS" never matches the
# rendered output and would pass vacuously whether the claim held or not.
row_field() {
    local branch="$1" n="$2" out="$3"
    printf '%s\n' "$out" | awk -v b="$branch" -v n="$n" '$1==b {print $n; exit}'
}

# new_base_repo — bare origin + a "primary" clone, signing off (fixture
# setting, not the script's), one seed commit on a branch explicitly named
# "main" (never relies on the ambient init.defaultBranch default). Prints
# the primary clone's path.
#
# Every scratch repo pins core.hooksPath, commit.gpgsign, gpg.format and
# gpg.program to values scoped to itself, so it cannot pick up this
# machine's global git config or its real gpg/op setup.
new_base_repo() {
    local work bare primary
    work=$(mktemp -d "${TMPDIR:-/tmp}/cswt-selftest.XXXXXX") || return 1
    SCRATCH_DIRS="$SCRATCH_DIRS $work"
    bare="$work/origin.git"
    git init --bare -q "$bare" || return 1
    primary="$work/primary"
    git clone -q "$bare" "$primary" >/dev/null 2>&1 || return 1
    git -C "$primary" checkout -q -b main
    git -C "$primary" config user.email "selftest@example.invalid"
    git -C "$primary" config user.name "commit-staged-worktrees-selftest"
    git -C "$primary" config commit.gpgsign false
    git -C "$primary" config core.hooksPath "$primary/.git/hooks"
    echo "seed" > "$primary/seed.txt"
    git -C "$primary" add seed.txt
    git -C "$primary" commit -q -m "init"
    git -C "$primary" push -q -u origin main >/dev/null 2>&1
    printf '%s' "$primary"
}

# add_worktree <primary> <branch> — creates a linked worktree off main,
# prints its path.
add_worktree() {
    local primary="$1" branch="$2" wtpath
    wtpath="$(dirname "$primary")/wt-$branch"
    git -C "$primary" worktree add -q -b "$branch" "$wtpath" main >/dev/null 2>&1 || return 1
    printf '%s' "$wtpath"
}

run_real() {
    local cwd="$1"; shift
    ( cd "$cwd" && "$SRC" "$@" )
}

# --------------------------------------------------------- 1. staged commit
#
# A worktree with staged changes and a .commit-msg.txt gets committed with
# that message. Oracle: `git log` on the worktree's own branch, not the
# script's own printed row — a mutant that prints COMMITTED without ever
# calling `git commit` must still fail this.

PRIMARY=$(new_base_repo) || die "could not build scratch repo (staged commit)"
WT=$(add_worktree "$PRIMARY" feature1) || die "could not add worktree (staged commit)"
echo "real work" > "$WT/real.txt"
git -C "$WT" add real.txt
printf 'feat: real work\n' > "$WT/.commit-msg.txt"
PRE_COUNT=$(git -C "$WT" rev-list --count HEAD)

OUT=$(run_real "$WT" 2>&1) || true
assert_eq "feature1's row status is COMMITTED" "COMMITTED" "$(row_field feature1 2 "$OUT")"

POST_COUNT=$(git -C "$WT" rev-list --count HEAD)
if [ "$POST_COUNT" -gt "$PRE_COUNT" ]; then
    echo "ok: git log shows a new commit landed on feature1"
else
    echo "FAIL: git rev-list count did not increase — no commit actually landed" >&2
    FAIL=1
fi
LOG_SUBJECT=$(git -C "$WT" log -1 --format=%s)
assert_eq "the new commit's subject (per git log) matches .commit-msg.txt's first line" "feat: real work" "$LOG_SUBJECT"
STAGED_AFTER=$(git -C "$WT" status --porcelain --untracked-files=no)
assert_eq "git status --porcelain shows a clean index after the commit" "" "$STAGED_AFTER"

# ------------------------------------------------- 2. nothing staged: skip

PRIMARY=$(new_base_repo) || die "could not build scratch repo (nothing staged)"
WT=$(add_worktree "$PRIMARY" feature2) || die "could not add worktree (nothing staged)"
echo "untracked, never staged" > "$WT/untouched.txt"
PRE_COUNT=$(git -C "$WT" rev-list --count HEAD)
PRE_STATUS=$(git -C "$WT" status --porcelain)

OUT=$(run_real "$WT" 2>&1) || true
assert_eq "feature2's row status is SKIPPED, not COMMITTED" "SKIPPED" "$(row_field feature2 2 "$OUT")"
assert_contains "reason names nothing staged" "$OUT" "nothing staged"

POST_COUNT=$(git -C "$WT" rev-list --count HEAD)
assert_eq "git log gained no commit (rev-list count unchanged)" "$PRE_COUNT" "$POST_COUNT"
POST_STATUS=$(git -C "$WT" status --porcelain)
assert_eq "git status --porcelain is byte-identical before and after (nothing touched)" "$PRE_STATUS" "$POST_STATUS"

# ----------------------------------------------- 3. gpgsign-lock recovery
#
# Simulates a worktree whose earlier `git commit` failed because signing
# was unavailable at the time (commit.gpgsign=true plus a signing helper
# that refuses): the FIRST run must report FAILED and leave the staged
# change and .commit-msg.txt untouched; a SECOND run, after the signing
# helper starts succeeding (recovery, without this script ever touching
# commit.gpgsign or any other signing config), must then commit
# successfully — the same recovery path the source script exists for.

PRIMARY=$(new_base_repo) || die "could not build scratch repo (gpgsign lock)"
WT=$(add_worktree "$PRIMARY" feature3) || die "could not add worktree (gpgsign lock)"

GPGDIR=$(mktemp -d "${TMPDIR:-/tmp}/cswt-selftest.XXXXXX") || die "could not create scratch bin dir"
SCRATCH_DIRS="$SCRATCH_DIRS $GPGDIR"
GPG_LOCK_FLAG="$GPGDIR/locked"
touch "$GPG_LOCK_FLAG"
KEYFILE="$GPGDIR/fixture-key"
echo "dummy-key-material" > "$KEYFILE"
# Fixture SSH-signing helper (stands in for gpg.ssh.program): fails while
# $GPG_LOCK_FLAG exists (simulating a locked credential/signing agent —
# e.g. a locked 1Password-style SSH-agent integration), succeeds once the
# flag is removed, writing the signature file git expects.
cat > "$GPGDIR/sshsign" <<EOF
#!/bin/bash
if [ -e "$GPG_LOCK_FLAG" ]; then
    echo "fixture-sshsign: signing agent locked" >&2
    exit 1
fi
last="\${@: -1}"
printf '%s\n' "-----BEGIN SSH SIGNATURE-----
fixture
-----END SSH SIGNATURE-----" > "\$last.sig"
exit 0
EOF
chmod +x "$GPGDIR/sshsign"

git -C "$WT" config commit.gpgsign true
git -C "$WT" config gpg.format ssh
git -C "$WT" config gpg.ssh.program "$GPGDIR/sshsign"
git -C "$WT" config user.signingkey "$KEYFILE"

echo "real work under lock" > "$WT/locked.txt"
git -C "$WT" add locked.txt
printf 'feat: recovers after the signing lock clears\n' > "$WT/.commit-msg.txt"
PRE_COUNT=$(git -C "$WT" rev-list --count HEAD)
PRE_STAGED=$(git -C "$WT" status --porcelain --untracked-files=no)

RC1=0
OUT1=$(run_real "$WT" 2>&1) || RC1=$?
assert_eq "while signing is locked, feature3's row is FAILED" "FAILED" "$(row_field feature3 2 "$OUT1")"
assert_eq "a lock-only run exits 1" "1" "$RC1"
MID_COUNT=$(git -C "$WT" rev-list --count HEAD)
assert_eq "git log gained no commit while locked" "$PRE_COUNT" "$MID_COUNT"
MID_STAGED=$(git -C "$WT" status --porcelain --untracked-files=no)
assert_eq "the staged change survives the failed attempt untouched" "$PRE_STAGED" "$MID_STAGED"
[ -f "$WT/.commit-msg.txt" ] || { echo "FAIL: .commit-msg.txt was deleted by the failed attempt" >&2; FAIL=1; }

# Recovery: the signing helper now succeeds. The script itself never
# touched commit.gpgsign/gpg.program/user.signingkey — only the fixture
# flag changed.
rm -f "$GPG_LOCK_FLAG"

RC2=0
OUT2=$(run_real "$WT" 2>&1) || RC2=$?
assert_eq "once signing recovers, a re-run reports COMMITTED" "COMMITTED" "$(row_field feature3 2 "$OUT2")"
assert_eq "the recovered run exits 0" "0" "$RC2"
POST_COUNT=$(git -C "$WT" rev-list --count HEAD)
if [ "$POST_COUNT" -gt "$PRE_COUNT" ]; then
    echo "ok: git log shows the recovered commit actually landed"
else
    echo "FAIL: git rev-list count did not increase after recovery" >&2
    FAIL=1
fi
LOG_SUBJECT3=$(git -C "$WT" log -1 --format=%s)
assert_eq "the recovered commit's subject matches .commit-msg.txt" "feat: recovers after the signing lock clears" "$LOG_SUBJECT3"
SIGNING_CFG_AFTER="$(git -C "$WT" config commit.gpgsign)"
assert_eq "the script never altered commit.gpgsign itself" "true" "$SIGNING_CFG_AFTER"

# ------------------------------------------------- 4. primary never touched
#
# Whatever is staged in the repository's OWN primary worktree, invoking the
# script from a linked worktree must never commit it there. Oracle: git log
# on the primary's own branch and git status --porcelain on its index —
# neither the script's printed table nor its exit code, so a mutant that
# silently committed the primary while still printing a clean report still
# fails this.

PRIMARY=$(new_base_repo) || die "could not build scratch repo (primary untouched)"
echo "wip in the owner's own checkout" > "$PRIMARY/wip.txt"
git -C "$PRIMARY" add wip.txt
printf 'WIP do not commit\n' > "$PRIMARY/.commit-msg.txt"
PRE_PRIMARY_LOG=$(git -C "$PRIMARY" log --oneline main)
PRE_PRIMARY_STAGED=$(git -C "$PRIMARY" status --porcelain --untracked-files=no)

WT=$(add_worktree "$PRIMARY" feature4) || die "could not add worktree (primary untouched)"
echo "real work" > "$WT/real.txt"
git -C "$WT" add real.txt
printf 'feat: real work in the linked worktree\n' > "$WT/.commit-msg.txt"

OUT=$(run_real "$WT" 2>&1) || true
assert_eq "the linked worktree still commits" "COMMITTED" "$(row_field feature4 2 "$OUT")"

POST_PRIMARY_LOG=$(git -C "$PRIMARY" log --oneline main)
assert_eq "the primary worktree's own branch gained no commit (git log unchanged)" "$PRE_PRIMARY_LOG" "$POST_PRIMARY_LOG"
POST_PRIMARY_STAGED=$(git -C "$PRIMARY" status --porcelain --untracked-files=no)
assert_eq "the primary worktree's staged WIP is byte-identical, untouched" "$PRE_PRIMARY_STAGED" "$POST_PRIMARY_STAGED"

# --------------------------------------------------- 5. merge in progress

PRIMARY=$(new_base_repo) || die "could not build scratch repo (merge in progress)"
echo "main version" > "$PRIMARY/conflict.txt"
git -C "$PRIMARY" add conflict.txt
git -C "$PRIMARY" commit -q -m "main edits conflict.txt"
git -C "$PRIMARY" push -q origin main >/dev/null 2>&1
git -C "$PRIMARY" checkout -q -b other
echo "other version" > "$PRIMARY/conflict.txt"
git -C "$PRIMARY" commit -q -am "other edits conflict.txt"
git -C "$PRIMARY" checkout -q main

WT=$(add_worktree "$PRIMARY" feature5) || die "could not add worktree (merge in progress)"
echo "feature version" > "$WT/conflict.txt"
git -C "$WT" commit -q -am "feature5 edits conflict.txt"
PRE_COUNT=$(git -C "$WT" rev-list --count HEAD)
git -C "$WT" merge other >/dev/null 2>&1 || true
GITDIR=$(git -C "$WT" rev-parse --git-dir)
case "$GITDIR" in /*) : ;; *) GITDIR="$WT/$GITDIR" ;; esac
[ -f "$GITDIR/MERGE_HEAD" ] || die "fixture setup failed: MERGE_HEAD not present after the forced conflict"
echo "resolved version" > "$WT/conflict.txt"
git -C "$WT" add conflict.txt
printf 'chore: unrelated staged tweak\n' > "$WT/.commit-msg.txt"

OUT=$(run_real "$PRIMARY" 2>&1) || true
assert_contains "merge-in-progress worktree is SKIPPED" "$OUT" "feature5"
assert_contains "reason names the merge, not the unrelated message" "$OUT" "merge in progress"
assert_eq "feature5's row status is SKIPPED, not COMMITTED" "SKIPPED" "$(row_field feature5 2 "$OUT")"
if [ -f "$GITDIR/MERGE_HEAD" ]; then
    echo "ok: MERGE_HEAD is still present — no commit consumed the merge"
else
    echo "FAIL: MERGE_HEAD disappeared — something committed through the merge" >&2
    FAIL=1
fi
POST_COUNT=$(git -C "$WT" rev-list --count HEAD)
assert_eq "no new commit landed on feature5's HEAD" "$PRE_COUNT" "$POST_COUNT"

# ---------------------------------------- 6. mid-rebase (detached + special)
#
# During a rebase HEAD is also detached, so this checks that the special-
# state reason ("rebase in progress") wins over the generic detached-HEAD
# reason — ordering, not just detection.

PRIMARY=$(new_base_repo) || die "could not build scratch repo (mid-rebase)"
echo "main version" > "$PRIMARY/rconflict.txt"
git -C "$PRIMARY" add rconflict.txt
git -C "$PRIMARY" commit -q -m "main edits rconflict.txt"
git -C "$PRIMARY" push -q origin main >/dev/null 2>&1

WT=$(add_worktree "$PRIMARY" feature6) || die "could not add worktree (mid-rebase)"
echo "feature version" > "$WT/rconflict.txt"
git -C "$WT" commit -q -am "feature6 edits rconflict.txt"
echo "main version v2" > "$PRIMARY/rconflict.txt"
git -C "$PRIMARY" commit -q -am "main edits rconflict.txt again (will conflict on rebase)"
git -C "$PRIMARY" push -q origin main >/dev/null 2>&1
git -C "$WT" fetch -q origin main >/dev/null 2>&1 || true
git -C "$WT" rebase origin/main >/dev/null 2>&1 || true
GITDIR=$(git -C "$WT" rev-parse --git-dir)
case "$GITDIR" in /*) : ;; *) GITDIR="$WT/$GITDIR" ;; esac
if [ ! -d "$GITDIR/rebase-merge" ] && [ ! -d "$GITDIR/rebase-apply" ]; then
    die "fixture setup failed: rebase did not leave rebase-merge/rebase-apply behind"
fi
printf 'chore: unrelated during rebase\n' > "$WT/.commit-msg.txt"

PRE_COUNT6=$(git -C "$WT" rev-list --count HEAD 2>/dev/null || echo "<rev-parse failed>")

OUT=$(run_real "$PRIMARY" 2>&1) || true
assert_contains "mid-rebase worktree is SKIPPED, not treated as plain detached" "$OUT" "rebase in progress"
# Observing the effect, not just the printed word: a mutant that matches the
# "rebase in progress" string but then falls through and commits anyway
# (e.g. a missing `continue`) must still fail this scenario.
# row_field keys on the table's BRANCH column, and mid-rebase HEAD is
# detached, so the script reports this row under "(detached)", not
# "feature6" (same as the detached-HEAD-only scenario below).
assert_eq "feature6's row status is SKIPPED, not COMMITTED or FAILED" "SKIPPED" "$(row_field '(detached)' 2 "$OUT")"
if [ -d "$GITDIR/rebase-merge" ] || [ -d "$GITDIR/rebase-apply" ]; then
    echo "ok: rebase-merge/rebase-apply state is still present — no commit consumed the rebase"
else
    echo "FAIL: rebase state directory disappeared — something committed through the rebase" >&2
    FAIL=1
fi
POST_COUNT6=$(git -C "$WT" rev-list --count HEAD 2>/dev/null || echo "<rev-parse failed>")
assert_eq "no new commit landed on feature6's HEAD during the rebase" "$PRE_COUNT6" "$POST_COUNT6"

# ------------------------------------------------- 7. detached HEAD skip

PRIMARY=$(new_base_repo) || die "could not build scratch repo (detached HEAD)"
WT=$(add_worktree "$PRIMARY" feature7) || die "could not add worktree (detached HEAD)"
DETACH_SHA=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" checkout -q --detach "$DETACH_SHA"
echo "staged under detached HEAD" > "$WT/detached.txt"
git -C "$WT" add detached.txt
printf 'feat: should never land\n' > "$WT/.commit-msg.txt"
PRE_COUNT=$(git -C "$WT" rev-list --count HEAD)

OUT=$(run_real "$PRIMARY" 2>&1) || true
assert_contains "detached-HEAD worktree is SKIPPED" "$OUT" "(detached)"
assert_contains "reason names detached HEAD" "$OUT" "detached HEAD"
assert_not_contains "the detached-HEAD subject never reaches a COMMITTED row" "$OUT" "COMMITTED"
POST_COUNT=$(git -C "$WT" rev-list --count HEAD)
assert_eq "detached HEAD gained no commit" "$PRE_COUNT" "$POST_COUNT"

# ----------------------------------------------- 8. dry-run FILES/TIP/list

PRIMARY=$(new_base_repo) || die "could not build scratch repo (dry-run detail)"
WT=$(add_worktree "$PRIMARY" feature8) || die "could not add worktree (dry-run detail)"
echo a > "$WT/a.txt"; echo b > "$WT/b.txt"; echo c > "$WT/c.txt"
git -C "$WT" add a.txt b.txt c.txt
printf 'feat: three files\n' > "$WT/.commit-msg.txt"
PRE_COUNT=$(git -C "$WT" rev-list --count HEAD)

OUT=$(run_real "$PRIMARY" --dry-run 2>&1) || true
assert_eq "dry-run status for feature8 is WOULD-COMMIT" "WOULD-COMMIT" "$(row_field feature8 2 "$OUT")"
assert_eq "dry-run shows the staged file count (3), not just the subject" "3" "$(row_field feature8 3 "$OUT")"
assert_contains "dry-run lists the actual staged files, not just a count" "$OUT" "a.txt"
assert_contains "dry-run staged-file list includes b.txt" "$OUT" "b.txt"
assert_contains "dry-run staged-file list includes c.txt" "$OUT" "c.txt"
POST_COUNT=$(git -C "$WT" rev-list --count HEAD)
assert_eq "--dry-run commits nothing" "$PRE_COUNT" "$POST_COUNT"

# --------------------------------------------- 9. whitespace-only message

PRIMARY=$(new_base_repo) || die "could not build scratch repo (whitespace message)"
WT=$(add_worktree "$PRIMARY" feature9) || die "could not add worktree (whitespace message)"
echo x > "$WT/x.txt"
git -C "$WT" add x.txt
printf '   \n\n' > "$WT/.commit-msg.txt"

DRY_OUT=$(run_real "$PRIMARY" --dry-run 2>&1) || true
assert_contains "dry-run recognises a whitespace-only message as blank" "$DRY_OUT" "(empty .commit-msg.txt)"
DRY_STATUS9=$(row_field feature9 2 "$DRY_OUT")
assert_eq "dry-run predicts WOULD-FAIL, not WOULD-COMMIT, for a message guaranteed to fail" "WOULD-FAIL" "$DRY_STATUS9"

REAL_OUT=$(run_real "$PRIMARY" 2>&1) || true
assert_contains "the real run agrees it was blank (git itself refuses an empty message)" "$REAL_OUT" "feature9"
REAL_STATUS9=$(row_field feature9 2 "$REAL_OUT")
assert_eq "the real run never silently commits a blank message" "FAILED" "$REAL_STATUS9"

# The discriminating check that a FAILED-only assertion above does not
# provide: git itself refuses an empty message with or without any guard in
# this script, so a FAILED-only assertion passes whether or not the script
# recognises blank messages at all. What must actually hold is that
# --dry-run's prediction is never contradicted by what the same fixture's
# real run, verified independently through git, actually does — cross-
# checked here against REAL_STATUS9 (git-observed truth), not against a
# literal string this script invented.
if [ "$DRY_STATUS9" = "WOULD-COMMIT" ] && [ "$REAL_STATUS9" != "COMMITTED" ]; then
    echo "FAIL: dry-run predicted WOULD-COMMIT but the real run on the identical fixture did not commit (git-verified outcome: $REAL_STATUS9) — dry-run contradicts reality" >&2
    FAIL=1
else
    echo "ok: dry-run's prediction for feature9 is never contradicted by the real run's git-verified outcome"
fi

# ---------------------------------------------- 10. .commit-msg.txt staged

PRIMARY=$(new_base_repo) || die "could not build scratch repo (msg file staged)"
WT=$(add_worktree "$PRIMARY" feature10) || die "could not add worktree (msg file staged)"
echo "real content" > "$WT/real10.txt"
printf 'feat: careless add -A\n' > "$WT/.commit-msg.txt"
git -C "$WT" add -A

OUT=$(run_real "$PRIMARY" 2>&1) || true
assert_eq "the worktree still commits successfully" "COMMITTED" "$(row_field feature10 2 "$OUT")"
COMMITTED_PATHS=$(git -C "$WT" show --stat --format= --name-only HEAD)
assert_not_contains "the resulting commit does not include .commit-msg.txt" "$COMMITTED_PATHS" ".commit-msg.txt"
assert_contains "the resulting commit does include the real file" "$COMMITTED_PATHS" "real10.txt"
STATUS_AFTER=$(git -C "$WT" status --porcelain -- .commit-msg.txt)
case "$STATUS_AFTER" in
    "?? .commit-msg.txt") echo "ok: .commit-msg.txt survives on disk, unstaged, after being unstaged" ;;
    *)
        echo "FAIL: .commit-msg.txt's post-commit status was unexpected: '$STATUS_AFTER'" >&2
        FAIL=1
        ;;
esac

# ------------------------------------------- 10b. only .commit-msg.txt staged
#
# If .commit-msg.txt is the ONLY staged path, unstaging it before commit
# would empty the index and turn `git commit` into an unexplained FAILED
# row. The script must recognise this case and SKIP before ever touching
# the index.

PRIMARY=$(new_base_repo) || die "could not build scratch repo (msg file only staged)"
WT=$(add_worktree "$PRIMARY" feature10b) || die "could not add worktree (msg file only staged)"
printf 'feat: only the message is staged\n' > "$WT/.commit-msg.txt"
git -C "$WT" add .commit-msg.txt
PRE_COUNT10B=$(git -C "$WT" rev-list --count HEAD)

OUT=$(run_real "$PRIMARY" 2>&1) || true
assert_eq "worktree with only .commit-msg.txt staged is SKIPPED, not FAILED" "SKIPPED" "$(row_field feature10b 2 "$OUT")"
assert_contains "reason explains nothing else was staged" "$OUT" "nothing to commit"
POST_COUNT10B=$(git -C "$WT" rev-list --count HEAD)
assert_eq "no commit landed" "$PRE_COUNT10B" "$POST_COUNT10B"
STATUS_AFTER10B=$(git -C "$WT" status --porcelain -- .commit-msg.txt)
assert_eq "the msg file's staged status is untouched — the index was never even reset" "A  .commit-msg.txt" "$STATUS_AFTER10B"

# --------------------------------- 10c. failed commit restores a staged msg
#
# The header claims a failed run "leaves everything exactly as found and
# can be re-run", but the unstage of .commit-msg.txt (when it was staged)
# must be undone on a failure path — a blank message here forces `git
# commit` to fail after the unstage has already run.

PRIMARY=$(new_base_repo) || die "could not build scratch repo (restore staged msg on failure)"
WT=$(add_worktree "$PRIMARY" feature10c) || die "could not add worktree (restore staged msg on failure)"
echo "real content" > "$WT/real10c.txt"
printf '   \n' > "$WT/.commit-msg.txt"
git -C "$WT" add -A
PRE_STATUS10C=$(git -C "$WT" status --porcelain -- .commit-msg.txt)

OUT=$(run_real "$PRIMARY" 2>&1) || true
assert_eq "the blank-message commit FAILS (not SKIPPED, not COMMITTED)" "FAILED" "$(row_field feature10c 2 "$OUT")"
POST_STATUS10C=$(git -C "$WT" status --porcelain -- .commit-msg.txt)
assert_eq "a failed run restores .commit-msg.txt's staged status exactly, matching the header's 'leaves everything exactly as found' claim" "$PRE_STATUS10C" "$POST_STATUS10C"

# --------------------------------------- 10d. commit failure reported on stdout
#
# The old capture pattern (`2>&1 >/dev/null`) keeps only stderr, so a `git
# commit` failure whose message lands on stdout (a pre-commit hook that
# doesn't redirect) would produce a generic "no error output captured"
# placeholder instead of the real reason. A pre-commit hook writing to its
# own stdout is exactly that case — git does not redirect hook output
# specially, so it reaches the same stream as everything else `git commit`
# prints.

PRIMARY=$(new_base_repo) || die "could not build scratch repo (stdout-only failure)"
WT=$(add_worktree "$PRIMARY" feature10d) || die "could not add worktree (stdout-only failure)"
echo real > "$WT/real10d.txt"
git -C "$WT" add real10d.txt
printf 'feat: should be blocked by hook\n' > "$WT/.commit-msg.txt"
HOOKDIR10D=$(git -C "$WT" rev-parse --git-path hooks)
case "$HOOKDIR10D" in /*) : ;; *) HOOKDIR10D="$WT/$HOOKDIR10D" ;; esac
mkdir -p "$HOOKDIR10D"
cat > "$HOOKDIR10D/pre-commit" <<'HOOK'
#!/bin/bash
echo "custom-hook-refusal: policy violation printed to STDOUT only"
exit 1
HOOK
chmod +x "$HOOKDIR10D/pre-commit"

OUT=$(run_real "$PRIMARY" 2>&1) || true
assert_eq "the hook-blocked commit is reported FAILED" "FAILED" "$(row_field feature10d 2 "$OUT")"
assert_contains "the FAILED row's reason captures the hook's stdout-only message" "$OUT" "custom-hook-refusal"
assert_not_contains "the placeholder is not used when a real reason exists on stdout" "$OUT" "no error output captured"

# ------------------------------------------ 10e. concurrent index.lock: UNKNOWN
#
# An index.lock left by a concurrent process (a live Herdr agent in the
# same worktree — the exact condition this script is meant to run against)
# says the worktree could not be evaluated right now, not that anything
# about it is known-bad. Must be UNKNOWN (exit 2), not FAILED (exit 1).

PRIMARY=$(new_base_repo) || die "could not build scratch repo (index.lock)"
WT=$(add_worktree "$PRIMARY" feature10e) || die "could not add worktree (index.lock)"
echo real > "$WT/real10e.txt"
git -C "$WT" add real10e.txt
printf 'feat: blocked by a concurrent lock\n' > "$WT/.commit-msg.txt"
GITDIR10E=$(git -C "$WT" rev-parse --git-dir)
case "$GITDIR10E" in /*) : ;; *) GITDIR10E="$WT/$GITDIR10E" ;; esac
touch "$GITDIR10E/index.lock"

RC10E=0
if OUT=$(run_real "$PRIMARY" 2>&1); then RC10E=0; else RC10E=$?; fi
rm -f "$GITDIR10E/index.lock"
assert_eq "a concurrently-locked index is reported UNKNOWN, not FAILED" "UNKNOWN" "$(row_field feature10e 2 "$OUT")"
assert_eq "an index.lock-only run exits 2 (could-not-evaluate), not 1" "2" "$RC10E"

# ---------------------------------------- 10f. vanished worktree path: UNKNOWN
#
# A worktree 'git worktree list' just reported, whose directory is gone by
# the time this script gets to it (removed by a concurrent Herdr agent), is
# unevaluated, not known-bad — same treatment as a vanished-worktree check
# elsewhere in this plugin.

PRIMARY=$(new_base_repo) || die "could not build scratch repo (vanished worktree)"
WT=$(add_worktree "$PRIMARY" feature10f) || die "could not add worktree (vanished worktree)"
echo real > "$WT/real10f.txt"
git -C "$WT" add real10f.txt
printf 'feat: never gets a chance\n' > "$WT/.commit-msg.txt"
rm -rf "$WT"

OUT=$(run_real "$PRIMARY" 2>&1) || true
assert_eq "a worktree whose path vanished between listing and evaluation is UNKNOWN, not FAILED" "UNKNOWN" "$(row_field feature10f 2 "$OUT")"

# ------------------------------------------- 10g. FILES count after unstage
#
# The FILES column must reflect the post-unstage staged count even when
# .commit-msg.txt was unstaged before the commit, not the pre-unstage
# count. Cross-checked against git's own view of the resulting commit, not
# just against a second copy of the same arithmetic.

PRIMARY=$(new_base_repo) || die "could not build scratch repo (FILES count after unstage)"
WT=$(add_worktree "$PRIMARY" feature10g) || die "could not add worktree (FILES count after unstage)"
echo a > "$WT/a10g.txt"; echo b > "$WT/b10g.txt"
printf 'feat: files count check\n' > "$WT/.commit-msg.txt"
git -C "$WT" add -A

OUT=$(run_real "$PRIMARY" 2>&1) || true
assert_eq "the worktree commits" "COMMITTED" "$(row_field feature10g 2 "$OUT")"
assert_eq "FILES column reflects the 2 files actually committed, not the pre-unstage 3" "2" "$(row_field feature10g 3 "$OUT")"
COMMITTED_PATHS10G=$(git -C "$WT" show --stat --format= --name-only HEAD)
ACTUAL_COUNT10G=$(printf '%s\n' "$COMMITTED_PATHS10G" | grep -c '')
assert_eq "git's own view of the commit has 2 paths, matching the FILES column" "2" "$ACTUAL_COUNT10G"

# --------------------------------------------------- 11. exit code priority
#
# UNKNOWN (git-dir could not be resolved) takes priority over FAILED
# (commit message file unreadable) — neither collapses into the other's
# status word.

PRIMARY=$(new_base_repo) || die "could not build scratch repo (exit codes, mixed)"

WT_OK=$(add_worktree "$PRIMARY" wok) || die "could not add worktree (wok)"
echo ok > "$WT_OK/ok.txt"; git -C "$WT_OK" add ok.txt
printf 'feat: ok\n' > "$WT_OK/.commit-msg.txt"

WT_FAIL=$(add_worktree "$PRIMARY" wfail) || die "could not add worktree (wfail)"
echo fail > "$WT_FAIL/f.txt"; git -C "$WT_FAIL" add f.txt
printf 'feat: fail\n' > "$WT_FAIL/.commit-msg.txt"
chmod 000 "$WT_FAIL/.commit-msg.txt"

WT_UNKNOWN=$(add_worktree "$PRIMARY" wunknown) || die "could not add worktree (wunknown)"
echo unknown > "$WT_UNKNOWN/u.txt"; git -C "$WT_UNKNOWN" add u.txt
printf 'feat: unknown\n' > "$WT_UNKNOWN/.commit-msg.txt"
# Corrupt the linked worktree's own .git file (normally "gitdir: <path>") so
# `git -C <path> rev-parse --git-dir`, run from inside that path, fails.
printf 'not a gitdir pointer\n' > "$WT_UNKNOWN/.git"

RC=0
OUT=$(run_real "$PRIMARY" 2>&1) || RC=$?
chmod 600 "$WT_FAIL/.commit-msg.txt"
assert_eq "mixed FAILED+UNKNOWN run exits 2 (unknown takes priority)" "2" "$RC"
assert_eq "the unreadable-message worktree is reported FAILED" "FAILED" "$(row_field wfail 2 "$OUT")"
assert_eq "the broken git-dir worktree is reported UNKNOWN, not collapsed into FAILED" "UNKNOWN" "$(row_field wunknown 2 "$OUT")"
assert_eq "the clean worktree still committed despite its siblings' trouble" "COMMITTED" "$(row_field wok 2 "$OUT")"

# only-FAILED (no unknown) case
PRIMARY=$(new_base_repo) || die "could not build scratch repo (exit codes, failed-only)"
WT_FAIL=$(add_worktree "$PRIMARY" xfail) || die "could not add worktree (xfail)"
echo fail > "$WT_FAIL/f.txt"; git -C "$WT_FAIL" add f.txt
printf 'feat: fail\n' > "$WT_FAIL/.commit-msg.txt"
chmod 000 "$WT_FAIL/.commit-msg.txt"
RC=0
run_real "$PRIMARY" >/dev/null 2>&1 || RC=$?
chmod 600 "$WT_FAIL/.commit-msg.txt"
assert_eq "FAILED-only run exits 1" "1" "$RC"

# clean-only case
PRIMARY=$(new_base_repo) || die "could not build scratch repo (exit codes, clean)"
WT_OK=$(add_worktree "$PRIMARY" yok) || die "could not add worktree (yok)"
echo ok > "$WT_OK/ok.txt"; git -C "$WT_OK" add ok.txt
printf 'feat: ok\n' > "$WT_OK/.commit-msg.txt"
RC=0
run_real "$PRIMARY" >/dev/null 2>&1 || RC=$?
assert_eq "an all-clean run exits 0" "0" "$RC"

# --------------------------------------------------------------- summary

if [ "$FAIL" = "0" ]; then
    echo "commit-staged-worktrees-selftest: all assertions passed"
    exit 0
else
    exit 1
fi
