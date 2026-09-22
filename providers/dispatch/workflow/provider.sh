#!/bin/bash
#
# provider.sh — the `workflow` implementation of the `dispatch` provider kind
# (verbs: start, watch, stop — see ../../README.md for the contract and for
# the one place these semantics differ from herdr's).
#
# The dispatcher here is Claude Code's Workflow tool: subagents run
# IN-PROCESS, inside the orchestrating turn, under a deterministic script.
# A subprocess cannot call an in-process tool, so this provider owns the
# deterministic half — compose, record, report — and the orchestrating turn
# owns the half only it can perform: the Workflow launch and TaskStop. Every
# verb prints one JSON object on stdout, and the run journal under the state
# directory is the only thing that outlives the turn.
#
#   start  composes the brief and records the launch request. It does NOT
#          itself launch, and it opens no pane and creates no worktree: the
#          brief tells the agent to create its own, the way the 2026-09-19
#          wave ran.
#   watch  prints the recorded state of the run at the moment it is asked.
#          It does not block, and there is nothing for a human to look at.
#   stop   records a stop request and prints the TaskStop the turn must
#          issue. No process is killed, because none was started.
#
# Usage:
#   provider.sh start <ticket-id> (--ticket-file PATH | --executor agent)
#                     [--model sonnet|opus|haiku] [--worktree PATH]
#                     [--agent NAME] [--timebox TEXT] [--forbidden TEXT]...
#                     [--base BRANCH] [--dry-run]
#   provider.sh watch <ticket-id>
#   provider.sh stop  <ticket-id> [--reason TEXT]
#
# <ticket-id> is matched case-insensitively; the branch, the journal name and
# the agent name are all the LOWERCASED id (e.g. `wo-026`).
#
# An unattended start requires an executor assertion and there is no default:
# `--ticket-file` reads `executor:` from the ticket's frontmatter and wins
# over `--executor`, which is for callers whose tickets are not files. Only
# `agent` is dispatched; `human`/`mixed` are refused. There is no tracker
# read and no tracker write in any verb — the lifecycle transition stays with
# the caller, which is the second declared difference from herdr.
#
# The brief names the base branch the worker's worktree is cut from, rather
# than letting `worktree add -b` default to whatever the shared checkout has
# checked out (NWM-144). --base overrides the resolved default.
#
# State: $NW_DISPATCH_WORKFLOW_STATE, else [dispatch.workflow] state_dir in
# config, else $XDG_STATE_HOME/night-watchman/dispatch-workflow (falling back
# to ~/.local/state). One `<branch>.json` journal and one `<branch>.brief.md`
# per ticket. It lives OUTSIDE the repo deliberately: an untracked file inside
# a worktree dirties it, and land-branch.sh then refuses before reading
# anything.
#
# Env:
#   NW_DISPATCH_WORKFLOW_STATE     the state directory (wins over config).
#   NW_WORKFLOW_BRIEF_TEMPLATE     overrides the brief template path.
#   NW_DRY_RUN                     "1" behaves as --dry-run.
#
# Exit codes:
#   0   the verb completed, or start found an open request and re-composed
#       nothing, or --dry-run printed its plan.
#   1   a check failed (bad args, a non-agent executor, no recorded run, a
#       flag this dispatcher does not offer).
#   2   a precondition could not be evaluated (no jq or git, an unreadable
#       brief template or ticket file, an unwritable state directory, a
#       corrupt journal).
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/kit.sh
. "$DIR/../../lib/kit.sh"
# shellcheck source=../../lib/config.sh
. "$DIR/../../lib/config.sh"

# stop2 — exit 2: a precondition could not be evaluated at all.
stop2() { echo "Error: $*" >&2; exit 2; }

lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
uppercase() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

BRIEF_TEMPLATE="${NW_WORKFLOW_BRIEF_TEMPLATE:-$DIR/../../../templates/dispatch-brief.md}"

# base_branch REPO — the repo's tracked default branch. Same resolution as
# scripts/required-checks.sh's default_branch: origin/HEAD's symref, else main.
base_branch() {
    local b
    b=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || b=""
    [ -n "$b" ] && { printf '%s' "${b#origin/}"; return 0; }
    printf '%s' "main"
}

