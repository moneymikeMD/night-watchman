#!/bin/bash
#
# Land a finished ticket branch onto the target branch (default: main),
# complete its ticket, and clean up.
# TRACKER. Two backends, via --tracker / LAND_BRANCH_TRACKER (default: file,
# so this plugin ships needing zero external accounts):
#
#   file    a ticket is a markdown file that moves between <issues-dir>/
#           {open,in-progress,awaiting-deployment,completed,cancelled}/, one
#           commit per move, edited before the move so it stages current content.
#
#   jira    a caller-supplied API wrapper (--jira-api PATH / ISSUES_JIRA_API)
#           called as `<wrapper> raw GET <path>`, `<wrapper> --yes write POST
#           <path> <json>` and `<wrapper> --yes comment <key> -` (text on
#           stdin); default providers/tracker/jira/jira-api.sh. Every
#           transition is resolved BY TARGET STATUS and READ BACK afterwards.
#
# LIFECYCLE. In Progress from dispatch; moved to Awaiting Deployment before
# landing and Completed after (--no-complete: only the first). Any other
# starting stage or jira status is refused.
#
# Usage:
#   land-branch.sh <branch> <ticket-id> [--dry-run]
#                  [--tracker file|jira] [--issues-dir DIR]
#                  [--jira-api PATH] [--jira-progress-status ID]
#                  [--jira-awaiting-status ID] [--jira-done-status ID]
#                  [--lint-cmd CMD] [--reset-land]
#                  [--outcome "text" | --outcome-file PATH]
#   land-branch.sh <branch> <ticket-id> --no-complete [--dry-run] [--note "text"] [--tracker file|jira] ...
#   land-branch.sh <branch> <ticket-id> --already-merged [--merged-as SHA] ...
#   land-branch.sh --help
#
# --already-merged (jira only) runs the LIFECYCLE half for a branch merged
# elsewhere, typically the GitHub UI's Squash and merge, merging and pushing
# nothing. It proves the landing by CONTENT, not ancestry, so a squash counts:
# every path the branch changed since it forked must be identical at the
# landing commit, named by --merged-as or found by ticket id and then judged.
#
# INTEGRATION WORKTREE. Merge, lint, completion and push run in
# `<parent-of-the-main-worktree>/<repo-basename>-land`, never in the invoking
# tree. Every run resets it to origin/<target-branch>; a dirty one is refused
# unless --reset-land is passed, and a concurrent run is refused by the lock
# at `<worktree>.lock`. The main worktree is NOT fast-forwarded after the push.
#
# Exit codes:
#   0   landed cleanly
#   1   a step failed AFTER the merge succeeded (lint, or completing). The
#       merge is reverted before this exit — except a failed `git push`,
#       which is NOT reverted (the landing is complete locally).
#   2   could not evaluate / stopped early — bad input, a dirty tree, a
#       missing ticket, a git precondition check that itself failed, or a
#       merge conflict. Nothing was mutated before this exit.
#
# Env overrides (all have a `--flag` equivalent; the flag wins):
#   TARGET_BRANCH                     branch to land onto (default: main).
#   LAND_BRANCH_TRACKER               file (default) | jira.
#   ISSUES_DIR                        file mode's tickets dir (default: issues).
#   ISSUES_JIRA_API                   jira mode's API wrapper path.
#   LAND_BRANCH_JIRA_PROGRESS_STATUS  In Progress status id. Required in jira
#                                     mode; no default.
#   LAND_BRANCH_JIRA_AWAITING_STATUS  Awaiting Deployment status id. Required
#                                     in jira mode; no default.
#   LAND_BRANCH_JIRA_DONE_STATUS      Completed status id. Required in jira
#                                     mode unless --no-complete; no default.
#   LAND_BRANCH_LINT_CMD              command run on the merged tree before
#                                     completing (default: ./scripts/lint.sh
#                                     if present, else skipped with a warning).
#   LAND_BRANCH_COAUTHOR              optional Co-Authored-By trailer.
#   LAND_BRANCH_SESSION               optional Claude-Session trailer.
#   LAND_BRANCH_ACK_WAIT_S            wait for scripts/land-ack.sh, s (default 10).
#   LAND_BRANCH_HANDOFF_FILE          closing-state path; unreadable = no closing state.
#   LAND_BRANCH_ORCHESTRATOR_PANE     override the orchestrator pane id.
#   LAND_BRANCH_EXECUTOR_FIELD        jira executor field (customfield_10047).
#   LAND_BRANCH_CLOSING_READBACK_ATTEMPTS jira read-back attempts (default 4).
#   LAND_BRANCH_CLOSING_READBACK_DELAY_S  seconds between them (default 1).
#   --reset-land                      (flag only) discard uncommitted changes in
#                                     the integration worktree before syncing.
#
# Optional layer: with HERDR_ENV=1 and `herdr` on PATH, a successful landing
# also removes the herdr worktree workspace matching this branch by name.
# Closing state (NWM-120, gated on a hand-off file by NWM-134): docs/decisions.md.

set -euo pipefail
# shellcheck source=lib/kit.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/kit.sh"

TARGET_BRANCH="${TARGET_BRANCH:-main}"
TRACKER="${LAND_BRANCH_TRACKER:-file}"
ISSUES_DIR="${ISSUES_DIR:-issues}"
JIRA_API="${ISSUES_JIRA_API:-}"
JIRA_DONE_STATUS="${LAND_BRANCH_JIRA_DONE_STATUS:-}"
JIRA_AWAITING_STATUS="${LAND_BRANCH_JIRA_AWAITING_STATUS:-}"
JIRA_PROGRESS_STATUS="${LAND_BRANCH_JIRA_PROGRESS_STATUS:-}"
LINT_CMD="${LAND_BRANCH_LINT_CMD:-}"
# Set once the jira issue reaches Awaiting Deployment, so every later stop
# says the issue stays there.
LIFECYCLE_NOTE=""

# stop2 — a precondition could not be met, BEFORE any mutating command has
# run. Releases the integration-worktree lock first; a no-op if never held.
stop2() { release_land_lock; echo "Error: $*${LIFECYCLE_NOTE:+
$LIFECYCLE_NOTE}" >&2; exit 2; }

# stop2_reset / die_reset — as stop2/die, but for a failure AFTER the merge:
# reset first, every time, so the merge commit never sits on $TARGET_BRANCH.
stop2_reset() {
    release_land_lock
    git reset --hard ORIG_HEAD >/dev/null 2>&1 \
        || warn "git reset --hard ORIG_HEAD also failed — $TARGET_BRANCH may still carry the merge commit, check by hand"
    echo "Error: $*${LIFECYCLE_NOTE:+
$LIFECYCLE_NOTE}" >&2
    exit 2
}
die_reset() {
    release_land_lock
    git reset --hard ORIG_HEAD >/dev/null 2>&1 \
        || warn "git reset --hard ORIG_HEAD also failed — $TARGET_BRANCH may still carry the merge commit, check by hand"
    die "$*${LIFECYCLE_NOTE:+
$LIFECYCLE_NOTE}"
}

# The lock serialises the shared integration worktree. kit.sh has no generic
# on-exit hook, so every controlled exit path calls release_land_lock
# explicitly; an uncontrolled crash is covered only by the stale-pid reclaim.

LAND_LOCK_DIR=""
LAND_LOCK_ACQUIRED=0

# release_land_lock — best-effort: a failure to remove it is warned, not
# fatal — the next run's stale-pid reclaim recovers it.
release_land_lock() {
    [ "$LAND_LOCK_ACQUIRED" = 1 ] || return 0
    [ -n "$LAND_LOCK_DIR" ] || return 0
    LAND_LOCK_ACQUIRED=0
    rm -f "$LAND_LOCK_DIR" 2>/dev/null \
        || warn "could not remove lock file '$LAND_LOCK_DIR' — remove it by hand once no land-branch.sh run is actually using it"
}

# acquire_land_lock <land-worktree-lock-file> — never waits: wins the lock, or
# refuses loudly (stop2) naming the holder's pid and start time. A holder with
# no live pid is reclaimed and the attempt retried, capped.
acquire_land_lock() {
    local dir="$1" attempt=0 tmp holder_pid holder_started
    LAND_LOCK_DIR="$dir"
    while [ "$attempt" -lt 20 ]; do
        attempt=$((attempt + 1))
        tmp="$dir.holder.$$"
        printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" > "$tmp" \
            || stop2 "could not write a temp lock-holder file '$tmp'"
        if ln "$tmp" "$dir" 2>/dev/null; then
            rm -f "$tmp"
            LAND_LOCK_ACQUIRED=1
            return 0
        fi
        rm -f "$tmp"
        holder_pid=""
        holder_started=""
        if [ -f "$dir" ]; then
            holder_pid=$(awk -F= '/^pid=/{print $2}' "$dir" 2>/dev/null)
            holder_started=$(awk -F= '/^started=/{print $2}' "$dir" 2>/dev/null)
        fi
        case "$holder_pid" in ''|*[!0-9]*) holder_pid="" ;; esac
        if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
            stop2 "integration worktree '$LAND_WORKTREE' is locked by pid $holder_pid (started epoch $holder_started) — another land-branch.sh run holds it. Wait for it to finish, or remove '$dir' by hand if you are certain that pid is not actually land-branch.sh"
        fi
        # No holder content, or its pid is not running: stale. Reclaim and retry.
        rm -f "$dir" 2>/dev/null
    done
    stop2 "could not acquire the integration worktree lock '$dir' after $attempt attempts — repeatedly lost the race, or could not create/remove it (permissions?)"
}


