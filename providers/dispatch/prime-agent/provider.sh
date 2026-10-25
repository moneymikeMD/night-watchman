#!/bin/bash
#
# provider.sh — the `prime-agent` implementation of the `dispatch` provider
# kind (verbs: start, watch, stop — see ../../README.md for the contract and
# for where these semantics differ from workflow's and herdr's). Selected per
# run with NW_DISPATCH=prime-agent; it is not the committed default.
#
# The dispatcher is a Prime Agent daemon. A daemon-backed session can only be
# created from inside a TOP-LEVEL Prime Agent session, by calling
# `rlm.create_session(...)` in its Python REPL: `prime-agent -p` runs do not
# register with the daemon, and no shell command creates one. So, like
# `workflow`, start cannot launch the worker. It composes, records and prints
# the exact Python call; the orchestrating Prime Agent turn makes it. watch
# and stop are real reads and writes of daemon state through the
# `prime-agent` CLI, which works from any shell.
#
#   start  checks the executor, composes the brief, creates the worktree from
#          an explicit base, records a journal, and prints one JSON object
#          whose launch.python is the call to make. The session is named
#          after the lowercased ticket id and its cwd is the worktree.
#   watch  reads `prime-agent sessions --json` (then `--all` when no live
#          session matches), matching by name AND cwd, and reports activity,
#          lifecycle, model, tokens and cost. --until polls until the state
#          is reached; --timeout bounds the poll.
#   stop   runs `prime-agent stop <active id>` on the live session found the
#          same way, and records the stop in the journal.
#
# Usage:
#   provider.sh start <ticket-id> (--ticket-file PATH | --executor agent)
#                     [--model PROVIDER/MODEL] [--thinking LEVEL]
#                     [--worktree PATH] [--base BRANCH] [--timebox TEXT]
#                     [--forbidden TEXT]... [--dry-run]
#   provider.sh watch <ticket-id> [--until STATE]... [--timeout MS]
#   provider.sh stop  <ticket-id> [--reason TEXT]
#
# The executor gate, the brief template, the MIXED TICKET section and the
# base-branch resolution are workflow's (see ../workflow/provider.sh). The
# model is a Prime Agent selector (`prime-agent model list`, e.g.
# anthropic/claude-sonnet-5-5) from --model or [dispatch.prime-agent] model;
# there is no built-in default. --thinking (or [dispatch.prime-agent]
# thinking) is one of off minimal low medium high xhigh max, and is left to
# Prime Agent's default when unset.
#
# watch's STATE is the session's `activity` while it is live (working, idle,
# ...), `archived` once only a stopped session matches, and `not-started`
# when no session matches at all — the launch call has not been made yet.
# `idle` is between turns, not finished: a worker waiting on a background
# command reads idle and wakes again when it completes.
#
# A session name is unique only among one parent's children, so a name alone
# could match another orchestrator's worker; the cwd (the worktree, as a
# physical path, because the daemon reports one) disambiguates. More than one
# live match is exit 2.
#
# State: $NW_DISPATCH_PRIME_AGENT_STATE, else [dispatch.prime-agent]
# state_dir, else $XDG_STATE_HOME/night-watchman/dispatch-prime-agent
# (falling back to ~/.local/state). One `<branch>.json` journal and one
# `<branch>.brief.md` per ticket, outside the repo for the reason workflow's
# header gives.
#
# Env:
#   NW_DISPATCH_PRIME_AGENT_STATE  the state directory (wins over config).
#   NW_PRIME_AGENT_BRIEF_TEMPLATE  overrides the brief template path.
#   NW_PRIME_AGENT_POLL_S          seconds between watch --until reads (5).
#   NW_DRY_RUN                     "1" behaves as --dry-run.
#
# Exit codes:
#   0   the verb completed, start found an open request, or --dry-run printed
#       its plan.
#   1   a check failed (bad args, an executor:human ticket, no recorded run,
#       nothing live to stop, watch --until timed out, prime-agent refused).
#   2   a precondition could not be evaluated (no jq, git or prime-agent, an
#       unreadable template or ticket, a corrupt journal, unparseable
#       prime-agent output, an ambiguous session match).
#
# The brief's TRACKER section names the read and comment commands: [dispatch.brief]
# tracker_read and tracker_comment verbatim (@KEY@ is replaced) when set, else this
# plugin's providers/lib/provider.sh tracker fetch|comment by absolute path.
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/kit.sh
. "$DIR/../../lib/kit.sh"
# shellcheck source=../../lib/config.sh
. "$DIR/../../lib/config.sh"

