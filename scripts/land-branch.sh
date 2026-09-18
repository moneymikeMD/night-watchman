#!/bin/bash
#
# Land a finished ticket branch onto the target branch (default: main),
# complete its ticket, and clean up.
#
# This script exists because of two defects produced, once, by doing this
# sequence by hand: (1) a ticket's `outcome` field was edited AFTER the
# ticket file had already been moved to its completed location, so the move
# staged the OLD (empty-outcome) content — several tickets reached
# "completed" with an empty outcome; (2) a merge conflict sat inside a shell
# `if` block in a way that `set -e` did not catch, so a broken merge with
# literal conflict markers was pushed to a shared remote. This script is the
# fix: it edits a completing ticket BEFORE moving it (so the move stages
# current content), re-`git add`s the moved path explicitly and asserts
# nothing is left unstaged, and it stops hard, by construction, on the first
# failure rather than continuing down an unguarded branch.
#
# TRACKER. Two backends, selected by --tracker / LAND_BRANCH_TRACKER
# (default: file — this plugin ships with zero external accounts required):
#
#   file    the to-issues skill's directory convention: a ticket is a
#           markdown file that moves between <issues-dir>/{open,in-progress,
#           awaiting-deployment,completed,cancelled}/. Before the merge, a
#           ticket in in-progress/ is moved to awaiting-deployment/ (updated
#           bumped) as its own commit; after the merge and lint, completing
#           it edits its frontmatter (outcome, updated) BEFORE `git mv`ing it
#           to completed/, then commits that move as its own commit, ticket
#           id first in the subject. One commit per move; the edit-before-move
#           ordering is what the header above exists to enforce. All commits
#           reach origin in the one push.
#
#   jira    an external tracker reached through a caller-supplied API
#           wrapper (--jira-api PATH / ISSUES_JIRA_API, matching the
#           to-issues skill's own convention) shaped like: `<wrapper> raw GET
#           <path>`, `<wrapper> --yes write POST <path> <json>`, and
#           `<wrapper> --yes comment <key> -` (text on stdin). This plugin
#           ships a default at providers/tracker/jira/jira-api.sh; a project
#           may point --jira-api at that or bring its own. Every transition
#           is resolved BY TARGET STATUS, never by a configured transition
#           id: the issue's live transitions list is fetched and the one
#           transition whose `to.id` equals the target status id is used;
#           zero or more than one such transition is refused rather than
#           guessed. Three status ids are needed, none with a default (every
#           tracker's workflow ids differ): --jira-progress-status,
#           --jira-awaiting-status and --jira-done-status. Every transition
#           is READ BACK and asserted to be in the target status — a 2xx is
#           not evidence the state actually moved. The outcome is posted as
#           a comment only after the Completed read-back confirms.
#
# LIFECYCLE. A ticket is In Progress from dispatch, Awaiting Deployment
# before landing, Completed after landing; this script drives the last two
# moves. Jira mode: before the merge, an In Progress issue is moved to
# Awaiting Deployment (skipped if already there; any other status is
# refused, because the lifecycle was skipped upstream); after the push, it
# is moved to Completed and the outcome is posted. File mode mirrors this
# with directory moves (in-progress/ -> awaiting-deployment/ before the
# merge, -> completed/ after lint); a ticket in open/ or cancelled/ is
# refused. --no-complete runs only the first move. A stop after the
# Awaiting Deployment move leaves the jira issue there (the message says
# so) and a re-run skips that move; file mode's move commit is local to the
# integration worktree until the push, so a stop discards it.
#
# Every failure between the merge and the push goes through die_reset (or
# stop2_reset for a "could not evaluate" case) so a half-landed branch is
# never left on $TARGET_BRANCH. After the push the landing stands and is
# never reverted: a failed `git push` (fix the push by hand), a failed jira
# Completed transition (exit 1; the issue stays Awaiting Deployment,
# complete it by hand and say so in the ticket), and a failed outcome
# comment after a confirmed Completed (warned; add it by hand).
#
# Usage:
#   land-branch.sh <branch> <ticket-id> [--dry-run]
#                  [--tracker file|jira] [--issues-dir DIR]
#                  [--jira-api PATH] [--jira-progress-status ID]
#                  [--jira-awaiting-status ID] [--jira-done-status ID]
#                  [--lint-cmd CMD] [--reset-land]
#                  [--outcome "text" | --outcome-file PATH]
#   land-branch.sh <branch> <ticket-id> --no-complete [--dry-run] [--note "text"] [--tracker file|jira] ...
#   land-branch.sh --help
#
# INTEGRATION WORKTREE. The merge, lint, completion and push no longer run
# in the tree this script was invoked from — they run in a dedicated
# worktree this script owns and keeps across runs:
# `<parent-of-the-repo's-main-worktree>/<repo-basename>-land` (e.g.
# `~/code/foo` -> `~/code/foo-land`). Derived from `git worktree list
# --porcelain`'s FIRST entry (git always lists the main worktree first),
# never from `$PWD` — so this works identically whether invoked from the
# main checkout, a Herdr worktree, or an agent's own isolated worktree.
#
# First use: `git worktree add --detach <path> <target-branch>` off the main
# worktree (--detach because <target-branch> is very likely already checked
# out THERE). Later uses: the worktree is verified to be a real, registered
# worktree of this repo, then `git fetch origin` + `git reset --hard
# origin/<target-branch>` + `git clean -fd` — every run starts it from
# exactly what origin has, discarding any prior local commits or untracked
# debris it left behind. A dirty integration worktree (any uncommitted
# change) is refused loudly BEFORE that reset, UNLESS `--reset-land` is
# passed, which discards it on purpose and says so.
#
# A second land-branch.sh run against the same repo while one is already
# using the integration worktree is refused loudly too — an mkdir-based lock
# (`<worktree>.lock`, holder pid/start time inside it) serializes the
# fetch/reset/merge/lint/push window; a lock whose holder pid is no longer
# running is reclaimed automatically.
#
# The invoking tree (wherever the script was actually run from) is never
# mutated — no merge, no reset, no stash, no commit, nothing — and is read
# for git state only to check <branch>'s own worktree (sometimes the
# invoking tree itself) for uncommitted changes. Its own dirty/clean state
# and current branch are irrelevant: TARGET_BRANCH no longer needs to be
# checked out anywhere, and the old "must be run from <target-branch> with a
# clean tree" preflight is gone in full, because the merge no longer happens
# there.
#
# Because the merge lands in the integration worktree and is pushed from
# there, the main worktree is NOT fast-forwarded automatically after a
# successful push. The final summary instead prints the one-line
# `git -C <main-worktree> pull --ff-only` the caller may run by hand.
#
# `--reset-land` only ever touches the integration worktree.
#
# Exit codes:
#   0   landed cleanly
#   1   a step failed AFTER the merge succeeded (lint, or completing). The
#       merge is reverted (`git reset --hard ORIG_HEAD`) before this exit,
#       every time, so $TARGET_BRANCH is exactly as it was before the run —
#       except a failed `git push`, which is NOT reverted (the landing is
#       complete locally; the message says so).
#   2   could not evaluate / stopped early — bad input, a dirty tree, a
#       missing ticket, a git command that itself failed while checking a
#       precondition, or a merge conflict. Nothing was mutated before this
#       exit (the two checks right after the merge that could still trigger
#       it also revert first).
#
# Env overrides (all have a `--flag` equivalent; the flag wins):
#   TARGET_BRANCH               branch to land onto (default: main). No
#                                worktree needs this branch checked out
#                                anywhere — the integration worktree is reset
#                                to origin/$TARGET_BRANCH itself, every run.
#   LAND_BRANCH_TRACKER          file (default) | jira.
#   ISSUES_DIR                   file mode's tickets directory (default: issues).
#   ISSUES_JIRA_API               jira mode's API wrapper path.
#   LAND_BRANCH_JIRA_PROGRESS_STATUS  jira mode's In Progress status id.
#                                Required in jira mode; no default.
#   LAND_BRANCH_JIRA_AWAITING_STATUS  jira mode's Awaiting Deployment status
#                                id. Required in jira mode; no default.
#   LAND_BRANCH_JIRA_DONE_STATUS  jira mode's Completed status id. Required in
#                                jira mode unless --no-complete; no default
#                                (every tracker's workflow ids differ).
#   LAND_BRANCH_LINT_CMD          command to run on the merged tree before
#                                completing (default: ./scripts/lint.sh if
#                                present and executable, else skipped with a
#                                warning — a consuming project need not have
#                                one at that path).
#   --reset-land                 (flag, not an env var) discards uncommitted
#                                changes in the integration worktree
#                                (`git reset --hard` + `git clean -fd`)
#                                before syncing it — for the one case the
#                                dirty-worktree guard refuses on its own.
#                                Never touches the invoking tree.
#   LAND_BRANCH_COAUTHOR          optional. "Name <email>" appended as a
#                                Co-Authored-By trailer on any completion or
#                                note commit. Unset means no such trailer —
#                                commits default to the owner alone.
#   LAND_BRANCH_SESSION           optional, same as LAND_BRANCH_COAUTHOR:
#                                a Claude-Session trailer when set, no
#                                trailer when unset.
#
# Optional layer: if HERDR_ENV=1 and the `herdr` CLI is on PATH, a
# successful landing also removes the herdr worktree workspace matching this
# branch (matched by branch name, never by sidebar position) and is a no-op
# otherwise — see the plugin's optional-layers doc.

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
# Set once the jira issue has been moved to Awaiting Deployment, so every
# later stop says the issue stays there.
LIFECYCLE_NOTE=""