BRANCH=""
TICKET_ID=""
DRY_RUN=0
OUTCOME_TEXT=""
OUTCOME_FILE=""
NO_COMPLETE=0
NOTE_TEXT=""
NOTE_GIVEN=0
RESET_LAND=0
ALREADY_MERGED=0
MERGED_AS=""
LANDED_SHA=""
LANDED_HOW="merge commit"
POSITIONAL=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|help) show_help ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-complete) NO_COMPLETE=1; shift ;;
        --reset-land) RESET_LAND=1; shift ;;
        --already-merged) ALREADY_MERGED=1; shift ;;
        --merged-as)
            [ $# -ge 2 ] || stop2 "--merged-as needs a commit-ish"
            MERGED_AS="$2"; shift 2 ;;
        --tracker)
            [ $# -ge 2 ] || stop2 "--tracker needs an argument: file or jira"
            TRACKER="$2"; shift 2 ;;
        --issues-dir)
            [ $# -ge 2 ] || stop2 "--issues-dir needs a path"
            ISSUES_DIR="$2"; shift 2 ;;
        --jira-api)
            [ $# -ge 2 ] || stop2 "--jira-api needs a path"
            JIRA_API="$2"; shift 2 ;;
        --jira-done-status)
            [ $# -ge 2 ] || stop2 "--jira-done-status needs a status id"
            JIRA_DONE_STATUS="$2"; shift 2 ;;
        --jira-awaiting-status)
            [ $# -ge 2 ] || stop2 "--jira-awaiting-status needs a status id"
            JIRA_AWAITING_STATUS="$2"; shift 2 ;;
        --jira-progress-status)
            [ $# -ge 2 ] || stop2 "--jira-progress-status needs a status id"
            JIRA_PROGRESS_STATUS="$2"; shift 2 ;;
        --lint-cmd)
            [ $# -ge 2 ] || stop2 "--lint-cmd needs a command"
            LINT_CMD="$2"; shift 2 ;;
        --note)
            [ $# -ge 2 ] || stop2 "--note needs an argument"
            case "$2" in
                -*) stop2 "--note needs a text argument, got '$2' — looks like a flag was swallowed; quote the text if it should start with '-'" ;;
            esac
            NOTE_GIVEN=1; NOTE_TEXT="$2"; shift 2 ;;
        --outcome)
            [ $# -ge 2 ] || stop2 "--outcome needs an argument"
            [ -z "$OUTCOME_FILE" ] || stop2 "--outcome and --outcome-file are mutually exclusive"
            OUTCOME_TEXT="$2"; shift 2 ;;
        --outcome-file)
            [ $# -ge 2 ] || stop2 "--outcome-file needs a path"
            [ -z "$OUTCOME_TEXT" ] || stop2 "--outcome and --outcome-file are mutually exclusive"
            OUTCOME_FILE="$2"; shift 2 ;;
        --) shift; while [ $# -gt 0 ]; do POSITIONAL="$POSITIONAL$1
"; shift; done ;;
        -*) stop2 "unknown option: $1 (see --help)" ;;
        *) POSITIONAL="$POSITIONAL$1
"; shift ;;
    esac
done

if [ "$NO_COMPLETE" = 1 ]; then
    if [ -n "$OUTCOME_TEXT" ] || [ -n "$OUTCOME_FILE" ]; then
        stop2 "--no-complete and --outcome/--outcome-file are mutually exclusive — a ticket left open takes no outcome"
    fi
else
    [ "$NOTE_GIVEN" = 0 ] || stop2 "--note requires --no-complete — a completed ticket takes an outcome, not a note"
fi
[ "$NOTE_GIVEN" != 1 ] || [ -n "$NOTE_TEXT" ] || stop2 "--note needs non-empty text"

case "$TRACKER" in
    file|jira) ;;
    *) stop2 "--tracker must be 'file' or 'jira' (got '$TRACKER')" ;;
esac

if [ "$ALREADY_MERGED" = 1 ]; then
    # The file tracker completes a ticket by COMMITTING its move between
    # directories, and a commit is the one thing this mode declines to make.
    [ "$TRACKER" != file ] || stop2 "--already-merged does not support --tracker file: the file tracker completes a ticket by committing its move between $ISSUES_DIR subdirectories, and this mode makes no commit and no push. Land it normally, or move the file and complete the ticket by hand"
    [ "$RESET_LAND" != 1 ] || stop2 "--already-merged and --reset-land are mutually exclusive: --reset-land names the integration worktree, which this mode never builds"
elif [ -n "$MERGED_AS" ]; then
    stop2 "--merged-as requires --already-merged — it names the commit an existing landing is already on, which the merging path resolves for itself"
fi
if [ "$TRACKER" = jira ] && [ "$NO_COMPLETE" != 1 ]; then
    [ -n "$JIRA_DONE_STATUS" ] || stop2 "jira mode needs --jira-done-status (or \$LAND_BRANCH_JIRA_DONE_STATUS) — no default exists across trackers"
    case "$JIRA_DONE_STATUS" in
        ''|*[!0-9]*) stop2 "--jira-done-status must be numeric (got '$JIRA_DONE_STATUS')" ;;
    esac
fi
if [ "$TRACKER" = jira ]; then
    [ -n "$JIRA_PROGRESS_STATUS" ] || stop2 "jira mode needs --jira-progress-status (or \$LAND_BRANCH_JIRA_PROGRESS_STATUS) — no default exists across trackers"
    [ -n "$JIRA_AWAITING_STATUS" ] || stop2 "jira mode needs --jira-awaiting-status (or \$LAND_BRANCH_JIRA_AWAITING_STATUS) — no default exists across trackers"
    case "$JIRA_PROGRESS_STATUS" in
        *[!0-9]*) stop2 "--jira-progress-status must be numeric (got '$JIRA_PROGRESS_STATUS')" ;;
    esac
    case "$JIRA_AWAITING_STATUS" in
        *[!0-9]*) stop2 "--jira-awaiting-status must be numeric (got '$JIRA_AWAITING_STATUS')" ;;
    esac
    [ -n "$JIRA_API" ] || stop2 "jira mode needs --jira-api PATH (or \$ISSUES_JIRA_API) — this plugin's default wrapper lives at providers/tracker/jira/jira-api.sh"
    [ -x "$JIRA_API" ] || stop2 "jira API wrapper is missing or not executable: $JIRA_API"
fi

# shellcheck disable=SC2086  # deliberate word splitting: POSITIONAL is a
# newline-joined list of bare args (branch, ticket id)
set -- $POSITIONAL
[ $# -eq 2 ] || stop2 "expected <branch> <ticket-id>, got $# positional argument(s) (see --help)"
BRANCH="$1"
TICKET_ID="$2"
[ -n "$BRANCH" ] || stop2 "branch name is empty"
case "$TICKET_ID" in
    [A-Za-z]*-[0-9]*) ;;
    *) stop2 "'$TICKET_ID' does not look like a ticket id (want PREFIX-nnn)" ;;
esac

need git


INVOKING_REPO=$(git rev-parse --show-toplevel 2>/dev/null) || stop2 "not inside a git repository"
cd "$INVOKING_REPO"

git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null \
    || stop2 "branch '$BRANCH' does not exist"

# `git worktree list --porcelain`'s first entry is always the main worktree.
# A real failure swallowed into "" is indistinguishable from "no worktrees",
# so it is a stop2, never a guessed pass.
if ! WT_PORCELAIN=$(git worktree list --porcelain 2>&1); then
    stop2 "could not evaluate 'git worktree list': $WT_PORCELAIN"
fi
MAIN_WORKTREE=$(printf '%s\n' "$WT_PORCELAIN" | awk '/^worktree /{sub(/^worktree /,""); print; exit}')
[ -n "$MAIN_WORKTREE" ] || stop2 "could not determine the main worktree from 'git worktree list'"
LAND_WORKTREE="$(dirname "$MAIN_WORKTREE")/$(basename "$MAIN_WORKTREE")-land"
LAND_EXISTS=0
printf '%s\n' "$WT_PORCELAIN" | grep -qxF "worktree $LAND_WORKTREE" && LAND_EXISTS=1

