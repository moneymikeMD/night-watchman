#!/bin/bash
#
# herdr-ticket-start.sh — one command that opens a Herdr git-worktree
# workspace for an open ticket, starts a Claude agent in it PINNED to a
# chosen model, and hands it the ticket's session-start brief.
#
# OPTIONAL LAYER, ported from a production system: this plugin does not
# ship or require Herdr (see the README's "optional layers"). It exists to
# enforce the model choice structurally instead of relying on someone
# remembering the `-- --model sonnet` flag by hand — a plain `claude`
# inherits the OWNER's global default model from ~/.claude/settings.json,
# which is easy to forget when a worktree-dispatch tool is starting several
# unattended agent processes back to back.
#
# Usage:
#   herdr-ticket-start.sh <ticket-id> --jira-progress-status ID [--model sonnet|opus|haiku] [--timebox TEXT] [--forbidden TEXT]... [--wait|--no-wait] [--dry-run]
#   herdr-ticket-start.sh --help
#
# BRIEF. Step 3 sends a complete brief rendered from templates/dispatch-brief.md
# ($HERDR_BRIEF_TEMPLATE overrides): TRACKER, TIMEBOX, FORBIDDEN, REPORT and
# STANDING, so no second prompt is needed for the initial brief. STANDING
# lives only in the template, which the session-start skill points at; the
# script must run from any checkout and cannot depend on the skill's path.
# --timebox TEXT and --forbidden TEXT (repeatable) give the per-ticket lines;
# defaults come from [dispatch.brief] `timebox` and `forbidden` in the
# config. If either is empty the script dies naming it before any herdr
# call. The TRACKER line carries the --jira-api path, the project key and
# [dispatch.brief] `cloud_id` if set. --dry-run prints the full brief.
#
# REQUIRED INPUTS. Export ISSUES_JIRA_API (or pass --jira-api PATH) or the
# script dies before doing anything. --jira-progress-status takes the STATUS
# id of In Progress (e.g. 3), NOT the transition id (e.g. 21).
#
# LIFECYCLE. A ticket is In Progress from the moment it is dispatched. After
# the brief hand-off returns (observed `working`, by default), the ticket is
# transitioned to In Progress, resolved BY TARGET STATUS: --jira-progress-status
# ID (or $HERDR_JIRA_PROGRESS_STATUS; required, no default — every tracker's
# workflow ids differ) is matched against the issue's live transitions list,
# and zero or several matches are refused before anything is created. The
# issue is read back after the POST; a 2xx is not proof. Already In Progress
# is a no-op. A failed transition exits 1 naming the ticket and leaves the
# agent running. --dry-run (or NW_DRY_RUN=1) prints the transition and sends
# nothing. The idempotent exit below (workspace already open) transitions
# nothing.
#
# <ticket-id> is matched case-insensitively against the Jira issue of the
# same key (e.g. `proj-123` and `PROJ-123` both resolve to the Jira issue
# PROJ-123 via `--jira-api PATH raw GET /issue/PROJ-123?fields=summary,
# <executor-field>` — see JIRA API below). The title and executor always
# come from Jira, never a local file. The branch, the herdr worktree label,
# and the herdr agent name are all the LOWERCASED id (e.g. `proj-123`) —
# matching the convention in this plugin's session-start skill,
# "Dispatching a wave through a worktree-dispatch tool".
#
# --model defaults to sonnet (the cost-efficient choice for a worker agent).
# Refused outright if it is anything else — this is the one flag the script
# exists to make impossible to skip, so an unresolvable value is a hard
# refusal, not a fallback to the caller's shell default.
#
# --no-wait / --wait: step 3's `herdr agent prompt` can block the CALLER —
# not the agent — for up to an hour when run with `--wait --timeout
# 3600000`. That makes a wave of tickets impossible to fan out with
# sequential calls: the first call would not return until its agent
# finished or the hour expired, so a second ticket could not even be
# started.
#
# The DEFAULT is a BOUNDED wait, not no wait at all: step 3 runs
# `--wait --until working --timeout 60000`, so the call returns as soon as
# herdr observes the agent reach `working` (normally a few seconds), and
# fails loudly — carrying herdr's own error text (agent_prompt_stalled,
# agent_blocked, or timeout; see `herdr agent prompt --help`) — if that is
# not observed within 60s. This closes the pane-readiness race: the prompt
# is handed off AND the script confirms the agent actually started working
# on it, in well under a minute, instead of either blocking for an hour or
# returning the instant the transport accepted the text with no
# confirmation it was ever read.
#
# --wait is the explicit opt-in that restores the old fully-blocking
# behaviour (`--wait --timeout 3600000`, no `--until`, so it settles on the
# first idle/done/blocked), for the case of starting one ticket and
# watching it to completion in the same call.
#
# --no-wait opts OUT of the bounded wait entirely: step 3 hands off the
# brief with no `--wait` flag at all and returns as soon as the transport
# accepts it, with no confirmation the agent ever started. Use it only when
# even the ~60s bounded wait is unacceptable (e.g. fanning out a very large
# wave and accepting the pane-readiness race as a known risk).
#
# --wait and --no-wait are mutually exclusive; when both are passed, the
# LAST one on the command line wins (ordinary shell flag-parsing
# last-writer semantics — this script does not special-case the
# combination or refuse it).
#
# Refusals (checked in this order, before anything is created):
#   1. --model is not sonnet/opus/haiku, or --jira-progress-status is
#      missing or not numeric.
#   2. HERDR_ENV is not "1" — this script only makes sense run from inside a
#      Herdr-managed session; a plain shell has no worktree/pane model to
#      hang a workspace off.
#   3. The Jira issue's executor custom field (see JIRA API below) resolves
#      to anything other than `agent` — `human` and `mixed` tickets need a
#      person in the loop and must never get an unattended agent.
#   4. The branch already exists — either as a herdr worktree (checked via
#      `herdr worktree list --cwd`) or as a plain local git branch with no
#      worktree at all.
#
# Idempotency: if a herdr workspace is ALREADY open on the target branch
# (`herdr worktree list`'s `open_workspace_id` for that branch is non-null),
# this is not treated as refusal #4 — it prints that the workspace already
# exists and exits 0. A branch/worktree that exists with NO open workspace
# is refusal #4 (something needs to be resolved by hand — land it or remove
# it — before starting fresh).
#
# --dry-run runs every check above (including the idempotency check, so a
# dry run against an existing workspace reports that too, not a fake plan)
# then prints the three herdr commands it would run, fully substituted, and
# exits 0. No herdr command that could create or change anything runs during
# a dry run. The one placeholder is the pane id in step 2's command: that
# value only exists once step 1 has actually run, so a dry run prints
# `<pane-from-step-1>` in its place.
#
# What actually runs, in order, on a real (non-dry-run) invocation:
#   1. herdr worktree create --cwd <repo-root> --branch <branch>
#        --label "<TICKET-ID> <title>" --no-focus
#      -> reads .result.root_pane.pane_id
#   2. herdr agent start <branch> --kind claude --pane <pane> -- --model <model>
#      If this fails with agent_not_ready, the pane is read (`herdr agent
#      read <pane> --source visible`) for Claude Code's folder-trust dialog
#      markers ("Is this a project you created or one you trust" / "Yes, I
#      trust this folder") — seen on a fresh Herdr worktree on some hosts,
#      not others. If found, `herdr agent send-keys <pane> Down
#      Enter` answers it and the script waits (`herdr agent wait <pane>
#      --until idle --timeout 60000`) before continuing to step 3. Any other
#      agent_not_ready cause, or a pane with no dialog markers, aborts
#      exactly as any other agent-start failure.
#   3. herdr agent prompt <branch> "<standard brief>"
#      (the brief text points at this ticket's Jira issue key, matching the
#      session-start skill's "Dispatching a wave through a worktree-dispatch
#      tool" section — no file path, the brief tells the agent to look the
#      ticket up in Jira. By default this carries `--wait --until working
#      --timeout 60000` and blocks the caller only until the agent is
#      observed working, or dies with herdr's own error (agent_prompt_stalled
#      / agent_blocked / timeout) if that is not seen within 60s. With
#      --wait, it instead carries `--wait --timeout 3600000` (no --until)
#      and blocks the caller until the agent settles (idle/done/blocked) or
#      the hour expires. With --no-wait, it carries no --wait flag at all
#      and the command returns as soon as the prompt is handed off, with no
#      confirmation the agent ever started)
#   4. <jira-api> --yes write POST /issue/<KEY>/transitions (the transition
#      into --jira-progress-status), then raw GET /issue/<KEY>?fields=status
#      to confirm — skipped when the issue is already in that status
#
# Exit codes (this plugin's land-branch.sh's own pattern):
#   0   started cleanly, OR a workspace for this branch already exists
#       (idempotent no-op), OR --dry-run printed its plan.
#   1   a check failed: bad --model or --jira-progress-status, a human/mixed
#       ticket, the branch/worktree trap, an ambiguous multiple-match, a herdr
#       command that ran but failed partway through (worktree create/agent
#       start/agent prompt) — message says what was and was not created so it
#       can be cleaned up by hand — or the In Progress transition failing or
#       not reading back (the agent is left running).
#   2   could not evaluate: `herdr`, `jq` or `git` missing from PATH, the
#       jira-api wrapper missing/not executable, the Jira issue unreadable or
#       missing a `summary` field, or its executor custom field carrying an
#       unrecognized value (neither agent/human/mixed — including unset/
#       null), a herdr JSON response that could not be parsed, or no single
#       live transition into the In Progress status.
#
# JIRA API. This plugin ships a default Jira client at
# providers/tracker/jira/jira-api.sh (see providers/README.md and
# land-branch.sh's own --jira-api). Point this script at it, or another
# wrapper, the same way:
#   --jira-api PATH  (or $ISSUES_JIRA_API) — a jira-api.sh-shaped wrapper
#     understanding `raw GET <path>`, printing the response body on stdout.
#
# The executor custom field id and its three option ids are themselves
# specific to whichever Jira instance this is pointed at — no universal
# default exists across projects — so they are configurable, defaulting to
# the values this script was ported with:
#   HERDR_EXECUTOR_FIELD       default: customfield_10047
#   HERDR_EXECUTOR_AGENT_ID    default: 10020  (unattended agent allowed)
#   HERDR_EXECUTOR_HUMAN_ID    default: 10021  (refuse: needs a person)
#   HERDR_EXECUTOR_MIXED_ID    default: 10022  (refuse: needs a person)
#
# Env:
#   HERDR_ENV        must be "1" (see refusal #2 above). Not read for
#                     anything else.
#   HERDR_JIRA_PROGRESS_STATUS  see LIFECYCLE above; --jira-progress-status wins.
#   NW_DRY_RUN       "1" behaves as --dry-run.
#   ISSUES_JIRA_API   see JIRA API above. Export JIRA_HOST=127.0.0.1 (or
#                     whatever env var your wrapper honours) for any test —
#                     never point a test wrapper at a live host.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

