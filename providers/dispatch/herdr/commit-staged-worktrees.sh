#!/bin/bash
#
# commit-staged-worktrees.sh — commit already-STAGED work sitting in Herdr
# worktrees whose `git commit` never happened, most often because the
# worktree's commit-signing setup was unavailable at the time. Uses each
# worktree's own .commit-msg.txt as the message. Never merges, pushes,
# completes a ticket, removes a worktree, or deletes .commit-msg.txt, so a
# failed run leaves everything as found and can be re-run.
#
# Usage:
#   commit-staged-worktrees.sh [--dry-run]
#   commit-staged-worktrees.sh --help
#
# --dry-run prints what WOULD be committed and where — subject line, staged
# file count, current HEAD, and the full staged file list per worktree — and
# runs no `git commit`. Idempotent: a worktree with nothing staged is
# SKIPPED, never committed empty. Never prints a secret, and never prints a
# commit message beyond its first line.
#
# A worktree is SKIPPED, never committed, for any of these (shown in the WHY
# column):
#   - it is the repository's primary worktree
#   - a merge, cherry-pick, revert, or rebase is in progress
#     (MERGE_HEAD/CHERRY_PICK_HEAD/REVERT_HEAD, or rebase-merge/rebase-apply
#     in its git-dir) — committing there would fold into that operation
#   - its HEAD is detached
#   - nothing is staged
#   - no .commit-msg.txt exists at its root
#   - the only staged path is .commit-msg.txt itself
#
# WOULD-FAIL (--dry-run only): a whitespace-only .commit-msg.txt. `git
# commit` refuses an empty message unconditionally, so that is predicted
# rather than promised as WOULD-COMMIT.
#
# This script NEVER passes --no-gpg-sign, and NEVER reads or writes
# commit.gpgsign, gpg.format, gpg.ssh.program, or any other signing
# configuration. A commit that fails to sign is reported FAILED and the run
# moves on to the next worktree. There is no pre-flight signing probe: a
# probe is not reliably correlated with whether `git commit` will succeed.
#
# Exit codes:
#   0   every worktree that could be evaluated was: some may still show
#       FAILED or SKIPPED — read the table, this is not "all committed"
#   1   at least one worktree definitively FAILED (a `git commit` that ran
#       and failed, most often a signing error), or the run could not start
#       (not inside a git checkout, or `git` missing from PATH)
#   2   at least one worktree could not even be evaluated (`git diff
#       --cached` failed, its path had vanished since `git worktree list`
#       reported it, or a concurrent process held index.lock) — takes
#       priority over 1, because unknown is worse news than known-bad
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

# table <tab-separated-header> — read TSV rows on stdin, render aligned.
table() {
    { printf '%s\n' "$1"; cat; } | column -t -s"$(printf '\t')"
}

# pipe_ok — swallow a pipeline's exit status so an explicit check can report
# the failure instead of `set -e` killing the script first.
pipe_ok() { return 0; }

