#!/bin/bash
#
# Land a finished ticket branch onto the target branch (default: main),
# complete its ticket, and clean up. The ticket LIFECYCLE is this script's;
# the merge, lint gate, push and branch cleanup are ai-toolkit's land-core.sh,
# resolved at run time by scripts/ai-toolkit-root.sh --land-core and driven
# through its four-point hook contract, with this script as the hook.
#
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
# landing (hook pre-merge) and Completed after (hook post-push; --no-complete:
# only the first). A file-tracker completion is committed at hook pre-push,
# so it is inside the pushed history. Any other starting stage is refused.
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
# elsewhere (e.g. the GitHub UI's squash) and calls no land-core.sh. It proves
# the landing by CONTENT, not ancestry, so a squash counts: every path the
# branch changed since it forked must be identical at the landing commit.
#
# INTEGRATION WORKTREE, lock, --reset-land and the lint gate are land-core.sh's
# (see its header): `<parent-of-the-main-worktree>/<repo-basename>-land`,
# reset to origin/<target-branch> every run. --lint-cmd runs through bash -c.
#
# Exit codes:
#   0   landed cleanly
#   1   a step failed AFTER the merge succeeded (lint, or completing), or the
#       Awaiting Deployment transition failed. The merge is reverted — except
#       a failed `git push`, which is NOT reverted (complete locally).
#   2   could not evaluate / stopped early — bad input, a dirty tree, a
#       missing ticket, a git precondition check that itself failed, a
#       missing ai-toolkit checkout, or a merge conflict.
#
# Env overrides (all have a `--flag` equivalent; the flag wins):
#   TARGET_BRANCH                     branch to land onto (default: main).
#   LAND_BRANCH_TRACKER               file (default) | jira.
#   ISSUES_DIR                        file mode's tickets dir (default: issues).
#   ISSUES_JIRA_API                   jira mode's API wrapper path.
#   LAND_BRANCH_JIRA_PROGRESS_STATUS  In Progress status id. Required in jira mode.
#   LAND_BRANCH_JIRA_AWAITING_STATUS  Awaiting Deployment status id. Required in jira mode.
#   LAND_BRANCH_JIRA_DONE_STATUS      Completed status id. Required in jira
#                                     mode unless --no-complete; no default.
#   LAND_BRANCH_LINT_CMD              command run on the merged tree (default:
#                                     ./scripts/lint.sh if present, else skipped).
#   AI_TOOLKIT_ROOT                   ai-toolkit checkout (ai-toolkit-root.sh).
#   LAND_BRANCH_ACK_WAIT_S            wait for scripts/land-ack.sh, s (default 10).
#   LAND_BRANCH_HANDOFF_FILE          closing-state path; unreadable = no closing state.
#   LAND_BRANCH_ORCHESTRATOR_PANE     override the orchestrator pane id.
#   LAND_BRANCH_EXECUTOR_FIELD        jira executor field (customfield_10047).
#   LAND_BRANCH_CLOSING_READBACK_ATTEMPTS jira read-back attempts (default 4).
#   LAND_BRANCH_CLOSING_READBACK_DELAY_S  seconds between them (default 1).
#
# Optional layer: with HERDR_ENV=1 and `herdr` on PATH, a successful landing
# also removes the herdr worktree workspace matching this branch by name.
# Closing state (NWM-120, gated on a hand-off file by NWM-134): docs/decisions.md.

set -euo pipefail
# shellcheck source=lib/kit.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/kit.sh"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$SELF_DIR/$(basename "$0")"
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
HOOK_MODE=0
HOOK_STATE=""
JIRA_ERR=""

stop2() { echo "Error: $*${LIFECYCLE_NOTE:+
$LIFECYCLE_NOTE}" >&2; exit 2; }

# save_state VAR... — in hook mode, persist VARs for the later hook points and
# for the wrapper, which sources the file again once land-core.sh returns.
save_state() {
    [ "$HOOK_MODE" = 1 ] || return 0
    local v
    for v in "$@"; do
        printf '%s=%q\n' "$v" "${!v}" >> "$HOOK_STATE"
    done
}

# lc_fail RC MESSAGE — a lifecycle step failed. In hook mode the non-zero exit
# makes land-core.sh reset or revert; WRAPPER_RC keeps this script's own code.
lc_fail() {
    local rc="$1"
    shift
    WRAPPER_RC="$rc"
    save_state WRAPPER_RC
    echo "Error: $*${LIFECYCLE_NOTE:+
$LIFECYCLE_NOTE}" >&2
    exit "$rc"
}

jira_read() { [ -n "$JIRA_ERR" ] || return 1; "$JIRA_API" raw GET "$1" 2>"$JIRA_ERR"; }
jira_err() { [ -n "$JIRA_ERR" ] && [ -s "$JIRA_ERR" ] && cat "$JIRA_ERR"; return 0; }
jira_write() { "$JIRA_API" --yes write POST "$1" "$2" >&2; }
jira_post_comment() { printf '%s' "$2" | "$JIRA_API" --yes comment "$1" - >&2; }

# jira_resolve_to STATUS_ID — sets RESOLVED_TID/RESOLVED_TO to the one live
# transition into STATUS_ID, or returns 1 with RESOLVE_MSG set.
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

# jira_move TRANSITION_ID TARGET_STATUS_ID — POST the transition, then read
# the issue back (a 2xx is not proof). Sets MOVE_AFTER_NAME and, on failure,
# MOVE_MSG; returns 0 only when the read-back shows the target.
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