# <branch>'s own worktree, if any, must be fully committed. Reuses
# $WT_PORCELAIN: same repo, so it already lists every worktree's branch.
BRANCH_WT=$(printf '%s\n' "$WT_PORCELAIN" | awk -v b="refs/heads/$BRANCH" '
    /^worktree / { path=$0; sub(/^worktree /,"",path) }
    /^branch /   { br=$0; sub(/^branch /,"",br); if (br==b) print path }
')
if [ -n "$BRANCH_WT" ]; then
    # NWM-147: the worker brief requires .night-watchman/closing-state.md
    # uncommitted in this worktree and step 5 reads it, so requiring the file
    # and then refusing it was a contradiction. -uall makes the exclusion
    # precise: without it git collapses the dir to '?? .night-watchman/'.
    if ! WT_STATUS=$(git -C "$BRANCH_WT" status --porcelain -uall \
            -- . ':!.night-watchman/closing-state.md' 2>&1); then
        stop2 "could not check worktree '$BRANCH_WT' for branch '$BRANCH' (git status failed — removed or corrupt worktree?): $WT_STATUS"
    fi
    [ -z "$WT_STATUS" ] || stop2 "branch '$BRANCH' worktree at '$BRANCH_WT' has uncommitted changes — commit or stash them first (.night-watchman/closing-state.md is exempt; nothing else is):
$WT_STATUS"
fi

# --already-merged: prove the branch's work is ON the target before anything
# transitions. Two proofs, because a squash-merged branch is not an ancestor
# of the target while a --no-ff merged one is, and each shape admits only one
# of them: ancestry where it holds, content everywhere else.
if [ "$ALREADY_MERGED" = 1 ]; then
    git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null 2>&1 \
        || stop2 "--already-merged: no local branch '$BRANCH' — its content is what this mode checks against the target, so the branch must still exist"
    echo "Fetching origin to check '$BRANCH' against '$TARGET_BRANCH'..."
    FETCH_OUT=$(git fetch origin 2>&1) || stop2 "--already-merged: git fetch origin failed: $FETCH_OUT"
    git rev-parse --verify --quiet "refs/remotes/origin/$TARGET_BRANCH" >/dev/null 2>&1 \
        || stop2 "--already-merged: origin/$TARGET_BRANCH does not exist — nothing to check the branch against"

    if git merge-base --is-ancestor "$BRANCH" "origin/$TARGET_BRANCH" 2>/dev/null; then
        # A merge that kept the branch's commits. Ancestry is a stronger proof
        # than content, and content cannot run here anyway: the fork point IS
        # the branch tip, so it would compare nothing and pass vacuously.
        LANDED_SHA=$(git rev-parse --verify --quiet "${MERGED_AS:-origin/$TARGET_BRANCH}^{commit}") \
            || stop2 "--merged-as: '$MERGED_AS' does not resolve to a commit in this repository"
        git merge-base --is-ancestor "$BRANCH" "$LANDED_SHA" 2>/dev/null \
            || stop2 "--merged-as $MERGED_AS predates '$BRANCH''s landing — '$BRANCH' is not an ancestor of it. Nothing was transitioned"
        echo "'$BRANCH' is an ancestor of origin/$TARGET_BRANCH — landed at $(git rev-parse --short "$LANDED_SHA")."
    else
        # Squashed or rebase-merged: the commits are gone, so the proof is
        # CONTENT. Every path the branch changed since it forked must be
        # identical at the landing commit; anything else there is other work.
        FORK_POINT=$(git merge-base "origin/$TARGET_BRANCH" "$BRANCH" 2>/dev/null) \
            || stop2 "--already-merged: '$BRANCH' and origin/$TARGET_BRANCH have no common ancestor"
        BRANCH_PATHS=$(git diff --name-only "$FORK_POINT" "$BRANCH" 2>/dev/null) \
            || stop2 "--already-merged: could not list the paths '$BRANCH' changed since $FORK_POINT"
        [ -n "$BRANCH_PATHS" ] || stop2 "--already-merged: '$BRANCH' changes no path relative to origin/$TARGET_BRANCH and is not an ancestor of it — there is nothing whose landing could be proved"

        # git diff takes no --pathspec-from-file, and splitting the list into
        # argv would break on a path with a space, so intersect the name lists.
        PATHS_FILE=$(tmpfile) || stop2 "--already-merged: could not create a temp file for the path list"
        printf '%s\n' "$BRANCH_PATHS" > "$PATHS_FILE"
        landing_holds() {
            local sha="$1" changed
            git merge-base --is-ancestor "$sha" "origin/$TARGET_BRANCH" 2>/dev/null || return 1
            changed=$(git diff --name-only "$sha" "$BRANCH" 2>/dev/null) || return 1
            [ -n "$changed" ] || return 0
            printf '%s\n' "$changed" | grep -qxF -f "$PATHS_FILE" && return 1
            return 0
        }

        if [ -n "$MERGED_AS" ]; then
            LANDED_SHA=$(git rev-parse --verify --quiet "$MERGED_AS^{commit}") \
                || stop2 "--merged-as: '$MERGED_AS' does not resolve to a commit in this repository"
            landing_holds "$LANDED_SHA" \
                || stop2 "--merged-as $MERGED_AS does not carry '$BRANCH''s work: either it is not on origin/$TARGET_BRANCH, or the paths '$BRANCH' changed differ there. Nothing was transitioned. Compare with: git diff $LANDED_SHA $BRANCH"
        else
            # A subject naming the ticket is a CANDIDATE, never the answer:
            # landing_holds is the oracle, so a wrong guess is refused.
            for cand in $(git log --format='%H' -n 50 "origin/$TARGET_BRANCH" 2>/dev/null); do
                git log --format='%s' -n 1 "$cand" 2>/dev/null | grep -qiF "$TICKET_ID" || continue
                if landing_holds "$cand"; then LANDED_SHA="$cand"; break; fi
            done
            [ -n "$LANDED_SHA" ] || stop2 "--already-merged: no commit in the last 50 on origin/$TARGET_BRANCH both names $TICKET_ID and carries '$BRANCH''s content. Pass --merged-as <sha> — find it with: git log origin/$TARGET_BRANCH --oneline | grep -i $TICKET_ID"
        fi
        echo "'$BRANCH''s work is on origin/$TARGET_BRANCH at $(git rev-parse --short "$LANDED_SHA") — $(printf '%s\n' "$BRANCH_PATHS" | wc -l | tr -d ' ') path(s) verified identical."
    fi
fi

# Resolve the ticket against $TARGET_BRANCH's content via `git show`, not the
# working tree, which need not be on $TARGET_BRANCH at all. A preview only:
# the same resolution runs again, authoritatively, against the post-merge tree.
TICKET_FILE=""
TICKET_STAGE=""
ALREADY_DONE=0
JIRA_STATUS_NOW=""
JIRA_AWAIT_TID=""
JIRA_AWAIT_TO=""
JIRA_DONE_TID=""
JIRA_DONE_TO=""
JIRA_ERR=""
COMPLETE_FAILED=""

if [ "$TRACKER" = file ]; then
    for stage in in-progress awaiting-deployment open completed cancelled; do
        cand="$ISSUES_DIR/$stage/$TICKET_ID.md"
        if git cat-file -e "$TARGET_BRANCH:$cand" 2>/dev/null; then
            TICKET_FILE="$cand"
            TICKET_STAGE="$stage"
            break
        fi
    done
    [ -n "$TICKET_FILE" ] || stop2 "no ticket file found for '$TICKET_ID' under '$ISSUES_DIR/{open,in-progress,awaiting-deployment,completed,cancelled}/' on '$TARGET_BRANCH'"
    if [ "$NO_COMPLETE" != 1 ] && [ "$TICKET_STAGE" = completed ]; then
        ALREADY_DONE=1
    fi
    case "$TICKET_STAGE" in
        in-progress|awaiting-deployment) ;;
        completed) [ "$ALREADY_DONE" = 1 ] || stop2 "$TICKET_FILE is already in completed/ — nothing to leave open with --no-complete" ;;
        *) stop2 "$TICKET_FILE is in $TICKET_STAGE/, not in-progress/ or awaiting-deployment/ — the lifecycle was skipped upstream (a dispatched ticket is in-progress). Nothing mutated. Move it by hand, say so in the ticket, then re-run" ;;
    esac
    # Both fields must already exist in the frontmatter block for the rewrite
    # to edit in place: appending one later would land past the closing '---',
    # in the body, where issues.py would never read it back.
    if [ "$NO_COMPLETE" != 1 ] && [ "$ALREADY_DONE" != 1 ]; then
        # awk reads to EOF: exiting at the second '---' SIGPIPEs git show on a
        # large ticket and pipefail turns that into exit 141.
        FM_TOP=$(git show "$TARGET_BRANCH:$TICKET_FILE" 2>/dev/null | awk '/^---$/{c++} c<2 {print}')
        printf '%s\n' "$FM_TOP" | grep -q '^outcome:' \
            || stop2 "$TICKET_FILE has no 'outcome:' field in its frontmatter to rewrite"
        printf '%s\n' "$FM_TOP" | grep -q '^updated:' \
            || stop2 "$TICKET_FILE has no 'updated:' field in its frontmatter to rewrite"
    fi
else
    need jq
    JIRA_ERR=$(tmpfile) || stop2 "could not create a temp file for jira-api diagnostics"

    jira_read() { [ -n "$JIRA_ERR" ] || return 1; "$JIRA_API" raw GET "$1" 2>"$JIRA_ERR"; }
    jira_err() { [ -n "$JIRA_ERR" ] && [ -s "$JIRA_ERR" ] && cat "$JIRA_ERR"; return 0; }
    jira_write() { "$JIRA_API" --yes write POST "$1" "$2" >&2; }
    jira_post_comment() { printf '%s' "$2" | "$JIRA_API" --yes comment "$1" - >&2; }

    # jira_resolve_to STATUS_ID — sets RESOLVED_TID/RESOLVED_TO to the one
    # live transition into STATUS_ID, or returns 1 with RESOLVE_MSG set.
    # Called directly, never inside $( ), so the globals survive.
    jira_resolve_to() {
        local tj m
        RESOLVED_TID=""; RESOLVED_TO=""; RESOLVE_MSG=""
        if ! tj=$(jira_read "/issue/$TICKET_ID/transitions"); then
            RESOLVE_MSG="could not list transitions for $TICKET_ID (GET /issue/$TICKET_ID/transitions). jira-api said:
$(jira_err)"
            return 1
        fi
        m=$(printf '%s' "$tj" | jq -r --arg s "$1" '
            [ (.transitions // [])[] | select((.to.id|tostring) == $s) ]
            | length as $n
            | if $n == 1 then "\(.[0].id)\t\(.[0].to.name)" else "COUNT \($n)" end
        ' 2>/dev/null) || m=""
        case "$m" in
            "COUNT 0") RESOLVE_MSG="issue $TICKET_ID has no transition to status id $1 — fix the workflow"; return 1 ;;
            COUNT*)    RESOLVE_MSG="issue $TICKET_ID has more than one transition to status id $1 — refusing to guess"; return 1 ;;
            "")        RESOLVE_MSG="could not parse GET /issue/$TICKET_ID/transitions — not a Jira transitions response?"; return 1 ;;
        esac
        RESOLVED_TID=$(printf '%s' "$m" | cut -f1)
        RESOLVED_TO=$(printf '%s' "$m" | cut -f2-)
        case "$RESOLVED_TID" in
            ''|*[!0-9]*) RESOLVE_MSG="resolved transition id '$RESOLVED_TID' is not numeric — refusing"; return 1 ;;
        esac
    }

    # jira_move TRANSITION_ID TARGET_STATUS_ID — POST the transition, then
    # read the issue back (a 2xx is not proof). Sets MOVE_AFTER_NAME and, on
    # failure, MOVE_MSG; returns 0 only when the read-back shows the target.
    jira_move() {
        local post_ok=1 after after_id
        MOVE_AFTER_NAME=""; MOVE_MSG=""
        jira_write "/issue/$TICKET_ID/transitions" "{\"transition\":{\"id\":\"$1\"}}" || post_ok=0
        if ! after=$(jira_read "/issue/$TICKET_ID?fields=status"); then
            MOVE_MSG="could not read $TICKET_ID back after the transition POST (POST $([ "$post_ok" = 1 ] && echo ok || echo FAILED)); it MAY be in status id $2, check by hand. jira-api said:
$(jira_err)"
            return 1
        fi
        after_id=$(printf '%s' "$after" | jq -r '.fields.status.id // empty' 2>/dev/null) || after_id=""
        MOVE_AFTER_NAME=$(printf '%s' "$after" | jq -r '.fields.status.name // empty' 2>/dev/null) || MOVE_AFTER_NAME=""
        if [ "$post_ok" != 1 ]; then
            if [ "$after_id" = "$2" ]; then
                MOVE_MSG="transition POST failed BUT $TICKET_ID reads back as '$MOVE_AFTER_NAME' — check it by hand"
            else
                MOVE_MSG="transition POST failed (jira-api's error is above); $TICKET_ID is still '$MOVE_AFTER_NAME'"
            fi
            return 1
        fi
        [ "$after_id" = "$2" ] && return 0
        MOVE_MSG="transition POST returned 2xx but $TICKET_ID reads back as '$MOVE_AFTER_NAME', not status id $2"
        return 1
    }

    # jira_closing_readback MARK — retries the comment read-back with a
    # bounded, linearly-backed-off wait, absorbing Jira's read-after-write
    # window. Sets CLOSING_READBACK_MSG to say whether the GET itself failed
    # or merely came back without MARK; returns 0 the first time MARK appears.
    jira_closing_readback() {
        local mark="$1" attempts="${LAND_BRANCH_CLOSING_READBACK_ATTEMPTS:-4}" \
            delay="${LAND_BRANCH_CLOSING_READBACK_DELAY_S:-1}" n=1 body
        # Both knobs feed a bash arithmetic expansion; a non-whole-number
        # value (e.g. "0.5" or "abc") would abort or kill the shell, so fall
        # back to the default instead of trusting operator input.
        case "$attempts" in (*[!0-9]*|'') attempts=4 ;; esac
        case "$delay" in (*[!0-9]*|'') delay=1 ;; esac
        CLOSING_READBACK_MSG=""
        while :; do
            if body=$(jira_read "/issue/$TICKET_ID/comment?maxResults=100&orderBy=-created"); then
                printf '%s' "$body" | grep -Fq "$mark" && return 0
                CLOSING_READBACK_MSG="attempt $n: the GET succeeded but the comment list did not carry '$mark' yet"
            else
                CLOSING_READBACK_MSG="attempt $n: GET /issue/$TICKET_ID/comment failed. jira-api said:
$(jira_err)"
            fi
            [ "$n" -lt "$attempts" ] || break
            sleep "$((delay * n))"
            n=$((n + 1))
        done
        return 1
    }

    ISSUE_JSON=$(jira_read "/issue/$TICKET_ID?fields=status") \
        || stop2 "could not read issue $TICKET_ID (GET /issue/$TICKET_ID) — nothing mutated. jira-api said:
$(jira_err)"
    JIRA_STATUS_NOW=$(printf '%s' "$ISSUE_JSON" | jq -r '.fields.status.name // empty' 2>/dev/null) || JIRA_STATUS_NOW=""
    [ -n "$JIRA_STATUS_NOW" ] || stop2 "GET /issue/$TICKET_ID returned no status name — not a Jira issue response?"
    JIRA_STATUS_NOW_ID=$(printf '%s' "$ISSUE_JSON" | jq -r '.fields.status.id // empty' 2>/dev/null) || JIRA_STATUS_NOW_ID=""

    if [ "$NO_COMPLETE" != 1 ] && [ "$JIRA_STATUS_NOW_ID" = "$JIRA_DONE_STATUS" ]; then
        ALREADY_DONE=1
    elif [ "$JIRA_STATUS_NOW_ID" = "$JIRA_AWAITING_STATUS" ]; then
        :
    elif [ "$JIRA_STATUS_NOW_ID" = "$JIRA_PROGRESS_STATUS" ]; then
        jira_resolve_to "$JIRA_AWAITING_STATUS" || stop2 "$RESOLVE_MSG — nothing mutated"
        JIRA_AWAIT_TID="$RESOLVED_TID"
        JIRA_AWAIT_TO="$RESOLVED_TO"
    else
        stop2 "issue $TICKET_ID is '$JIRA_STATUS_NOW' (status id ${JIRA_STATUS_NOW_ID:-unknown}), not In Progress ($JIRA_PROGRESS_STATUS) or Awaiting Deployment ($JIRA_AWAITING_STATUS) — the lifecycle was skipped upstream (dispatch start moves a ticket to In Progress). Nothing mutated. Repair the status by hand, say so in the ticket, then re-run"
    fi
fi

if [ "$NO_COMPLETE" != 1 ]; then
    if [ -n "$OUTCOME_FILE" ]; then
        [ -r "$OUTCOME_FILE" ] || stop2 "cannot read --outcome-file '$OUTCOME_FILE'"
        OUTCOME_TEXT=$(cat "$OUTCOME_FILE") || stop2 "could not read '$OUTCOME_FILE'"
    fi
    [ -n "$OUTCOME_TEXT" ] || OUTCOME_TEXT="Completed $(date +%F). Landed branch '$BRANCH' via land-branch.sh."
fi

# Trailers are opt-in: unset means no trailer, not a refusal. TRAILER_BLOCK
# carries its own leading blank line and collapses to "" when both are unset.
TRAILER_BLOCK=""
[ -n "${LAND_BRANCH_COAUTHOR:-}" ] && TRAILER_BLOCK="$TRAILER_BLOCK
Co-Authored-By: $LAND_BRANCH_COAUTHOR"
[ -n "${LAND_BRANCH_SESSION:-}" ] && TRAILER_BLOCK="$TRAILER_BLOCK
Claude-Session: $LAND_BRANCH_SESSION"
[ -z "$TRAILER_BLOCK" ] || TRAILER_BLOCK="
$TRAILER_BLOCK"

CLOSING=0
CLOSING_FAILED=""
CLOSING_TEXT=""
CLOSING_MARK=""
ORCH_PANE="${LAND_BRANCH_ORCHESTRATOR_PANE:-}"
if [ "${HERDR_ENV:-}" = "1" ]; then
    HANDOFF_FILE="${LAND_BRANCH_HANDOFF_FILE:-}"
    WORKER_WT=$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$BRANCH" '/^worktree /{p=substr($0,10)} $1=="branch" && $2==b {print p}') || WORKER_WT=""
    if [ -z "$HANDOFF_FILE" ] && [ -n "$WORKER_WT" ]; then
        HANDOFF_FILE="$WORKER_WT/.night-watchman/closing-state.md"
    fi
    [ -n "$HANDOFF_FILE" ] && [ -r "$HANDOFF_FILE" ] && CLOSING=1

    # handoff_section HEADING — body of `## HEADING` in the handoff file,
    # trimmed of blank edges; empty when the file or section is absent.
    handoff_section() {
        [ -n "$HANDOFF_FILE" ] && [ -r "$HANDOFF_FILE" ] || return 0
        awk -v h="## $1" '
            $0 == h { on = 1; next }
            /^## / { on = 0 }
            on { print }
        ' "$HANDOFF_FILE" | sed -e '/./,$!d' | awk '{ l[NR] = $0 } END { n = NR; while (n > 0 && l[n] == "") n--; for (i = 1; i <= n; i++) print l[i] }'
    }

    if [ "$TRACKER" = file ]; then
        EXECUTOR=$(git show "$TARGET_BRANCH:$TICKET_FILE" 2>/dev/null | awk '/^---$/ { c++; next } c == 1 && !d && /^executor:/ { sub(/^executor:[ \t]*/, ""); print; d = 1 }') || EXECUTOR=""
    else
        EXEC_FIELD="${LAND_BRANCH_EXECUTOR_FIELD:-customfield_10047}"
        EXECUTOR=""
        if EXEC_JSON=$(jira_read "/issue/$TICKET_ID?fields=$EXEC_FIELD"); then
            EXECUTOR=$(printf '%s' "$EXEC_JSON" | jq -r --arg f "$EXEC_FIELD" '.fields[$f].value // empty' 2>/dev/null) || EXECUTOR=""
        fi
    fi
    EXECUTOR=$(printf '%s' "$EXECUTOR" | tr '[:upper:]' '[:lower:]' | tr -d ' \t\r')
    RUN_LIST=$(handoff_section "Human run list")
    case "$EXECUTOR" in
        human|mixed)
            [ -n "$RUN_LIST" ] || stop2 "$TICKET_ID's executor is '$EXECUTOR' but no '## Human run list' was found in '${HANDOFF_FILE:-<no worker worktree found for branch $BRANCH>}' — the closing state must carry the run list; have the worker write it (or set LAND_BRANCH_HANDOFF_FILE). Nothing mutated"
            ;;
    esac
    [ -n "$ORCH_PANE" ] || {
        [ -n "$HANDOFF_FILE" ] && [ -r "$HANDOFF_FILE" ] && ORCH_PANE=$(sed -n 's/^orchestrator-pane:[[:space:]]*//p' "$HANDOFF_FILE" | head -1) || true
    }
    BRANCH_CONDITION="landed; nothing left uncommitted in the worker's worktree"
    if [ -n "$WORKER_WT" ] && [ -d "$WORKER_WT" ]; then
        WT_DIRTY=$(git -C "$WORKER_WT" status --porcelain -- . ':!.night-watchman' 2>/dev/null) || WT_DIRTY=""
        [ -z "$WT_DIRTY" ] || BRANCH_CONDITION="landed, but the worker's worktree has UNCOMMITTED work that was not landed"
    else
        BRANCH_CONDITION="landed; worker worktree not found, uncommitted state unknown"
    fi
fi

MERGE_MSG="$TICKET_ID: merge branch '$BRANCH' into $TARGET_BRANCH

Landed via land-branch.sh."

# Read-only: no worktree add/fetch/reset runs here, dry-run or not.
if [ "$LAND_EXISTS" = 1 ]; then
    if ! LAND_PLAN_STATUS=$(git -C "$LAND_WORKTREE" status --porcelain 2>&1); then
        LAND_STATE_DESC="exists, but its status could not be checked: $LAND_PLAN_STATUS"
    elif [ -z "$LAND_PLAN_STATUS" ]; then
        LAND_STATE_DESC="exists, clean"
    else
        LAND_STATE_DESC="exists, DIRTY:
$LAND_PLAN_STATUS"
    fi