# stop2 — a precondition could not be evaluated at all (tool missing, file
# unreadable, unparseable JSON). Distinct from die() (exit 1, "a check
# failed") per this script's own exit-code contract above — same split
# land-branch.sh's stop2 uses.
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

# ------------------------------------------------------------------- parse

TICKET_ARG=""
MODEL="sonnet"
DRY_RUN=0
[ "${NW_DRY_RUN:-0}" = 1 ] && DRY_RUN=1
# WAIT_MODE — one of "bounded" (default), "full" (--wait), "none" (--no-wait).
# --wait/--no-wait are mutually exclusive; the case statement below applies
# them in argv order, so the LAST one wins (last-writer, not a special-cased
# "no-op" — see the header comment on --no-wait above).
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

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || stop2 "not inside a git repository"
cd "$REPO"

[ -n "$JIRA_API" ] || stop2 "no Jira API wrapper — pass --jira-api PATH (or set \$ISSUES_JIRA_API); this plugin's default lives at providers/tracker/jira/jira-api.sh"
[ -x "$JIRA_API" ] || stop2 "Jira API wrapper is missing or not executable: $JIRA_API"

# ---------------------------------------------------------------- jira read
#
# The title and executor come from the Jira issue, never a local file.
# stderr is captured SEPARATELY, not merged with 2>&1 — a benign stderr
# line on an otherwise-successful read would corrupt the JSON, the same
# trap land-branch.sh's jira_read documents.
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

