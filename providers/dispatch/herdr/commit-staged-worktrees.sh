#!/bin/bash
#
# Commit already-STAGED work sitting in Herdr worktrees whose `git commit`
# never happened — most often because the worktree's commit-signing setup
# (commit.gpgsign plus whatever signing program is configured) was not
# available at the moment an agent tried to commit.
#
# Companion to a land script, not a replacement for one: this script's only
# job is to turn staged changes into a commit, in each worktree, using that
# worktree's own .commit-msg.txt as the message. It never merges, pushes,
# completes a ticket, or removes a worktree — land separately, per branch,
# once you are ready. It also never deletes .commit-msg.txt, so a failed
# run leaves everything exactly as found and can be re-run.
#
# A worktree is SKIPPED, never committed, for any of these reasons (shown in
# the WHY column — do not assume any particular count or set of worktrees is
# "the exception"; that state changes as worktrees are created and landed):
#   - it is the repository's primary worktree (the owner's own main
#     checkout, never a Herdr agent worktree)
#   - it is in the middle of a merge, cherry-pick, revert, or rebase
#     (MERGE_HEAD/CHERRY_PICK_HEAD/REVERT_HEAD present, or rebase-merge/
#     rebase-apply present in its git-dir) — committing staged content there
#     would silently fold it into that unrelated operation
#   - its HEAD is detached — not a named Herdr branch worktree, and a commit
#     made there is one `git checkout`/`rebase --abort` away from becoming
#     unreachable
#   - nothing is staged
#   - no .commit-msg.txt exists at its root
#   - the only staged path is .commit-msg.txt itself (nothing else to commit)
#
# WOULD-FAIL (--dry-run only): a whitespace-only .commit-msg.txt. `git
# commit` refuses an empty message unconditionally, so --dry-run predicts
# that outcome rather than claiming WOULD-COMMIT for a run that is
# guaranteed to fail once it is not a dry run.
#
# Hard requirement: this script NEVER passes --no-gpg-sign, and NEVER reads
# or writes commit.gpgsign, gpg.format, gpg.ssh.program, or any other
# signing configuration. A commit that fails to sign is reported FAILED and
# the script moves on to the next worktree. Signing policy belongs to the
# owner; a script that quietly disabled it to make itself succeed would be
# worse than no script.
#
# No pre-flight signing probe: whatever tool backs commit signing on a
# given host, a probe of it is not reliably correlated with whether `git
# commit` itself will succeed — the two can disagree in either direction.
# Each worktree's real `git commit` is the only thing that actually knows,
# and its failure is reported per-row below.
#
# Usage:
#   commit-staged-worktrees.sh [--dry-run]
#   commit-staged-worktrees.sh --help
#
# --dry-run discovers every worktree, checks each one for staged changes and
# a .commit-msg.txt, and prints what WOULD be committed and where: subject
# line, staged file count, current HEAD, and (below the table) the full
# staged file list per worktree — so an outlier is visible before anything
# is committed. No `git commit` runs on this path.
#
# Idempotent: a worktree with nothing staged is SKIPPED, never committed
# empty, so running this twice in a row is harmless — the second run just
# reports everything already committed as SKIPPED (nothing staged).
#
# Never prints a secret, and never prints a commit message body in full —
# only its first line (the subject), which is enough for the table below.
#
# Exit codes:
#   0   every worktree that could be evaluated was: some may still show
#       FAILED or SKIPPED — read the table, this is not "all committed"
#   1   at least one worktree definitively FAILED (a `git commit` that ran
#       and failed for a reason that says something is actually wrong there
#       — most often a signing error)
#   2   at least one worktree could not even be evaluated (e.g. `git diff
#       --cached` itself failed, its path had vanished since 'git worktree
#       list' reported it, or `git commit` failed only because a concurrent
#       process — a live Herdr agent in that worktree — held index.lock) —
#       worse news than a known FAILED, so it takes priority when both
#       appear; something about that worktree is unknown rather than
#       known-bad
#   (also 1: could not even start — not run from inside a git checkout, or
#   `git` missing from PATH)
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
# the failure instead of `set -e` killing the script first. Use as:
#     something | grep x > "$f" || pipe_ok
#     [ -s "$f" ] || die "meaningful message"
pipe_ok() { return 0; }

