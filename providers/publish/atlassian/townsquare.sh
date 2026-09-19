#!/bin/bash
#
# townsquare.sh — Atlassian Home Projects client over the platform GraphQL
# gateway (/gateway/api/graphql), the status-feed half of the `publish`
# kind's `atlassian` implementation (see providers/README.md). Home
# Projects has no REST API; its schema calls itself "Townsquare".
#
# Ships whoami, list projects, post a status update, and edits for a
# project's About tab and its Learning/Risk/Decision highlights. The
# free-form mutate passthrough stays unshipped — see docs/decisions.md,
# WO-037: a passthrough makes an arbitrary mutation one typo away.
#
# Usage:
#   townsquare.sh whoami
#   townsquare.sh projects                      # KEY, NAME, STATE, ID for every project
#                                               # on the site (first 100)
#   townsquare.sh update <project-ari> <status> -
#                                               # post a status update; text on stdin
#                                               # becomes the ADF summary. status is one of
#                                               # pending|on_track|at_risk|off_track|paused|
#                                               # cancelled|done|archived
#   townsquare.sh about <project-ari> -
#                                               # set the About tab. Stdin is one document
#                                               # split into sections by a line reading
#                                               # exactly (case-insensitive) "## what",
#                                               # "## why" or "## measurement"; a section
#                                               # not marked is left untouched, not blanked.
#   townsquare.sh learning <project-ari> -
#   townsquare.sh decision <project-ari> -
#   townsquare.sh risk     <project-ari> -
#                                               # add one Learning/Decision/Risk entry.
#                                               # Text on stdin becomes the ADF body; its
#                                               # first line also becomes the short
#                                               # plain-text summary the tab lists it by.
#
# Global flags, before the subcommand:
#   --dry-run   print the exact request that WOULD be issued, exit 0. No
#               network, no credential. Also on with $NW_DRY_RUN=1, or as
#               a write verb's sole argument (e.g. `learning --dry-run`).
#   --yes       skip the interactive confirmation for a write
#
# API facts this relies on (recorded live, see fixtures/townsquare/*.json):
#   - A project is addressed by its ARI (the ID column of `projects`),
#     never by its short key — a key is rejected as an invalid ARI.
#   - `update`'s summary and About/Learning/Risk/Decision's `description`
#     must be an ADF document JSON-stringified into the String field; plain
#     text fails with success:false "Invalid ADF". Learning/Risk/Decision's
#     `summary` is the one exception — confirmed plain text, sent as-is.
#   - A mutation can answer HTTP 200 with no top-level errors and still
#     report success:false; every write here checks the payload's own flag.
#   - The `update` summary is length-capped server-side (236 characters
#     accepted, 654 rejected in testing); provider.sh post-headline enforces
#     236. No such cap is confirmed for About/Learning/Risk/Decision.
#   - projects_search needs containerId = "ari:cloud:townsquare::site/<cloudId>",
#     resolved here from the host via tenantContexts.
#   - Operations must be named, or the gateway attaches a warning that
#     reads as an error.
#   - Risk and Decision's created id carries the ARI type segment
#     "learning" regardless — the server's own inconsistency, not a bug
#     here; the entry itself files under the right tab.
#
# Each write prints one line naming what was created or updated and the
# project ARI it went to.
#
# Exit codes: 0 success, 1 failure (including a rejected write).
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

# shellcheck disable=SC1091  # sourced at paths computed from $0
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATL_PROVIDERS_DIR="$(cd "$DIR/../.." && pwd)"
# shellcheck source=../../lib/kit.sh
. "$ATL_PROVIDERS_DIR/lib/kit.sh"
# shellcheck source=../../lib/config.sh
. "$ATL_PROVIDERS_DIR/lib/config.sh"
# shellcheck source=../../tracker/jira/lib/http.sh
. "$ATL_PROVIDERS_DIR/tracker/jira/lib/http.sh"
# shellcheck source=lib/atlassian-common.sh
. "$DIR/lib/atlassian-common.sh"