# ------------------------------------------------------- idempotency check
#
# The array lives at .result.worktrees[], `branch` is the SHORT name (no
# refs/heads/ prefix), and the workspace id field is `open_workspace_id`,
# which is `null` when the worktree exists but has no workspace open on it
# right now — that is refusal #4, not idempotency. Matched on `.branch` AND
# `.is_linked_worktree == true` together, same as land-branch.sh's own
# workspace-removal lookup, so the repo's primary worktree ("main",
# is_linked_worktree=false) or a same-named decoy can never match. stderr is
# captured SEPARATELY, not merged with 2>&1 — a benign stderr line on an
# otherwise-successful call would corrupt the JSON in $LISTING and this
# would then report "invalid JSON" for a call that actually worked.
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

# No herdr worktree at all — still check for a bare local git branch with
# the same name (e.g. created by hand, never turned into a worktree).
git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null 2>&1 \
    && die "branch '$BRANCH' already exists locally (git branch --list) with no herdr worktree — resolve it by hand before retrying"

# ------------------------------------------------- resolve the In Progress move
#
# Resolved now, before anything is created, so a workflow with no single
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

# PROMPT_ARGS / WAIT_SUFFIX — the extra herdr flags step 3 runs with
# (PROMPT_ARGS, an array — used for the real call) and prints (WAIT_SUFFIX,
# its string form — used for the --dry-run plan). "bounded" is the default,
# a wait capped at 60s for the agent to be observed `working` (closes the
# pane-readiness race without reintroducing the up-to-an-hour block); "full"
# (--wait) restores the old settle-on-idle/done/blocked wait up to an hour;
# "none" (--no-wait) sends the prompt and returns immediately with no
# confirmation.
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

