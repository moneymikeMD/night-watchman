#!/bin/bash
#
# herdr-ticket-start.sh — open a Herdr git-worktree workspace for a ticket,
# start a Claude agent in it pinned to a chosen model, and hand it the
# ticket's brief. Optional layer: this plugin does not ship or require Herdr.
#
# Usage:
#   herdr-ticket-start.sh <ticket-id> --jira-progress-status ID [--model sonnet|opus|haiku] [--timebox TEXT] [--forbidden TEXT]... [--wait|--no-wait] [--dry-run]
#   herdr-ticket-start.sh --help
#
# <ticket-id> is matched case-insensitively. The title and executor always
# come from the tracker, never a local file. The branch, the herdr worktree
# label and the herdr agent name are all the LOWERCASED id (e.g. proj-123).
#
# Flags:
#   --model                 sonnet (default), opus or haiku. Anything else is
#                           a hard refusal, never a fallback to the caller's
#                           shell default.
#   --jira-progress-status  REQUIRED. The STATUS id of In Progress (e.g. 3),
#                           NOT the transition id (e.g. 21). No default
#                           exists: every tracker's workflow ids differ.
#   --timebox TEXT          the brief's TIMEBOX line.
#   --forbidden TEXT        the brief's FORBIDDEN lines; repeatable.
#   --wait                  block until the agent settles (up to an hour).
#   --no-wait               hand off and return with no confirmation.
#   (default)               bounded: --wait --until working --timeout 60000.
#   --dry-run               run every check, print the plan and the full
#                           brief, send nothing. Also on with NW_DRY_RUN=1.
#
# --wait and --no-wait are mutually exclusive; the last one on the command
# line wins.
#
# The brief is rendered from templates/dispatch-brief.md: TRACKER, TIMEBOX,
# FORBIDDEN, REPORT and STANDING. --timebox/--forbidden default to
# [dispatch.brief]; an empty one dies naming it before any herdr or tracker
# call, so an incomplete brief is never sent.
#
# After the brief hand-off the ticket is transitioned to In Progress,
# resolved by matching --jira-progress-status against the issue's live
# transitions; zero or several matches are refused before anything is
# created. The issue is read back after the POST; a 2xx is not proof.
# Already In Progress is a no-op.
#
# Refusals, checked in this order, before anything is created:
#   1. bad --model, or --jira-progress-status missing or not numeric
#   2. HERDR_ENV is not "1"
#   3. the issue's executor field is not `agent` (human/mixed need a person)
#   4. the branch already exists, as a herdr worktree or a bare local branch
#
# Idempotency: a herdr workspace ALREADY open on the target branch prints
# that and exits 0, transitioning nothing. A branch or worktree with NO open
# workspace is refusal #4 — land it or remove it by hand first.
#
# Exit codes:
#   0   started cleanly, OR the workspace already existed, OR --dry-run
#       printed its plan.
#   1   a check failed, or a herdr command failed partway through (the
#       message says what was and was not created), or the transition failed
#       or did not read back (the agent is left running).
#   2   could not evaluate: herdr, jq or git missing from PATH, the jira-api
#       wrapper missing or not executable, the issue unreadable or missing a
#       `summary`, an unrecognized or unset executor value, unparseable
#       JSON, or no single live transition into the target status.
#
# Env:
#   ISSUES_JIRA_API   a jira-api.sh-shaped wrapper understanding
#                     `raw GET <path>` and printing the body on stdout (or
#                     --jira-api PATH). This plugin ships one at
#                     providers/tracker/jira/jira-api.sh. Export
#                     JIRA_HOST=127.0.0.1 for any test — never point a test
#                     wrapper at a live host.
#   HERDR_ENV         must be "1".
#   HERDR_JIRA_PROGRESS_STATUS   --jira-progress-status wins over it.
#   HERDR_BRIEF_TEMPLATE         overrides the brief template path.
#   NW_DRY_RUN        "1" behaves as --dry-run.
#   HERDR_EXECUTOR_FIELD      default: customfield_10047
#   HERDR_EXECUTOR_AGENT_ID   default: 10020  (unattended agent allowed)
#   HERDR_EXECUTOR_HUMAN_ID   default: 10021  (refuse: needs a person)
#   HERDR_EXECUTOR_MIXED_ID   default: 10022  (refuse: needs a person)
#   The executor field id and its option ids are specific to the Jira
#   instance this is pointed at; no universal default exists.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