# base_ref REPO BRANCH — the ref a worktree branches FROM: the remote-tracking
# ref when there is one, else the local branch. Non-zero if neither exists,
# which start reports rather than falling back to HEAD.
base_ref() {
    local repo="$1" b="$2"
    git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null 2>&1 \
        && { printf '%s' "origin/$b"; return 0; }
    git -C "$repo" rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1 \
        && { printf '%s' "$b"; return 0; }
    return 1
}

# resolve_state_dir — the run journal's directory, from the env var, then
# config, then the XDG default. Creates nothing.
resolve_state_dir() {
    local d="${NW_DISPATCH_WORKFLOW_STATE:-}"
    if [ -z "$d" ]; then
        d=$(nw_config_get dispatch.workflow.state_dir "" 2>/dev/null) || d=""
    fi
    [ -n "$d" ] || d="${XDG_STATE_HOME:-$HOME/.local/state}/night-watchman/dispatch-workflow"
    printf '%s' "$d"
}

# journal_read PATH — the journal's JSON on stdout; a corrupt one is exit 2.
journal_read() {
    local path="$1" json
    json=$(cat "$path") || stop2 "cannot read the run journal: $path"
    printf '%s' "$json" | jq -e . >/dev/null 2>&1 \
        || stop2 "the run journal is not valid JSON: $path (remove it by hand to start over)"
    printf '%s' "$json"
}

# journal_write PATH JSON — replace the journal in one rename, so a killed
# write leaves the previous state rather than half a file.
journal_write() {
    local path="$1" json="$2" tmp
    tmp="$path.tmp.$$"
    printf '%s\n' "$json" > "$tmp" || stop2 "cannot write the run journal: $path"
    mv "$tmp" "$path" || stop2 "cannot replace the run journal: $path"
}

# frontmatter_executor PATH — the `executor:` value from a ticket file's
# leading `---` frontmatter block, or nothing.
frontmatter_executor() {
    awk '
        NR == 1 && $0 != "---" { exit }
        NR > 1 && $0 == "---" { exit }
        /^executor:[[:space:]]*/ {
            sub(/^executor:[[:space:]]*/, "")
            sub(/[[:space:]]*$/, "")
            print
            exit
        }
    ' "$1" 2>/dev/null
}

verb="${1:-}"
case "$verb" in
    -h|--help|help) show_help ;;
esac
[ -n "$verb" ] && shift

