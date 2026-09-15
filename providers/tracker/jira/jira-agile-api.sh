#!/bin/bash
#
# Client for the Jira Cloud Agile REST API (/rest/agile/1.0) — boards and
# sprints. OPTIONAL LAYER, ported from a production system (see the
# plugin's README, "Optional layers"): adopting Jira at all remains
# optional core-wide. Sibling to the plain issue-API wrapper
# (providers/tracker/jira/jira-api.sh, the one scripts/land-branch.sh's
# jira mode and --jira-api PATH / $ISSUES_JIRA_API convention already
# assume) rather than an extension of it: this script pins /rest/agile/1.0
# as a hard security boundary the same way that wrapper pins /rest/api/3 —
# a `raw`/`write` path argument
# can never be walked into a different API version by string
# concatenation. It exists to open/populate/close a Jira Sprint around a
# work block, which the plain issue API has no endpoints for at all.
#
# Auth: HTTP Basic <account-email>:<api-token>, read once at startup from
# two required env vars (never argv — see JIRA_AGILE_USER/JIRA_AGILE_TOKEN
# below) and passed to curl via a config on stdin (curl_auth_config, see
# lib/http.sh), never on curl's command line.
#
# Usage:
#   ./jira-agile-api.sh boards <project-key>             # boards for a project
#   ./jira-agile-api.sh sprint <sprint-id>                # one sprint's state
#   ./jira-agile-api.sh sprint-create <board-id> <name>   # create, state=future
#   ./jira-agile-api.sh sprint-start <sprint-id> [--end <ISO-8601>]  # future -> active
#   ./jira-agile-api.sh sprint-close <sprint-id>          # active -> closed
#   ./jira-agile-api.sh sprint-update <sprint-id> [--name N] [--goal G] \
#                                      [--start ISO-8601] [--end ISO-8601]
#                                                          # partial update,
#                                                          #   at least one flag
#   ./jira-agile-api.sh sprint-delete <sprint-id>         # 'future' sprints
#                                                          #   only, permanent
#   ./jira-agile-api.sh sprint-add-issue <sprint-id> <issue-key> [<issue-key>...]
#   ./jira-agile-api.sh raw GET <path>                    # any /rest/agile/1.0
#                                                          #   read, redacted
#   ./jira-agile-api.sh write <METHOD> <path> [json]      # a mutating call,
#                                                          #   guarded exactly
#                                                          #   like the plain
#                                                          #   issue-API wrapper
#
# Global flags, before the subcommand:
#   --show-secrets   do not redact credential-shaped fields in the output
#   --dry-run        print the exact request that WOULD be issued and exit 0
#   --yes            skip the interactive confirmation for POST/PUT/PATCH
#
# Examples:
#   ./jira-agile-api.sh boards PROJ
#   ./jira-agile-api.sh sprint-create 42 "2026-09-11 Thu evening"
#   ./jira-agile-api.sh sprint-add-issue 7 PROJ-1 PROJ-2
#   ./jira-agile-api.sh sprint-close 7
#
# SPRINT STATE MACHINE (found live against a real Jira Cloud site,
# recorded here because neither behavior is documented anywhere obvious).
# A company-managed (classic) project created from a basic
# software-development template gets a KANBAN board by default, and POST
# /sprint against it 400s "The board does not support sprints" — a SCRUM
# board has to be created separately (a saved filter via POST
# /rest/api/3/filter, then POST /rest/agile/1.0/board
# {name, type:"scrum", filterId}) before any of this script's sprint
# commands have anywhere to point. `boards <project-key>` shows the TYPE
# column for exactly this reason — check it before sprint-create.
#
# A sprint is created in state "future" — POST /sprint accepts only
# originBoardId/name/startDate/endDate/goal, no state field. Moving it to
# "active" (POST /sprint/{id} {state:"active"}) needs startDate AND endDate
# in that SAME request — sending state alone 400s "You must specify a start
# date for the sprint", even though creation a moment earlier accepted none.
# sprint-start supplies both (now, and +24h or --end) for this reason.
# Closing a "future" sprint directly also 400s "You must specify a start
# date for the sprint." — the SAME message as the missing-dates case above,
# not a distinct "not compatible" message; see
# fixtures/write.close-future-sprint-rejected.txt for the real capture.
# Jira checks for missing dates before it checks the state-transition rule,
# so future -> active and future -> closed fail identically at this step.
# The transition is always future -> active -> closed regardless. sprint-close
# therefore reads the sprint's current state first and dies rather than
# force-starting a "future" sprint on the caller's behalf, because that
# transition would also set the sprint's real start date to "now" without
# being asked.
#
# sprint-update is a partial PUT /sprint/{id} — only the fields named by a
# flag are sent, so an update to just --goal does not clobber name/dates the
# caller did not mention.
#
# DELETE /sprint/{id} exists (unlike the plain issue API, which has no
# delete-sprint endpoint at all) but Jira accepts it only for a sprint still
# in "future" state — an active or closed sprint's DELETE is rejected.
# sprint-delete reads current state first and refuses on active/closed,
# the same caution sprint-close applies above, rather than surfacing Jira's
# rejection after the fact.
#
# Env vars (all required, no defaults hardcoded to any one team's Jira
# instance — see the plugin's own convention of taking arguments/env
# rather than hardcoding one target):
#   JIRA_HOST           bare hostname of the Jira Cloud site, e.g.
#                        yourteam.atlassian.net. Point it at 127.0.0.1 to
#                        test — see jira-agile-api-selftest.sh.
#   JIRA_AGILE_USER      the Jira account email for HTTP Basic auth.
#   JIRA_AGILE_TOKEN     the Jira API token for HTTP Basic auth. Never pass
#                        this on argv; export it from whatever credential
#                        store your project already uses (e.g.
#                        `export JIRA_AGILE_TOKEN=$(op read
#                        op://vault/item/field)`), a call this script never
#                        makes itself.

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib/kit.sh
. "$DIR/../../lib/kit.sh"
# shellcheck source=lib/http.sh
. "$DIR/lib/http.sh"