DRY_RUN=0
case "${1:-}" in
    -h|--help|help) show_help ;;
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *) die "unknown argument '$1' (see --help)" ;;
esac
[ $# -le 1 ] || die "unexpected extra argument(s) (see --help)"

need git

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$REPO"

# `git worktree list --porcelain`, never a hardcoded worktree-directory glob:
# that layout is the dispatch tool's choice, not this script's to assume.
WT_PORCELAIN=$(git worktree list --porcelain 2>&1) || die "'git worktree list' failed: $WT_PORCELAIN"

WT_LIST=$(tmpfile) || die "could not create temp file"
printf '%s\n' "$WT_PORCELAIN" | awk '
    BEGIN { path = ""; branch = "" }
    /^worktree / { path = $0; sub(/^worktree /, "", path) }
    /^branch /   { branch = $0; sub(/^branch refs\/heads\//, "", branch) }
    /^detached$/ { branch = "(detached)" }
    /^$/ {
        if (path != "") print path "\t" branch
        path = ""; branch = ""
    }
    END { if (path != "") print path "\t" branch }
' > "$WT_LIST" || pipe_ok
[ -s "$WT_LIST" ] || die "'git worktree list --porcelain' produced no worktrees to parse — cannot continue"

# The porcelain format documents the primary worktree as the FIRST entry, so
# it is read from here, never assumed to be $REPO (itself often a linked one).
PRIMARY_WT=$(head -n1 "$WT_LIST" | cut -f1)
[ -n "$PRIMARY_WT" ] || die "could not determine the primary worktree from 'git worktree list --porcelain'"

# staged_check <path> — 0 with STAGED_COUNT/STAGED_LIST set, 1 if nothing is
# staged, 2 if it could not be evaluated. Prints nothing on failure.
STAGED_COUNT=0
STAGED_LIST=""
staged_check() {
    local path="$1" out
    out=$(git -C "$path" diff --cached --name-only 2>&1) || return 2
    if [ -n "$out" ]; then
        STAGED_LIST="$out"
        STAGED_COUNT=$(printf '%s\n' "$out" | grep -c '' || true)
        return 0
    fi
    STAGED_LIST=""
    STAGED_COUNT=0
    return 1
}

# in_special_state <path> — 0 with SPECIAL_STATE_WHY set if a merge, cherry-pick,
# revert or rebase is live in that worktree's OWN git-dir (the shared common dir
# would false-positive on a sibling's); 1 if clean, 2 if unresolvable.
SPECIAL_STATE_WHY=""
in_special_state() {
    local path="$1" gitdir
    gitdir=$(git -C "$path" rev-parse --git-dir 2>/dev/null) || return 2
    case "$gitdir" in
        /*) : ;;
        *) gitdir="$path/$gitdir" ;;
    esac
    if [ -f "$gitdir/MERGE_HEAD" ]; then
        SPECIAL_STATE_WHY="merge in progress (MERGE_HEAD present)"; return 0
    fi
    if [ -f "$gitdir/CHERRY_PICK_HEAD" ]; then
        SPECIAL_STATE_WHY="cherry-pick in progress (CHERRY_PICK_HEAD present)"; return 0
    fi
    if [ -f "$gitdir/REVERT_HEAD" ]; then
        SPECIAL_STATE_WHY="revert in progress (REVERT_HEAD present)"; return 0
    fi
    if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]; then
        SPECIAL_STATE_WHY="rebase in progress"; return 0
    fi
    return 1
}

# field_or_dash <value> — a blank column shifts every later one left under
# `column -t`, so every field goes through this before add_row.
field_or_dash() {
    local stripped
    stripped=$(printf '%s' "$1" | tr -d '[:space:]')
    if [ -n "$stripped" ]; then
        printf '%s' "$1"
    else
        printf '%s' "-"
    fi
}

ROWS=""
add_row() {
    ROWS="$ROWS$(field_or_dash "$1")	$(field_or_dash "$2")	$(field_or_dash "$3")	$(field_or_dash "$4")	$(field_or_dash "$5")
"
}

DRY_RUN_DETAIL=""
HAD_FAILURE=0
HAD_UNKNOWN=0

while IFS="$(printf '\t')" read -r path branch; do
    [ -n "$path" ] || continue
    [ -n "$branch" ] || branch="(unknown)"

    [ "$path" = "$PRIMARY_WT" ] && continue

    if [ ! -d "$path" ]; then
        # A concurrent agent removing its own worktree is the live condition
        # this script runs against, so the path vanishing is UNKNOWN, not FAILED.
        add_row "$branch" "UNKNOWN" "-" "-" "worktree path '$path' does not exist — could not evaluate"
        HAD_UNKNOWN=1
        continue
    fi

    rc=0
    in_special_state "$path" || rc=$?
    case "$rc" in
        0) add_row "$branch" "SKIPPED" "-" "-" "$SPECIAL_STATE_WHY"; continue ;;
        2) add_row "$branch" "UNKNOWN" "-" "-" "could not resolve git-dir to check for an in-progress merge/rebase"; HAD_UNKNOWN=1; continue ;;
    esac

    if [ "$branch" = "(detached)" ]; then
        add_row "$branch" "SKIPPED" "-" "-" "detached HEAD — not a named Herdr branch worktree"
        continue
    fi

    rc=0
    staged_check "$path" || rc=$?
    case "$rc" in
        1) add_row "$branch" "SKIPPED" "0" "-" "nothing staged"; continue ;;
        2) add_row "$branch" "UNKNOWN" "-" "-" "could not check staged changes ('git diff --cached' failed)"; HAD_UNKNOWN=1; continue ;;
    esac

    TIP=$(git -C "$path" rev-parse --short HEAD 2>/dev/null) || TIP="(no commits)"

    MSG_FILE="$path/.commit-msg.txt"
    if [ ! -f "$MSG_FILE" ]; then
        add_row "$branch" "SKIPPED" "$STAGED_COUNT" "$TIP" "no .commit-msg.txt at worktree root"
        continue
    fi

    SUBJECT=$(head -n1 "$MSG_FILE" 2>/dev/null) || SUBJECT="(could not read .commit-msg.txt)"
    # `[ -n ]` passes "   " through, so strip before testing, not the raw bytes.
    SUBJECT_STRIPPED=$(printf '%s' "$SUBJECT" | tr -d '[:space:]')
    [ -n "$SUBJECT_STRIPPED" ] || SUBJECT="(empty .commit-msg.txt)"

    # If .commit-msg.txt is the only staged path, the unstage below would empty
    # the index and `git commit` would fail undiagnosably — so SKIP first.
    NON_MSG_STAGED=$(printf '%s\n' "$STAGED_LIST" | grep -vx '\.commit-msg\.txt' || true)
    if [ -z "$NON_MSG_STAGED" ]; then
        add_row "$branch" "SKIPPED" "$STAGED_COUNT" "$TIP" "only staged path is .commit-msg.txt itself — nothing to commit"
        continue
    fi

    if [ "$DRY_RUN" = 1 ]; then
        if [ -n "$SUBJECT_STRIPPED" ]; then
            add_row "$branch" "WOULD-COMMIT" "$STAGED_COUNT" "$TIP" "$SUBJECT"
        else
            add_row "$branch" "WOULD-FAIL" "$STAGED_COUNT" "$TIP" "$SUBJECT"
        fi
        DRY_RUN_DETAIL="$DRY_RUN_DETAIL
$branch ($STAGED_COUNT staged):
$(printf '%s\n' "$STAGED_LIST" | sed 's/^/    /')"
        continue
    fi

    # Unstage .commit-msg.txt (never touching the working-tree copy) so it is
    # not folded into the commit, and re-stage it if the commit then fails, so
    # a failed run leaves the index exactly as found.
    UNSTAGED_MSG=0
    if printf '%s\n' "$STAGED_LIST" | grep -qx '\.commit-msg\.txt'; then
        git -C "$path" reset -q -- .commit-msg.txt 2>/dev/null || true
        UNSTAGED_MSG=1
    fi

    COMMIT_FILE_COUNT="$STAGED_COUNT"
    [ "$UNSTAGED_MSG" = 1 ] && COMMIT_FILE_COUNT=$((STAGED_COUNT - 1))

    if COMMIT_ERR=$(git -C "$path" commit -F "$MSG_FILE" 2>&1); then
        add_row "$branch" "COMMITTED" "$COMMIT_FILE_COUNT" "$TIP" "$SUBJECT"
    else
        if [ "$UNSTAGED_MSG" = 1 ]; then
            git -C "$path" add -- .commit-msg.txt 2>/dev/null || true
        fi
        FIRST_LINE=$(printf '%s\n' "$COMMIT_ERR" | head -n1)
        [ -n "$FIRST_LINE" ] || FIRST_LINE="commit failed (no error output captured)"
        case "$COMMIT_ERR" in
            *index.lock*)
                # A concurrent agent's index.lock means "not evaluable now",
                # not "known-bad".
                add_row "$branch" "UNKNOWN" "$STAGED_COUNT" "$TIP" "could not evaluate — $FIRST_LINE"
                HAD_UNKNOWN=1
                ;;
            *)
                add_row "$branch" "FAILED" "$STAGED_COUNT" "$TIP" "$FIRST_LINE"
                HAD_FAILURE=1
                ;;
        esac
    fi
done < "$WT_LIST"

echo
if [ "$DRY_RUN" = 1 ]; then
    echo "--dry-run: nothing was committed. Plan:"
else
    echo "Result:"
fi
echo
printf '%s' "$ROWS" | table "BRANCH	STATUS	FILES	TIP	WHY"

if [ "$DRY_RUN" = 1 ] && [ -n "$DRY_RUN_DETAIL" ]; then
    echo
    echo "Staged files by worktree:"
    printf '%s\n' "$DRY_RUN_DETAIL"
fi
echo

if [ "$HAD_UNKNOWN" = 1 ]; then
    exit 2
fi
if [ "$HAD_FAILURE" = 1 ]; then
    exit 1
fi
exit 0