else
    LAND_STATE_DESC="does not exist yet — will be created via 'git worktree add --detach' on '$TARGET_BRANCH'"
fi

echo "Plan:"
if [ "$ALREADY_MERGED" = 1 ]; then
    echo "  0. --already-merged: no integration worktree, no merge, no lint, no push. '$BRANCH''s work is already on origin/$TARGET_BRANCH at $(git rev-parse --short "$LANDED_SHA")."
else
    echo "  0. integration worktree: '$LAND_WORKTREE' ($LAND_STATE_DESC)"
fi
if [ "$TRACKER" = file ]; then
    if [ "$TICKET_STAGE" = in-progress ]; then
        echo "  1a. git mv $ISSUES_DIR/in-progress/$TICKET_ID.md -> $ISSUES_DIR/awaiting-deployment/ (updated bumped), commit — unless '$BRANCH' already moved it"
    else
        echo "  1a. ticket is in '$ISSUES_DIR/$TICKET_STAGE/' — no awaiting-deployment move"
    fi
elif [ -n "$JIRA_AWAIT_TID" ]; then
    echo "  1a. POST transition $JIRA_AWAIT_TID on $TICKET_ID ('$JIRA_STATUS_NOW' -> '$JIRA_AWAIT_TO'), read back to confirm"
else
    echo "  1a. issue $TICKET_ID is '$JIRA_STATUS_NOW' — no Awaiting Deployment move"
fi
if [ "$ALREADY_MERGED" = 1 ]; then
    echo "  1. (--already-merged) nothing merged — $(git rev-parse --short "$LANDED_SHA") already carries it"
    echo "  2. (--already-merged) no lint — this tree was not merged here"
else
    echo "  1. merge '$BRANCH' into '$TARGET_BRANCH' (--no-ff), inside the integration worktree"
    if [ -n "$LINT_CMD" ] || [ -x ./scripts/lint.sh ]; then
        echo "  2. ${LINT_CMD:-./scripts/lint.sh} on the merged tree"
    else
        echo "  2. (no lint command configured or found — skipped)"
    fi
fi
if [ "$TRACKER" = file ]; then
    if [ "$NO_COMPLETE" = 1 ]; then
        if [ "$NOTE_GIVEN" = 1 ]; then
            echo "  3. (--no-complete) append note to $ISSUES_DIR/$TICKET_STAGE/$TICKET_ID.notes.md — ticket stays in '$TICKET_STAGE/'"
        else
            echo "  3. (--no-complete) ticket left in '$ISSUES_DIR/$TICKET_STAGE/' — NOT completed"
        fi
    elif [ "$ALREADY_DONE" = 1 ]; then
        echo "  3. ticket is already in 'completed/' — nothing to move"
    else
        echo "  3. edit outcome/updated, git mv $ISSUES_DIR/$TICKET_STAGE/$TICKET_ID.md -> $ISSUES_DIR/completed/, commit"
    fi
else
    if [ "$NO_COMPLETE" = 1 ]; then
        [ "$NOTE_GIVEN" = 1 ] && echo "  3. (--no-complete) POST the note as a comment on $TICKET_ID — issue stays '$JIRA_STATUS_NOW'" \
            || echo "  3. (--no-complete) issue $TICKET_ID left in status '$JIRA_STATUS_NOW' — NOT completed"
    elif [ "$ALREADY_DONE" = 1 ]; then
        echo "  3. (after the push) issue $TICKET_ID is already '$JIRA_STATUS_NOW' — no transition needed; POST the outcome as a comment"
    else
        echo "  3. (after the push) POST the transition into status id $JIRA_DONE_STATUS on $TICKET_ID (resolved from its live transitions once Awaiting Deployment, before the merge), read back to confirm, POST outcome as a comment"
    fi
fi
if [ "$ALREADY_MERGED" = 1 ]; then
    echo "  4. (--already-merged) nothing pushed"
else
    echo "  4. git push origin HEAD:$TARGET_BRANCH (from the integration worktree; '$MAIN_WORKTREE' is not fast-forwarded automatically)"
fi
PLAN_BRANCH_DEL=-d
[ "$ALREADY_MERGED" != 1 ] || PLAN_BRANCH_DEL=-D
WT_PLAN=" git worktree remove $BRANCH_WT, then"
[ -n "$BRANCH_WT" ] && [ "$BRANCH_WT" != "$MAIN_WORKTREE" ] || WT_PLAN=""
if [ "${HERDR_ENV:-}" = "1" ]; then
    if [ "$CLOSING" = 1 ]; then
        echo "  5. (HERDR_ENV=1) write the worker's closing state durably ('$HANDOFF_FILE', executor '${EXECUTOR:-unknown}'), read it back, notify the orchestrator best-effort (pane '${ORCH_PANE:-none}')"
    else
        echo "  5. (HERDR_ENV=1) no hand-off file found for '$BRANCH' — no closing state is written and nobody is notified"
    fi
    echo "  6. remove the herdr worktree workspace for branch '$BRANCH' (HERDR_ENV=1), then$WT_PLAN git branch $PLAN_BRANCH_DEL '$BRANCH'"
else
    echo "  5.$WT_PLAN git branch $PLAN_BRANCH_DEL '$BRANCH' (HERDR_ENV not set — no herdr workspace is touched)"
fi

if [ "$DRY_RUN" = 1 ]; then
    echo
    echo "--dry-run: stopping before any git-mutating command (including the integration worktree). Nothing was changed."
    exit 0
fi

# Everything from here through the push runs inside $LAND_WORKTREE, never in
# $INVOKING_REPO — see the header's INTEGRATION WORKTREE section.

if [ "$ALREADY_MERGED" = 1 ]; then
    # No merge, no push, so no integration worktree and no lock: the rest of
    # this run only reads the worker's worktree and talks to the tracker.
    echo
    echo "--already-merged: skipping the integration worktree, the merge, the lint and the push."
    REPO="$MAIN_WORKTREE"
    cd "$REPO"
else

echo
echo "Acquiring the integration worktree lock..."
acquire_land_lock "$LAND_WORKTREE.lock"

# Recomputed under the lock: the preflight read happened before this run held
# it, so another run could have created or removed the worktree in between.
if ! WT_PORCELAIN=$(git worktree list --porcelain 2>&1); then
    stop2 "could not re-evaluate 'git worktree list' after acquiring the lock: $WT_PORCELAIN"
fi
LAND_EXISTS=0
printf '%s\n' "$WT_PORCELAIN" | grep -qxF "worktree $LAND_WORKTREE" && LAND_EXISTS=1

if [ "$LAND_EXISTS" != 1 ]; then
    if [ -e "$LAND_WORKTREE" ]; then
        stop2 "'$LAND_WORKTREE' exists on disk but is not a registered worktree of this repo — remove it or move it aside, then re-run"
    fi
    echo "Creating integration worktree '$LAND_WORKTREE' (detached, on '$TARGET_BRANCH')..."
    ADD_OUT=$(git -C "$MAIN_WORKTREE" worktree add --detach "$LAND_WORKTREE" "$TARGET_BRANCH" 2>&1) \
        || stop2 "could not create integration worktree '$LAND_WORKTREE': $ADD_OUT"
elif [ ! -e "$LAND_WORKTREE/.git" ]; then
    # Registered but missing on disk (removed by hand outside this script) —
    # prune the stale administrative entry and recreate.
    echo "Integration worktree '$LAND_WORKTREE' is registered but missing on disk — pruning and recreating..."
    git -C "$MAIN_WORKTREE" worktree prune >/dev/null 2>&1 || true
    ADD_OUT=$(git -C "$MAIN_WORKTREE" worktree add --detach "$LAND_WORKTREE" "$TARGET_BRANCH" 2>&1) \
        || stop2 "could not recreate integration worktree '$LAND_WORKTREE': $ADD_OUT"
fi

# Refuse a dirty integration worktree BEFORE the reset below, which would
# otherwise discard any uncommitted change silently. --reset-land opts in.
LAND_STATUS_PRE=$(git -C "$LAND_WORKTREE" status --porcelain 2>&1) \
    || stop2 "could not check integration worktree '$LAND_WORKTREE' status: $LAND_STATUS_PRE"
if [ -n "$LAND_STATUS_PRE" ]; then
    if [ "$RESET_LAND" = 1 ]; then
        echo "--reset-land: discarding uncommitted changes in '$LAND_WORKTREE':"
        printf '%s\n' "$LAND_STATUS_PRE"
        git -C "$LAND_WORKTREE" reset --hard >/dev/null 2>&1 || stop2 "--reset-land: 'git reset --hard' failed in '$LAND_WORKTREE'"
        git -C "$LAND_WORKTREE" clean -fd >/dev/null 2>&1 || stop2 "--reset-land: 'git clean -fd' failed in '$LAND_WORKTREE'"
    else
        stop2 "integration worktree '$LAND_WORKTREE' has uncommitted changes:
$LAND_STATUS_PRE
Pass --reset-land to discard them, or clean '$LAND_WORKTREE' by hand. The invoking tree is untouched either way."
    fi
fi

echo "Fetching origin into '$LAND_WORKTREE'..."
FETCH_OUT=$(git -C "$LAND_WORKTREE" fetch origin 2>&1) || stop2 "git fetch origin failed in '$LAND_WORKTREE': $FETCH_OUT"
echo "Resetting '$LAND_WORKTREE' to origin/$TARGET_BRANCH..."
git -C "$LAND_WORKTREE" reset --hard "origin/$TARGET_BRANCH" >/dev/null 2>&1 \
    || stop2 "could not reset '$LAND_WORKTREE' to origin/$TARGET_BRANCH — does that ref exist on origin?"
git -C "$LAND_WORKTREE" clean -fd >/dev/null 2>&1 \
    || stop2 "could not clean untracked files from '$LAND_WORKTREE' after reset"

REPO="$LAND_WORKTREE"
cd "$REPO"

fi

# Before the merge — see the header's LIFECYCLE section. Nothing is merged
# yet, so no stop here needs a reset.