stop2() { echo "Error: $*" >&2; exit 2; }

lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
uppercase() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

PLUGIN_ROOT="$(cd "$DIR/../../.." && pwd)"
BRIEF_TEMPLATE="${NW_PRIME_AGENT_BRIEF_TEMPLATE:-$PLUGIN_ROOT/templates/dispatch-brief.md}"

base_branch() {
    local b
    b=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || b=""
    [ -n "$b" ] && { printf '%s' "${b#origin/}"; return 0; }
    printf '%s' "main"
}

base_ref() {
    local repo="$1" b="$2"
    git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null 2>&1 \
        && { printf '%s' "origin/$b"; return 0; }
    git -C "$repo" rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1 \
        && { printf '%s' "$b"; return 0; }
    return 1
}

resolve_state_dir() {
    local d="${NW_DISPATCH_PRIME_AGENT_STATE:-}"
    if [ -z "$d" ]; then
        d=$(nw_config_get dispatch.prime-agent.state_dir "" 2>/dev/null) || d=""
    fi
    [ -n "$d" ] || d="${XDG_STATE_HOME:-$HOME/.local/state}/night-watchman/dispatch-prime-agent"
    printf '%s' "$d"
}

journal_read() {
    local path="$1" json
    json=$(cat "$path") || stop2 "cannot read the run journal: $path"
    printf '%s' "$json" | jq -e . >/dev/null 2>&1 \
        || stop2 "the run journal is not valid JSON: $path (remove it by hand to start over)"
    printf '%s' "$json"
}

journal_write() {
    local path="$1" json="$2" tmp
    tmp="$path.tmp.$$"
    printf '%s\n' "$json" > "$tmp" || stop2 "cannot write the run journal: $path"
    mv "$tmp" "$path" || stop2 "cannot replace the run journal: $path"
}

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

# journal_for TICKET-ID — the journal's JSON for a ticket, or exit 1 naming
# the verb that records one.
journal_for() {
    local branch state_dir journal
    branch=$(lowercase "$1")
    state_dir=$(resolve_state_dir)
    journal="$state_dir/$branch.json"
    [ -f "$journal" ] \
        || die "no prime-agent dispatch recorded for '$branch' — 'start' records one (journals live in $state_dir)"
    journal_read "$journal"
}

# sessions_json [--all] — `prime-agent sessions --json`, checked for shape.
sessions_json() {
    local out
    out=$(prime-agent sessions "$@" --json) || die "'prime-agent sessions $* --json' failed"
    printf '%s' "$out" | jq -e '.sessions | type == "array"' >/dev/null 2>&1 \
        || stop2 "'prime-agent sessions $* --json' did not return a sessions[] array"
    printf '%s' "$out"
}

