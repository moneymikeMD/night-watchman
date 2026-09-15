#!/bin/bash
#
# ROUND-1 FIXTURE (frozen for evals/script-reviewer). This is a
# trimmed reconstruction of the first pass of trackers/jira/jira-workflow-apply.sh,
# with the five bugs found during that review still in place, seeded from
# the real incident narrated in the final script's header comments
# (git show 409ea45:trackers/jira/jira-workflow-apply.sh) and commit
# history (bfe325b, 4a347ab). NEVER run this against a live Jira project —
# it is a review fixture only.
#
# Adds six plugin-stage statuses/transitions to a project's default
# workflow via POST /rest/api/3/workflows/update, through a
# jira-api.sh-shaped wrapper.

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib/kit.sh"

TARGET_STATUS_LIST='Open
Triage
Awaiting Deployment
Deferred
Completed
Cancelled'
TARGET_TRANSITION_IDS='51
41
61
71
81
91'

PROJECT_KEY=""
JIRA_API_PATH="${ISSUES_JIRA_API:-}"
DRY_RUN=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|help) show_help ;;
        --jira-api) [ $# -ge 2 ] || die "--jira-api needs a path"; JIRA_API_PATH="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        --) shift; break ;;
        -*) die "unknown flag '$1' — run with --help" ;;
        *) [ -z "$PROJECT_KEY" ] || die "unexpected extra argument '$1'"; PROJECT_KEY="$1"; shift ;;
    esac
done

[ -n "$PROJECT_KEY" ] || die "a PROJECT_KEY is required"
[ -n "$JIRA_API_PATH" ] || die "no jira-api.sh-shaped wrapper given — pass --jira-api PATH or export \$ISSUES_JIRA_API"
[ -x "$JIRA_API_PATH" ] || die "--jira-api path is not an executable file: '$JIRA_API_PATH'"

need jq

jira_raw_get() { "$JIRA_API_PATH" raw GET "$1"; }
jira_write() { local method="$1" path="$2" body="$3"; "$JIRA_API_PATH" --yes write "$method" "$path" "$body"; }

# --------------------------------------------------------------- status ids
#
# resolve_status_ids — populate RESOLVED_STATUS_IDS by NAME from
# GET /statuses/search?maxResults=100.
RESOLVED_STATUS_IDS=""
resolve_status_ids() {
    local all missing="" name id ids=""
    all=$(jira_raw_get "/statuses/search?maxResults=100") \
        || die "could not read /statuses/search"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        id=$(printf '%s' "$all" | jq -r --arg n "$name" '[.values[] | select(.name == $n)][0].id // empty') \
            || die "could not parse /statuses/search response while resolving '$name'"
        if [ -z "$id" ]; then
            missing="$missing$name, "
        else
            ids="$ids$id
"
        fi
    done <<EOF
$TARGET_STATUS_LIST
EOF
    [ -z "$missing" ] || die "these status names do not exist on this Jira site: ${missing%, }"
    RESOLVED_STATUS_IDS="$ids"
}

# --------------------------------------------------------------- workflow read

WORKFLOW_NAME=""
WORKFLOW_ENTITY_ID=""
WORKFLOW_JSON=""

read_workflow() {
    local key="$1" enc total
    WORKFLOW_NAME="Software Simplified Workflow for Project $key"
    enc=$(jq -rn --arg v "$WORKFLOW_NAME" '$v|@uri') || die "could not url-encode workflow name"
    WORKFLOW_JSON=$(jira_raw_get "/workflow/search?workflowName=$enc&expand=transitions,statuses") \
        || die "could not read workflow '$WORKFLOW_NAME'"
    total=$(printf '%s' "$WORKFLOW_JSON" | jq -r '.total // 0') || die "could not parse workflow/search response"
    [ "$total" -ge 1 ] 2>/dev/null || die "no workflow named '$WORKFLOW_NAME' was found"
    WORKFLOW_ENTITY_ID=$(printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].id.entityId // empty') \
        || die "could not read the workflow's entityId"
    [ -n "$WORKFLOW_ENTITY_ID" ] || die "workflow/search response has no id.entityId"
}

workflow_status_names() { printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].statuses[].name'; }
workflow_transition_names() { printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].transitions[].name'; }

name_in_list() { printf '%s\n' "$2" | grep -qxF "$1"; }

MISSING_STATUS_NAMES=""
MISSING_TRANSITION_NAMES=""