# stop2 — a precondition could not be met, BEFORE any mutating command has
# run. Same message shape as kit.sh's die(), different exit code. Releases
# the integration-worktree lock first (a no-op if never acquired) — stop2
# runs both before and after the lock is taken.
stop2() { release_land_lock; echo "Error: $*${LIFECYCLE_NOTE:+
$LIFECYCLE_NOTE}" >&2; exit 2; }

# stop2_reset / die_reset — same as stop2/die, but for a failure that
# happens AFTER the merge: reset first, every time, so an unresolved
# assertion or a hard failure never leaves the merge commit sitting on
# $TARGET_BRANCH.
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

# ------------------------------------------------------------ integration lock
#
# The integration worktree is shared by every land-branch.sh run against
# this repo, with no serialisation of its own — two concurrent landings
# would fetch/reset/merge/lint/push in the same directory at once. An
# mkdir-based lock at "<worktree>.lock" (mkdir is atomic even cross-process,
# and needs no external tool — macOS ships no flock(1)) serialises the whole
# integration-worktree window. this repo's kit.sh has no generic on-exit
# hook, so every controlled exit path (stop2/stop2_reset/die_reset above,
# the push-failure die()s, and the final success exit) calls
# release_land_lock explicitly. An uncontrolled crash/SIGINT is not covered
# by that — the stale-pid reclaim below is the safety net for it.

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