# stop2 — exit 2: a precondition could not be evaluated at all.
stop2() { echo "Error: $*" >&2; exit 2; }

EXECUTOR_FIELD="${HERDR_EXECUTOR_FIELD:-customfield_10047}"
EXECUTOR_AGENT_ID="${HERDR_EXECUTOR_AGENT_ID:-10020}"
EXECUTOR_HUMAN_ID="${HERDR_EXECUTOR_HUMAN_ID:-10021}"
EXECUTOR_MIXED_ID="${HERDR_EXECUTOR_MIXED_ID:-10022}"
JIRA_API="${ISSUES_JIRA_API:-}"
PROGRESS_STATUS="${HERDR_JIRA_PROGRESS_STATUS:-}"
BRIEF_TEMPLATE="${HERDR_BRIEF_TEMPLATE:-$HERE/../../../templates/dispatch-brief.md}"
TIMEBOX=""
FORBIDDEN=""

TICKET_ARG=""
MODEL="sonnet"
DRY_RUN=0
[ "${NW_DRY_RUN:-0}" = 1 ] && DRY_RUN=1
WAIT_MODE="bounded"

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|help) show_help ;;
        --model)
            [ $# -ge 2 ] || die "--model needs an argument: sonnet, opus or haiku (see --help)"
            MODEL="$2"
            shift 2
            ;;
        --jira-api)
            [ $# -ge 2 ] || die "--jira-api needs a path"
            JIRA_API="$2"
            shift 2
            ;;
        --jira-progress-status)
            [ $# -ge 2 ] || die "--jira-progress-status needs a status id"
            PROGRESS_STATUS="$2"
            shift 2
            ;;
        --timebox)
            [ $# -ge 2 ] || die "--timebox needs text, e.g. \"3 hours\""
            TIMEBOX="$2"
            shift 2
            ;;
        --forbidden)
            [ $# -ge 2 ] || die "--forbidden needs text"
            FORBIDDEN="${FORBIDDEN:+$FORBIDDEN$'\n'}- $2"
            shift 2
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        --wait) WAIT_MODE="full"; shift ;;
        --no-wait) WAIT_MODE="none"; shift ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *)
            [ -z "$TICKET_ARG" ] || die "unexpected extra argument: $1 (see --help)"
            TICKET_ARG="$1"
            shift
            ;;
    esac
done

[ -n "$TICKET_ARG" ] || die "usage: herdr-ticket-start.sh <ticket-id> [--model sonnet|opus|haiku] [--wait|--no-wait] [--dry-run] [--jira-api PATH] (see --help)"

case "$MODEL" in
    sonnet|opus|haiku) ;;
    *) die "--model must be one of sonnet, opus, haiku (got '$MODEL')" ;;
esac
[ -n "$PROGRESS_STATUS" ] || die "--jira-progress-status is required (or \$HERDR_JIRA_PROGRESS_STATUS) — the STATUS id of In Progress (e.g. 3), not a transition id (e.g. 21); no default exists across trackers"
case "$PROGRESS_STATUS" in
    *[!0-9]*) die "--jira-progress-status must be numeric (got '$PROGRESS_STATUS')" ;;
esac

[ "${HERDR_ENV:-}" = "1" ] || die "HERDR_ENV is not 1 — this must run inside a Herdr-managed session"