compute_missing() {
    local have_statuses have_transitions name
    have_statuses=$(workflow_status_names) || die "could not read current statuses"
    have_transitions=$(workflow_transition_names) || die "could not read current transitions"
    MISSING_STATUS_NAMES=""
    MISSING_TRANSITION_NAMES=""
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        name_in_list "$name" "$have_statuses" || MISSING_STATUS_NAMES="$MISSING_STATUS_NAMES$name
"
        name_in_list "$name" "$have_transitions" || MISSING_TRANSITION_NAMES="$MISSING_TRANSITION_NAMES$name
"
    done <<EOF
$TARGET_STATUS_LIST
EOF
}

# --------------------------------------------------------------- update body
#
# build_update_body <bulkget-response-json> <version-json> — renders the
# POST /workflows/update request body.
#
# NOTE: additions are computed from MISSING_STATUS_NAMES only. A name
# whose status already exists but whose transition is still missing (or
# vice versa) is not separately covered here.
build_update_body() {
    local bulkget_json="$1" version_json="$2"
    jq -n \
        --argjson bulkget "$bulkget_json" \
        --arg wfname "$WORKFLOW_NAME" \
        --argjson version "$version_json" \
        --arg targetNamesNL "$TARGET_STATUS_LIST" \
        --arg statusIdsNL "$RESOLVED_STATUS_IDS" \
        --arg transitionIdsNL "$TARGET_TRANSITION_IDS" \
        --arg missingStatusNamesNL "$MISSING_STATUS_NAMES" \
        '
        def lines: split("\n") | map(select(length > 0));
        ( $targetNamesNL | lines ) as $allNames
        | ( $statusIdsNL | lines ) as $allIds
        | ( $transitionIdsNL | lines ) as $allTransIds
        | ( $missingStatusNamesNL | lines ) as $missingStatusNames
        | [ range(0; ($allNames | length))
            | { name: $allNames[.], id: $allIds[.], transitionId: $allTransIds[.] }
          ] as $resolved
        # Additions: status + transition for every name still missing a
        # STATUS. statusCategory is left null — resolve_status_ids above
        # never captured it, and it is a required enum on any status
        # definition /workflows/update accepts.
        | [ $resolved[] | select(.name as $n | $missingStatusNames | index($n) != null)
            | { id: .id, statusReference: .id, name: .name, statusCategory: null }
          ] as $status_additions
        | [ $resolved[] | select(.name as $n | $missingStatusNames | index($n) != null)
            | { id: .transitionId, name: .name, type: "GLOBAL", toStatusReference: .id }
          ] as $transition_additions
        | ($bulkget.workflows[] | select(.name == $wfname)) as $wf
        # Request body carries ONLY the additions — existing statuses and
        # transitions already on the workflow are not re-declared here.
        | {
            statuses: $status_additions,
            workflows: [ {
                id: $wf.id,
                version: $version,
                statuses: ($status_additions | map({statusReference})),
                transitions: $transition_additions
            } ]
        }
        '
}

# --------------------------------------------------------------- main

resolve_status_ids
read_workflow "$PROJECT_KEY"
compute_missing

if [ -z "$MISSING_STATUS_NAMES" ] && [ -z "$MISSING_TRANSITION_NAMES" ]; then
    echo "already complete."
    exit 0
fi

VERSION_BULKGET_BODY=$(jq -n --arg n "$WORKFLOW_NAME" '{workflowNames: [$n]}') \
    || die "could not build /workflows bulk-get request body"
VERSION_RESP=$(jira_write POST /workflows "$VERSION_BULKGET_BODY") \
    || die "could not obtain the workflow's current version"
# Version selector: nested under an {name, entityId} id object, matching
# workflow/search's OWN read shape rather than POST /workflows's actual
# response shape (a plain top-level string `name` per workflow object).
VERSION_JSON=$(printf '%s' "$VERSION_RESP" | jq -c --arg n "$WORKFLOW_NAME" '[.workflows[] | select(.id.name == $n)][0].version // null') \
    || die "could not parse POST /workflows response"
[ "$VERSION_JSON" != "null" ] || die "POST /workflows returned no 'version' for '$WORKFLOW_NAME'"

FINAL_BODY=$(build_update_body "$VERSION_RESP" "$VERSION_JSON") \
    || die "could not render the /workflows/update request body"

echo "This is the request body for /rest/api/3/workflows/update:"
printf '%s\n' "$FINAL_BODY" | jq .

if [ "$DRY_RUN" = "1" ]; then
    exit 0
fi

if [ "$ASSUME_YES" != "1" ]; then
    warn "not confirmed (no --yes) — the update was never sent."
    exit 3
fi

jira_write POST /workflows/update "$FINAL_BODY" \
    || die "POST /workflows/update failed outright"