# acquire_land_lock <land-worktree-lock-file> — never waits: either wins the
# lock immediately or refuses loudly (stop2) naming the current holder's pid
# and start time. A holder with no live pid is reclaimed: the stale lock is
# removed and the attempt retried, capped so a permissions problem can't
# loop forever.
#
# The lock is a single file, won by `ln` (atomic: it fails with the target
# already existing unless this call created it). Content (pid + start time)
# is written to a private temp file FIRST, then `ln`ed into place — so by
# the time any other process can see the lock file exist, its content is
# already complete. A two-step "mkdir the lock, then separately write a
# holder file inside it" was tried first and rejected: a second process
# racing the gap between the winner's mkdir and its holder-file write would
# see an empty/missing holder, read that as "stale", and reclaim a lock
# another process had already won — this `ln`-with-pre-written-content
# construction has no such window.
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

# ------------------------------------------------------------------- parse

BRANCH=""
TICKET_ID=""
DRY_RUN=0
OUTCOME_TEXT=""
OUTCOME_FILE=""
NO_COMPLETE=0
NOTE_TEXT=""
NOTE_GIVEN=0
RESET_LAND=0
POSITIONAL=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|help) show_help ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-complete) NO_COMPLETE=1; shift ;;
        --reset-land) RESET_LAND=1; shift ;;
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