# ---------------------------------------------------------------- dry run

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

# -------------------------------------------------------------------- run

echo "Creating herdr worktree for branch '$BRANCH'..."
CREATE_JSON=$(herdr worktree create --cwd "$REPO" --branch "$BRANCH" --label "$LABEL" --no-focus) \
    || die "'herdr worktree create' failed"
printf '%s' "$CREATE_JSON" | jq -e . >/dev/null 2>&1 \
    || die "'herdr worktree create' did not return valid JSON: $CREATE_JSON"
PANE=$(printf '%s' "$CREATE_JSON" | jq -r '.result.root_pane.pane_id // empty') || PANE=""
[ -n "$PANE" ] || die "'herdr worktree create' returned no .result.root_pane.pane_id — a workspace may have been half-created; check 'herdr worktree list --cwd $REPO' by hand"

echo "Starting Claude (model: $MODEL) on pane $PANE..."
# agent_not_ready can mean Claude Code is showing its folder-trust dialog on
# a fresh worktree (observed on linux-host) rather than any
# real startup failure. stderr is captured SEPARATELY so the detection below
# can inspect herdr's own error text without disturbing stdout.
START_ERR=$(tmpfile) || die "could not create a temp file for 'herdr agent start' diagnostics"
if ! herdr agent start "$BRANCH" --kind claude --pane "$PANE" -- --model "$MODEL" 2>"$START_ERR"; then
    START_ERR_TEXT=$(cat "$START_ERR" 2>/dev/null) || START_ERR_TEXT=""
    case "$START_ERR_TEXT" in
        *agent_not_ready*)
            # Read the pane and look for the trust dialog's own markers —
            # detection by pane text, not by editing any Claude config file
            # (see the ticket's Decisions: parent-directory trust does not
            # inherit, so no config-side fix exists).
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
# Output (stdout+stderr) is captured rather than streamed, so a failure
# carries herdr's OWN error text (agent_prompt_stalled / agent_blocked /
# timeout) in the die message, not just a generic "failed" — the caller
# needs to know WHICH of those it was to decide what to do next.
# bash 3.2 (macOS default) treats "${arr[@]}" on a zero-element array as an
# unbound-variable error under `set -u`, even though the array itself was
# assigned empty — hence the count guard rather than a bare expansion.
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