case "$verb" in
    start)
        TICKET_ARG=""
        MODEL="sonnet"
        TICKET_FILE=""
        EXECUTOR_ARG=""
        WORKTREE=""
        AGENT_NAME=""
        BASE=""
        TIMEBOX=""
        FORBIDDEN=""
        DRY_RUN=0
        [ "${NW_DRY_RUN:-0}" = 1 ] && DRY_RUN=1

        while [ $# -gt 0 ]; do
            case "$1" in
                --model)
                    [ $# -ge 2 ] || die "--model needs an argument: sonnet, opus or haiku"
                    MODEL="$2"; shift 2 ;;
                --ticket-file)
                    [ $# -ge 2 ] || die "--ticket-file needs a path"
                    TICKET_FILE="$2"; shift 2 ;;
                --executor)
                    [ $# -ge 2 ] || die "--executor needs a value (agent, human or mixed)"
                    EXECUTOR_ARG="$2"; shift 2 ;;
                --worktree)
                    [ $# -ge 2 ] || die "--worktree needs a path"
                    WORKTREE="$2"; shift 2 ;;
                --agent)
                    [ $# -ge 2 ] || die "--agent needs a name"
                    AGENT_NAME="$2"; shift 2 ;;
                --timebox)
                    [ $# -ge 2 ] || die "--timebox needs text, e.g. \"3 hours\""
                    TIMEBOX="$2"; shift 2 ;;
                --forbidden)
                    [ $# -ge 2 ] || die "--forbidden needs text"
                    if [ -n "$FORBIDDEN" ]; then
                        FORBIDDEN="$FORBIDDEN
- $2"
                    else
                        FORBIDDEN="- $2"
                    fi
                    shift 2 ;;
                --base)
                    [ $# -ge 2 ] || die "--base needs a branch name"
                    BASE="$2"; shift 2 ;;
                --dry-run) DRY_RUN=1; shift ;;
                -*) die "unknown option to 'start': $1 (see --help)" ;;
                *)
                    [ -z "$TICKET_ARG" ] || die "unexpected extra argument: $1 (see --help)"
                    TICKET_ARG="$1"; shift ;;
            esac
        done

        [ -n "$TICKET_ARG" ] || die "usage: provider.sh start <ticket-id> (--ticket-file PATH | --executor agent) [--model sonnet|opus|haiku] [--worktree PATH] [--dry-run] (see --help)"
        case "$MODEL" in
            sonnet|opus|haiku) ;;
            *) die "--model must be one of sonnet, opus, haiku (got '$MODEL')" ;;
        esac

        need jq
        need git

        TICKET_UPPER=$(uppercase "$TICKET_ARG")
        BRANCH=$(lowercase "$TICKET_ARG")
        case "$TICKET_UPPER" in
            *[!A-Za-z0-9_-]*) die "ticket id '$TICKET_ARG' contains characters that are not letters, digits, '_' or '-' (see --help)" ;;
        esac
        case "$TICKET_UPPER" in
            [A-Z]*-[0-9]*) ;;
            *) die "ticket id '$TICKET_ARG' does not look like PROJ-### (see --help)" ;;
        esac

        EXECUTOR=""
        if [ -n "$TICKET_FILE" ]; then
            [ -r "$TICKET_FILE" ] || stop2 "cannot read the ticket file: $TICKET_FILE"
            EXECUTOR=$(frontmatter_executor "$TICKET_FILE") || EXECUTOR=""
            EXECUTOR=$(lowercase "$EXECUTOR")
            [ -n "$EXECUTOR" ] || stop2 "$TICKET_FILE carries no 'executor:' line in its frontmatter — could not evaluate whether $TICKET_UPPER may run unattended"
        elif [ -n "$EXECUTOR_ARG" ]; then
            EXECUTOR=$(lowercase "$EXECUTOR_ARG")
        else
            die "refusing to start $TICKET_UPPER with no executor assertion: pass --ticket-file PATH (its frontmatter decides) or --executor agent"
        fi
        case "$EXECUTOR" in
            agent) ;;
            human|mixed) die "$TICKET_UPPER's executor is '$EXECUTOR' — refusing to dispatch it unattended (only 'agent' tickets qualify)" ;;
            *) stop2 "$TICKET_UPPER's executor is '$EXECUTOR', not one of agent/human/mixed — could not evaluate" ;;
        esac

        [ -n "$TIMEBOX" ] || TIMEBOX=$(nw_config_get dispatch.brief.timebox "" 2>/dev/null) || TIMEBOX=""
        if [ -z "$FORBIDDEN" ]; then
            CFG_FORBIDDEN=$(nw_config_get dispatch.brief.forbidden "" 2>/dev/null) || CFG_FORBIDDEN=""
            [ -z "$CFG_FORBIDDEN" ] || FORBIDDEN="- $CFG_FORBIDDEN"
        fi
        [ -n "$TIMEBOX" ] || die "no TIMEBOX: pass --timebox TEXT or set [dispatch.brief] timebox — an incomplete brief is never sent"
        [ -n "$FORBIDDEN" ] || die "no FORBIDDEN: pass --forbidden TEXT (repeatable) or set [dispatch.brief] forbidden — an incomplete brief is never sent"

        REPO=$(git rev-parse --show-toplevel 2>/dev/null) || stop2 "not inside a git repository — the brief names the worktree the agent creates, which is relative to the repo being worked on"
        [ -n "$AGENT_NAME" ] || AGENT_NAME="$BRANCH"
        [ -n "$WORKTREE" ] || WORKTREE="$(dirname "$REPO")/wt-$BRANCH"

        [ -n "$BASE" ] || BASE=$(base_branch "$REPO")
        BASE_REF=$(base_ref "$REPO" "$BASE") \
            || stop2 "cannot resolve base branch '$BASE' in $REPO: neither refs/remotes/origin/$BASE nor refs/heads/$BASE exists — refusing to compose a brief that would cut the worktree from whatever HEAD happens to be"
        CURRENT_BRANCH=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null) || CURRENT_BRANCH=""
        BASE_WARNING=""
        if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "$BASE" ]; then
            BASE_WARNING="the shared checkout $REPO is on '$CURRENT_BRANCH', not the base '$BASE'; the worktree is cut from $BASE_REF regardless, but something else is mid-flight in that repo"
        fi

        TEMPLATE_BODY=$(awk 'f{print; next} /^# /{f=1; print}' "$BRIEF_TEMPLATE" 2>/dev/null) \
            || stop2 "cannot read brief template $BRIEF_TEMPLATE"
        [ -n "$TEMPLATE_BODY" ] || stop2 "brief template $BRIEF_TEMPLATE is missing or has no heading"

        CFG_PROJECT=$(nw_config_get tracker.jira.project "" 2>/dev/null) || CFG_PROJECT=""
        if [ -n "$TICKET_FILE" ]; then
            TRACKER_LINE="Ticket file $TICKET_FILE is the contract; tracker project ${CFG_PROJECT:-${TICKET_UPPER%%-*}}"
        else
            TRACKER_LINE="Tracker project ${CFG_PROJECT:-${TICKET_UPPER%%-*}}; read $TICKET_UPPER there first"
        fi

        PROMPT_TEXT=${TEMPLATE_BODY//@KEY@/$TICKET_UPPER}
        PROMPT_TEXT=${PROMPT_TEXT//@BRANCH@/$BRANCH}
        PROMPT_TEXT=${PROMPT_TEXT//@MODEL@/$MODEL}
        PROMPT_TEXT=${PROMPT_TEXT//@TRACKER@/$TRACKER_LINE}
        PROMPT_TEXT=${PROMPT_TEXT//@TIMEBOX@/$TIMEBOX}
        PROMPT_TEXT=${PROMPT_TEXT//@FORBIDDEN@/$FORBIDDEN}
        PROMPT_TEXT="$PROMPT_TEXT

## WORKTREE
Create and work only inside your own: \`git -C $REPO worktree add $WORKTREE -b $BRANCH $BASE_REF\`.
The base ref is named on purpose: without it the branch is cut from whatever
$REPO has checked out, which inherits somebody else's in-flight commits.
Never commit in $REPO itself — sibling agents are running against other paths
in that same repo, and this dispatcher opens no worktree for you.

## CLOSING STATE
Before you stop, write \`.night-watchman/closing-state.md\` in your worktree (do
not commit it) with \`## Human run list\` (required if this ticket's executor is
human or mixed), \`## Left undone\` and \`## Findings\` sections: what you
deliberately left undone and why, and anything you noticed but did not act on.
land-branch.sh writes it to the tracker and confirms the write before your
session ends."

        STATE_DIR=$(resolve_state_dir)
        JOURNAL="$STATE_DIR/$BRANCH.json"
        BRIEF_PATH="$STATE_DIR/$BRANCH.brief.md"

        if [ -f "$JOURNAL" ]; then
            EXISTING=$(journal_read "$JOURNAL")
            EXISTING_STATE=$(printf '%s' "$EXISTING" | jq -r '.state // empty') || EXISTING_STATE=""
            case "$EXISTING_STATE" in
                requested|running)
                    printf '%s' "$EXISTING" \
                        | jq '. + {note:"a launch request for this ticket is already recorded; nothing was re-composed"}'
                    exit 0 ;;
                *)
                    die "a workflow run for '$BRANCH' is already recorded in state '${EXISTING_STATE:-<none>}' — remove $JOURNAL by hand to start over" ;;
            esac
        fi

        LAUNCH_NOTE="hand $BRIEF_PATH to the Workflow tool as $AGENT_NAME's brief; this provider records the request and cannot make the in-process call itself"
        REQUEST=$(jq -n \
            --arg ticket "$TICKET_UPPER" \
            --arg branch "$BRANCH" \
            --arg agent "$AGENT_NAME" \
            --arg model "$MODEL" \
            --arg repo "$REPO" \
            --arg worktree "$WORKTREE" \
            --arg brief "$BRIEF_PATH" \
            --arg journal "$JOURNAL" \
            --arg at "$(now_utc)" \
            --arg note "$LAUNCH_NOTE" \
            --arg base "$BASE" \
            --arg base_ref "$BASE_REF" \
            --arg base_warning "$BASE_WARNING" \
            '{provider:"workflow", ticket:$ticket, branch:$branch, agent:$agent,
              model:$model, repo:$repo, worktree:$worktree, base:$base,
              base_ref:$base_ref, brief_path:$brief,
              journal:$journal, state:"requested", requested_at:$at,
              launch:{tool:"Workflow", performed_by:"the orchestrating turn", note:$note}}
             + (if $base_warning == "" then {} else {base_warning:$base_warning} end)') \
            || stop2 "could not compose the launch request JSON"

        if [ "$DRY_RUN" = 1 ]; then
            printf '%s' "$REQUEST" | jq --arg brief "$PROMPT_TEXT" \
                '. + {dry_run:true, state:"not-requested", brief:$brief,
                      note:"--dry-run: no journal, no brief file, no request recorded"}' \
                || stop2 "could not compose the --dry-run JSON"
            exit 0
        fi

        mkdir -p "$STATE_DIR" || stop2 "cannot create the state directory: $STATE_DIR"
        printf '%s\n' "$PROMPT_TEXT" > "$BRIEF_PATH" || stop2 "cannot write the brief: $BRIEF_PATH"
        journal_write "$JOURNAL" "$REQUEST"
        printf '%s\n' "$REQUEST"
        ;;
    watch)
        TICKET_ID="${1:-}"
        [ -n "$TICKET_ID" ] || die "usage: provider.sh watch <ticket-id>"
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
                --until|--timeout)
                    die "'$1' is not offered by the workflow dispatcher: watch does not block and there is no pane to watch. The states it would wait on are written by the orchestrating turn that holds the Workflow tool, never by this subprocess, so a wait here could only time out. That gap is declared in providers/README.md; re-run 'watch' to re-read the recorded state." ;;
                *) die "unknown option to 'watch': $1" ;;
            esac
        done

        need jq
        BRANCH=$(lowercase "$TICKET_ID")
        STATE_DIR=$(resolve_state_dir)
        JOURNAL="$STATE_DIR/$BRANCH.json"
        [ -f "$JOURNAL" ] \
            || die "no workflow dispatch recorded for '$BRANCH' — 'start' records one (journals live in $STATE_DIR)"
        WATCH_JSON=$(journal_read "$JOURNAL")
        printf '%s' "$WATCH_JSON" | jq --arg at "$(now_utc)" '. + {observed_at:$at}'
        ;;
    stop)
        TICKET_ID="${1:-}"
        [ -n "$TICKET_ID" ] || die "usage: provider.sh stop <ticket-id> [--reason TEXT]"
        shift
        REASON=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --reason)
                    [ $# -ge 2 ] || die "--reason needs text"
                    REASON="$2"; shift 2 ;;
                *) die "unknown option to 'stop': $1" ;;
            esac
        done

        need jq
        BRANCH=$(lowercase "$TICKET_ID")
        STATE_DIR=$(resolve_state_dir)
        JOURNAL="$STATE_DIR/$BRANCH.json"
        [ -f "$JOURNAL" ] \
            || die "no workflow dispatch recorded for '$BRANCH' — nothing to stop (journals live in $STATE_DIR)"
        STOP_JSON=$(journal_read "$JOURNAL")
        STOP_STATE=$(printf '%s' "$STOP_JSON" | jq -r '.state // empty') || STOP_STATE=""
        if [ "$STOP_STATE" = "stop-requested" ]; then
            printf '%s' "$STOP_JSON" \
                | jq '. + {note:"a stop was already requested; the recorded request is unchanged"}'
            exit 0
        fi

        STOP_NOTE="issue TaskStop for this agent in the turn that launched it; no process is killed here, because this provider started none"
        UPDATED=$(printf '%s' "$STOP_JSON" | jq \
            --arg at "$(now_utc)" \
            --arg reason "$REASON" \
            --arg note "$STOP_NOTE" \
            '. + {state:"stop-requested", stop_requested_at:$at,
                  stop_reason:(if $reason == "" then null else $reason end),
                  stop:{tool:"TaskStop", agent:.agent, performed_by:"the orchestrating turn", note:$note}}') \
            || stop2 "could not compose the stop request JSON"
        journal_write "$JOURNAL" "$UPDATED"
        printf '%s\n' "$UPDATED"
        ;;
    "")
        echo "Error: usage: provider.sh VERB [ARG...] (verbs: start, watch, stop)" >&2
        exit 1
        ;;
    *)
        echo "Error: unknown dispatch verb: $verb (contract: start, watch, stop)" >&2
        exit 1
        ;;
esac