# shellcheck disable=SC2086  # word splitting is the point: POSITIONAL is a
# newline-joined list of bare args (branch, ticket id), neither of which is
# ever expected to contain whitespace.
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

# ---------------------------------------------------------------- preflight

INVOKING_REPO=$(git rev-parse --show-toplevel 2>/dev/null) || stop2 "not inside a git repository"
cd "$INVOKING_REPO"

git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null \
    || stop2 "branch '$BRANCH' does not exist"

# 1. Resolve the main worktree and the integration worktree (read-only —
# `git worktree list --porcelain`'s first entry is always the main
# worktree). Refs are shared repo-wide, so every read below works
# identically regardless of which worktree this script was invoked from.
#
# Review finding: 'git worktree list' swallowing a real failure
# into "" is indistinguishable from "no worktrees" — stop2 ("could not
# evaluate"), not a guessed pass.
if ! WT_PORCELAIN=$(git worktree list --porcelain 2>&1); then
    stop2 "could not evaluate 'git worktree list': $WT_PORCELAIN"
fi
MAIN_WORKTREE=$(printf '%s\n' "$WT_PORCELAIN" | awk '/^worktree /{sub(/^worktree /,""); print; exit}')
[ -n "$MAIN_WORKTREE" ] || stop2 "could not determine the main worktree from 'git worktree list'"
LAND_WORKTREE="$(dirname "$MAIN_WORKTREE")/$(basename "$MAIN_WORKTREE")-land"
LAND_EXISTS=0
printf '%s\n' "$WT_PORCELAIN" | grep -qxF "worktree $LAND_WORKTREE" && LAND_EXISTS=1