if [ "$TRACKER" = jira ]; then
    if [ -n "$JIRA_AWAIT_TID" ]; then
        echo
        echo "Transitioning $TICKET_ID ('$JIRA_STATUS_NOW' -> '$JIRA_AWAIT_TO') before the merge..."
        if ! jira_move "$JIRA_AWAIT_TID" "$JIRA_AWAITING_STATUS"; then
            release_land_lock
            die "$MOVE_MSG — nothing merged, nothing pushed"
        fi
        JIRA_STATUS_NOW="$MOVE_AFTER_NAME"
        LIFECYCLE_NOTE="Note: $TICKET_ID was moved to '$MOVE_AFTER_NAME' before this stop and stays there; re-running land-branch.sh skips that move."
        echo "transitioned; read-back confirms '$MOVE_AFTER_NAME'."
    fi
    if [ "$NO_COMPLETE" != 1 ] && [ "$ALREADY_DONE" != 1 ]; then
        jira_resolve_to "$JIRA_DONE_STATUS" || stop2 "$RESOLVE_MSG — nothing merged, nothing pushed"
        JIRA_DONE_TID="$RESOLVED_TID"
        JIRA_DONE_TO="$RESOLVED_TO"
    fi
else
    AWAIT_SRC="$ISSUES_DIR/in-progress/$TICKET_ID.md"
    AWAIT_DEST="$ISSUES_DIR/awaiting-deployment/$TICKET_ID.md"
    # file_await_fail MSG — undo a half-made move commit, then stop.
    file_await_fail() {
        git reset --hard "origin/$TARGET_BRANCH" >/dev/null 2>&1 \
            || warn "could not reset '$LAND_WORKTREE' to origin/$TARGET_BRANCH — the next run's sync will"
        stop2 "$* — nothing merged, nothing pushed"
    }
    if [ -f "$AWAIT_SRC" ] \
        && ! git cat-file -e "$BRANCH:$AWAIT_DEST" 2>/dev/null \
        && ! git cat-file -e "$BRANCH:$ISSUES_DIR/completed/$TICKET_ID.md" 2>/dev/null; then
        echo
        echo "Moving $AWAIT_SRC -> $AWAIT_DEST before the merge..."
        mkdir -p "$ISSUES_DIR/awaiting-deployment" || file_await_fail "could not create $ISSUES_DIR/awaiting-deployment"
        AWAIT_TMP=$(tmpfile) || file_await_fail "could not create a temp file"
        awk -v today="$(date +%F)" '
            $0 == "---" { fm++ }
            fm == 1 && !done && /^updated:/ { print "updated: " today; done = 1; next }
            { print }
        ' "$AWAIT_SRC" > "$AWAIT_TMP" || file_await_fail "could not bump 'updated:' in $AWAIT_SRC"
        [ -s "$AWAIT_TMP" ] || file_await_fail "bumping 'updated:' in $AWAIT_SRC produced an empty file"
        cat "$AWAIT_TMP" > "$AWAIT_SRC" || file_await_fail "could not rewrite $AWAIT_SRC"
        git mv "$AWAIT_SRC" "$AWAIT_DEST" || file_await_fail "git mv $AWAIT_SRC -> $AWAIT_DEST failed"
        git add -- "$AWAIT_DEST" || file_await_fail "could not stage $AWAIT_DEST"
        git commit -q -m "$TICKET_ID: awaiting deployment

Moved in-progress -> awaiting-deployment by land-branch.sh before merging '$BRANCH'.$TRAILER_BLOCK" || file_await_fail "could not commit the awaiting-deployment move"
        git cat-file -e "HEAD:$AWAIT_DEST" 2>/dev/null \
            || file_await_fail "HEAD does not contain $AWAIT_DEST after the move commit"
        if git cat-file -e "HEAD:$AWAIT_SRC" 2>/dev/null; then
            file_await_fail "HEAD still contains $AWAIT_SRC after the move commit"
        fi
        AWAIT_LEFTOVER=$(git status --porcelain -- "$ISSUES_DIR" 2>/dev/null) || AWAIT_LEFTOVER=""
        [ -z "$AWAIT_LEFTOVER" ] || file_await_fail "working tree under $ISSUES_DIR is not clean after the move commit:
$AWAIT_LEFTOVER"
        echo "moved; committed."
    fi
fi


if [ "$ALREADY_MERGED" != 1 ]; then

echo
echo "Merging '$BRANCH' into '$TARGET_BRANCH'..."
MERGE_OUTPUT=""
if ! MERGE_OUTPUT=$(git merge --no-ff "$BRANCH" -m "$MERGE_MSG" 2>&1); then
    if ! CONFLICTS=$(git diff --name-only --diff-filter=U 2>&1); then
        CONFLICTS="(could not list conflicting files: $CONFLICTS)"
    fi
    git merge --abort >/dev/null 2>&1 || true
    if [ -n "$CONFLICTS" ]; then
        stop2 "merge conflict, aborted, nothing changed. Conflicting file(s):
$CONFLICTS"
    else
        stop2 "git merge failed, aborted, nothing changed — not a content conflict (no conflicting files were left). git said:
$MERGE_OUTPUT"
    fi
fi

if ! STILL_UNMERGED=$(git diff --name-only --diff-filter=U 2>&1); then
    stop2_reset "could not verify the merge left no unmerged paths: $STILL_UNMERGED"
fi
[ -z "$STILL_UNMERGED" ] || stop2_reset "merge reported success but left unmerged paths — reverted:
$STILL_UNMERGED"
echo "merged clean."

fi

if [ "$CLOSING" = 1 ]; then
    if [ "$ALREADY_MERGED" = 1 ]; then
        MERGE_SHA="$LANDED_SHA"
        LANDED_HOW="already on $TARGET_BRANCH at"
    else
        MERGE_SHA=$(git rev-parse HEAD)
        LANDED_HOW="merge commit"
    fi
    CLOSING_MARK="closing-state:$TICKET_ID:${MERGE_SHA}"
    closing_field() { local v; v=$(handoff_section "$1"); printf '%s' "${v:-none reported by the worker}"; }
    CLOSING_TEXT="Closing state ($CLOSING_MARK)
Landed: yes, $LANDED_HOW $MERGE_SHA onto $TARGET_BRANCH
Branch condition: $BRANCH_CONDITION
Executor: ${EXECUTOR:-unknown}
Human run list:
$(closing_field "Human run list")
Left undone:
$(closing_field "Left undone")
Findings noticed, not acted on:
$(closing_field "Findings")"
    if [ "$TRACKER" = file ]; then
        if [ "$NO_COMPLETE" = 1 ]; then
            NOTE_TEXT="${NOTE_TEXT:+$NOTE_TEXT

}$CLOSING_TEXT"
            NOTE_GIVEN=1
        else
            OUTCOME_TEXT="$OUTCOME_TEXT

$CLOSING_TEXT"
        fi
    fi
fi

# A worker may move its own ticket file as part of its branch, so the
# pre-merge $TICKET_FILE can point at a path this merge just deleted.
# Re-resolve against the post-merge tree before touching the ticket at all.
if [ "$TRACKER" = file ]; then
    TICKET_FILE=""
    TICKET_STAGE=""
    for stage in in-progress awaiting-deployment open completed cancelled; do
        cand="$ISSUES_DIR/$stage/$TICKET_ID.md"
        if [ -f "$cand" ]; then
            TICKET_FILE="$cand"
            TICKET_STAGE="$stage"
            break
        fi
    done
    [ -n "$TICKET_FILE" ] || die_reset "ticket '$TICKET_ID' not found under '$ISSUES_DIR/{open,in-progress,awaiting-deployment,completed,cancelled}/' after the merge — merge reverted, nothing pushed"
    if [ "$NO_COMPLETE" != 1 ]; then
        if [ "$TICKET_STAGE" = completed ]; then
            ALREADY_DONE=1
        else
            ALREADY_DONE=0
            FM_TOP=$(awk '/^---$/{c++; if (c==2) exit} {print}' "$TICKET_FILE")
            printf '%s\n' "$FM_TOP" | grep -q '^outcome:' \
                || die_reset "$TICKET_FILE has no 'outcome:' field in its frontmatter to rewrite — merge reverted, nothing pushed"
            printf '%s\n' "$FM_TOP" | grep -q '^updated:' \
                || die_reset "$TICKET_FILE has no 'updated:' field in its frontmatter to rewrite — merge reverted, nothing pushed"
        fi
    fi
fi


EFFECTIVE_LINT="$LINT_CMD"
[ "$ALREADY_MERGED" != 1 ] || EFFECTIVE_LINT=""
[ -n "$EFFECTIVE_LINT" ] || [ "$ALREADY_MERGED" = 1 ] \
    || { [ -x ./scripts/lint.sh ] && EFFECTIVE_LINT=./scripts/lint.sh; }
if [ "$ALREADY_MERGED" = 1 ]; then
    echo "--already-merged: not linting — this tree was not merged here, and whatever landed already passed the PR's checks."
elif [ -n "$EFFECTIVE_LINT" ]; then
    echo "Running $EFFECTIVE_LINT on the merged tree..."
    if ! $EFFECTIVE_LINT; then
        echo "lint failed on the merged tree — reverting the merge." >&2
        die_reset "lint failed; merge reverted, nothing pushed"
    fi
    echo "lint: clean."
else
    warn "no lint command configured (--lint-cmd / \$LAND_BRANCH_LINT_CMD) and no executable ./scripts/lint.sh found — skipping"
fi


if [ "$TRACKER" = file ]; then
    if [ "$NO_COMPLETE" = 1 ]; then
        if [ "$NOTE_GIVEN" = 1 ]; then
            NOTES_FILE="$ISSUES_DIR/$TICKET_STAGE/$TICKET_ID.notes.md"
            echo "## $(date +%F)