# --------------------------------------------------------------------- parse

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

# --------------------------------------------------------------- discovery
#
# `git worktree list --porcelain` from the repo root, never a hardcoded
# worktree-directory glob — that layout is the dispatch tool's choice, not
# something this script should assume.

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

# `git worktree list` always lists the repository's primary worktree first —
# that is a documented property of the porcelain format, not an assumption
# about $REPO (the toplevel of *this checkout*, which is a linked worktree
# when this script is invoked from one). Read it from the same parse the
# per-worktree loop below uses, so both agree on what "primary" means.
PRIMARY_WT=$(head -n1 "$WT_LIST" | cut -f1)
[ -n "$PRIMARY_WT" ] || die "could not determine the primary worktree from 'git worktree list --porcelain'"

# --------------------------------------------------------------- per-worktree
#
# Fallible, prints nothing on failure, returns:
#   0  has staged changes (STAGED_COUNT and STAGED_LIST set)
#   1  nothing staged
#   2  could not evaluate (worktree missing/corrupt, git error)
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

# in_special_state <path> — 0 and SPECIAL_STATE_WHY set if a merge,
# cherry-pick, revert, or rebase is in progress in that worktree's own
# git-dir (each linked worktree has its own; a shared common dir would give
# a false positive from an unrelated worktree's in-progress operation).
# 1 if clean, 2 if the git-dir itself could not be resolved.
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

# field_or_dash <value> — a blank column shifts every later column left
# under `column -t`. Applied to every field before add_row.
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

    # Skip the primary worktree — only linked worktrees hold the Herdr agent
    # work this script exists to commit. Compared against the porcelain
    # listing's own first entry, not against $REPO (see PRIMARY_WT above).
    [ "$path" = "$PRIMARY_WT" ] && continue

    if [ ! -d "$path" ]; then
        # Not known-bad: 'git worktree list' reported this path a moment
        # ago; a Herdr agent process removing/relocating its own worktree
        # concurrently is exactly the live-worktree condition this script is
        # meant to run against, and nothing here says the *content* was ever
        # in trouble. UNKNOWN, not FAILED.
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
    # A whitespace-only first line is blank, not present: `[ -n ]` alone
    # passes "   " straight through, so the guard has to strip before it
    # tests, not test the raw bytes.
    SUBJECT_STRIPPED=$(printf '%s' "$SUBJECT" | tr -d '[:space:]')
    [ -n "$SUBJECT_STRIPPED" ] || SUBJECT="(empty .commit-msg.txt)"

    # If .commit-msg.txt is itself the only staged path, the unstage below
    # (needed so the message file never becomes a tracked file) would leave
    # nothing staged at all — `git commit` then fails with no useful
    # diagnosis. Recognize it here, before either dry-run or the real commit
    # attempt, and SKIP: there is genuinely nothing of the caller's to
    # commit, in a worktree already reported clean otherwise.
    NON_MSG_STAGED=$(printf '%s\n' "$STAGED_LIST" | grep -vx '\.commit-msg\.txt' || true)
    if [ -z "$NON_MSG_STAGED" ]; then
        add_row "$branch" "SKIPPED" "$STAGED_COUNT" "$TIP" "only staged path is .commit-msg.txt itself — nothing to commit"
        continue
    fi

    if [ "$DRY_RUN" = 1 ]; then
        # A whitespace-only message is not a prediction of success: `git
        # commit` refuses an empty message unconditionally, so promising
        # WOULD-COMMIT here would contradict what the real run reports for
        # the identical fixture.
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

    # If .commit-msg.txt itself ended up staged (e.g. a later `git add -A`
    # in that worktree), unstage it before committing so it is never folded
    # into the commit as a tracked file. Unstage only, never touch the
    # working-tree copy — the file, and the commit it describes, must
    # survive a failed or re-run invocation exactly as documented above. If
    # the commit then fails for any reason, re-stage it so a failed run
    # really does leave the index exactly as found, not permanently missing
    # one file's staged state.
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
                # Not known-bad: an index.lock left by a concurrent process
                # (a live Herdr agent in this same worktree, the case this
                # script is meant to run against) says the index could not
                # be evaluated right now, not that anything here is wrong.
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

# ------------------------------------------------------------------- report

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