# <branch>'s own worktree (if any — this is the shape a Herdr wave leaves
# it in, and sometimes the invoking tree itself), fully committed. Reuses
# $WT_PORCELAIN from above — same repo, so it already has every worktree's
# branch, not just the main one. Same "could not evaluate" treatment as
# above, not a guessed pass.
BRANCH_WT=$(printf '%s\n' "$WT_PORCELAIN" | awk -v b="refs/heads/$BRANCH" '
    /^worktree / { path=$0; sub(/^worktree /,"",path) }
    /^branch /   { br=$0; sub(/^branch /,"",br); if (br==b) print path }
')
if [ -n "$BRANCH_WT" ]; then
    if ! WT_STATUS=$(git -C "$BRANCH_WT" status --porcelain 2>&1); then
        stop2 "could not check worktree '$BRANCH_WT' for branch '$BRANCH' (git status failed — removed or corrupt worktree?): $WT_STATUS"
    fi
    [ -z "$WT_STATUS" ] || stop2 "branch '$BRANCH' worktree at '$BRANCH_WT' has uncommitted changes — commit or stash them first"
fi

# 1c. Resolve the ticket's current location/status against $TARGET_BRANCH's
# own content — read via `git show`/`git cat-file`, not the working tree,
# since the invoking tree's checkout may not (and need not) be on
# $TARGET_BRANCH at all. Both modes: a read-only check, before the merge, so
# a missing ticket is a stop2 with nothing mutated. This is a preview only —
# the merge below lands on top of the integration worktree's freshly synced
# origin/$TARGET_BRANCH, and the same resolution runs again, authoritatively,
# against that post-merge tree further down.
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
    # Both fields must already exist inside the frontmatter block for the
    # completion rewrite to edit in place. A missing field is refused here,
    # before the merge (stop2, nothing mutated) — appending it after the
    # merge would land past the closing '---', into the ticket body, which
    # is not frontmatter at all and issues.py would never read it back.
    if [ "$NO_COMPLETE" != 1 ] && [ "$ALREADY_DONE" != 1 ]; then
        # awk reads to EOF (no early exit): exiting at the second '---'
        # SIGPIPEs git show on a large ticket and pipefail kills the run (141).
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

# Trailers are opt-in: each var present appends its own trailer line;
# unset means no trailer for that var, not a refusal (owner decision
# 2026-09-15 — commits are attributed to the owner alone by default).
# TRAILER_BLOCK carries its own leading blank line so callers can just
# append "$TRAILER_BLOCK" after the commit body with no extra punctuation;
# when both vars are unset it collapses to the empty string.
TRAILER_BLOCK=""
[ -n "${LAND_BRANCH_COAUTHOR:-}" ] && TRAILER_BLOCK="$TRAILER_BLOCK
Co-Authored-By: $LAND_BRANCH_COAUTHOR"
[ -n "${LAND_BRANCH_SESSION:-}" ] && TRAILER_BLOCK="$TRAILER_BLOCK
Claude-Session: $LAND_BRANCH_SESSION"
[ -z "$TRAILER_BLOCK" ] || TRAILER_BLOCK="
$TRAILER_BLOCK"

MERGE_MSG="$TICKET_ID: merge branch '$BRANCH' into $TARGET_BRANCH

Landed via land-branch.sh."

# Report the integration worktree's path and current state (read-only — no
# worktree add/fetch/reset runs here, dry-run or not).
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
echo "  0. integration worktree: '$LAND_WORKTREE' ($LAND_STATE_DESC)"
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
echo "  1. merge '$BRANCH' into '$TARGET_BRANCH' (--no-ff), inside the integration worktree"
if [ -n "$LINT_CMD" ] || [ -x ./scripts/lint.sh ]; then
    echo "  2. ${LINT_CMD:-./scripts/lint.sh} on the merged tree"
else
    echo "  2. (no lint command configured or found — skipped)"
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
echo "  4. git push origin HEAD:$TARGET_BRANCH (from the integration worktree; '$MAIN_WORKTREE' is not fast-forwarded automatically)"
if [ "${HERDR_ENV:-}" = "1" ]; then
    echo "  5. remove the herdr worktree workspace for branch '$BRANCH' (HERDR_ENV=1), then git branch -d '$BRANCH'"
else
    echo "  5. git branch -d '$BRANCH' (HERDR_ENV not set — no worktree removal)"
fi

if [ "$DRY_RUN" = 1 ]; then
    echo
    echo "--dry-run: stopping before any git-mutating command (including the integration worktree). Nothing was changed."
    exit 0
fi

# --------------------------------------------------- integration worktree
#
# Everything from here through the push runs inside $LAND_WORKTREE, never in
# $INVOKING_REPO — see the header's INTEGRATION WORKTREE section.

echo
echo "Acquiring the integration worktree lock..."
acquire_land_lock "$LAND_WORKTREE.lock"

# Recomputed fresh, under the lock: $LAND_EXISTS above was read during
# preflight (for the --dry-run plan), before this run necessarily held the
# lock — another run could have created (or removed) the integration
# worktree in between. Everything from here on is serialised by the lock, so
# this re-read is authoritative for the rest of the script.
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

# Refuse a dirty integration worktree before it is ever reset — discarding
# uncommitted work silently is the exact failure mode this guard exists to
# prevent, and the reset immediately below would otherwise do exactly that
# to ANY uncommitted change, with no way to tell it was ever there.
# --reset-land clears it on purpose.
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

# ------------------------------------------- lifecycle: awaiting deployment
#
# Before the merge — see the header's LIFECYCLE section. Nothing is merged
# yet, so no stop here needs a reset; file mode's move commit is local to
# this worktree and discarded by the reset below or the next run's sync.

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

# -------------------------------------------------------------------- merge

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

# A worker may legitimately move its own ticket file as part of its branch
# (e.g. a mixed-executor ticket parking itself in awaiting-deployment/ to
# wait on a human step) — that move lands as part of THIS merge, so
# $TICKET_FILE/$TICKET_STAGE, resolved in 1c against the PRE-merge tree, can
# now point at a path the merge just deleted. Re-resolve against the
# post-merge tree before touching the ticket file at all. (Review findings:
# land-branch used to refuse and revert a clean merge here because the
# pre-merge path no longer existed.)
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

# -------------------------------------------------------------------- lint

EFFECTIVE_LINT="$LINT_CMD"
[ -n "$EFFECTIVE_LINT" ] || { [ -x ./scripts/lint.sh ] && EFFECTIVE_LINT=./scripts/lint.sh; }
if [ -n "$EFFECTIVE_LINT" ]; then
    echo "Running $EFFECTIVE_LINT on the merged tree..."
    if ! $EFFECTIVE_LINT; then
        echo "lint failed on the merged tree — reverting the merge." >&2
        die_reset "lint failed; merge reverted, nothing pushed"
    fi
    echo "lint: clean."
else
    warn "no lint command configured (--lint-cmd / \$LAND_BRANCH_LINT_CMD) and no executable ./scripts/lint.sh found — skipping"
fi

# ---------------------------------------------------------------- complete

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
        echo "--no-complete: ticket left in '$ISSUES_DIR/$TICKET_STAGE/'."
    elif [ "$ALREADY_DONE" = 1 ]; then
        echo "ticket is already in 'completed/' — nothing to move."
    else
        DEST="$ISSUES_DIR/completed/$TICKET_ID.md"
        mkdir -p "$ISSUES_DIR/completed" || die_reset "could not create $ISSUES_DIR/completed — merge reverted, nothing pushed"

        # Edit BEFORE the move — the ordering the header comment exists for.
        # `outcome:` is rewritten as a YAML block scalar (`outcome: |`) so a
        # multi-line outcome survives intact, matching the to-issues skill's
        # ticket-template.md shape — a single-line sed substitution (the
        # original attempt at this) silently truncates a multi-line outcome
        # at its first newline. Ported from the last pre-removal revision of
        # this script (recovered via git history) and adapted to a
        # configurable ISSUES_DIR and to drop the tracker dual-write this
        # plugin's file mode does not do.
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
                    # A YAML block scalar body line is either indented (2
                    # spaces here, the convention this script writes) or
                    # blank — a blank line inside the block does NOT end it.
                    # Checking only /^  / stopped skipping at the first blank
                    # line in an EXISTING multi-line outcome, so every stale
                    # line after that blank fell through as ordinary
                    # frontmatter and got kept verbatim in the rewritten
                    # ticket.
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
                # A ticket with no updated: field still completes — outcome
                # is the field the frontmatter contract actually requires.
                exit(outcome_done ? 0 : 1)
            }
        ' "$TICKET_FILE" > "$NEW_TICKET" \
            || die_reset "could not find 'outcome:' inside $TICKET_FILE's frontmatter — merge reverted, nothing pushed"
        [ -s "$NEW_TICKET" ] || die_reset "rewriting $TICKET_FILE produced an empty file — merge reverted, nothing pushed"

        # mv, not a truncating write, and restore the original file's mode —
        # content correctness matters more than the bit, but there is no
        # reason to lose it either.
        ORIG_MODE=$(stat -f '%Lp' "$TICKET_FILE" 2>/dev/null) || ORIG_MODE=$(stat -c '%a' "$TICKET_FILE" 2>/dev/null) || ORIG_MODE=""
        mv "$NEW_TICKET" "$TICKET_FILE" || die_reset "could not overwrite $TICKET_FILE — merge reverted, nothing pushed"
        [ -n "$ORIG_MODE" ] && { chmod "$ORIG_MODE" "$TICKET_FILE" 2>/dev/null || true; }

        git mv "$TICKET_FILE" "$DEST" || die_reset "git mv $TICKET_FILE -> $DEST failed — merge reverted, nothing pushed"
        # This is the step the header's defect #1 was missing: git add the
        # moved path explicitly even though git mv already staged it, then
        # ASSERT it — don't just trust the convention.
        git add -- "$DEST" || die_reset "could not stage $DEST — merge reverted, nothing pushed"
        # Assertion, not trust: every line under $ISSUES_DIR must be fully
        # staged (porcelain's 2nd column blank) — a non-blank 2nd column is
        # an unstaged working-tree change git status --porcelain would also
        # report for an ordinary staged rename (1st column R, 2nd blank),
        # which is the expected, fine case and must not trip this check.
        LEFTOVER=$(git status --porcelain -- "$ISSUES_DIR" 2>/dev/null | awk 'substr($0,2,1) != " "') || LEFTOVER=""
        [ -z "$LEFTOVER" ] || die_reset "unstaged changes remain under $ISSUES_DIR after staging the move — merge reverted, nothing pushed:
$LEFTOVER"
        # And the staged blob must actually carry the outcome we just wrote —
        # not stale pre-edit content, which is exactly what defect #1 shipped.
        # grep -c reads all input: grep -q would exit on the first match and
        # SIGPIPE git show on a ticket larger than the pipe buffer, and
        # pipefail would turn that into a false assertion failure.
        git show ":$DEST" 2>/dev/null | grep -c '^outcome: |$' >/dev/null \
            || die_reset "assertion failed: staged '$DEST' does not carry the outcome block — merge reverted, nothing pushed"

        # No pathspec: `git mv` stages a rename as two index entries (the
        # deletion of the old path and the addition at $DEST), and a
        # pathspec-limited `git commit -- "$DEST"` only commits the add side
        # — the deletion of $TICKET_FILE stays staged afterward, and the
        # NEXT run's dirty-tree preflight then refuses on a staged 'D
        # <old-path>' this run silently left behind. Preflight (1a) already
        # guaranteed a clean tree before the merge, and nothing between the
        # merge and here stages anything but this move, so an unscoped
        # commit is exactly as narrow in practice and does not leave a
        # dangling half of the rename.
        git commit -m "$TICKET_ID: complete

$OUTCOME_TEXT$TRAILER_BLOCK" \
            || die_reset "could not commit the ticket completion — merge reverted, nothing pushed"

        # Post-commit assertion, reading HEAD rather than the index: the
        # pre-commit checks above (LEFTOVER, the outcome-block grep) only
        # ever inspected staged state, which cannot see a commit that staged
        # correctly but was then made with a pathspec narrow enough to drop
        # half of it — that is exactly the class of bug the pathspec fix
        # above closes, and this is the check that would have caught it.
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

