#!/bin/bash
#
# townsquare.sh — Atlassian Home Projects client over the platform GraphQL
# gateway (/gateway/api/graphql), the status-feed half of the `publish`
# kind's `atlassian` implementation (see providers/README.md). Home
# Projects has no REST API; its schema calls itself "Townsquare".
#
# Trimmed to what posting a headline needs: whoami, list projects (to find a
# feed's id), post one status update. Project creation, About/Learning/Risk/
# Decision edits and the free-form mutate passthrough are not shipped.
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
#
# Global flags, before the subcommand:
#   --dry-run   print the exact request that WOULD be issued, exit 0. No
#               network, no credential. Also on with $NW_DRY_RUN=1.
#   --yes       skip the interactive confirmation for update
#
# API facts this relies on (recorded live, see fixtures/townsquare/*.json):
#   - A project is addressed by its ARI (the ID column of `projects`),
#     never by its short key — a key is rejected as an invalid ARI.
#   - `summary` must be an ADF document JSON-stringified into the String
#     field; plain text fails with success:false "Invalid ADF".
#   - A mutation can answer HTTP 200 with no top-level errors and still
#     report success:false; `update` checks the payload's own flag.
#   - The summary is length-capped server-side (236 characters accepted,
#     654 rejected in testing); provider.sh post-headline enforces 236.
#   - projects_search needs containerId = "ari:cloud:townsquare::site/<cloudId>",
#     resolved here from the host via tenantContexts.
#   - Operations must be named, or the gateway attaches a warning that
#     reads as an error.
#
# `update` prints one line: `Update <update-ari> posted on <project-ari>`.
#
# Exit codes: 0 success, 1 failure (including a rejected post).
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
    *) die "unknown command '$CMD' — run with --help" ;;
esac