DRY_RUN=0
[ "${NW_DRY_RUN:-0}" = "1" ] && DRY_RUN=1
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        *) break ;;
    esac
done

[ $# -ge 1 ] || show_help
case "$1" in -h|--help|help) show_help ;; esac

need curl jq column
atl_resolve_host

# api QUERY VARS — dies on transport failure, non-2xx, or top-level GraphQL
# errors. Top-level only (redirect into a file), never inside $( ).
api() {
    local query="$1" vars="$2" out code rc=0 bodyfile
    atl_load_credentials
    out=$(tmpfile) || die "could not create temp file"
    bodyfile=$(tmpfile) || die "could not create temp file"
    jq -cn --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}' > "$bodyfile" \
        || die "could not build the GraphQL request body"
    code=$(curl_auth_config "$ATL_USER" "$ATL_TOKEN" \
        | curl -s -m"$LABKIT_TIMEOUT" --config - -X POST \
               -H 'Content-Type: application/json' \
               --data-binary @"$bodyfile" \
               -o "$out" -w '%{http_code}' \
               "https://$HOST/gateway/api/graphql") || rc=$?
    [ "$rc" -eq 0 ] || die "POST /gateway/api/graphql: could not reach https://$HOST (curl exit $rc)"
    case "$code" in
        2??) ;;
        *)
            warn "townsquare: HTTP $code POST /gateway/api/graphql"
            atl_error_body "$out"
            die "POST /gateway/api/graphql failed (HTTP $code)"
            ;;
    esac
    if jq -e '(.errors // []) | length > 0' < "$out" >/dev/null 2>&1; then
        warn "townsquare: GraphQL errors in response"
        atl_error_body "$out"
        die "POST /gateway/api/graphql returned GraphQL errors (HTTP $code)"
    fi
    cat "$out"
}

would_issue() {
    warn "would issue: POST https://$HOST/gateway/api/graphql"
    warn "would issue query: $1"
    warn "would issue variables: $2"
    warn "--dry-run: nothing was sent, no credential was read."
}

# adf_doc TEXT — bare ADF document, one paragraph per line.
adf_doc() {
    jq -cn --arg t "$1" '{
        type: "doc", version: 1,
        content: ($t | gsub("\r"; "") | sub("\n+$"; "") | split("\n") | map(
            if . == "" then {type: "paragraph", content: []}
            else {type: "paragraph", content: [{type: "text", text: .}]} end
        ))
    }'
}

# about_from_stdin — stdin split by lines "## what"/"## why"/"## measurement"
# (case-insensitive); prints JSON with only the sections seen, since an
# omitted one is left alone server-side rather than blanked (confirmed live).
about_from_stdin() {
    local raw section="" line has_what=0 has_why=0 has_measurement=0 \
        what="" why="" measurement="" what_adf="" why_adf="" measurement_adf=""
    raw=$(cat) || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]' | sed -e 's/[[:space:]]*$//')" in
            "## what")        section="what";        has_what=1;        continue ;;
            "## why")         section="why";          has_why=1;         continue ;;
            "## measurement") section="measurement";  has_measurement=1; continue ;;
        esac
        case "$section" in
            what)        what="${what}${line}"$'\n' ;;
            why)         why="${why}${line}"$'\n' ;;
            measurement) measurement="${measurement}${line}"$'\n' ;;
        esac
    done <<< "$raw"
    [ "$has_what" = "1" ] || [ "$has_why" = "1" ] || [ "$has_measurement" = "1" ] || return 1
    what="${what%$'\n'}"; why="${why%$'\n'}"; measurement="${measurement%$'\n'}"
    [ "$has_what" = "1" ]        && { what_adf=$(adf_doc "$what") || return 1; }
    [ "$has_why" = "1" ]         && { why_adf=$(adf_doc "$why") || return 1; }
    [ "$has_measurement" = "1" ] && { measurement_adf=$(adf_doc "$measurement") || return 1; }
    jq -cn \
        --argjson hw "$has_what" --arg w "$what_adf" \
        --argjson hy "$has_why" --arg y "$why_adf" \
        --argjson hm "$has_measurement" --arg m "$measurement_adf" \
        '({} + (if $hw==1 then {what:$w} else {} end)
             + (if $hy==1 then {why:$y} else {} end)
             + (if $hm==1 then {measurement:$m} else {} end))'
}