# --------------------------------------------------------------------- push

REMOTES=$(git remote 2>/dev/null) || REMOTES=""
if [ -n "$REMOTES" ]; then
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

# ------------------------------------------------ lifecycle: completed (jira)
#
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

# --------------------------------------------------------------- herdr + branch

if [ "${HERDR_ENV:-}" = "1" ]; then
    if ! command -v herdr >/dev/null 2>&1; then
        echo "HERDR_ENV=1 but 'herdr' is not on PATH — skipping worktree removal."
    elif ! command -v jq >/dev/null 2>&1; then
        echo "HERDR_ENV=1 but 'jq' is not on PATH — skipping worktree removal."
    else
        # End the worker's Claude session cleanly BEFORE the workspace (and
        # its pane) is torn down. `herdr worktree remove` kills the pane
        # outright; Claude Code never gets to tell Remote Control it
        # finished, so the session is left as a permanent "offline" entry
        # (NWM-117). A clean `/exit` makes the entry disappear instead of
        # going offline — verified live 2026-09-18, see
        # docs/open-questions.md. herdr-ticket-start.sh always names the
        # worker's agent after its branch, so the branch name is its own
        # target; no live agent by that name means it already exited (or
        # was never started this way) and there is nothing to do.
        #
        # `/exit` is sent as literal text (not a `send-keys` logical key —
        # there is no such key), which opens Claude Code's slash-command
        # picker; the picker needs a first Enter to accept the match and a
        # second to submit it, matching what was observed live. A bounded
        # poll of `agent get` then waits for the agent to disappear — a
        # hung worker must never block landing, so exceeding the bound is
        # logged and the workspace is removed anyway.
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

        # --cwd names the repo herdr resolves against, not the tree this
        # script happens to be running in — the integration worktree ($REPO
        # by this point) is a valid worktree of the same repo, but
        # $MAIN_WORKTREE is what herdr knows this repo as.
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
            echo "branch '$BRANCH' has a herdr worktree but no workspace open on it — nothing to remove."
        elif [ -n "$MATCH_COUNT" ] && [ "$MATCH_COUNT" -gt 1 ] 2>/dev/null; then
            echo "more than one herdr worktree matches branch '$BRANCH' — skipping removal (not guessing)."
        else
            echo "no herdr worktree matches branch '$BRANCH' — skipping removal."
        fi
    fi
else
    echo "HERDR_ENV not set — skipping herdr worktree removal."
fi

if git branch -d "$BRANCH" >/dev/null 2>&1; then
    echo "deleted local branch '$BRANCH'."
else
    warn "could not delete local branch '$BRANCH' — left in place"
fi

echo
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