# jira_closing_readback MARK — retries the comment read-back with a bounded,
# linearly-backed-off wait, absorbing Jira's read-after-write window.
jira_closing_readback() {
    local mark="$1" attempts="${LAND_BRANCH_CLOSING_READBACK_ATTEMPTS:-4}" \
        delay="${LAND_BRANCH_CLOSING_READBACK_DELAY_S:-1}" n=1 body
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

# handoff_section HEADING — body of `## HEADING` in the handoff file, trimmed
# of blank edges; empty when the file or section is absent.
handoff_section() {
    [ -n "${HANDOFF_FILE:-}" ] && [ -r "$HANDOFF_FILE" ] || return 0
    awk -v h="## $1" '
        $0 == h { on = 1; next }
        /^## / { on = 0 }
        on { print }
    ' "$HANDOFF_FILE" | sed -e '/./,$!d' | awk '{ l[NR] = $0 } END { n = NR; while (n > 0 && l[n] == "") n--; for (i = 1; i <= n; i++) print l[i] }'
}
closing_field() { local v; v=$(handoff_section "$1"); printf '%s' "${v:-none reported by the worker}"; }

# lc_pre_merge — the Awaiting Deployment move. Nothing is merged yet; in hook
# mode a refusal makes land-core.sh reset to origin/<target>, undoing a commit.
lc_pre_merge() {
    if [ "$TRACKER" = jira ]; then
        if [ -n "$JIRA_AWAIT_TID" ]; then
            echo
            echo "Transitioning $TICKET_ID ('$JIRA_STATUS_NOW' -> '$JIRA_AWAIT_TO') $WHEN_BEFORE..."
            jira_move "$JIRA_AWAIT_TID" "$JIRA_AWAITING_STATUS" \
                || lc_fail 1 "$MOVE_MSG — nothing merged, nothing pushed"
            JIRA_STATUS_NOW="$MOVE_AFTER_NAME"
            LIFECYCLE_NOTE="Note: $TICKET_ID was moved to '$MOVE_AFTER_NAME' before this stop and stays there; re-running land-branch.sh skips that move."
            save_state JIRA_STATUS_NOW LIFECYCLE_NOTE
            echo "transitioned; read-back confirms '$MOVE_AFTER_NAME'."
        fi
        if [ "$NO_COMPLETE" != 1 ] && [ "$ALREADY_DONE" != 1 ]; then
            jira_resolve_to "$JIRA_DONE_STATUS" || lc_fail 2 "$RESOLVE_MSG — nothing merged, nothing pushed"
            JIRA_DONE_TID="$RESOLVED_TID"
            JIRA_DONE_TO="$RESOLVED_TO"
            save_state JIRA_DONE_TID JIRA_DONE_TO
        fi
        return 0
    fi
    local src="$ISSUES_DIR/in-progress/$TICKET_ID.md" dest="$ISSUES_DIR/awaiting-deployment/$TICKET_ID.md" tmp leftover
    if [ -f "$src" ] \
        && ! git cat-file -e "$BRANCH:$dest" 2>/dev/null \
        && ! git cat-file -e "$BRANCH:$ISSUES_DIR/completed/$TICKET_ID.md" 2>/dev/null; then
        echo
        echo "Moving $src -> $dest before the merge..."
        mkdir -p "$ISSUES_DIR/awaiting-deployment" || lc_fail 2 "could not create $ISSUES_DIR/awaiting-deployment — nothing merged, nothing pushed"
        tmp=$(tmpfile) || lc_fail 2 "could not create a temp file — nothing merged, nothing pushed"
        awk -v today="$(date +%F)" '
            $0 == "---" { fm++ }
            fm == 1 && !done && /^updated:/ { print "updated: " today; done = 1; next }
            { print }
        ' "$src" > "$tmp" || lc_fail 2 "could not bump 'updated:' in $src — nothing merged, nothing pushed"
        [ -s "$tmp" ] || lc_fail 2 "bumping 'updated:' in $src produced an empty file — nothing merged, nothing pushed"
        cat "$tmp" > "$src" || lc_fail 2 "could not rewrite $src — nothing merged, nothing pushed"
        git mv "$src" "$dest" || lc_fail 2 "git mv $src -> $dest failed — nothing merged, nothing pushed"
        git add -- "$dest" || lc_fail 2 "could not stage $dest — nothing merged, nothing pushed"
        git commit -q -m "$TICKET_ID: awaiting deployment

Moved in-progress -> awaiting-deployment by land-branch.sh before merging '$BRANCH'." \
            || lc_fail 2 "could not commit the awaiting-deployment move — nothing merged, nothing pushed"
        git cat-file -e "HEAD:$dest" 2>/dev/null \
            || lc_fail 2 "HEAD does not contain $dest after the move commit — nothing merged, nothing pushed"
        if git cat-file -e "HEAD:$src" 2>/dev/null; then
            lc_fail 2 "HEAD still contains $src after the move commit — nothing merged, nothing pushed"
        fi
        leftover=$(git status --porcelain -- "$ISSUES_DIR" 2>/dev/null) || leftover=""
        [ -z "$leftover" ] || lc_fail 2 "working tree under $ISSUES_DIR is not clean after the move commit:
$leftover — nothing merged, nothing pushed"
        echo "moved; committed."
    fi
}

# lc_post_merge — build the closing state against the landing commit, and
# re-resolve a file ticket against the merged tree: a worker may have moved
# its own ticket file on its branch.
lc_post_merge() {
    local stage cand fm_top
    if [ "$CLOSING" = 1 ]; then
        if [ "$ALREADY_MERGED" = 1 ]; then
            MERGE_SHA="$LANDED_SHA"
            LANDED_HOW="already on $TARGET_BRANCH at"
        else
            MERGE_SHA=$(git rev-parse HEAD)
            LANDED_HOW="merge commit"
        fi
        CLOSING_MARK="closing-state:$TICKET_ID:${MERGE_SHA}"
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
        save_state MERGE_SHA LANDED_HOW CLOSING_MARK CLOSING_TEXT NOTE_TEXT NOTE_GIVEN OUTCOME_TEXT
    fi
    [ "$TRACKER" = file ] || return 0
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
    [ -n "$TICKET_FILE" ] || lc_fail 1 "ticket '$TICKET_ID' not found under '$ISSUES_DIR/{open,in-progress,awaiting-deployment,completed,cancelled}/' after the merge — merge reverted, nothing pushed"
    if [ "$NO_COMPLETE" != 1 ]; then
        if [ "$TICKET_STAGE" = completed ]; then
            ALREADY_DONE=1
        else
            ALREADY_DONE=0
            fm_top=$(awk '/^---$/{c++; if (c==2) exit} {print}' "$TICKET_FILE")
            printf '%s\n' "$fm_top" | grep -q '^outcome:' \
                || lc_fail 1 "$TICKET_FILE has no 'outcome:' field in its frontmatter to rewrite — merge reverted, nothing pushed"
            printf '%s\n' "$fm_top" | grep -q '^updated:' \
                || lc_fail 1 "$TICKET_FILE has no 'updated:' field in its frontmatter to rewrite — merge reverted, nothing pushed"
        fi
    fi
    save_state TICKET_FILE TICKET_STAGE ALREADY_DONE
}

# lc_file_complete — edit, move and commit a file ticket into completed/.
# Runs at pre-push, so the commit is inside the history land-core.sh pushes.
lc_file_complete() {
    local dest="$ISSUES_DIR/completed/$TICKET_ID.md" today outcome_indented new_ticket orig_mode leftover l
    mkdir -p "$ISSUES_DIR/completed" || lc_fail 1 "could not create $ISSUES_DIR/completed — merge reverted, nothing pushed"

    # Edit BEFORE the move. `outcome:` is rewritten as a YAML block scalar
    # (`outcome: |`) so a multi-line outcome survives intact.
    today=$(date +%F)
    outcome_indented=$(tmpfile) || lc_fail 1 "could not create temp file — merge reverted, nothing pushed"
    while IFS= read -r l || [ -n "$l" ]; do
        if [ -n "$l" ]; then printf '  %s\n' "$l"; else printf '\n'; fi
    done <<EOF >"$outcome_indented"
$OUTCOME_TEXT
EOF

    new_ticket=$(tmpfile) || lc_fail 1 "could not create temp file — merge reverted, nothing pushed"
    awk -v outfile="$outcome_indented" -v today="$today" '
        BEGIN { fm = 0; outcome_done = 0; updated_done = 0; skipping = 0 }
        {
            if (skipping == 1) {
                # A blank line inside a block scalar does not end it.
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
        END { exit(outcome_done ? 0 : 1) }
    ' "$TICKET_FILE" > "$new_ticket" \
        || lc_fail 1 "could not find 'outcome:' inside $TICKET_FILE's frontmatter — merge reverted, nothing pushed"
    [ -s "$new_ticket" ] || lc_fail 1 "rewriting $TICKET_FILE produced an empty file — merge reverted, nothing pushed"

    orig_mode=$(stat -f '%Lp' "$TICKET_FILE" 2>/dev/null) || orig_mode=$(stat -c '%a' "$TICKET_FILE" 2>/dev/null) || orig_mode=""
    mv "$new_ticket" "$TICKET_FILE" || lc_fail 1 "could not overwrite $TICKET_FILE — merge reverted, nothing pushed"
    [ -n "$orig_mode" ] && { chmod "$orig_mode" "$TICKET_FILE" 2>/dev/null || true; }

    git mv "$TICKET_FILE" "$dest" || lc_fail 1 "git mv $TICKET_FILE -> $dest failed — merge reverted, nothing pushed"
    git add -- "$dest" || lc_fail 1 "could not stage $dest — merge reverted, nothing pushed"
    # A staged rename is 'R ' and must not trip this; a blank 2nd column is staged.
    leftover=$(git status --porcelain -- "$ISSUES_DIR" 2>/dev/null | awk 'substr($0,2,1) != " "') || leftover=""
    [ -z "$leftover" ] || lc_fail 1 "unstaged changes remain under $ISSUES_DIR after staging the move — merge reverted, nothing pushed:
$leftover"
    # grep -c reads all input: grep -q SIGPIPEs git show on a large ticket.
    git show ":$dest" 2>/dev/null | grep -c '^outcome: |$' >/dev/null \
        || lc_fail 1 "assertion failed: staged '$dest' does not carry the outcome block — merge reverted, nothing pushed"

    # No pathspec: a pathspec-limited commit takes only the add side of a rename.
    git commit -m "$TICKET_ID: complete

$OUTCOME_TEXT" \
        || lc_fail 1 "could not commit the ticket completion — merge reverted, nothing pushed"

    git cat-file -e "HEAD:$dest" 2>/dev/null \
        || lc_fail 1 "HEAD does not contain $dest after the completion commit — merge reverted, nothing pushed"
    if git cat-file -e "HEAD:$TICKET_FILE" 2>/dev/null; then
        lc_fail 1 "HEAD still contains $TICKET_FILE after the completion commit — the move did not fully land, merge reverted, nothing pushed"
    fi
    git show "HEAD:$dest" 2>/dev/null | grep -c '^outcome: |$' >/dev/null \
        || lc_fail 1 "assertion failed: HEAD:$dest does not carry the outcome block — merge reverted, nothing pushed"
    leftover=$(git status --porcelain -- "$ISSUES_DIR" 2>/dev/null) || leftover=""
    [ -z "$leftover" ] \
        || lc_fail 1 "working tree under $ISSUES_DIR is not clean after the completion commit — merge reverted, nothing pushed:
$leftover"
    if [ "$CLOSING" = 1 ] && ! git show "HEAD:$dest" 2>/dev/null | grep -Fc "$CLOSING_MARK" >/dev/null; then
        lc_fail 1 "closing state read-back failed: HEAD:$dest does not carry '$CLOSING_MARK' — merge reverted, nothing pushed"
    fi
    echo "$TICKET_ID moved to '$ISSUES_DIR/completed/'."
}

# lc_pre_push — lint has passed and nothing is pushed: commit the file
# tracker's completion or note, or post a jira --no-complete note.
lc_pre_push() {
    local notes_file
    if [ "$TRACKER" = file ]; then
        if [ "$NO_COMPLETE" = 1 ]; then
            notes_file="$ISSUES_DIR/$TICKET_STAGE/$TICKET_ID.notes.md"
            if [ "$NOTE_GIVEN" = 1 ]; then
                echo "## $(date +%F)
$NOTE_TEXT
" >> "$notes_file" || lc_fail 1 "could not append to $notes_file — merge reverted, nothing pushed"
                git add -- "$notes_file" || lc_fail 1 "could not stage $notes_file — merge reverted, nothing pushed"
                git commit -m "$TICKET_ID: progress note (land-branch.sh --no-complete)" -- "$notes_file" \
                    || lc_fail 1 "could not commit $notes_file — merge reverted, nothing pushed"
            fi
            if [ "$CLOSING" = 1 ] && ! git show "HEAD:$notes_file" 2>/dev/null | grep -Fc "$CLOSING_MARK" >/dev/null; then
                lc_fail 1 "closing state read-back failed: HEAD:$notes_file does not carry '$CLOSING_MARK' — merge reverted, nothing pushed"
            fi
            echo "--no-complete: ticket left in '$ISSUES_DIR/$TICKET_STAGE/'."
        elif [ "$ALREADY_DONE" = 1 ]; then
            echo "ticket is already in 'completed/' — nothing to move."
        else
            lc_file_complete
        fi
    elif [ "$NO_COMPLETE" = 1 ]; then
        if [ -n "$NOTE_TEXT" ]; then
            echo "Posting note as a comment on $TICKET_ID..."
            jira_post_comment "$TICKET_ID" "Progress note ($(date +%F), branch '$BRANCH' landed via land-branch.sh --no-complete):
$NOTE_TEXT" \
                || lc_fail 1 "POST comment failed — merge reverted, nothing pushed, no note posted"
            echo "comment posted."
        fi
        echo "--no-complete: issue $TICKET_ID left in status '$JIRA_STATUS_NOW'."
    fi
    PRE_PUSH_OK=1
    save_state PRE_PUSH_OK
}

# lc_herdr_teardown — end the worker's session, then remove its herdr
# workspace. Runs before land-core.sh's own worktree and branch cleanup.
lc_herdr_teardown() {
    local agent_pane exit_bound_s exit_waited_s listing match_count ws_id
    if ! command -v herdr >/dev/null 2>&1; then
        echo "HERDR_ENV=1 but 'herdr' is not on PATH — skipping worktree removal."
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "HERDR_ENV=1 but 'jq' is not on PATH — skipping worktree removal."
        return 0
    fi
    # End the session BEFORE the pane is torn down: `herdr worktree remove`
    # kills it outright, leaving a permanent "offline" entry (NWM-117).
    # `/exit` is literal text, so the slash-command picker needs two Enters.
    if herdr agent get "$BRANCH" >/dev/null 2>&1; then
        agent_pane=$(herdr agent get "$BRANCH" 2>/dev/null | jq -r '.result.agent.pane_id // empty' 2>/dev/null) || agent_pane=""
        if [ -z "$agent_pane" ]; then
            warn "found a live Herdr agent named '$BRANCH' but could not read its pane_id — skipping clean exit, removing its workspace anyway"
        else
            echo "Exiting the worker's Claude session on '$BRANCH' (pane $agent_pane) before removing its workspace..."
            herdr pane send-text "$agent_pane" "/exit" >/dev/null 2>&1 || true
            sleep 1
            herdr agent send-keys "$BRANCH" enter >/dev/null 2>&1 || true
            sleep 1
            herdr agent send-keys "$BRANCH" enter >/dev/null 2>&1 || true
            exit_bound_s="${LAND_BRANCH_EXIT_WAIT_S:-15}"
            exit_waited_s=0
            while [ "$exit_waited_s" -lt "$exit_bound_s" ] && herdr agent get "$BRANCH" >/dev/null 2>&1; do
                sleep 1
                exit_waited_s=$((exit_waited_s + 1))
            done
            if herdr agent get "$BRANCH" >/dev/null 2>&1; then
                warn "worker on '$BRANCH' did not exit its Claude session within ${exit_bound_s}s — removing its workspace anyway (Remote Control will show it as offline until pruned by hand)"
            else
                echo "worker session on '$BRANCH' exited cleanly."
            fi
        fi
    else
        echo "no live Herdr agent named '$BRANCH' — nothing to exit."
    fi

    # --cwd names the repo as herdr knows it: the main worktree.
    listing=$(herdr worktree list --cwd "$MAIN_WORKTREE" --json 2>/dev/null) || listing=""
    match_count=""
    if [ -n "$listing" ]; then
        match_count=$(printf '%s' "$listing" | jq -r --arg b "$BRANCH" '
            [ (.result.worktrees // [])[] | select(.is_linked_worktree == true and .branch == $b) ] | length
        ' 2>/dev/null) || match_count=""
    fi
    ws_id=""
    if [ "$match_count" = "1" ]; then
        ws_id=$(printf '%s' "$listing" | jq -r --arg b "$BRANCH" '
            [ (.result.worktrees // [])[] | select(.is_linked_worktree == true and .branch == $b) ][0].open_workspace_id // empty
        ' 2>/dev/null) || ws_id=""
    fi
    if [ -n "$ws_id" ]; then
        echo "Removing herdr worktree workspace '$ws_id' (matched by branch '$BRANCH')..."
        herdr worktree remove --workspace "$ws_id" || warn "herdr worktree remove failed — remove it by hand"
    elif [ "$match_count" = "1" ]; then
        echo "branch '$BRANCH' has a herdr worktree with no workspace open on it — git removes it below."
    elif [ -n "$match_count" ] && [ "$match_count" -gt 1 ] 2>/dev/null; then
        echo "more than one herdr worktree matches branch '$BRANCH' — skipping removal (not guessing)."
    else
        echo "no herdr worktree matches branch '$BRANCH' — skipping removal."
    fi
}

# lc_post_push — the push is the deploy, so nothing here reverts anything:
# complete the jira issue, write the closing state durably, notify, tear down.
# Returns 1 when the ticket or the closing state was left unfinished.
lc_post_push() {
    local after_name ack_file ack_bound_s ack_waited_s
    if [ "$TRACKER" = jira ] && [ "$NO_COMPLETE" != 1 ]; then
        after_name="$JIRA_STATUS_NOW"
        if [ "$ALREADY_DONE" = 1 ]; then
            echo "issue $TICKET_ID is already '$JIRA_STATUS_NOW' — nothing to transition."
        else
            echo "Transitioning $TICKET_ID ('$JIRA_STATUS_NOW' -> '$JIRA_DONE_TO') $WHEN_AFTER..."
            if jira_move "$JIRA_DONE_TID" "$JIRA_DONE_STATUS"; then
                after_name="$MOVE_AFTER_NAME"
                echo "transitioned; read-back confirms '$after_name'."
            else
                COMPLETE_FAILED="$MOVE_MSG"
                save_state COMPLETE_FAILED
            fi
        fi
        if [ -z "$COMPLETE_FAILED" ]; then
            echo "Posting outcome as a comment on $TICKET_ID..."
            if jira_post_comment "$TICKET_ID" "$OUTCOME_TEXT"; then
                echo "comment posted."
            else
                warn "comment POST failed after a successful transition — the landing stands (issue is '$after_name'); add the outcome by hand"
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
    save_state CLOSING_FAILED

    if [ "$CLOSING" = 1 ] && [ -z "$CLOSING_FAILED" ]; then
        ack_file="${LAND_BRANCH_ACK_FILE:-${TMPDIR:-/tmp}/nw-ack-$TICKET_ID-${MERGE_SHA:0:8}}"
        rm -f "$ack_file" 2>/dev/null || true
        if [ -z "$ORCH_PANE" ]; then
            echo "no orchestrator pane recorded — closing state is in the tracker; nobody was notified."
        elif ! command -v herdr >/dev/null 2>&1; then
            warn "no 'herdr' on PATH — orchestrator pane $ORCH_PANE was not notified; closing state is in the tracker"
        else
            herdr_notify "$ORCH_PANE" "$TICKET_ID landed; closing state is in the tracker ($CLOSING_MARK). Acknowledge with: $SELF_DIR/land-ack.sh '$ack_file'" || true
            ack_bound_s="${LAND_BRANCH_ACK_WAIT_S:-10}"
            ack_waited_s=0
            while [ "$ack_waited_s" -lt "$ack_bound_s" ] && [ ! -e "$ack_file" ]; do
                sleep 1
                ack_waited_s=$((ack_waited_s + 1))
            done
            if [ -e "$ack_file" ]; then
                echo "orchestrator acknowledged the closing state."
            else
                warn "orchestrator pane $ORCH_PANE did not acknowledge within ${ack_bound_s}s — the closing state IS in the tracker, continuing with the exit"
            fi
        fi
    fi

    if [ "$CLOSING" = 1 ] && [ -n "$CLOSING_FAILED" ]; then
        warn "closing state was NOT written durably ($CLOSING_FAILED) — leaving the worker's session and workspace in place so its output survives"
    elif [ "${HERDR_ENV:-}" = "1" ]; then
        lc_herdr_teardown
    else
        echo "HERDR_ENV not set — skipping herdr worktree removal."
    fi
    [ -z "$COMPLETE_FAILED" ] && [ -z "$CLOSING_FAILED" ]
}

# lc_finish — the wrapper's closing line, after the landing itself stands.
lc_finish() {
    echo
    if [ -n "$CLOSING_FAILED" ]; then
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
        die "branch '$BRANCH' landed on '$TARGET_BRANCH' and was pushed — the landing stands and was NOT reverted — but $TICKET_ID was NOT completed: $COMPLETE_FAILED. It stays '$JIRA_STATUS_NOW'; complete it by hand and say so in the ticket"
    else
        echo "$TICKET_ID landed on '$TARGET_BRANCH' and completed."
    fi
    exit 0
}

# Hook mode: land-core.sh calls this script as `<path> <point>` from the
# integration worktree, with the state file the wrapper wrote.
if [ $# -eq 1 ] && [ -n "${LAND_BRANCH_HOOK_STATE:-}" ] && [ "${LAND_CORE_POINT:-}" = "$1" ]; then
    HOOK_MODE=1
    HOOK_STATE="$LAND_BRANCH_HOOK_STATE"
    [ -f "$HOOK_STATE" ] && [ -O "$HOOK_STATE" ] || die "hook state '$HOOK_STATE' is missing or not owned by this user"
    # shellcheck disable=SC1090  # written by this script's own wrapper half
    . "$HOOK_STATE"
    if [ "$TRACKER" = jira ]; then
        JIRA_ERR=$(tmpfile) || die "could not create a temp file for jira-api diagnostics"
    fi
    case "$1" in
        pre-merge)  lc_pre_merge ;;
        post-merge) lc_post_merge ;;
        pre-push)   lc_pre_push ;;
        post-push)  lc_post_push || exit 1 ;;
    esac
    exit 0
fi

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
# What the transition narration says about where the landing stands.
WHEN_BEFORE="before the merge"
WHEN_AFTER="after the push"
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
    # land-core.sh runs the hooks from the integration worktree, so a relative
    # wrapper path would resolve against the wrong directory there.
    case "$JIRA_API" in
        /*) ;;
        *) JIRA_API="$(cd "$(dirname "$JIRA_API")" && pwd)/$(basename "$JIRA_API")" ;;
    esac
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
if ! WT_PORCELAIN=$(git worktree list --porcelain 2>&1); then
    stop2 "could not evaluate 'git worktree list': $WT_PORCELAIN"
fi
MAIN_WORKTREE=$(printf '%s\n' "$WT_PORCELAIN" | awk '/^worktree /{sub(/^worktree /,""); print; exit}')
[ -n "$MAIN_WORKTREE" ] || stop2 "could not determine the main worktree from 'git worktree list'"
LAND_WORKTREE="$(dirname "$MAIN_WORKTREE")/$(basename "$MAIN_WORKTREE")-land"
LAND_EXISTS=0
printf '%s\n' "$WT_PORCELAIN" | grep -qxF "worktree $LAND_WORKTREE" && LAND_EXISTS=1

BRANCH_WT=$(printf '%s\n' "$WT_PORCELAIN" | awk -v b="refs/heads/$BRANCH" '
    /^worktree / { path=$0; sub(/^worktree /,"",path) }
    /^branch /   { br=$0; sub(/^branch /,"",br); if (br==b) print path }
')
if [ -n "$BRANCH_WT" ]; then
    # NWM-147: the worker brief requires .night-watchman/closing-state.md
    # uncommitted in this worktree; -uall makes the exclusion exact.
    if ! WT_STATUS=$(git -C "$BRANCH_WT" status --porcelain -uall \
            -- . ':!.night-watchman/closing-state.md' 2>&1); then
        stop2 "could not check worktree '$BRANCH_WT' for branch '$BRANCH' (git status failed — removed or corrupt worktree?): $WT_STATUS"
    fi
    [ -z "$WT_STATUS" ] || stop2 "branch '$BRANCH' worktree at '$BRANCH_WT' has uncommitted changes — commit or stash them first (.night-watchman/closing-state.md is exempt; nothing else is):
$WT_STATUS"
fi

# --already-merged: prove the branch's work is ON the target before anything
# transitions — ancestry where it holds, content everywhere else.
if [ "$ALREADY_MERGED" = 1 ]; then
    WHEN_BEFORE="against the landing already on $TARGET_BRANCH"
    WHEN_AFTER="against the landing already on $TARGET_BRANCH"
    echo "Fetching origin to check '$BRANCH' against '$TARGET_BRANCH'..."
    FETCH_OUT=$(git fetch origin 2>&1) || stop2 "--already-merged: git fetch origin failed: $FETCH_OUT"
    git rev-parse --verify --quiet "refs/remotes/origin/$TARGET_BRANCH" >/dev/null 2>&1 \
        || stop2 "--already-merged: origin/$TARGET_BRANCH does not exist — nothing to check the branch against"

    if git merge-base --is-ancestor "$BRANCH" "origin/$TARGET_BRANCH" 2>/dev/null; then
        # Content cannot run here: the fork point IS the branch tip, so it
        # would compare nothing and pass vacuously.
        LANDED_SHA=$(git rev-parse --verify --quiet "${MERGED_AS:-origin/$TARGET_BRANCH}^{commit}") \
            || stop2 "--merged-as: '$MERGED_AS' does not resolve to a commit in this repository"
        git merge-base --is-ancestor "$BRANCH" "$LANDED_SHA" 2>/dev/null \
            || stop2 "--merged-as $MERGED_AS predates '$BRANCH''s landing — '$BRANCH' is not an ancestor of it. Nothing was transitioned"
        echo "'$BRANCH' is an ancestor of origin/$TARGET_BRANCH — landed at $(git rev-parse --short "$LANDED_SHA")."
    else
        FORK_POINT=$(git merge-base "origin/$TARGET_BRANCH" "$BRANCH" 2>/dev/null) \
            || stop2 "--already-merged: '$BRANCH' and origin/$TARGET_BRANCH have no common ancestor"
        BRANCH_PATHS=$(git diff --name-only "$FORK_POINT" "$BRANCH" 2>/dev/null) \
            || stop2 "--already-merged: could not list the paths '$BRANCH' changed since $FORK_POINT"
        [ -n "$BRANCH_PATHS" ] || stop2 "--already-merged: '$BRANCH' changes no path relative to origin/$TARGET_BRANCH and is not an ancestor of it — there is nothing whose landing could be proved"

        # git diff takes no --pathspec-from-file, so intersect the name lists.
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
            # A subject naming the ticket is a CANDIDATE, never the answer.
            for cand in $(git log --format='%H' -n 50 "origin/$TARGET_BRANCH" 2>/dev/null); do
                git log --format='%s' -n 1 "$cand" 2>/dev/null | grep -qiF "$TICKET_ID" || continue
                if landing_holds "$cand"; then LANDED_SHA="$cand"; break; fi
            done
            [ -n "$LANDED_SHA" ] || stop2 "--already-merged: no commit in the last 50 on origin/$TARGET_BRANCH both names $TICKET_ID and carries '$BRANCH''s content. Pass --merged-as <sha> — find it with: git log origin/$TARGET_BRANCH --oneline | grep -i $TICKET_ID"
        fi
        echo "'$BRANCH''s work is on origin/$TARGET_BRANCH at $(git rev-parse --short "$LANDED_SHA") — $(printf '%s\n' "$BRANCH_PATHS" | wc -l | tr -d ' ') path(s) verified identical."
    fi
fi

# Resolve the ticket against $TARGET_BRANCH's content via `git show`. A
# preview only: it runs again, authoritatively, against the merged tree.
TICKET_FILE=""
TICKET_STAGE=""
ALREADY_DONE=0
JIRA_STATUS_NOW=""
JIRA_AWAIT_TID=""
JIRA_AWAIT_TO=""
JIRA_DONE_TID=""
JIRA_DONE_TO=""
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
    # Both fields must already exist in the frontmatter for an in-place edit.
    if [ "$NO_COMPLETE" != 1 ] && [ "$ALREADY_DONE" != 1 ]; then
        # awk reads to EOF: exiting early SIGPIPEs git show on a large ticket.
        FM_TOP=$(git show "$TARGET_BRANCH:$TICKET_FILE" 2>/dev/null | awk '/^---$/{c++} c<2 {print}')
        printf '%s\n' "$FM_TOP" | grep -q '^outcome:' \
            || stop2 "$TICKET_FILE has no 'outcome:' field in its frontmatter to rewrite"
        printf '%s\n' "$FM_TOP" | grep -q '^updated:' \
            || stop2 "$TICKET_FILE has no 'updated:' field in its frontmatter to rewrite"
    fi
else
    need jq
    JIRA_ERR=$(tmpfile) || stop2 "could not create a temp file for jira-api diagnostics"
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

CLOSING=0
CLOSING_FAILED=""
CLOSING_TEXT=""
CLOSING_MARK=""
MERGE_SHA=""
HANDOFF_FILE=""
EXECUTOR=""
BRANCH_CONDITION=""
WORKER_WT=""
PRE_PUSH_OK=""
WRAPPER_RC=""
ORCH_PANE="${LAND_BRANCH_ORCHESTRATOR_PANE:-}"
if [ "${HERDR_ENV:-}" = "1" ]; then
    HANDOFF_FILE="${LAND_BRANCH_HANDOFF_FILE:-}"
    WORKER_WT=$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$BRANCH" '/^worktree /{p=substr($0,10)} $1=="branch" && $2==b {print p}') || WORKER_WT=""
    if [ -z "$HANDOFF_FILE" ] && [ -n "$WORKER_WT" ]; then
        HANDOFF_FILE="$WORKER_WT/.night-watchman/closing-state.md"
    fi
    [ -n "$HANDOFF_FILE" ] && [ -r "$HANDOFF_FILE" ] && CLOSING=1

    if [ "$TRACKER" = file ]; then
        EXECUTOR=$(git show "$TARGET_BRANCH:$TICKET_FILE" 2>/dev/null | awk '/^---$/ { c++; next } c == 1 && !d && /^executor:/ { sub(/^executor:[ \t]*/, ""); print; d = 1 }') || EXECUTOR=""
    else
        EXEC_FIELD="${LAND_BRANCH_EXECUTOR_FIELD:-customfield_10047}"
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

LAND_CORE=""
if [ "$ALREADY_MERGED" != 1 ]; then
    CORE_ERR=$("$SELF_DIR/ai-toolkit-root.sh" --land-core 2>&1 >/dev/null) || true
    LAND_CORE=$("$SELF_DIR/ai-toolkit-root.sh" --land-core 2>/dev/null) \
        || stop2 "cannot resolve ai-toolkit's land-core.sh, which does this landing's merge and push. Nothing mutated. ai-toolkit-root.sh said:
$CORE_ERR"
    [ -x "$LAND_CORE" ] || stop2 "ai-toolkit's land-core.sh at '$LAND_CORE' is not executable. Nothing mutated"
fi

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
    echo "  0. integration worktree: '$LAND_WORKTREE' ($LAND_STATE_DESC); merge, lint, push and cleanup by $LAND_CORE"
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
        echo "  3. ($WHEN_AFTER) issue $TICKET_ID is already '$JIRA_STATUS_NOW' — no transition needed; POST the outcome as a comment"
    else
        echo "  3. ($WHEN_AFTER) POST the transition into status id $JIRA_DONE_STATUS on $TICKET_ID (resolved from its live transitions once Awaiting Deployment, $WHEN_BEFORE), read back to confirm, POST outcome as a comment"
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

if [ "$ALREADY_MERGED" = 1 ]; then
    # No merge and no push, so no land-core.sh: the lifecycle runs inline
    # against the main worktree, and this script does the cleanup itself.
    echo
    echo "--already-merged: skipping the integration worktree, the merge, the lint and the push."
    cd "$MAIN_WORKTREE"
    lc_pre_merge
    lc_post_merge
    echo "--already-merged: not linting — this tree was not merged here, and whatever landed already passed the PR's checks."
    lc_pre_push
    echo "--already-merged: nothing to push — $TARGET_BRANCH already carries this work at $(git rev-parse --short "$LANDED_SHA")."
    lc_post_push || true
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
    # -D: git never sees a squash-merged branch as merged, and the content
    # check above is exactly the evidence -d wants and cannot compute.
    if git branch -D "$BRANCH" >/dev/null 2>&1; then
        echo "deleted local branch '$BRANCH'."
    else
        warn "could not delete local branch '$BRANCH' — left in place"
    fi
    lc_finish
fi

HOOK_STATE=$(tmpfile) || stop2 "could not create the hook state file. Nothing mutated"
HOOK_MODE=1
save_state TRACKER ISSUES_DIR JIRA_API JIRA_DONE_STATUS JIRA_AWAITING_STATUS JIRA_PROGRESS_STATUS \
    BRANCH TICKET_ID TARGET_BRANCH NO_COMPLETE NOTE_TEXT NOTE_GIVEN OUTCOME_TEXT ALREADY_MERGED \
    LANDED_SHA LANDED_HOW WHEN_BEFORE WHEN_AFTER TICKET_FILE TICKET_STAGE ALREADY_DONE \
    JIRA_STATUS_NOW JIRA_AWAIT_TID JIRA_AWAIT_TO JIRA_DONE_TID JIRA_DONE_TO COMPLETE_FAILED \
    CLOSING CLOSING_FAILED CLOSING_TEXT CLOSING_MARK MERGE_SHA HANDOFF_FILE EXECUTOR \
    BRANCH_CONDITION WORKER_WT ORCH_PANE MAIN_WORKTREE PRE_PUSH_OK WRAPPER_RC \
    LIFECYCLE_NOTE
HOOK_MODE=0

CORE_ARGS=(--repo "$MAIN_WORKTREE" --branch "$BRANCH" --target "$TARGET_BRANCH"
    --label "$TICKET_ID" --merge-message "$MERGE_MSG" --hook "$SELF")
[ "$RESET_LAND" != 1 ] || CORE_ARGS+=(--reset-land)
[ -z "$LINT_CMD" ] || CORE_ARGS+=(--lint-cmd "$LINT_CMD")

echo
set +e
env -u LAND_CORE_LINT_CMD -u LAND_CORE_HOOK -u LAND_CORE_TARGET_BRANCH \
    LAND_BRANCH_HOOK_STATE="$HOOK_STATE" "$LAND_CORE" "${CORE_ARGS[@]}"
CORE_RC=$?
set -e

# shellcheck disable=SC1090  # the state file this run wrote and its hooks appended to
. "$HOOK_STATE"

if [ "$CORE_RC" = 0 ] || [ -n "$CLOSING_FAILED$COMPLETE_FAILED" ]; then
    lc_finish
fi
[ -z "$WRAPPER_RC" ] || exit "$WRAPPER_RC"
if [ "$PRE_PUSH_OK" = 1 ] && [ "$CORE_RC" = 1 ]; then
    if [ "$TRACKER" = jira ]; then
        die "the push failed after the merge — the landing is complete LOCALLY in '$LAND_WORKTREE' and was NOT reverted. $TICKET_ID is '$JIRA_STATUS_NOW' and was NOT completed: complete it by hand after the push and say so in the ticket"
    fi
    die "the push failed after the merge — the landing is complete LOCALLY in '$LAND_WORKTREE' (the ticket move commits are part of it) and was NOT reverted"
fi
[ -z "$LIFECYCLE_NOTE" ] || echo "$LIFECYCLE_NOTE" >&2
exit "$CORE_RC"