TICKET_UPPER=$(printf '%s' "$TICKET_ARG" | tr '[:lower:]' '[:upper:]')
BRANCH=$(printf '%s' "$TICKET_ARG" | tr '[:upper:]' '[:lower:]')
case "$TICKET_UPPER" in
    *[!A-Za-z0-9_-]*) die "ticket id '$TICKET_ARG' contains characters that are not letters, digits, '_' or '-' (see --help)" ;;
esac
case "$TICKET_UPPER" in
    [A-Z]*-[0-9]*) ;;
    *) die "ticket id '$TICKET_ARG' does not look like PROJ-### (see --help)" ;;
esac

command -v herdr >/dev/null 2>&1 || stop2 "'herdr' is not on PATH"
command -v jq >/dev/null 2>&1 || stop2 "'jq' is not on PATH"
command -v git >/dev/null 2>&1 || stop2 "'git' is not on PATH"

CFG_LIB="$HERE/../../lib/config.sh"
CFG_PROJECT=""
CFG_CLOUD_ID=""
if [ -f "$CFG_LIB" ]; then
    # shellcheck source=../../lib/config.sh
    . "$CFG_LIB"
    [ -n "$TIMEBOX" ] || TIMEBOX=$(nw_config_get dispatch.brief.timebox "" 2>/dev/null) || true
    if [ -z "$FORBIDDEN" ]; then
        CFG_FORBIDDEN=$(nw_config_get dispatch.brief.forbidden "" 2>/dev/null) || true
        [ -z "$CFG_FORBIDDEN" ] || FORBIDDEN="- $CFG_FORBIDDEN"
    fi
    CFG_PROJECT=$(nw_config_get tracker.jira.project "" 2>/dev/null) || true
    CFG_CLOUD_ID=$(nw_config_get dispatch.brief.cloud_id "" 2>/dev/null) || true