$NOTE_TEXT
" >> "$NOTES_FILE" || die_reset "could not append to $NOTES_FILE — merge reverted, nothing pushed"
            git add -- "$NOTES_FILE" || die_reset "could not stage $NOTES_FILE — merge reverted, nothing pushed"
            git commit -m "$TICKET_ID: progress note (land-branch.sh --no-complete)$TRAILER_BLOCK" -- "$NOTES_FILE" \
                || die_reset "could not commit $NOTES_FILE — merge reverted, nothing pushed"
        fi
        if [ "$CLOSING" = 1 ] && ! git show "HEAD:$NOTES_FILE" 2>/dev/null | grep -Fc "$CLOSING_MARK" >/dev/null; then
            die_reset "closing state read-back failed: HEAD:$NOTES_FILE does not carry '$CLOSING_MARK' — merge reverted, nothing pushed"
        fi
        echo "--no-complete: ticket left in '$ISSUES_DIR/$TICKET_STAGE/'."
    elif [ "$ALREADY_DONE" = 1 ]; then
        echo "ticket is already in 'completed/' — nothing to move."
    else
        DEST="$ISSUES_DIR/completed/$TICKET_ID.md"
        mkdir -p "$ISSUES_DIR/completed" || die_reset "could not create $ISSUES_DIR/completed — merge reverted, nothing pushed"

        # Edit BEFORE the move. `outcome:` is rewritten as a YAML block scalar
        # (`outcome: |`) so a multi-line outcome survives intact; a single-line
        # sed substitution truncates it at the first newline.
        UPDATED_TODAY=$(date +%F)
        OUTCOME_INDENTED=$(tmpfile) || die_reset "could not create temp file — merge reverted, nothing pushed"
        while IFS= read -r l || [ -n "$l" ]; do
            if [ -n "$l" ]; then printf '  %s\n' "$l"; else printf '\n'; fi
        done <<EOF >"$OUTCOME_INDENTED"
$OUTCOME_TEXT
EOF

        NEW_TICKET=$(tmpfile) || die_reset "could not create temp file — merge reverted, nothing pushed"
        awk -v outfile="$OUTCOME_INDENTED" -v today="$UPDATED_TODAY" '
            BEGIN { fm = 0; outcome_done = 0; updated_done = 0; skipping = 0 }
            {
                if (skipping == 1) {
                    # A block-scalar body line is either indented or BLANK — a
                    # blank line inside the block does not end it, so checking
                    # only /^  / leaks stale lines into the rewritten ticket.
                    if ($0 ~ /^  /) { next }
                    if ($0 == "") { next }
                    skipping = 0
                }
                if ($0 == "---") { fm++; print; next }
                if (fm == 1 && !outcome_done && $0 ~ /^outcome:/) {
                    print "outcome: |"
                    while ((getline line < outfile) > 0) print line
                    close(outfile)
                    outcome_done = 1
                    skipping = 1
                    next
                }
                if (fm == 1 && !updated_done && $0 ~ /^updated:/) {
                    print "updated: " today
                    updated_done = 1
                    next
                }
                print
            }
            END {
                # A ticket with no updated: field still completes; outcome is
                # the only field the frontmatter contract requires.
                exit(outcome_done ? 0 : 1)
            }
        ' "$TICKET_FILE" > "$NEW_TICKET" \
            || die_reset "could not find 'outcome:' inside $TICKET_FILE's frontmatter — merge reverted, nothing pushed"
        [ -s "$NEW_TICKET" ] || die_reset "rewriting $TICKET_FILE produced an empty file — merge reverted, nothing pushed"

        # mv, not a truncating write, and restore the original file's mode.
        ORIG_MODE=$(stat -f '%Lp' "$TICKET_FILE" 2>/dev/null) || ORIG_MODE=$(stat -c '%a' "$TICKET_FILE" 2>/dev/null) || ORIG_MODE=""
        mv "$NEW_TICKET" "$TICKET_FILE" || die_reset "could not overwrite $TICKET_FILE — merge reverted, nothing pushed"
        [ -n "$ORIG_MODE" ] && { chmod "$ORIG_MODE" "$TICKET_FILE" 2>/dev/null || true; }

        git mv "$TICKET_FILE" "$DEST" || die_reset "git mv $TICKET_FILE -> $DEST failed — merge reverted, nothing pushed"
        # git add the moved path explicitly even though git mv already staged
        # it, then ASSERT it rather than trusting the convention.
        git add -- "$DEST" || die_reset "could not stage $DEST — merge reverted, nothing pushed"
        # Every line under $ISSUES_DIR must be fully staged (porcelain's 2nd
        # column blank); a staged rename is 'R ' and must not trip this.
        LEFTOVER=$(git status --porcelain -- "$ISSUES_DIR" 2>/dev/null | awk 'substr($0,2,1) != " "') || LEFTOVER=""
        [ -z "$LEFTOVER" ] || die_reset "unstaged changes remain under $ISSUES_DIR after staging the move — merge reverted, nothing pushed:
$LEFTOVER"
        # The staged blob must carry the outcome just written, not stale
        # pre-edit content. grep -c reads all input: grep -q exits on the first
        # match and SIGPIPEs git show on a ticket larger than the pipe buffer.
        git show ":$DEST" 2>/dev/null | grep -c '^outcome: |$' >/dev/null \
            || die_reset "assertion failed: staged '$DEST' does not carry the outcome block — merge reverted, nothing pushed"

        # No pathspec: `git mv` stages a rename as two index entries, and a
        # pathspec-limited commit takes only the add side, leaving a staged
        # 'D <old-path>' the next run's dirty-tree preflight refuses on.
        git commit -m "$TICKET_ID: complete

$OUTCOME_TEXT$TRAILER_BLOCK" \
            || die_reset "could not commit the ticket completion — merge reverted, nothing pushed"

        # Reads HEAD, not the index: the pre-commit checks inspect staged state
        # only, which cannot see a commit that dropped half of the rename.
        git cat-file -e "HEAD:$DEST" 2>/dev/null \
            || die_reset "HEAD does not contain $DEST after the completion commit — merge reverted, nothing pushed"
        if git cat-file -e "HEAD:$TICKET_FILE" 2>/dev/null; then
            die_reset "HEAD still contains $TICKET_FILE after the completion commit — the move did not fully land, merge reverted, nothing pushed"
        fi
        git show "HEAD:$DEST" 2>/dev/null | grep -c '^outcome: |$' >/dev/null \
            || die_reset "assertion failed: HEAD:$DEST does not carry the outcome block — merge reverted, nothing pushed"
        LEFTOVER_AFTER=$(git status --porcelain -- "$ISSUES_DIR" 2>/dev/null) || LEFTOVER_AFTER=""
        [ -z "$LEFTOVER_AFTER" ] \
            || die_reset "working tree under $ISSUES_DIR is not clean after the completion commit — merge reverted, nothing pushed:
$LEFTOVER_AFTER"

        if [ "$CLOSING" = 1 ] && ! git show "HEAD:$DEST" 2>/dev/null | grep -Fc "$CLOSING_MARK" >/dev/null; then
            die_reset "closing state read-back failed: HEAD:$DEST does not carry '$CLOSING_MARK' — merge reverted, nothing pushed"
        fi

        echo "$TICKET_ID moved to '$ISSUES_DIR/completed/'."
    fi
else
    if [ "$NO_COMPLETE" = 1 ]; then
        if [ -n "$NOTE_TEXT" ]; then
            echo "Posting note as a comment on $TICKET_ID..."
            jira_post_comment "$TICKET_ID" "Progress note ($(date +%F), branch '$BRANCH' landed via land-branch.sh --no-complete):
$NOTE_TEXT" \
                || die_reset "POST comment failed — merge reverted, nothing pushed, no note posted"
            echo "comment posted."
        fi
        echo "--no-complete: issue $TICKET_ID left in status '$JIRA_STATUS_NOW'."
    fi
fi


REMOTES=$(git remote 2>/dev/null) || REMOTES=""
if [ "$ALREADY_MERGED" = 1 ]; then
    echo "--already-merged: nothing to push — $TARGET_BRANCH already carries this work at $(git rev-parse --short "$LANDED_SHA")."
elif [ -n "$REMOTES" ]; then
    echo "Pushing (integration worktree HEAD is detached — explicit refspec)..."
    # The integration worktree is always detached (see header), so a bare
    # `git push` has no branch to infer and fails outright.
    if ! git push origin "HEAD:$TARGET_BRANCH"; then
        release_land_lock
        if [ "$TRACKER" = jira ]; then
            die "git push failed — the landing is complete LOCALLY (in '$REPO'); resolve, then run 'git -C \"$REPO\" push origin HEAD:$TARGET_BRANCH' by hand — do not reset, that would discard a completed landing. $TICKET_ID is '$JIRA_STATUS_NOW' and was NOT completed: complete it by hand after the push and say so in the ticket"
        fi
        die "git push failed — the landing is complete LOCALLY (in '$REPO'; the ticket move commits are part of it); resolve, then run 'git -C \"$REPO\" push origin HEAD:$TARGET_BRANCH' by hand — do not reset, that would discard a completed landing"
    fi
    echo "pushed."
    echo
    echo "Note: '$MAIN_WORKTREE' was NOT fast-forwarded automatically (a sibling may hold uncommitted edits there). To update it:"
    echo "  git -C '$MAIN_WORKTREE' pull --ff-only"
else
    echo "no remote configured — skipping push."
fi

# After the push — the push is the deploy. The landing stands whatever
# happens here; a failure is reported and exits 1 at the end, never reset.

if [ "$TRACKER" = jira ] && [ "$NO_COMPLETE" != 1 ]; then
    AFTER_NAME="$JIRA_STATUS_NOW"
    if [ "$ALREADY_DONE" = 1 ]; then
        echo "issue $TICKET_ID is already '$JIRA_STATUS_NOW' — nothing to transition."
    else
        echo "Transitioning $TICKET_ID ('$JIRA_STATUS_NOW' -> '$JIRA_DONE_TO') after the push..."
        if jira_move "$JIRA_DONE_TID" "$JIRA_DONE_STATUS"; then
            AFTER_NAME="$MOVE_AFTER_NAME"
            echo "transitioned; read-back confirms '$AFTER_NAME'."
        else
            COMPLETE_FAILED="$MOVE_MSG"
        fi
    fi
    if [ -z "$COMPLETE_FAILED" ]; then
        echo "Posting outcome as a comment on $TICKET_ID..."
        if jira_post_comment "$TICKET_ID" "$OUTCOME_TEXT"; then
            echo "comment posted."
        else
            warn "comment POST failed after a successful transition — the landing stands (issue is '$AFTER_NAME'); add the outcome by hand"
        fi
    fi