# observe NAME CWD — one JSON object {state, session} for the session named
# NAME whose cwd is CWD: the live one if any, else the newest archived one,
# else state not-started with a null session.
observe() {
    local name="$1" cwd="$2" json live n
    # shellcheck disable=SC2016  # $n and $c are jq variables
    local pick='[.sessions[] | select((.sessionName // "") == $n and .cwd == $c)]'
    # shellcheck disable=SC2016
    local shape='{id, sessionId, name: .sessionName, cwd, lifecycle, activity,
        model: (if (.model | type) == "object" then "\(.model.provider)/\(.model.id)" else null end),
        usage: {inputTokens: .usage.inputTokens, outputTokens: .usage.outputTokens, cost: .usage.cost},
        modified}'
    json=$(sessions_json)
    live=$(printf '%s' "$json" | jq -c --arg n "$name" --arg c "$cwd" "$pick | map(select(.lifecycle == \"live\"))") \
        || stop2 "could not read sessions[] from prime-agent"
    n=$(printf '%s' "$live" | jq 'length')
    if [ "$n" -gt 1 ]; then
        stop2 "$n live Prime Agent sessions are named '$name' with cwd $cwd ($(printf '%s' "$live" | jq -r 'map(.id) | join(", ")')) — refusing to guess which is this ticket's"
    fi
    if [ "$n" = 1 ]; then
        printf '%s' "$live" | jq -c ".[0] | {state: .activity, session: $shape}"
        return 0
    fi
    json=$(sessions_json --all)
    printf '%s' "$json" | jq -c --arg n "$name" --arg c "$cwd" \
        "$pick | sort_by(.modified // \"\") | last
         | if . == null then {state: \"not-started\", session: null}
           else {state: (if .lifecycle == \"live\" then .activity else .lifecycle end), session: $shape} end" \
        || stop2 "could not read sessions[] from 'prime-agent sessions --all'"
}

verb="${1:-}"
case "$verb" in
    -h|--help|help) show_help ;;
esac
[ -n "$verb" ] && shift

case "$verb" in
    start)
        TICKET_ARG=""
        MODEL=""
        THINKING=""
        TICKET_FILE=""
        EXECUTOR_ARG=""
        WORKTREE=""
        BASE=""
        TIMEBOX=""
        FORBIDDEN=""
        DRY_RUN=0
        [ "${NW_DRY_RUN:-0}" = 1 ] && DRY_RUN=1

        while [ $# -gt 0 ]; do
            case "$1" in
                --model)
                    [ $# -ge 2 ] || die "--model needs a selector, e.g. anthropic/claude-sonnet-5-5"
                    MODEL="$2"; shift 2 ;;
                --thinking)
                    [ $# -ge 2 ] || die "--thinking needs a level"
                    THINKING="$2"; shift 2 ;;
                --ticket-file)
                    [ $# -ge 2 ] || die "--ticket-file needs a path"
                    TICKET_FILE="$2"; shift 2 ;;
                --executor)
                    [ $# -ge 2 ] || die "--executor needs a value (agent, human or mixed)"
                    EXECUTOR_ARG="$2"; shift 2 ;;
                --worktree)
                    [ $# -ge 2 ] || die "--worktree needs a path"
                    WORKTREE="$2"; shift 2 ;;
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

        [ -n "$TICKET_ARG" ] || die "usage: provider.sh start <ticket-id> (--ticket-file PATH | --executor agent) [--model PROVIDER/MODEL] [--dry-run] (see --help)"

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

        [ -n "$MODEL" ] || MODEL=$(nw_config_get dispatch.prime-agent.model "" 2>/dev/null) || MODEL=""
        [ -n "$MODEL" ] || die "no model: pass --model PROVIDER/MODEL or set [dispatch.prime-agent] model ('prime-agent model list' names them, e.g. anthropic/claude-sonnet-5-5)"
        case "$MODEL" in
            */*) ;;
            *) die "--model must be a Prime Agent selector PROVIDER/MODEL, e.g. anthropic/claude-sonnet-5-5 (got '$MODEL')" ;;
        esac
        case "$MODEL" in
            /*|*/|*[!A-Za-z0-9._/-]*) die "--model must be a Prime Agent selector PROVIDER/MODEL, e.g. anthropic/claude-sonnet-5-5 (got '$MODEL')" ;;
        esac
        [ -n "$THINKING" ] || THINKING=$(nw_config_get dispatch.prime-agent.thinking "" 2>/dev/null) || THINKING=""
        case "$THINKING" in
            ""|off|minimal|low|medium|high|xhigh|max) ;;
            *) die "--thinking must be one of off, minimal, low, medium, high, xhigh, max (got '$THINKING')" ;;
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
            agent|mixed) ;;
            human) die "$TICKET_UPPER's executor is 'human' — refusing to dispatch it unattended (only 'agent' and 'mixed' tickets qualify)" ;;
            *) stop2 "$TICKET_UPPER's executor is '$EXECUTOR', not one of agent/human/mixed — could not evaluate" ;;
        esac

        [ -n "$TIMEBOX" ] || TIMEBOX=$(nw_config_get dispatch.brief.timebox "" 2>/dev/null) || TIMEBOX=""
        if [ -z "$FORBIDDEN" ]; then
            CFG_FORBIDDEN=$(nw_config_get dispatch.brief.forbidden "" 2>/dev/null) || CFG_FORBIDDEN=""
            [ -z "$CFG_FORBIDDEN" ] || FORBIDDEN="- $CFG_FORBIDDEN"
        fi
        [ -n "$TIMEBOX" ] || die "no TIMEBOX: pass --timebox TEXT or set [dispatch.brief] timebox — an incomplete brief is never sent"
        [ -n "$FORBIDDEN" ] || die "no FORBIDDEN: pass --forbidden TEXT (repeatable) or set [dispatch.brief] forbidden — an incomplete brief is never sent"

        REPO=$(git rev-parse --show-toplevel 2>/dev/null) || stop2 "not inside a git repository — start creates the worktree the session runs in"
        [ -n "$WORKTREE" ] || WORKTREE="$(dirname "$REPO")/wt-$BRANCH"

        [ -n "$BASE" ] || BASE=$(base_branch "$REPO")
        BASE_REF=$(base_ref "$REPO" "$BASE") \
            || stop2 "cannot resolve base branch '$BASE' in $REPO: neither refs/remotes/origin/$BASE nor refs/heads/$BASE exists — refusing to cut the worktree from whatever HEAD happens to be"

        TEMPLATE_BODY=$(awk 'f{print; next} /^# /{f=1; print}' "$BRIEF_TEMPLATE" 2>/dev/null) \
            || stop2 "cannot read brief template $BRIEF_TEMPLATE"
        [ -n "$TEMPLATE_BODY" ] || stop2 "brief template $BRIEF_TEMPLATE is missing or has no heading"

        STATE_DIR=$(resolve_state_dir)
        JOURNAL="$STATE_DIR/$BRANCH.json"
        BRIEF_PATH="$STATE_DIR/$BRANCH.brief.md"

        if [ -f "$JOURNAL" ]; then
            EXISTING=$(journal_read "$JOURNAL")
            EXISTING_STATE=$(printf '%s' "$EXISTING" | jq -r '.state // empty') || EXISTING_STATE=""
            if [ "$EXISTING_STATE" = requested ]; then
                printf '%s' "$EXISTING" \
                    | jq '. + {note:"a launch request for this ticket is already recorded; nothing was re-composed and no worktree was created"}'
                exit 0
            fi
            die "a prime-agent run for '$BRANCH' is already recorded in state '${EXISTING_STATE:-<none>}' — remove $JOURNAL by hand to start over"
        fi
        [ ! -e "$WORKTREE" ] \
            || die "$WORKTREE already exists and no run is recorded for '$BRANCH' — remove it or pass --worktree PATH"

        CFG_PROJECT=$(nw_config_get tracker.jira.project "" 2>/dev/null) || CFG_PROJECT=""
        if [ -n "$TICKET_FILE" ]; then
            TRACKER_LINE="Ticket file $TICKET_FILE is the contract; tracker project ${CFG_PROJECT:-${TICKET_UPPER%%-*}}"
        else
            TRACKER_LINE="Tracker project ${CFG_PROJECT:-${TICKET_UPPER%%-*}}; read $TICKET_UPPER there first"
        fi
        TRACKER_READ=$(nw_config_get dispatch.brief.tracker_read "" 2>/dev/null) || TRACKER_READ=""
        TRACKER_COMMENT=$(nw_config_get dispatch.brief.tracker_comment "" 2>/dev/null) || TRACKER_COMMENT=""
        [ -n "$TRACKER_READ" ] || TRACKER_READ="$PLUGIN_ROOT/providers/lib/provider.sh tracker fetch $TICKET_UPPER"
        [ -n "$TRACKER_COMMENT" ] || TRACKER_COMMENT="$PLUGIN_ROOT/providers/lib/provider.sh tracker comment $TICKET_UPPER -"
        TRACKER_READ=${TRACKER_READ//@KEY@/$TICKET_UPPER}
        TRACKER_COMMENT=${TRACKER_COMMENT//@KEY@/$TICKET_UPPER}
        TRACKER_LINE="$TRACKER_LINE
Read the ticket:    $TRACKER_READ
Comment on it:      $TRACKER_COMMENT  (text on stdin)"

        PROMPT_TEXT=${TEMPLATE_BODY//@KEY@/$TICKET_UPPER}
        PROMPT_TEXT=${PROMPT_TEXT//@BRANCH@/$BRANCH}
        PROMPT_TEXT=${PROMPT_TEXT//@MODEL@/$MODEL}
        PROMPT_TEXT=${PROMPT_TEXT//@TRACKER@/$TRACKER_LINE}
        PROMPT_TEXT=${PROMPT_TEXT//@TIMEBOX@/$TIMEBOX}
        PROMPT_TEXT=${PROMPT_TEXT//@FORBIDDEN@/$FORBIDDEN}
        PROMPT_TEXT=${PROMPT_TEXT//"Post as a Jira comment on your ticket, then stop:"/"Post as a Jira comment on your ticket with the \"Comment on it\" command in TRACKER above, then stop:"}
        PROMPT_TEXT="$PROMPT_TEXT

## WORKTREE
Your working directory is your own worktree, $WORKTREE, on branch \`$BRANCH\`,
cut from $BASE_REF before you started. Work and commit only there. Never
commit in $REPO itself — sibling agents are running against other paths in
that same repo.

## HARNESS
You are a Prime Agent session, not a Claude Code one: this plugin's skills,
agents and hooks are not loaded. Where this brief names a skill, read
$PLUGIN_ROOT/skills/<name>/SKILL.md and follow it. Staying inside your
worktree and inside the ticket's touches is on you.

## CLOSING STATE
Before you stop, write \`.night-watchman/closing-state.md\` in your worktree (do
not commit it) with \`## Human run list\` (required if this ticket's executor is
human or mixed), \`## Left undone\` and \`## Findings\` sections: what you
deliberately left undone and why, and anything you noticed but did not act on.
land-branch.sh writes it to the tracker and confirms the write before your
session ends."

        if [ "$EXECUTOR" = mixed ]; then
            PROMPT_TEXT="$PROMPT_TEXT

## MIXED TICKET
This ticket's executor is mixed: only the agent portion runs unattended. Work
it to the verify block, commit, push your branch and open the PR as usual.
Before you stop, write the \`## Human run list\` section in
\`.night-watchman/closing-state.md\` — it is required for a mixed ticket and it
is what land-branch.sh checks before it will land one. Then STOP and report.
Do not transition the ticket and do not land it yourself; the human steps are
run by a person after landing, not before."
        fi

        if [ "$DRY_RUN" = 1 ]; then
            jq -n \
                --arg ticket "$TICKET_UPPER" --arg branch "$BRANCH" --arg model "$MODEL" \
                --arg thinking "$THINKING" --arg repo "$REPO" --arg worktree "$WORKTREE" \
                --arg base "$BASE" --arg base_ref "$BASE_REF" --arg brief "$PROMPT_TEXT" \
                '{provider:"prime-agent", ticket:$ticket, branch:$branch, session_name:$branch,
                  model:$model, thinking:(if $thinking == "" then null else $thinking end),
                  repo:$repo, worktree:$worktree, base:$base, base_ref:$base_ref,
                  dry_run:true, state:"not-requested", brief:$brief,
                  note:"--dry-run: no worktree, no journal, no brief file, no request recorded"}' \
                || stop2 "could not compose the --dry-run JSON"
            exit 0
        fi

        mkdir -p "$STATE_DIR" || stop2 "cannot create the state directory: $STATE_DIR"
        git -C "$REPO" worktree add --quiet "$WORKTREE" -b "$BRANCH" "$BASE_REF" >&2 \
            || die "'git worktree add $WORKTREE -b $BRANCH $BASE_REF' failed"
        # The daemon reports a session's cwd as a physical path, and watch
        # matches on it.
        WORKTREE=$(cd "$WORKTREE" && pwd -P)
        printf '%s\n' "$PROMPT_TEXT" > "$BRIEF_PATH" || stop2 "cannot write the brief: $BRIEF_PATH"

        REQUEST=$(jq -n \
            --arg ticket "$TICKET_UPPER" --arg branch "$BRANCH" --arg model "$MODEL" \
            --arg thinking "$THINKING" --arg repo "$REPO" --arg worktree "$WORKTREE" \
            --arg base "$BASE" --arg base_ref "$BASE_REF" --arg brief "$BRIEF_PATH" \
            --arg journal "$JOURNAL" --arg at "$(now_utc)" \
            '{provider:"prime-agent", ticket:$ticket, branch:$branch, session_name:$branch,
              model:$model, thinking:(if $thinking == "" then null else $thinking end),
              repo:$repo, worktree:$worktree, base:$base, base_ref:$base_ref,
              brief_path:$brief, journal:$journal, state:"requested", requested_at:$at,
              launch:{
                performed_by:"the orchestrating turn, which must be a top-level Prime Agent session",
                python:("await rlm.create_session(prompt=open(\($brief | tojson)).read(), name=\($branch | tojson), cwd=\($worktree | tojson), model=\($model | tojson)"
                        + (if $thinking == "" then "" else ", thinking=\($thinking | tojson)" end) + ")"),
                note:"run launch.python in the orchestrating Prime Agent REPL; this provider cannot create a daemon session from a subprocess"}}') \
            || stop2 "could not compose the launch request JSON"
        journal_write "$JOURNAL" "$REQUEST"
        printf '%s\n' "$REQUEST"
        ;;
    watch)
        TICKET_ID="${1:-}"
        [ -n "$TICKET_ID" ] || die "usage: provider.sh watch <ticket-id> [--until STATE]... [--timeout MS]"
        shift
        UNTIL=""
        TIMEOUT_MS=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --until)
                    [ -n "${2:-}" ] || die "--until needs a state (working, idle, archived, not-started, ...)"
                    UNTIL="$UNTIL $2 "; shift 2 ;;
                --timeout)
                    [ -n "${2:-}" ] || die "--timeout needs milliseconds"
                    case "$2" in *[!0-9]*) die "--timeout takes whole milliseconds (got '$2')" ;; esac
                    TIMEOUT_MS="$2"; shift 2 ;;
                *) die "unknown option to 'watch': $1" ;;
            esac
        done
        [ -z "$TIMEOUT_MS" ] || [ -n "$UNTIL" ] || die "--timeout bounds an --until wait; pass --until STATE with it"

        need jq
        need prime-agent
        JOURNAL_JSON=$(journal_for "$TICKET_ID")
        NAME=$(printf '%s' "$JOURNAL_JSON" | jq -r '.session_name // empty')
        CWD=$(printf '%s' "$JOURNAL_JSON" | jq -r '.worktree // empty')
        [ -n "$NAME" ] && [ -n "$CWD" ] || stop2 "the run journal for '$TICKET_ID' names no session_name or worktree"

        POLL_S="${NW_PRIME_AGENT_POLL_S:-5}"
        START_S=$(date +%s)
        TIMED_OUT=false
        while :; do
            OBS=$(observe "$NAME" "$CWD")
            STATE=$(printf '%s' "$OBS" | jq -r '.state')
            [ -n "$UNTIL" ] || break
            case "$UNTIL" in *" $STATE "*) break ;; esac
            if [ -n "$TIMEOUT_MS" ] && [ $(( ($(date +%s) - START_S) * 1000 )) -ge "$TIMEOUT_MS" ]; then
                TIMED_OUT=true
                break
            fi
            sleep "$POLL_S"
        done

        printf '%s' "$JOURNAL_JSON" | jq --argjson obs "$OBS" --arg at "$(now_utc)" --argjson timed_out "$TIMED_OUT" \
            '. + {state:$obs.state, session:$obs.session, observed_at:$at}
             + (if $timed_out then {timed_out:true} else {} end)'
        [ "$TIMED_OUT" = false ] || { echo "Error: watch --until timed out after ${TIMEOUT_MS}ms in state '$STATE'" >&2; exit 1; }
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
        need prime-agent
        JOURNAL_JSON=$(journal_for "$TICKET_ID")
        JOURNAL=$(printf '%s' "$JOURNAL_JSON" | jq -r '.journal')
        NAME=$(printf '%s' "$JOURNAL_JSON" | jq -r '.session_name // empty')
        CWD=$(printf '%s' "$JOURNAL_JSON" | jq -r '.worktree // empty')
        [ -n "$NAME" ] && [ -n "$CWD" ] || stop2 "the run journal for '$TICKET_ID' names no session_name or worktree"

        OBS=$(observe "$NAME" "$CWD")
        LIFECYCLE=$(printf '%s' "$OBS" | jq -r '.session.lifecycle // empty')
        if [ "$LIFECYCLE" != live ]; then
            if [ "$(printf '%s' "$JOURNAL_JSON" | jq -r '.state')" = stopped ]; then
                printf '%s' "$JOURNAL_JSON" | jq '. + {note:"already stopped; the recorded stop is unchanged"}'
                exit 0
            fi
            die "no live Prime Agent session named '$NAME' with cwd $CWD — nothing to stop (state: $(printf '%s' "$OBS" | jq -r '.state'))"
        fi
        SESSION_ID=$(printf '%s' "$OBS" | jq -r '.session.id')
        STOP_OUT=$(prime-agent stop "$SESSION_ID" --json) || die "'prime-agent stop $SESSION_ID' failed"
        printf '%s' "$STOP_OUT" | jq -e '.success == true' >/dev/null 2>&1 \
            || stop2 "'prime-agent stop $SESSION_ID --json' did not report success: $STOP_OUT"

        UPDATED=$(printf '%s' "$JOURNAL_JSON" | jq --arg at "$(now_utc)" --arg reason "$REASON" \
            --argjson session "$(printf '%s' "$OBS" | jq -c '.session')" \
            '. + {state:"stopped", stopped_at:$at,
                  stop_reason:(if $reason == "" then null else $reason end),
                  stopped_session:$session}') \
            || stop2 "could not compose the stop record"
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