# highlight_meta KIND — sets OPNAME/FIELDNAME/LABEL for learning|risk|decision.
# Three distinct mutations, not one type+enum (introspected live).
highlight_meta() {
    case "$1" in
        learning) OPNAME="projects_createLearning"; FIELDNAME="learning"; LABEL="Learning" ;;
        risk)     OPNAME="projects_createRisk";     FIELDNAME="risk";     LABEL="Risk" ;;
        decision) OPNAME="projects_createDecision"; FIELDNAME="decision"; LABEL="Decision" ;;
        *) die "highlight_meta: unknown kind '$1'" ;;
    esac
}

# create_highlight KIND PID SUMMARY TEXT — KIND is learning|risk|decision.
# SUMMARY is sent as plain text; TEXT is ADF-encoded into `description`.
create_highlight() {
    local kind="$1" pid="$2" summary="$3" text="$4" query vars out success err new_id adf
    highlight_meta "$kind"
    adf=$(adf_doc "$text") || die "could not build the ADF description"
    query="mutation Create$LABEL(\$pid: ID!, \$summary: String!, \$description: String!) { $OPNAME(input: { projectId: \$pid, summary: \$summary, description: \$description }) { success errors { message } $FIELDNAME { id } } }"
    vars=$(jq -cn --arg pid "$pid" --arg summary "$summary" --arg description "$adf" \
        '{pid: $pid, summary: $summary, description: $description}') \
        || die "could not build request variables"
    if [ "$DRY_RUN" = "1" ]; then would_issue "$query" "$vars"; exit 0; fi
    warn "about to issue: POST https://$HOST/gateway/api/graphql ($OPNAME on $pid)"
    atl_confirm "this $LABEL entry"
    out=$(tmpfile) || die "could not create temp file"
    api "$query" "$vars" > "$out"
    success=$(jq -r --arg op "$OPNAME" '.data[$op].success' < "$out") || die "could not parse the $OPNAME response"
    if [ "$success" != "true" ]; then
        err=$(jq -r --arg op "$OPNAME" '[.data[$op].errors[]?.message] | join("; ")' < "$out") || err="(could not parse the error payload)"
        die "$OPNAME reported failure: $err"
    fi
    new_id=$(jq -r --arg op "$OPNAME" --arg f "$FIELDNAME" '.data[$op][$f].id // empty' < "$out") \
        || die "could not parse the created $kind's id from the response"
    [ -n "$new_id" ] || die "$OPNAME reported success but the response carried no id"
    echo "$LABEL $new_id created on $pid"
}