# --------------------------------------------------------------- host

[ -n "${JIRA_HOST:-}" ] || die "\$JIRA_HOST is required (e.g. yourteam.atlassian.net) — no default is hardcoded to any one team's Jira instance"
HOST="$JIRA_HOST"
case "$HOST" in
    *[[:space:]]*|*/*|*@*|*:*) die "\$JIRA_HOST does not look like a bare hostname: '${HOST:0:40}'" ;;
esac

# --------------------------------------------------------------- credentials

AGILE_USER=""
AGILE_TOKEN=""
CREDS_LOADED=0
load_credentials() {
    [ "$CREDS_LOADED" = "1" ] && return 0
    [ -n "${JIRA_AGILE_USER:-}" ] || die "\$JIRA_AGILE_USER is required (the Jira account email for HTTP Basic auth)"
    [ -n "${JIRA_AGILE_TOKEN:-}" ] || die "\$JIRA_AGILE_TOKEN is required (the Jira API token for HTTP Basic auth) — export it from your own credential store, never on argv"
    AGILE_USER="$JIRA_AGILE_USER"
    AGILE_TOKEN="$JIRA_AGILE_TOKEN"
    CREDS_LOADED=1
}

# --------------------------------------------------------------- flags

SHOW_SECRETS=0
DRY_RUN=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --show-secrets) SHOW_SECRETS=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --yes|-y)       ASSUME_YES=1; shift ;;
        *) break ;;
    esac
done

[ $# -ge 1 ] || show_help
case "$1" in -h|--help|help) show_help ;; esac

need curl jq column

# --------------------------------------------------------------- validation
#
# Same boundary as the plain issue-API wrapper's valid_path, applied to the
# agile prefix — a string-concatenation risk, not cosmetic: without this, a
# caller-supplied path containing '..' or a second leading '/' could walk a
# `raw`/`write` call outside /rest/agile/1.0 entirely.
valid_path() {
    local p="$1"
    case "$p" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$p" in
        //*) return 1 ;;
        *[[:space:]]*) return 1 ;;
        *..*) return 1 ;;
    esac
    return 0
}

require_path() {
    valid_path "$1" || die "path must start with '/' and contain no '..', '//' or whitespace: '$1'"
}

# error_body <file> — print a failed response's body to stderr, redacted.
# The agile API's error bodies observed live are flat {errorMessages,
# errors} shapes — a plain string, or a field->string map — not a nested
# name/value pair echoing a submitted field back, so a single redact_json
# pass is enough here (unlike a richer /rest/api/3 surface that might need
# more).
error_body() {
    local in="$1"
    if jq -e . >/dev/null 2>&1 < "$in"; then
        redact_json < "$in" >&2 || cat "$in" >&2
    else
        cat "$in" >&2
    fi
    return 0
}

# api <METHOD> <path> [json-body] — dies on a non-2xx response and on a
# transport failure (rule: no die-inside-$( ), this is the top-level call).
LABKIT_TIMEOUT="${LABKIT_TIMEOUT:-25}"
api() {
    local method="$1" path="$2" body="${3:-}" out code bodyfile rc
    load_credentials
    out=$(tmpfile) || die "could not create temp file"
    rc=0
    if [ -n "$body" ]; then
        bodyfile=$(tmpfile) || die "could not create temp file"
        printf '%s' "$body" > "$bodyfile"
        code=$(curl_auth_config "$AGILE_USER" "$AGILE_TOKEN" \
            | curl -s -m"$LABKIT_TIMEOUT" --config - -X "$method" \
                   -H 'Content-Type: application/json' \
                   --data-binary @"$bodyfile" \
                   -o "$out" -w '%{http_code}' \
                   "https://$HOST/rest/agile/1.0$path") || rc=$?
    else
        code=$(curl_auth_config "$AGILE_USER" "$AGILE_TOKEN" \
            | curl -s -m"$LABKIT_TIMEOUT" --config - -X "$method" \
                   -o "$out" -w '%{http_code}' \
                   "https://$HOST/rest/agile/1.0$path") || rc=$?
    fi
    [ "$rc" -eq 0 ] \
        || die "$method $path: could not reach https://$HOST (curl exit $rc) — check \$JIRA_HOST, DNS and connectivity"
    case "$code" in
        2??) ;;
        *)
            warn "jira-agile-api: HTTP $code $method $path"
            error_body "$out"
            die "$method $path failed (HTTP $code)"
            ;;
    esac
    cat "$out"
}

# emit <method> <path> [body] — run the request and print it, redacted
# unless --show-secrets. api's die must run outside a pipeline's left-hand
# subshell for its exit status to reach the caller.
emit() {
    local method="$1" path="$2" body="${3:-}" out
    if [ "$SHOW_SECRETS" = "1" ]; then
        warn "--show-secrets: credential fields are NOT redacted. Do not paste this."
        api "$method" "$path" "$body"
        return $?
    fi
    out=$(tmpfile) || die "could not create temp file"
    api "$method" "$path" "$body" > "$out"
    redact_json < "$out" || die "redact_json failed — refusing to print unredacted output"
}

# ---------------------------------------------------------------- views

view_boards() {
    local key="$1" enc
    # Whole-string check, not just the first char — a trailing `*` in a
    # `case ... [A-Z]*)` pattern matches any remaining characters, so the
    # WHOLE string must be validated before it is spliced into a query
    # string.
    case "$key" in
        [A-Z]*) ;;
        *) die "boards: project key must look like a Jira key (e.g. PROJ), got '$key'" ;;
    esac
    case "$(printf '%s' "$key" | tr -d 'A-Z0-9')" in
        "") ;;
        *) die "boards: project key must be A-Z0-9 only (starting with a letter), got '$key'" ;;
    esac
    enc=$(jq -rn --arg v "$key" '$v|@uri') || die "boards: could not encode project key"
    api GET "/board?projectKeyOrId=$enc" | jq -r "$JQ_PRELUDE"'.values[]
        | "\(.id)\t\(blank(.name))\t\(blank(.type))"' \
        | table "ID	NAME	TYPE"
}

view_sprint() {
    local id="$1"
    case "$id" in ''|*[!0-9]*) die "sprint: sprint id must be numeric, got '$id'" ;; esac
    api GET "/sprint/$id" | jq -r "$JQ_PRELUDE"'
        "Id:        \(.id)",
        "Name:      \(blank(.name))",
        "State:     \(blank(.state))",
        "Board:     \(.originBoardId)",
        "Start:     \(blank(.startDate))",
        "End:       \(blank(.endDate))",
        "Complete:  \(blank(.completeDate))",
        "Goal:      \(blank(.goal))"'
}

# ---------------------------------------------------------------- write guard
#
# POST/PUT/PATCH need --yes or a y/N answer on a terminal. There is no
# DELETE path here (nothing this script exposes deletes anything).
show_request() {
    warn "$4 $1 https://$HOST/rest/agile/1.0$2"
    [ -n "$3" ] && warn "$4 body: $3"
    return 0
}

have_terminal() { [ -t 0 ] && [ -r /dev/tty ]; }
confirm_write() {
    local method="$1" answer
    [ "$ASSUME_YES" = "1" ] && return 0
    have_terminal || die "$method needs confirmation and there is no terminal — pass --yes if you really mean it"
    warn "Issue this $method? [y/N]"
    IFS= read -r answer < /dev/tty || die "could not read confirmation"
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) die "not confirmed — nothing was sent" ;;
    esac
}

do_write() {
    local method="$1" path="$2" body="${3:-}"
    require_path "$path"
    if [ "$DRY_RUN" = "1" ]; then
        show_request "$method" "$path" "$body" "would issue:"
        warn "--dry-run: nothing was sent, no credential was read."
        exit 0
    fi
    show_request "$method" "$path" "$body" "about to issue:"
    confirm_write "$method"
    emit "$method" "$path" "$body"
}

# sprint-create <board-id> <name> — a new sprint, state "future" (Jira's own
# default — POST /sprint does not accept a state field at all; see the
# header's SPRINT STATE MACHINE note).
do_sprint_create() {
    local board="$1" name="$2" body
    case "$board" in ''|*[!0-9]*) die "sprint-create: board id must be numeric, got '$board'" ;; esac
    [ -n "$name" ] || die "sprint-create: name must not be empty"
    body=$(jq -n --arg name "$name" --argjson board "$board" '{name: $name, originBoardId: $board}') \
        || die "sprint-create: could not build request body"
    do_write POST /sprint "$body"
}

# now_iso8601 / end_iso8601 — startDate/endDate are ALSO required to move a
# sprint to "active" (see the header's state-machine note), even though the
# create call a moment earlier accepted no dates at all. `date`'s
# relative-offset syntax differs between BSD (macOS) and GNU, so both forms
# are tried rather than assuming one.
now_iso8601() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
end_iso8601() {
    local days="$1"
    date -u -v+"${days}"d +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -d "+${days} day" +%Y-%m-%dT%H:%M:%S.000Z
}

# sprint-start <sprint-id> [--end <ISO-8601>] — future -> active. Required
# before sprint-close; see the header note. --end defaults to 24h from now,
# which is a placeholder Jira requires but that sprint-close does not check
# against — closing early is normal for a work-block sprint that finishes
# sooner than the placeholder end date implies.
do_sprint_start() {
    local id="$1" end="" body
    shift
    case "$id" in ''|*[!0-9]*) die "sprint-start: sprint id must be numeric, got '$id'" ;; esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --end)
                [ $# -ge 2 ] || die "sprint-start: --end needs a value"
                end="$2"; shift 2
                ;;
            *) die "sprint-start: unknown argument '$1'" ;;
        esac
    done
    [ -n "$end" ] || end=$(end_iso8601 1) || die "sprint-start: could not compute a default end date"
    body=$(jq -n --arg s "$(now_iso8601)" --arg e "$end" '{state: "active", startDate: $s, endDate: $e}') \
        || die "sprint-start: could not build request body"
    do_write POST "/sprint/$id" "$body"
}

# sprint-close <sprint-id> — active -> closed. Refuses (rather than
# force-starting) a sprint that is still "future" — see the header note.
do_sprint_close() {
    local id="$1" state body
    case "$id" in ''|*[!0-9]*) die "sprint-close: sprint id must be numeric, got '$id'" ;; esac
    if [ "$DRY_RUN" != "1" ]; then
        # api's own `die` (a non-2xx GET, e.g. a 404 for a bad sprint id)
        # runs inside this pipe inside a command substitution — that only
        # reaches the caller because the top-level `set -euo pipefail`
        # makes the pipeline's exit status the RIGHTMOST failing command's,
        # and `jq` itself exits 0 on api's empty stdout when api already
        # died, so `api`'s exit code, not jq's, is what `|| die` below
        # sees. Covered by jira-agile-api-selftest.sh's "close a
        # nonexistent sprint" case; do not remove `pipefail` without
        # re-checking this call site.
        state=$(api GET "/sprint/$id" | jq -r '.state') \
            || die "sprint-close: could not read current state of sprint $id"
        case "$state" in
            active) ;;
            future) die "sprint-close: sprint $id is still 'future' — run sprint-start $id first (closing a future sprint directly is rejected by Jira, and this script will not silently start it on your behalf, which would also set its start date to now)" ;;
            closed) die "sprint-close: sprint $id is already closed" ;;
            *) die "sprint-close: sprint $id is in unexpected state '$state'" ;;
        esac
    fi
    body=$(jq -n '{state: "closed"}') || die "sprint-close: could not build request body"
    do_write POST "/sprint/$id" "$body"
}

# sprint-update <sprint-id> [--name N] [--goal G] [--start ISO] [--end ISO] —
# partial PUT /sprint/{id}. Only fields named by a flag are sent (see the
# header note); at least one is required.
do_sprint_update() {
    local id="$1"; shift
    local name="" goal="" start="" end=""
    local has_name=0 has_goal=0 has_start=0 has_end=0
    local body
    case "$id" in ''|*[!0-9]*) die "sprint-update: sprint id must be numeric, got '$id'" ;; esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --name)
                [ $# -ge 2 ] || die "sprint-update: --name needs a value"
                name="$2"; has_name=1; shift 2 ;;
            --goal)
                [ $# -ge 2 ] || die "sprint-update: --goal needs a value"
                goal="$2"; has_goal=1; shift 2 ;;
            --start)
                [ $# -ge 2 ] || die "sprint-update: --start needs a value"
                start="$2"; has_start=1; shift 2 ;;
            --end)
                [ $# -ge 2 ] || die "sprint-update: --end needs a value"
                end="$2"; has_end=1; shift 2 ;;
            *) die "sprint-update: unknown argument '$1'" ;;
        esac
    done
    [ "$has_name$has_goal$has_start$has_end" != "0000" ] \
        || die "sprint-update: needs at least one of --name, --goal, --start, --end"
    body=$(jq -n \
        --arg name "$name" --argjson has_name "$has_name" \
        --arg goal "$goal" --argjson has_goal "$has_goal" \
        --arg start "$start" --argjson has_start "$has_start" \
        --arg end "$end" --argjson has_end "$has_end" \
        '{}
         | if $has_name == 1 then .name = $name else . end
         | if $has_goal == 1 then .goal = $goal else . end
         | if $has_start == 1 then .startDate = $start else . end
         | if $has_end == 1 then .endDate = $end else . end') \
        || die "sprint-update: could not build request body"
    do_write PUT "/sprint/$id" "$body"
}

# sprint-delete <sprint-id> — permanently deletes a sprint. Jira only
# accepts this for a 'future' sprint (see the header note); reads the
# current state first and refuses on active/closed rather than letting
# Jira's own rejection surface after the fact.
do_sprint_delete() {
    local id="$1" state
    case "$id" in ''|*[!0-9]*) die "sprint-delete: sprint id must be numeric, got '$id'" ;; esac
    if [ "$DRY_RUN" != "1" ]; then
        state=$(api GET "/sprint/$id" | jq -r '.state') \
            || die "sprint-delete: could not read current state of sprint $id"
        case "$state" in
            future) ;;
            active) die "sprint-delete: sprint $id is 'active' — Jira only allows deleting a 'future' sprint; use sprint-close to end it instead" ;;
            closed) die "sprint-delete: sprint $id is already 'closed' — Jira only allows deleting a 'future' sprint (a closed sprint is terminal, not removed)" ;;
            *) die "sprint-delete: sprint $id is in unexpected state '$state'" ;;
        esac
    fi
    do_write DELETE "/sprint/$id" ""
}

# sprint-add-issue <sprint-id> <issue-key>... — POST /sprint/{id}/issue,
# {issues:[keys...]}. Jira accepts a batch in one call; this passes every
# key given on the command line through in one request rather than looping,
# so a caller adding a whole wave issues exactly one POST.
do_sprint_add_issue() {
    local id="$1" body; shift
    case "$id" in ''|*[!0-9]*) die "sprint-add-issue: sprint id must be numeric, got '$id'" ;; esac
    [ $# -ge 1 ] || die "sprint-add-issue: needs at least one issue key"
    body=$(jq -n --args '{issues: $ARGS.positional}' -- "$@") \
        || die "sprint-add-issue: could not build request body"
    do_write POST "/sprint/$id/issue" "$body"
}

# ---------------------------------------------------------------- main

CMD="$1"; shift
case "$CMD" in
    boards)
        [ $# -ge 1 ] || die "boards needs a project key, e.g. boards PROJ"
        view_boards "$1"
        ;;
    sprint)
        [ $# -ge 1 ] || die "sprint needs a sprint id, e.g. sprint 7"
        view_sprint "$1"
        ;;
    sprint-create)
        [ $# -ge 2 ] || die "sprint-create needs a board id and a name, e.g. sprint-create 42 '2026-09-11 Thu evening'"
        do_sprint_create "$1" "$2"
        ;;
    sprint-start)
        [ $# -ge 1 ] || die "sprint-start needs a sprint id, e.g. sprint-start 7 [--end <ISO-8601>]"
        do_sprint_start "$@"
        ;;
    sprint-close)
        [ $# -ge 1 ] || die "sprint-close needs a sprint id, e.g. sprint-close 7"
        do_sprint_close "$1"
        ;;
    sprint-update)
        [ $# -ge 1 ] || die "sprint-update needs a sprint id, e.g. sprint-update 7 --goal 'ship it'"
        do_sprint_update "$@"
        ;;
    sprint-delete)
        [ $# -ge 1 ] || die "sprint-delete needs a sprint id, e.g. sprint-delete 7"
        do_sprint_delete "$1"
        ;;
    sprint-add-issue)
        [ $# -ge 2 ] || die "sprint-add-issue needs a sprint id and at least one issue key, e.g. sprint-add-issue 7 PROJ-1"
        do_sprint_add_issue "$@"
        ;;
    raw)
        [ $# -ge 2 ] || die "raw needs a METHOD and a path, e.g. raw GET /board"
        METHOD="$1"; RAWPATH="$2"
        case "$METHOD" in
            GET|HEAD) ;;
            *) die "raw is read-only and takes GET or HEAD — use 'write $METHOD $RAWPATH' for a mutating call, which is guarded" ;;
        esac
        require_path "$RAWPATH"
        if [ "$DRY_RUN" = "1" ]; then
            show_request "$METHOD" "$RAWPATH" "" "would issue:"
            exit 0
        fi
        emit "$METHOD" "$RAWPATH" ""
        ;;
    write)
        [ $# -ge 2 ] || die "write needs a METHOD and a path, e.g. write POST /sprint '{...}'"
        METHOD="$1"; RAWPATH="$2"; BODY="${3:-}"
        case "$METHOD" in
            POST|PUT|PATCH) ;;
            GET|HEAD) die "write is for mutating methods — use 'raw $METHOD $RAWPATH'" ;;
            DELETE) die "write does not support DELETE — use sprint-delete for that (guarded: only a 'future' sprint can be deleted)" ;;
            *) die "write takes POST, PUT or PATCH (got '$METHOD')" ;;
        esac
        do_write "$METHOD" "$RAWPATH" "$BODY"
        ;;
    *) die "unknown command '$CMD' — run with --help" ;;
esac