fi

if [ "$CLOSING" = 1 ] && [ "$TRACKER" = jira ]; then
    echo "Writing $TICKET_ID's closing state to the tracker..."
    if ! jira_post_comment "$TICKET_ID" "$CLOSING_TEXT"; then
        CLOSING_FAILED="POST of the closing-state comment failed"
    elif ! jira_closing_readback "$CLOSING_MARK"; then
        CLOSING_FAILED="the closing-state comment was POSTed but '$CLOSING_MARK' did not read back from $TICKET_ID's comments after retrying — $CLOSING_READBACK_MSG"
    else
        echo "closing state written and read back."
    fi
fi
if [ "$CLOSING" = 1 ] && [ "$TRACKER" = file ]; then
    if [ "$ALREADY_DONE" = 1 ]; then
        CLOSING_FAILED="the ticket was already completed before this landing, so the file tracker had no outcome or note to carry the closing state"
    else
        echo "closing state written to the ticket and read back ($CLOSING_MARK)."
    fi
fi

if [ "$CLOSING" = 1 ] && [ -z "$CLOSING_FAILED" ]; then
    ACK_FILE="${LAND_BRANCH_ACK_FILE:-${TMPDIR:-/tmp}/nw-ack-$TICKET_ID-${MERGE_SHA:0:8}}"
    rm -f "$ACK_FILE" 2>/dev/null || true
    if [ -z "$ORCH_PANE" ]; then
        echo "no orchestrator pane recorded — closing state is in the tracker; nobody was notified."
    elif ! command -v herdr >/dev/null 2>&1; then
        warn "no 'herdr' on PATH — orchestrator pane $ORCH_PANE was not notified; closing state is in the tracker"
    else
        herdr_notify "$ORCH_PANE" "$TICKET_ID landed; closing state is in the tracker ($CLOSING_MARK). Acknowledge with: $(cd "$(dirname "$0")" && pwd)/land-ack.sh '$ACK_FILE'" || true
        ACK_BOUND_S="${LAND_BRANCH_ACK_WAIT_S:-10}"
        ACK_WAITED_S=0
        while [ "$ACK_WAITED_S" -lt "$ACK_BOUND_S" ] && [ ! -e "$ACK_FILE" ]; do
            sleep 1
            ACK_WAITED_S=$((ACK_WAITED_S + 1))
        done
        if [ -e "$ACK_FILE" ]; then
            echo "orchestrator acknowledged the closing state."
        else
            warn "orchestrator pane $ORCH_PANE did not acknowledge within ${ACK_BOUND_S}s — the closing state IS in the tracker, continuing with the exit"
        fi
    fi
fi

if [ "$CLOSING" = 1 ] && [ -n "$CLOSING_FAILED" ]; then
    warn "closing state was NOT written durably ($CLOSING_FAILED) — leaving the worker's session and workspace in place so its output survives"
elif [ "${HERDR_ENV:-}" = "1" ]; then
    if ! command -v herdr >/dev/null 2>&1; then
        echo "HERDR_ENV=1 but 'herdr' is not on PATH — skipping worktree removal."
    elif ! command -v jq >/dev/null 2>&1; then
        echo "HERDR_ENV=1 but 'jq' is not on PATH — skipping worktree removal."
    else
        # End the session BEFORE the pane is torn down: `herdr worktree remove`
        # kills it outright, leaving a permanent "offline" entry (NWM-117).
        # `/exit` is literal text, so the slash-command picker needs two Enters;
        # exceeding the poll bound removes the workspace anyway.
        if herdr agent get "$BRANCH" >/dev/null 2>&1; then
            AGENT_PANE=$(herdr agent get "$BRANCH" 2>/dev/null | jq -r '.result.agent.pane_id // empty' 2>/dev/null) || AGENT_PANE=""
            if [ -z "$AGENT_PANE" ]; then
                warn "found a live Herdr agent named '$BRANCH' but could not read its pane_id — skipping clean exit, removing its workspace anyway"
            else
                echo "Exiting the worker's Claude session on '$BRANCH' (pane $AGENT_PANE) before removing its workspace..."
                herdr pane send-text "$AGENT_PANE" "/exit" >/dev/null 2>&1 || true
                sleep 1
                herdr agent send-keys "$BRANCH" enter >/dev/null 2>&1 || true
                sleep 1
                herdr agent send-keys "$BRANCH" enter >/dev/null 2>&1 || true
                EXIT_BOUND_S="${LAND_BRANCH_EXIT_WAIT_S:-15}"
                EXIT_WAITED_S=0
                while [ "$EXIT_WAITED_S" -lt "$EXIT_BOUND_S" ] && herdr agent get "$BRANCH" >/dev/null 2>&1; do
                    sleep 1
                    EXIT_WAITED_S=$((EXIT_WAITED_S + 1))
                done
                if herdr agent get "$BRANCH" >/dev/null 2>&1; then
                    warn "worker on '$BRANCH' did not exit its Claude session within ${EXIT_BOUND_S}s — removing its workspace anyway (Remote Control will show it as offline until pruned by hand)"
                else
                    echo "worker session on '$BRANCH' exited cleanly."
                fi
            fi
        else
            echo "no live Herdr agent named '$BRANCH' — nothing to exit."
        fi

        # --cwd names the repo herdr resolves against: $MAIN_WORKTREE is what
        # herdr knows this repo as, not the integration worktree.
        LISTING=$(herdr worktree list --cwd "$MAIN_WORKTREE" --json 2>/dev/null) || LISTING=""
        MATCH_COUNT=""
        if [ -n "$LISTING" ]; then
            MATCH_COUNT=$(printf '%s' "$LISTING" | jq -r --arg b "$BRANCH" '
                [ (.result.worktrees // [])[] | select(.is_linked_worktree == true and .branch == $b) ] | length
            ' 2>/dev/null) || MATCH_COUNT=""
        fi
        WS_ID=""
        if [ "$MATCH_COUNT" = "1" ]; then
            WS_ID=$(printf '%s' "$LISTING" | jq -r --arg b "$BRANCH" '
                [ (.result.worktrees // [])[] | select(.is_linked_worktree == true and .branch == $b) ][0].open_workspace_id // empty
            ' 2>/dev/null) || WS_ID=""
        fi
        if [ -n "$WS_ID" ]; then
            echo "Removing herdr worktree workspace '$WS_ID' (matched by branch '$BRANCH')..."
            herdr worktree remove --workspace "$WS_ID" || warn "herdr worktree remove failed — remove it by hand"
        elif [ "$MATCH_COUNT" = "1" ]; then
            echo "branch '$BRANCH' has a herdr worktree with no workspace open on it — git removes it below."
        elif [ -n "$MATCH_COUNT" ] && [ "$MATCH_COUNT" -gt 1 ] 2>/dev/null; then
            echo "more than one herdr worktree matches branch '$BRANCH' — skipping removal (not guessing)."
        else
            echo "no herdr worktree matches branch '$BRANCH' — skipping removal."
        fi
    fi
else
    echo "HERDR_ENV not set — skipping herdr worktree removal."
fi

# NWM-149: `herdr worktree remove` needs a workspace id and a landed worktree
# rarely still has one, so git is the only path that removes it — or the branch.
if [ -n "$BRANCH_WT" ] && [ "$BRANCH_WT" != "$MAIN_WORKTREE" ] && [ -e "$BRANCH_WT" ]; then
    case "$(pwd -P)/" in
        "$BRANCH_WT"/*) warn "worktree '$BRANCH_WT' holds branch '$BRANCH' but this script is running inside it — left in place" ;;
        *)
            if WT_RM=$(git -C "$MAIN_WORKTREE" worktree remove "$BRANCH_WT" 2>&1); then
                echo "removed worktree '$BRANCH_WT'."
            else
                warn "could not remove worktree '$BRANCH_WT' — left in place: $WT_RM"
            fi
            ;;
    esac
fi

# -D under --already-merged: git will not see a squash-merged branch as
# merged, and the content check above already proved it landed, which is
# exactly the evidence -d wants and cannot compute for itself.
BRANCH_DEL=-d
[ "$ALREADY_MERGED" != 1 ] || BRANCH_DEL=-D
if git branch "$BRANCH_DEL" "$BRANCH" >/dev/null 2>&1; then
    echo "deleted local branch '$BRANCH'."
else
    warn "could not delete local branch '$BRANCH' — left in place"
fi

echo
if [ -n "$CLOSING_FAILED" ]; then
    release_land_lock
    die "branch '$BRANCH' landed on '$TARGET_BRANCH' and was pushed — the landing stands and was NOT reverted — but the worker's closing state was NOT written durably: $CLOSING_FAILED. The worker's pane and workspace were left in place; recover its closing state by hand and post it on $TICKET_ID"
fi
if [ "$NO_COMPLETE" = 1 ]; then
    if [ "$TRACKER" = file ]; then
        echo "branch '$BRANCH' landed on '$TARGET_BRANCH'. $TICKET_ID was DELIBERATELY NOT COMPLETED (--no-complete) — it remains in '$ISSUES_DIR/$TICKET_STAGE/'."
    else
        echo "branch '$BRANCH' landed on '$TARGET_BRANCH'. $TICKET_ID was DELIBERATELY NOT COMPLETED (--no-complete) — it remains '$JIRA_STATUS_NOW'."
    fi
elif [ "$ALREADY_DONE" = 1 ]; then
    echo "$TICKET_ID landed on '$TARGET_BRANCH'; it was already complete before this landing."
elif [ -n "$COMPLETE_FAILED" ]; then
    release_land_lock
    die "branch '$BRANCH' landed on '$TARGET_BRANCH' and was pushed — the landing stands and was NOT reverted — but $TICKET_ID was NOT completed: $COMPLETE_FAILED. It stays '$JIRA_STATUS_NOW'; complete it by hand and say so in the ticket"
else
    echo "$TICKET_ID landed on '$TARGET_BRANCH' and completed."
fi
release_land_lock
exit 0