CMD="$1"; shift
case "$CMD" in
    whoami)
        Q='query Whoami { me { user { accountId name } } }'
        if [ "$DRY_RUN" = "1" ]; then would_issue "$Q" '{}'; exit 0; fi
        OUT=$(tmpfile) || die "could not create temp file"
        api "$Q" '{}' > "$OUT"
        jq -r "$JQ_PRELUDE"'
            "Account:    \(blank(.data.me.user.name))",
            "Account ID: \(blank(.data.me.user.accountId))"' < "$OUT"
        ;;
    projects)
        [ $# -eq 0 ] || die "usage: townsquare.sh projects"
        # shellcheck disable=SC2016  # $h/$cid/$s are GraphQL variables
        TQ='query TenantCtx($h: [String!]) { tenantContexts(hostNames: $h) { cloudId } }'
        # shellcheck disable=SC2016
        PQ='query Projects($cid: String!, $s: String!) { projects_search(searchString: $s, containerId: $cid, first: 100) { edges { node { id key name state { label } } } } }'
        TVARS=$(jq -cn --arg h "$HOST" '{h: [$h]}') || die "could not build request variables"
        if [ "$DRY_RUN" = "1" ]; then
            would_issue "$TQ" "$TVARS"
            would_issue "$PQ" '{"cid":"<resolved live via tenantContexts>","s":""}'
            exit 0
        fi
        OUT=$(tmpfile) || die "could not create temp file"
        api "$TQ" "$TVARS" > "$OUT"
        CLOUD=$(jq -r '.data.tenantContexts[0].cloudId // empty' < "$OUT") || true
        [ -n "$CLOUD" ] || die "could not resolve the site's cloud id for '$HOST'"
        PVARS=$(jq -cn --arg cid "ari:cloud:townsquare::site/$CLOUD" '{cid: $cid, s: ""}') || die "could not build request variables"
        api "$PQ" "$PVARS" > "$OUT"
        # Named extraction, never redact_json: its word list blanks a bare `key`.
        jq -r "$JQ_PRELUDE"'.data.projects_search.edges[]? | .node
            | "\(blank(.key))\t\(blank(.name))\t\(blank(.state.label))\t\(blank(.id))"' < "$OUT" \
            | table "KEY	NAME	STATE	ID"
        ;;
    update)
        [ $# -eq 3 ] || die "usage: townsquare.sh update <project-ari> <status> -"
        UPID="$1"; USTATUS="$2"
        [ "$3" = "-" ] || die "update: the update text is always read from stdin — pass '-' as the last argument"
        case "$UPID" in
            ari:cloud:townsquare:*:project/*) ;;
            *) die "update: project id must be a Home Project ARI (ari:cloud:townsquare:<cloud>:project/<uuid>), not a key — got '${UPID:0:60}'" ;;
        esac
        case "$USTATUS" in
            pending|on_track|at_risk|off_track|paused|cancelled|done|archived) ;;
            *) die "update: status must be one of pending|on_track|at_risk|off_track|paused|cancelled|done|archived (got '$USTATUS')" ;;
        esac
        UTEXT=$(cat) || die "could not read update text from stdin"
        [ -n "$UTEXT" ] || die "update text is empty — refusing to post an empty update"
        UADF=$(adf_doc "$UTEXT") || die "could not build the ADF summary"
        # shellcheck disable=SC2016  # $pid/$status/$summary are GraphQL variables
        UQ='mutation CreateUpdate($pid: ID!, $status: String, $summary: String) { projects_createUpdate(input: { projectId: $pid, status: $status, summary: $summary }) { success errors { message } update { id creationDate } } }'
        UVARS=$(jq -cn --arg pid "$UPID" --arg status "$USTATUS" --arg summary "$UADF" '{pid: $pid, status: $status, summary: $summary}') \
            || die "could not build request variables"
        if [ "$DRY_RUN" = "1" ]; then would_issue "$UQ" "$UVARS"; exit 0; fi
        warn "about to issue: POST https://$HOST/gateway/api/graphql (projects_createUpdate on $UPID)"
        atl_confirm "this status update"
        OUT=$(tmpfile) || die "could not create temp file"
        api "$UQ" "$UVARS" > "$OUT"
        USUCCESS=$(jq -r '.data.projects_createUpdate.success' < "$OUT") || die "could not parse the projects_createUpdate response"
        if [ "$USUCCESS" != "true" ]; then
            UERR=$(jq -r '[.data.projects_createUpdate.errors[]?.message] | join("; ")' < "$OUT") || UERR="(could not parse the error payload)"
            die "projects_createUpdate reported failure: $UERR"
        fi
        UNEW=$(jq -r '.data.projects_createUpdate.update.id // empty' < "$OUT")
        [ -n "$UNEW" ] || die "projects_createUpdate reported success but the response carried no update id"
        echo "Update $UNEW posted on $UPID"
        ;;
    about)
        # shellcheck disable=SC2016  # $id/$what/$why/$measurement are GraphQL variables
        ABQ='mutation EditAbout($id: ID!, $what: String, $why: String, $measurement: String) { projects_edit(input: { id: $id, description: { what: $what, why: $why, measurement: $measurement } }) { success errors { message } project { id } } }'
        if [ $# -eq 1 ] && [ "$1" = "--dry-run" ]; then
            would_issue "$ABQ" \
                '{"id":"<caller-supplied ARI>","...":"<only the \"## what\"/\"## why\"/\"## measurement\" sections present on stdin>"}'
            exit 0
        fi
        [ $# -eq 2 ] || die "usage: townsquare.sh about <project-ari> -"
        ABPID="$1"
        [ "$2" = "-" ] || die "about: the description is always read from stdin — pass '-' as the last argument"
        if [ "$DRY_RUN" = "1" ]; then
            ABJSON=$(about_from_stdin) || ABJSON='{}'
        else
            case "$ABPID" in
                ari:cloud:townsquare:*:project/*) ;;
                *) die "about: project id must be a Home Project ARI (ari:cloud:townsquare:<cloud>:project/<uuid>), not a key — got '${ABPID:0:60}'" ;;
            esac
            ABJSON=$(about_from_stdin) || die "about: stdin had none of the '## what' / '## why' / '## measurement' markers — nothing to update"
        fi
        ABVARS=$(jq -cn --arg id "$ABPID" --argjson d "$ABJSON" '{id: $id} + $d') || die "could not build request variables"
        if [ "$DRY_RUN" = "1" ]; then would_issue "$ABQ" "$ABVARS"; exit 0; fi
        warn "about to issue: POST https://$HOST/gateway/api/graphql (projects_edit on $ABPID)"
        atl_confirm "this About edit"
        ABOUT=$(tmpfile) || die "could not create temp file"
        api "$ABQ" "$ABVARS" > "$ABOUT"
        ABSUCCESS=$(jq -r '.data.projects_edit.success' < "$ABOUT") || die "could not parse the projects_edit response"
        if [ "$ABSUCCESS" != "true" ]; then
            ABERR=$(jq -r '[.data.projects_edit.errors[]?.message] | join("; ")' < "$ABOUT") || ABERR="(could not parse the error payload)"
            die "projects_edit reported failure: $ABERR"
        fi
        echo "About updated on $ABPID"
        ;;
    learning|decision|risk)
        if [ $# -eq 1 ] && [ "$1" = "--dry-run" ]; then
            highlight_meta "$CMD"
            would_issue "mutation Create$LABEL(\$pid: ID!, \$summary: String!, \$description: String!) { $OPNAME(input: { projectId: \$pid, summary: \$summary, description: \$description }) { success errors { message } $FIELDNAME { id } } }" \
                '{"pid":"<caller-supplied ARI>","summary":"<first line of stdin>","description":"<ADF of stdin>"}'
            exit 0
        fi
        [ $# -eq 2 ] || die "usage: townsquare.sh $CMD <project-ari> -"
        HPID="$1"
        [ "$2" = "-" ] || die "$CMD: the body is always read from stdin — pass '-' as the last argument"
        if [ "$DRY_RUN" != "1" ]; then
            case "$HPID" in
                ari:cloud:townsquare:*:project/*) ;;
                *) die "$CMD: project id must be a Home Project ARI (ari:cloud:townsquare:<cloud>:project/<uuid>), not a key — got '${HPID:0:60}'" ;;
            esac
        fi
        HTEXT=$(cat) || die "could not read $CMD text from stdin"
        if [ "$DRY_RUN" != "1" ]; then
            [ -n "$HTEXT" ] || die "$CMD text is empty — refusing to create an empty $CMD"
        fi
        # First line doubles as the plain-text summary; the whole text is
        # the ADF description, so a single-line input serves both.
        HSUMMARY="${HTEXT%%$'\n'*}"
        HSUMMARY="${HSUMMARY%$'\r'}"
        create_highlight "$CMD" "$HPID" "$HSUMMARY" "$HTEXT"
        ;;
    *) die "unknown command '$CMD' — run with --help" ;;
esac