fi
[ -n "$TIMEBOX" ] || die "no TIMEBOX: pass --timebox TEXT or set [dispatch.brief] timebox — an incomplete brief is never sent"
[ -n "$FORBIDDEN" ] || die "no FORBIDDEN: pass --forbidden TEXT (repeatable) or set [dispatch.brief] forbidden — an incomplete brief is never sent"
TRACKER_LINE="Jira project ${CFG_PROJECT:-${TICKET_UPPER%%-*}}; API wrapper ${JIRA_API:-unset} (raw GET/POST /issue/$TICKET_UPPER...); status ids, not transition ids"
[ -z "$CFG_CLOUD_ID" ] || TRACKER_LINE="$TRACKER_LINE; connector cloud id $CFG_CLOUD_ID"
TEMPLATE_BODY=$(awk 'f{print; next} /^# /{f=1; print}' "$BRIEF_TEMPLATE" 2>/dev/null) || stop2 "cannot read brief template $BRIEF_TEMPLATE"
[ -n "$TEMPLATE_BODY" ] || stop2 "brief template $BRIEF_TEMPLATE is missing or has no heading"
PROMPT_TEXT=${TEMPLATE_BODY//@KEY@/$TICKET_UPPER}
PROMPT_TEXT=${PROMPT_TEXT//@BRANCH@/$BRANCH}
PROMPT_TEXT=${PROMPT_TEXT//@MODEL@/$MODEL}
PROMPT_TEXT=${PROMPT_TEXT//@TRACKER@/$TRACKER_LINE}
PROMPT_TEXT=${PROMPT_TEXT//@TIMEBOX@/$TIMEBOX}
PROMPT_TEXT=${PROMPT_TEXT//@FORBIDDEN@/$FORBIDDEN}
ORCH_PANE_ID="${HERDR_PANE_ID:-}"
PROMPT_TEXT="$PROMPT_TEXT

## CLOSING STATE
Before you stop, write \`.night-watchman/closing-state.md\` in your worktree (do not commit it) with \`## Human run list\` (required if this ticket's executor is human or mixed), \`## Left undone\` and \`## Findings\` sections: what you deliberately left undone and why, and anything you noticed but did not act on, including outside this ticket's scope.${ORCH_PANE_ID:+ Add the line \`orchestrator-pane: $ORCH_PANE_ID\` so landing can notify the orchestrator.} land-branch.sh writes it to the tracker and confirms the write before your session ends."

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || stop2 "not inside a git repository"
cd "$REPO"

[ -n "$JIRA_API" ] || stop2 "no Jira API wrapper — pass --jira-api PATH (or set \$ISSUES_JIRA_API); this plugin's default lives at providers/tracker/jira/jira-api.sh"
[ -x "$JIRA_API" ] || stop2 "Jira API wrapper is missing or not executable: $JIRA_API"

# stderr is captured separately, never merged with 2>&1: a benign stderr line
# on an otherwise-successful read would corrupt the JSON.
JIRA_ERR=$(tmpfile) || stop2 "could not create a temp file for jira-api diagnostics"
if ! ISSUE_JSON=$("$JIRA_API" raw GET "/issue/$TICKET_UPPER?fields=summary,status,$EXECUTOR_FIELD" 2>"$JIRA_ERR"); then
    stop2 "could not read Jira issue $TICKET_UPPER (GET /issue/$TICKET_UPPER) — is it open? jira-api said:
$(cat "$JIRA_ERR" 2>/dev/null)"
fi
printf '%s' "$ISSUE_JSON" | jq -e . >/dev/null 2>&1 \
    || stop2 "GET /issue/$TICKET_UPPER did not return valid JSON"

TITLE=$(printf '%s' "$ISSUE_JSON" | jq -r '.fields.summary // empty' 2>/dev/null) || TITLE=""
[ -n "$TITLE" ] || stop2 "GET /issue/$TICKET_UPPER returned no 'summary' field — not a Jira issue response?"
STATUS_ID=$(printf '%s' "$ISSUE_JSON" | jq -r '.fields.status.id // empty' 2>/dev/null) || STATUS_ID=""
STATUS_NAME=$(printf '%s' "$ISSUE_JSON" | jq -r '.fields.status.name // empty' 2>/dev/null) || STATUS_NAME=""
[ -n "$STATUS_ID" ] || stop2 "GET /issue/$TICKET_UPPER returned no status id — not a Jira issue response?"

EXECUTOR_ID=$(printf '%s' "$ISSUE_JSON" | jq -r --arg f "$EXECUTOR_FIELD" '.fields[$f].id // empty' 2>/dev/null) || EXECUTOR_ID=""
if [ -n "$EXECUTOR_ID" ] && [ "$EXECUTOR_ID" = "$EXECUTOR_AGENT_ID" ]; then
    EXECUTOR=agent
elif [ -n "$EXECUTOR_ID" ] && [ "$EXECUTOR_ID" = "$EXECUTOR_HUMAN_ID" ]; then
    EXECUTOR=human
elif [ -n "$EXECUTOR_ID" ] && [ "$EXECUTOR_ID" = "$EXECUTOR_MIXED_ID" ]; then
    EXECUTOR=mixed
else
    EXECUTOR="$EXECUTOR_ID"
fi

case "$EXECUTOR" in
    agent) ;;
    human|mixed)
        die "$TICKET_UPPER's executor is '$EXECUTOR' — refusing to start an unattended Herdr agent on it (only 'agent' tickets qualify)"
        ;;
    *)
        stop2 "$TICKET_UPPER's executor custom field ($EXECUTOR_FIELD) is '${EXECUTOR:-<unset>}', not one of agent/human/mixed — could not evaluate (unrecognized or unset value)"
        ;;
esac

# `open_workspace_id` is null when the worktree exists with no workspace open
# — refusal #4, not idempotency. `is_linked_worktree` excludes the primary.
LISTING_ERR=$(tmpfile) || stop2 "could not create a temp file for 'herdr worktree list' diagnostics"
if ! LISTING=$(herdr worktree list --cwd "$REPO" 2>"$LISTING_ERR"); then
    stop2 "'herdr worktree list --cwd $REPO' failed: $(cat "$LISTING_ERR" 2>/dev/null)"
fi
printf '%s' "$LISTING" | jq -e . >/dev/null 2>&1 \
    || stop2 "'herdr worktree list' did not return valid JSON: $LISTING"

MATCH_COUNT=$(printf '%s' "$LISTING" | jq -r --arg b "$BRANCH" '
    [ (.result.worktrees // [])[] | select(.is_linked_worktree == true and .branch == $b) ] | length
') || MATCH_COUNT=""
case "$MATCH_COUNT" in
    '' | *[!0-9]*) stop2 "could not parse 'herdr worktree list' output for branch '$BRANCH'" ;;
esac

case "$MATCH_COUNT" in
    0) ;;
    1)
        WS_ID=$(printf '%s' "$LISTING" | jq -r --arg b "$BRANCH" '
            [ (.result.worktrees // [])[] | select(.is_linked_worktree == true and .branch == $b) ][0].open_workspace_id // empty
        ') || WS_ID=""
        if [ -n "$WS_ID" ]; then
            echo "a herdr workspace already exists for branch '$BRANCH' (workspace $WS_ID) — nothing to do."
            exit 0
        fi
        die "a herdr worktree for branch '$BRANCH' already exists with no open workspace — land it (scripts/land-branch.sh) or remove it (herdr worktree remove) before retrying"
        ;;
    *)
        die "more than one herdr worktree matches branch '$BRANCH' — refusing to guess"
        ;;
esac

git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null 2>&1 \
    && die "branch '$BRANCH' already exists locally (git branch --list) with no herdr worktree — resolve it by hand before retrying"

# Resolved before anything is created, so a workflow with no single
# transition into the target refuses with nothing to clean up.
TRANSITION_ID=""
TRANSITION_TO=""
if [ "$STATUS_ID" != "$PROGRESS_STATUS" ]; then
    if ! TRANSITIONS_JSON=$("$JIRA_API" raw GET "/issue/$TICKET_UPPER/transitions" 2>"$JIRA_ERR"); then
        stop2 "could not list transitions for $TICKET_UPPER (GET /issue/$TICKET_UPPER/transitions) — nothing created. jira-api said:
$(cat "$JIRA_ERR" 2>/dev/null)"
    fi
    MATCH=$(printf '%s' "$TRANSITIONS_JSON" | jq -r --arg s "$PROGRESS_STATUS" '
        [ (.transitions // [])[] | select((.to.id|tostring) == $s) ]
        | length as $n
        | if $n == 1 then "\(.[0].id)\t\(.[0].to.name)" else "COUNT \($n)" end
    ' 2>/dev/null) || MATCH=""
    case "$MATCH" in
        "COUNT 0") stop2 "$TICKET_UPPER ('$STATUS_NAME') has no transition to status id $PROGRESS_STATUS — nothing created; fix the workflow or the status id" ;;
        COUNT*)    stop2 "$TICKET_UPPER has more than one transition to status id $PROGRESS_STATUS — nothing created; refusing to guess" ;;
        "")        stop2 "could not parse GET /issue/$TICKET_UPPER/transitions — nothing created" ;;
    esac
    TRANSITION_ID=$(printf '%s' "$MATCH" | cut -f1)
    TRANSITION_TO=$(printf '%s' "$MATCH" | cut -f2-)
    case "$TRANSITION_ID" in
        ''|*[!0-9]*) stop2 "resolved transition id '$TRANSITION_ID' is not numeric — nothing created" ;;
    esac
fi

LABEL="$TICKET_UPPER $TITLE"

PROMPT_ARGS=()
case "$WAIT_MODE" in
    bounded)
        PROMPT_ARGS=(--wait --until working --timeout 60000)
        WAIT_SUFFIX=" --wait --until working --timeout 60000"
        ;;
    full)
        PROMPT_ARGS=(--wait --timeout 3600000)
        WAIT_SUFFIX=" --wait --timeout 3600000"
        ;;
    none)
        PROMPT_ARGS=()
        WAIT_SUFFIX=""
        ;;
esac

if [ "$DRY_RUN" = 1 ]; then
    echo "Plan for $TICKET_UPPER (model: $MODEL, branch: $BRANCH):"
    echo "  1. herdr worktree create --cwd \"$REPO\" --branch \"$BRANCH\" --label \"$LABEL\" --no-focus"
    echo "  2. herdr agent start \"$BRANCH\" --kind claude --pane <pane-from-step-1> -- --model \"$MODEL\""
    echo "  3. herdr agent prompt \"$BRANCH\" <brief below>$WAIT_SUFFIX"
    if [ -n "$TRANSITION_ID" ]; then
        echo "  4. transition $TICKET_UPPER '$STATUS_NAME' -> '$TRANSITION_TO': POST /issue/$TICKET_UPPER/transitions {\"transition\":{\"id\":\"$TRANSITION_ID\"}} (resolved from target status $PROGRESS_STATUS), then read back"
    else
        echo "  4. $TICKET_UPPER is already '$STATUS_NAME' (status $PROGRESS_STATUS) — no transition"
    fi
    echo
    echo "Brief:"
    printf '%s\n' "$PROMPT_TEXT"
    echo
    echo "--dry-run: stopping before any herdr-mutating command or tracker write. Nothing was created or sent."
    exit 0
fi

echo "Creating herdr worktree for branch '$BRANCH'..."
CREATE_JSON=$(herdr worktree create --cwd "$REPO" --branch "$BRANCH" --label "$LABEL" --no-focus) \
    || die "'herdr worktree create' failed"
printf '%s' "$CREATE_JSON" | jq -e . >/dev/null 2>&1 \
    || die "'herdr worktree create' did not return valid JSON: $CREATE_JSON"
PANE=$(printf '%s' "$CREATE_JSON" | jq -r '.result.root_pane.pane_id // empty') || PANE=""
[ -n "$PANE" ] || die "'herdr worktree create' returned no .result.root_pane.pane_id — a workspace may have been half-created; check 'herdr worktree list --cwd $REPO' by hand"

echo "Starting Claude (model: $MODEL) on pane $PANE..."
START_ERR=$(tmpfile) || die "could not create a temp file for 'herdr agent start' diagnostics"
if ! herdr agent start "$BRANCH" --kind claude --pane "$PANE" -- --model "$MODEL" 2>"$START_ERR"; then
    START_ERR_TEXT=$(cat "$START_ERR" 2>/dev/null) || START_ERR_TEXT=""
    case "$START_ERR_TEXT" in
        *agent_not_ready*)
            PANE_TEXT=$(herdr agent read "$PANE" --source visible 2>/dev/null) || PANE_TEXT=""
            case "$PANE_TEXT" in
                *"Is this a project you created or one you trust"*"Yes, I trust this folder"*)
                    echo "$TICKET_UPPER: detected Claude's folder-trust dialog on pane $PANE — answering it (Down, Enter)."
                    herdr agent send-keys "$PANE" Down Enter \
                        || die "'herdr agent send-keys $PANE Down Enter' failed while answering the folder-trust dialog — the worktree and pane were already created; check '$BRANCH' by hand, it was not cleaned up automatically"
                    herdr agent wait "$PANE" --until idle --timeout 60000 \
                        || die "the agent on pane $PANE did not reach idle within 60s after answering the folder-trust dialog — the worktree and pane were already created; check '$BRANCH' by hand, it was not cleaned up automatically"
                    ;;
                *)
                    die "'herdr agent start' failed with agent_not_ready, but pane $PANE showed no folder-trust dialog — the worktree was already created (pane $PANE); check it by hand, it was not cleaned up automatically. herdr said: $START_ERR_TEXT"
                    ;;
            esac
            ;;
        *)
            die "'herdr agent start' failed — the worktree was already created (pane $PANE); check it by hand, it was not cleaned up automatically. herdr said: $START_ERR_TEXT"
            ;;
    esac
fi

echo "Handing $TICKET_UPPER's brief to '$BRANCH'..."
# 2>&1 is deliberate: the die message must carry herdr's own error text.
# bash 3.2: "${arr[@]}" on an empty array errors under set -u, hence the guard.
if [ ${#PROMPT_ARGS[@]} -gt 0 ]; then
    PROMPT_OUT=$(herdr agent prompt "$BRANCH" "$PROMPT_TEXT" "${PROMPT_ARGS[@]}" 2>&1) && PROMPT_RC=0 || PROMPT_RC=$?
else
    PROMPT_OUT=$(herdr agent prompt "$BRANCH" "$PROMPT_TEXT" 2>&1) && PROMPT_RC=0 || PROMPT_RC=$?
fi
if [ "$PROMPT_RC" != 0 ]; then
    die "'herdr agent prompt' failed (exit $PROMPT_RC) — the worktree and agent were already created; check '$BRANCH' by hand. herdr said: $PROMPT_OUT"
fi
[ -n "$PROMPT_OUT" ] && printf '%s\n' "$PROMPT_OUT"

echo "$TICKET_UPPER: herdr workspace and agent started on branch '$BRANCH' (pane $PANE, model $MODEL)."

if [ -z "$TRANSITION_ID" ]; then
    echo "$TICKET_UPPER is already '$STATUS_NAME' — no transition."
    exit 0
fi
echo "Transitioning $TICKET_UPPER ('$STATUS_NAME' -> '$TRANSITION_TO')..."
POST_OK=1
"$JIRA_API" --yes write POST "/issue/$TICKET_UPPER/transitions" "{\"transition\":{\"id\":\"$TRANSITION_ID\"}}" >/dev/null 2>"$JIRA_ERR" || POST_OK=0
POST_ERR=$(cat "$JIRA_ERR" 2>/dev/null) || POST_ERR=""
if ! AFTER_JSON=$("$JIRA_API" raw GET "/issue/$TICKET_UPPER?fields=status" 2>"$JIRA_ERR"); then
    die "$TICKET_UPPER: the agent is running on '$BRANCH', but $TICKET_UPPER could not be read back after the In Progress transition (POST $([ "$POST_OK" = 1 ] && echo ok || echo FAILED)) — check its status by hand. jira-api said:
$POST_ERR$(cat "$JIRA_ERR" 2>/dev/null)"
fi
AFTER_ID=$(printf '%s' "$AFTER_JSON" | jq -r '.fields.status.id // empty' 2>/dev/null) || AFTER_ID=""
AFTER_NAME=$(printf '%s' "$AFTER_JSON" | jq -r '.fields.status.name // empty' 2>/dev/null) || AFTER_NAME=""
if [ "$POST_OK" != 1 ]; then
    die "$TICKET_UPPER: the agent is running on '$BRANCH', but the transition to '$TRANSITION_TO' failed; $TICKET_UPPER reads back as '$AFTER_NAME'. Move it by hand and say so in the ticket. jira-api said:
$POST_ERR"
fi
[ "$AFTER_ID" = "$PROGRESS_STATUS" ] \
    || die "$TICKET_UPPER: the agent is running on '$BRANCH', but after a 2xx transition POST $TICKET_UPPER reads back as '$AFTER_NAME', not status $PROGRESS_STATUS. Move it by hand and say so in the ticket"
echo "transitioned; read-back confirms '$AFTER_NAME'."
exit 0
