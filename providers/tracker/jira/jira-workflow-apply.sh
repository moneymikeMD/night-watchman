#!/bin/bash
#
# jira-workflow-apply.sh — adds this plugin's six stage statuses (Open,
# Triage, Awaiting Deployment, Deferred, Completed, Cancelled) and a GLOBAL
# transition into each to a Jira company-managed project's own copy of the
# "simplified scrum classic" template workflow, which ships only To Do/In
# Progress/Done. Idempotent: "already complete" exits 0 doing nothing.
#
# Every status id, statusCategory and transition id is resolved by NAME at
# runtime — all three are assigned per Jira SITE, never hardcode one.
#
# Existing statuses and transitions are carried forward with EVERY field
# the bulk-get returned. POST /workflows/update REPLACES a transition
# wholesale rather than merging, so omitting a field DELETES it.
#
# Usage:
#   ./jira-workflow-apply.sh <PROJECT_KEY> [--jira-api PATH] [--dry-run]
#                             [--yes] [--restore-from PATH] [--rules PATH]
#
#   PROJECT_KEY      the Jira project key, e.g. NWM
#   --jira-api PATH  path to a jira-api.sh-shaped wrapper. Defaults to
#                     $ISSUES_JIRA_API; one of the two is required.
#   --dry-run        run every read-only call and print the exact FINAL
#                     request body, then exit 0 without calling
#                     /workflows/update itself.
#   --yes            actually issue the /workflows/update write. THIS
#                     SCRIPT'S OWN --yes IS THE ONLY GATE: the wrapper's
#                     own --yes is passed through unconditionally, so its
#                     interactive y/N never fires for that call.
#   --restore-from PATH   re-POST the exact workflow document in PATH (a
#                     snapshot this script wrote) with a FRESH `version`.
#                     A literal restore, not "add whatever's missing".
#                     REFUSES a file containing "<redacted>": a rule value
#                     only ever seen redacted cannot be recovered.
#   --rules PATH     also ensure the transition validators in PATH (see
#                     workflow-rules.json) are present. Additive only,
#                     matched by ruleKey + parameters; nothing is removed.
#                     Not combinable with --restore-from.
#
# Examples:
#   ./jira-workflow-apply.sh NWM --dry-run
#   ./jira-workflow-apply.sh NWM --yes
#   ./jira-workflow-apply.sh SPK4 --rules workflow-rules.json --dry-run
#   ./jira-workflow-apply.sh SPK4 --restore-from /tmp/jira-workflow-apply.SPK4.<epoch>.before.json --yes
#
# Env vars:
#   ISSUES_JIRA_API   default --jira-api path.
#
# Exit status:
#   0   already complete, --dry-run completed, or the write succeeded and
#       the read-back and deep-diff both prove it.
#   1   a general failure — nothing was changed.
#   2   the write SUCCEEDED but the post-write rule deep-diff shows an
#       existing transition's rules changed: changed, but not safely. See
#       the before/after snapshot paths this run printed.
#   3   stopped because --yes was not given. A refusal, not a failure.

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib/kit.sh
. "$DIR/../../lib/kit.sh"
# shellcheck source=lib/http.sh
. "$DIR/lib/http.sh"

# Parallel, newline-separated lists in exact table order (bash 3.2 has no
# associative arrays, and a space-split string would break on the names
# that contain a space, e.g. "Awaiting Deployment").
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
RESTORE_FROM=""
RULES_PATH=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|help) show_help ;;
        --jira-api)
            [ $# -ge 2 ] || die "--jira-api needs a path"
            JIRA_API_PATH="$2"; shift 2
            ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        --restore-from)
            [ $# -ge 2 ] || die "--restore-from needs a path to a before/after snapshot file"
            RESTORE_FROM="$2"; shift 2
            ;;
        --rules)
            [ $# -ge 2 ] || die "--rules needs a path to a rules spec (see workflow-rules.json)"
            RULES_PATH="$2"; shift 2
            ;;
        --) shift; break ;;
        -*) die "unknown flag '$1' — run with --help" ;;
        *)
            [ -z "$PROJECT_KEY" ] || die "unexpected extra argument '$1' (project key already given: '$PROJECT_KEY')"
            PROJECT_KEY="$1"; shift
            ;;
    esac
done

[ -n "$PROJECT_KEY" ] || die "a PROJECT_KEY is required, e.g. $(basename "$0") NWM --dry-run"
case "$PROJECT_KEY" in
    [A-Z]*) ;;
    *) die "PROJECT_KEY must look like a Jira project key (e.g. NWM), got '$PROJECT_KEY'" ;;
esac
case "$(printf '%s' "$PROJECT_KEY" | tr -d 'A-Z0-9')" in
    "") ;;
    *) die "PROJECT_KEY must be A-Z0-9 only (starting with a letter), got '$PROJECT_KEY'" ;;
esac

[ -n "$JIRA_API_PATH" ] || die "no jira-api.sh-shaped wrapper given — pass --jira-api PATH or export \$ISSUES_JIRA_API"
[ -x "$JIRA_API_PATH" ] || die "--jira-api path is not an executable file: '$JIRA_API_PATH'"

need jq

if [ -n "$RULES_PATH" ]; then
    [ -z "$RESTORE_FROM" ] || die "--rules and --restore-from are mutually exclusive (a restore is literal)"
    [ -f "$RULES_PATH" ] || die "--rules file not found: '$RULES_PATH'"
fi

# jira_raw_get <path> — GET through the wrapper, output already redacted.
jira_raw_get() {
    "$JIRA_API_PATH" raw GET "$1"
}

# jira_write_readonly_semantics <method> <path> <body> — a POST that does
# NOT mutate anything despite the verb, routed through the wrapper's
# `write` only because its verb allowlist has no other category for a
# POST. Runs even under --dry-run.
jira_write_readonly_semantics() {
    local method="$1" path="$2" body="$3"
    "$JIRA_API_PATH" --yes write "$method" "$path" "$body"
}

# jira_bulkget <workflowNames-body> — POST /workflows, the ONLY use of
# --show-secrets here. Without it the wrapper blanks ruleKey/permissionKey
# (rule identifiers, not credentials) and the round-trip destroys the rule.
jira_bulkget() {
    local body="$1"
    "$JIRA_API_PATH" --show-secrets --yes write POST /workflows "$body"
}

# jira_write_mutating <method> <path> <body> — the one call in this script
# that actually changes Jira state. Never called under --dry-run or
# without ASSUME_YES=1.
jira_write_mutating() {
    local method="$1" path="$2" body="$3"
    "$JIRA_API_PATH" --yes write "$method" "$path" "$body"
}

# resolve_status_ids — fill RESOLVED_STATUS_IDS and
# RESOLVED_STATUS_CATEGORIES by NAME from /statuses/search, in
# TARGET_STATUS_LIST order, dying on every name it could not find.
RESOLVED_STATUS_IDS=""
RESOLVED_STATUS_CATEGORIES=""
resolve_status_ids() {
    local all missing="" name id category ids="" categories=""
    all=$(jira_raw_get "/statuses/search?maxResults=100") \
        || die "could not read /statuses/search — cannot resolve target status ids by name"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        id=$(printf '%s' "$all" | jq -r --arg n "$name" '[.values[] | select(.name == $n)][0].id // empty') \
            || die "could not parse /statuses/search response while resolving '$name'"
        category=$(printf '%s' "$all" | jq -r --arg n "$name" '[.values[] | select(.name == $n)][0].statusCategory // empty') \
            || die "could not parse /statuses/search response while resolving '$name''s category"
        if [ -z "$id" ] || [ -z "$category" ]; then
            missing="$missing$name, "
        else
            ids="$ids$id
"
            categories="$categories$category
"
        fi
    done <<EOF
$TARGET_STATUS_LIST
EOF
    [ -z "$missing" ] || die "these status names do not exist on this Jira site (resolve by NAME, never hardcode an id): ${missing%, }"
    RESOLVED_STATUS_IDS="$ids"
    RESOLVED_STATUS_CATEGORIES="$categories"
}


WORKFLOW_NAME=""
WORKFLOW_ENTITY_ID=""
WORKFLOW_JSON=""

# read_workflow <project-key> — GET /workflow/search for "Software
# Simplified Workflow for Project <KEY>", dying if Jira has none by that
# exact name. Captures the entityId an update request needs as `id`.
read_workflow() {
    local key="$1" enc total
    WORKFLOW_NAME="Software Simplified Workflow for Project $key"
    enc=$(jq -rn --arg v "$WORKFLOW_NAME" '$v|@uri') \
        || die "could not url-encode workflow name"
    WORKFLOW_JSON=$(jira_raw_get "/workflow/search?workflowName=$enc&expand=transitions,statuses") \
        || die "could not read workflow '$WORKFLOW_NAME'"
    total=$(printf '%s' "$WORKFLOW_JSON" | jq -r '.total // 0') \
        || die "could not parse workflow/search response"
    [ "$total" -ge 1 ] 2>/dev/null || die "no workflow named '$WORKFLOW_NAME' was found — is '$key' a project created from the simplified-scrum template, with its default (uncopied) workflow still in place?"
    WORKFLOW_ENTITY_ID=$(printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].id.entityId // empty') \
        || die "could not read the workflow's entityId from workflow/search"
    [ -n "$WORKFLOW_ENTITY_ID" ] || die "workflow/search response for '$WORKFLOW_NAME' has no id.entityId — cannot build an update request without it"
}

# workflow_status_names / workflow_transition_names — newline-separated
# names currently present in WORKFLOW_JSON's first value.
workflow_status_names() {
    printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].statuses[].name'
}
workflow_transition_names() {
    printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].transitions[].name'
}
# workflow_transition_id_name_pairs — "id<TAB>name" for every transition
# currently on the workflow.
workflow_transition_id_name_pairs() {
    printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].transitions[] | "\(.id)\t\(.name)"'
}

# name_in_list <name> <newline-list> — bash 3.2 literal-line membership.
name_in_list() {
    local name="$1" list="$2"
    printf '%s\n' "$list" | grep -qxF "$name"
}


MISSING_STATUS_NAMES=""
MISSING_TRANSITION_NAMES=""

# check_transition_id_collisions — die if a target transition id is already
# held by a different name. Runs for EVERY target pair, not only the
# missing ones: id reuse is orthogonal to whether the name is present.
check_transition_id_collisions() {
    local have_pairs want_name want_id existing_name
    have_pairs=$(workflow_transition_id_name_pairs) || die "could not read current transition id/name pairs from workflow response"
    while IFS="$(printf '\t')" read -r want_name want_id; do
        [ -n "$want_name" ] || continue
        existing_name=$(printf '%s\n' "$have_pairs" | awk -F'\t' -v id="$want_id" '$1==id{print $2; exit}')
        if [ -n "$existing_name" ] && [ "$existing_name" != "$want_name" ]; then
            die "transition id $want_id already exists on workflow '$WORKFLOW_NAME' under a DIFFERENT name ('$existing_name'), not '$want_name' — refusing to reuse a caller-assigned id that would collide with an unrelated existing transition"
        fi
    done <<EOF
$(paste <(printf '%s\n' "$TARGET_STATUS_LIST") <(printf '%s\n' "$TARGET_TRANSITION_IDS"))
EOF
}

compute_missing() {
    local have_statuses have_transitions name
    have_statuses=$(workflow_status_names) || die "could not read current statuses from workflow response"
    have_transitions=$(workflow_transition_names) || die "could not read current transitions from workflow response"
    check_transition_id_collisions
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

# Rule identity is ruleKey + parameters, never the uuid rule id Jira
# regenerates on every write.

RESOLVED_RULES_JSON="[]"
MISSING_RULES_JSON="[]"

# resolve_rules — RESOLVED_RULES_JSON: the spec's transitions, each
# {field:<name>} / {status:<name>} parameter value replaced by the one site
# id that name matches. Dies naming every name with zero or several matches.
resolve_rules() {
    local spec fields statuses unresolved
    spec=$(jq -c '.transitions
        | if type != "array" then error("no top-level transitions array") else . end
        | map(if (.name | type) != "string" or (.validators | type) != "array" then error("each transition needs a name and a validators array") else . end)
        | map(.validators |= map(if (.ruleKey | type) != "string" or (.parameters | type) != "object" then error("each validator needs a ruleKey string and a parameters object") else {ruleKey, parameters} end))
        ' "$RULES_PATH") \
        || die "--rules file '$RULES_PATH' is not a valid rules spec (see workflow-rules.json for the shape)"
    fields=$(jira_raw_get "/field") || die "could not read /field — cannot resolve rule field names"
    statuses=$(jira_raw_get "/statuses/search?maxResults=100") \
        || die "could not read /statuses/search — cannot resolve rule status names"
    RESOLVED_RULES_JSON=$(jq -cn --argjson spec "$spec" --argjson fields "$fields" --argjson statuses "$statuses" '
        def one($kind; $n; $matches):
            if ($matches | length) == 1 then $matches[0].id else "UNRESOLVED:" + $kind + ":" + $n end;
        def resolve:
            if type != "string" then .
            elif test("^\\{field:.+\\}$") then
                capture("^\\{field:(?<n>.+)\\}$").n as $n | one("field"; $n; [$fields[] | select(.name == $n)])
            elif test("^\\{status:.+\\}$") then
                capture("^\\{status:(?<n>.+)\\}$").n as $n | one("status"; $n; [$statuses.values[] | select(.name == $n)])
            else . end;
        def resolve_all:
            if type == "object" then map_values(resolve_all)
            elif type == "array" then map(resolve_all)
            else resolve end;
        $spec | map(.validators |= map(.parameters |= resolve_all))
        ') || die "could not resolve the placeholders in --rules file '$RULES_PATH'"
    unresolved=$(printf '%s' "$RESOLVED_RULES_JSON" | jq -r '[.. | strings | select(startswith("UNRESOLVED:"))] | unique | join(", ")') \
        || die "could not scan the resolved rules for unresolved names"
    [ -z "$unresolved" ] || die "--rules names something this site does not have exactly once: $unresolved"
    # A mistyped placeholder ({Field:x}, { field:x}, trailing text) matches
    # neither pattern above and would reach the update body literally.
    if printf '%s' "$RESOLVED_RULES_JSON" | grep -Eiq '\{[[:space:]]*(field|status)[[:space:]]*:'; then
        die "--rules still contains a placeholder-shaped value after resolution (a typo, wrong case, or extra text?) — refusing to send it to Jira: $(printf '%s' "$RESOLVED_RULES_JSON" | grep -Eio '\{[[:space:]]*(field|status)[[:space:]]*:[^"]*' | head -3 | tr '\n' ' ')"
    fi
}

# check_rule_transitions — every transition the spec names must be on the
# workflow already or be one this run adds; a typo must not match nothing.
check_rule_transitions() {
    local have names name unknown=""
    have=$(workflow_transition_names) || die "could not read current transitions from workflow response"
    names=$(printf '%s' "$RESOLVED_RULES_JSON" | jq -r '.[].name') || die "could not read transition names from the rules spec"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        name_in_list "$name" "$have" || name_in_list "$name" "$TARGET_STATUS_LIST" || unknown="$unknown$name, "
    done <<EOF
$names
EOF
    [ -z "$unknown" ] || die "--rules names transitions workflow '$WORKFLOW_NAME' does not have and this run does not add: ${unknown%, }"
}

# compute_missing_rules <bulkget-json> — MISSING_RULES_JSON: per transition
# name, the spec validators not already present by ruleKey + parameters.
compute_missing_rules() {
    MISSING_RULES_JSON=$(jq -cn --argjson bulkget "$1" --argjson rules "$RESOLVED_RULES_JSON" --arg wfname "$WORKFLOW_NAME" '
        ($bulkget.workflows[] | select(.name == $wfname)) as $wf
        | [ $rules[] as $r
            | ([$wf.transitions[] | select(.name == $r.name)][0].validators // [] | map({ruleKey, parameters})) as $have
            | {name: $r.name, validators: [$r.validators[] | select(. as $v | any($have[]; . == $v) | not)]}
            | select(.validators | length > 0)
          ]') || die "could not compare --rules against the workflow's current validators"
}

# build_update_body <bulkget-response-json> <version-json> — the FULL
# POST /workflows/update request: existing statuses and transitions
# VERBATIM plus additions, never a delta, dying on an empty union. Sources
# them from the bulk-get, not workflow/search, whose field names differ.

# Every status declaration needs BOTH id and statusReference set to the same
# global status id, or Jira reads it as a CREATE and 400s NON_UNIQUE_STATUS_NAME.
build_update_body() {
    local bulkget_json="$1" version_json="$2"
    jq -n \
        --argjson bulkget "$bulkget_json" \
        --arg wfname "$WORKFLOW_NAME" \
        --argjson version "$version_json" \
        --arg targetNamesNL "$TARGET_STATUS_LIST" \
        --arg statusIdsNL "$RESOLVED_STATUS_IDS" \
        --arg statusCategoriesNL "$RESOLVED_STATUS_CATEGORIES" \
        --arg transitionIdsNL "$TARGET_TRANSITION_IDS" \
        --arg missingStatusNamesNL "$MISSING_STATUS_NAMES" \
        --arg missingTransitionNamesNL "$MISSING_TRANSITION_NAMES" \
        --argjson missingRules "$MISSING_RULES_JSON" \
        '
        def lines: split("\n") | map(select(length > 0));
        ( $targetNamesNL | lines ) as $allNames
        | ( $statusIdsNL | lines ) as $allIds
        | ( $statusCategoriesNL | lines ) as $allCats
        | ( $transitionIdsNL | lines ) as $allTransIds
        | ( $missingStatusNamesNL | lines ) as $missingStatusNames
        | ( $missingTransitionNamesNL | lines ) as $missingTransitionNames
        | [ range(0; ($allNames | length))
            | { name: $allNames[.], id: $allIds[.], category: $allCats[.], transitionId: $allTransIds[.] }
          ] as $resolved
        | [ $resolved[] | select(.name as $n | $missingStatusNames | index($n) != null)
            | { id: .id, statusReference: .id, name: .name, statusCategory: .category }
          ] as $status_additions
        | [ $resolved[] | select(.name as $n | $missingTransitionNames | index($n) != null)
            | { id: .transitionId, name: .name, type: "GLOBAL", toStatusReference: .id }
          ] as $transition_additions
        | if ($status_additions | length) == 0 and ($transition_additions | length) == 0 and ($missingRules | length) == 0
          then error("build_update_body: computed additions are EMPTY — refusing to send a no-op /workflows/update (this should be unreachable; the caller must check \"already complete\" before calling this)")
          else . end
        | ($bulkget.workflows[] | select(.name == $wfname)) as $wf
        # The three existing sets, carried forward VERBATIM. Reshaping any
        # of them, even reordering fields, strips rules on write.
        | $bulkget.statuses as $existing_status_defs
        | $wf.statuses as $existing_statuses
        | $wf.transitions as $existing_transitions
        | {
            statuses: ($existing_status_defs + $status_additions),
            workflows: [ {
                id: $wf.id,
                version: $version,
                statuses: ($existing_statuses + ($status_additions | map({statusReference}))),
                # --rules matches transitions by NAME, so unique transition
                # names are load-bearing here too.
                transitions: (($existing_transitions + $transition_additions)
                    | map(. as $t
                        | [$missingRules[] | select(.name == $t.name) | .validators[]] as $add
                        | if ($add | length) > 0 then .validators = ((.validators // []) + $add) else . end))
            } ]
        }
        '
}

# validate_update_body <update-body> — POST /workflows/update/validation,
# always, even under --dry-run; an ERROR dies, a WARNING continues. The
# endpoint needs a {payload, validationOptions} envelope, not the bare body.
validate_update_body() {
    local body="$1" envelope resp errors_json error_count warning_count
    envelope=$(jq -n --argjson payload "$body" \
        '{payload: $payload, validationOptions: {levels: ["ERROR", "WARNING"]}}') \
        || die "could not build the /workflows/update/validation envelope"
    resp=$(jira_write_readonly_semantics POST /workflows/update/validation "$envelope") \
        || die "POST /workflows/update/validation failed outright — see the wrapper's own error output above"
    # An unparseable 2xx, or one with no `errors` key, is a hard die — not
    # "zero errors" the way a `// []` default would make it.
    printf '%s' "$resp" | jq -e '.errors | type == "array"' >/dev/null 2>&1 \
        || die "POST /workflows/update/validation returned a response this script could not parse, or one with no 'errors' array — refusing to treat that as \"zero errors\". Raw response: $resp"
    errors_json=$(printf '%s' "$resp" | jq -c '.errors')
    error_count=$(printf '%s' "$errors_json" | jq '[.[] | select(.level == "ERROR")] | length')
    warning_count=$(printf '%s' "$errors_json" | jq '[.[] | select(.level == "WARNING")] | length')
    if [ "$warning_count" != "0" ]; then
        warn "workflow update validation reported $warning_count warning(s):"
        printf '%s\n' "$errors_json" | jq '[.[] | select(.level == "WARNING")]' >&2 \
            || printf '%s\n' "$errors_json" >&2
    fi
    if [ "$error_count" != "0" ]; then
        warn "workflow update validation reported $error_count error(s):"
        printf '%s\n' "$errors_json" | jq '[.[] | select(.level == "ERROR")]' >&2 \
            || printf '%s\n' "$errors_json" >&2
        die "refusing to write — /workflows/update/validation reported at least one ERROR (see above)"
    fi
}


# assert_readback — re-read the workflow and confirm every target status
# and transition name is present, naming whatever is not.
assert_readback() {
    read_workflow "$PROJECT_KEY"
    compute_missing
    if [ -z "$MISSING_STATUS_NAMES" ] && [ -z "$MISSING_TRANSITION_NAMES" ]; then
        echo "read-back confirms: all target statuses and transitions are present."
        return 0
    fi
    warn "read-back after the write shows this is STILL missing:"
    [ -z "$MISSING_STATUS_NAMES" ] || warn "  statuses:    $(printf '%s' "$MISSING_STATUS_NAMES" | tr '\n' ',' | sed 's/,$//')"
    [ -z "$MISSING_TRANSITION_NAMES" ] || warn "  transitions: $(printf '%s' "$MISSING_TRANSITION_NAMES" | tr '\n' ',' | sed 's/,$//')"
    die "workflow update did not take effect as expected — see the diff above"
}

# validate_write_and_diff <final-body> <pre-write-bulkget-resp> — the
# validate -> print -> gate -> write -> snapshot -> deep-diff sequence,
# shared by the missing-set path and --restore-from. Reads
# $VERSION_BULKGET_BODY and $WORKFLOW_NAME from the caller's globals.
validate_write_and_diff() {
    local final_body="$1" pre_write_resp="$2"

    validate_update_body "$final_body"

    echo
    echo "validation passed. This is the exact request body for /rest/api/3/workflows/update:"
    printf '%s\n' "$final_body" | jq .

    if [ "$DRY_RUN" = "1" ]; then
        warn "--dry-run: the update itself was never sent (every call above is read-only-by-semantics)."
        exit 0
    fi

    if [ "$ASSUME_YES" != "1" ]; then
        warn "not confirmed (no --yes) — the update was never sent. Re-run with --yes to apply."
        exit 3
    fi

    # Persist the pre-write document BEFORE the write. It came from
    # jira_bulkget (--show-secrets), so it is a --restore-from source, not
    # merely a diff source.
    SNAPSHOT_STAMP=$(date +%s) || die "could not compute a timestamp for the before/after snapshot filenames"
    BEFORE_FILE="${TMPDIR:-/tmp}/jira-workflow-apply.$PROJECT_KEY.$SNAPSHOT_STAMP.before.json"
    printf '%s\n' "$pre_write_resp" > "$BEFORE_FILE" || die "could not write the pre-write snapshot to $BEFORE_FILE"
    echo "pre-write snapshot saved: $BEFORE_FILE (--show-secrets — full rule definitions, still no credentials — a restore source, not merely a diff source)"

    UPDATE_RESP=$(jira_write_mutating POST /workflows/update "$final_body") \
        || die "POST /workflows/update failed outright — see the wrapper's own error output above. Nothing after this point ran; check the workflow's actual state before retrying."
    echo
    echo "/workflows/update response:"
    printf '%s\n' "$UPDATE_RESP" | jq . 2>/dev/null || printf '%s\n' "$UPDATE_RESP"

    AFTER_RESP=$(jira_bulkget "$VERSION_BULKGET_BODY") \
        || die "the write itself returned above, but the post-write bulk-get re-read failed — cannot compute the rule diff. Check the workflow's actual state by hand before trusting anything about it."
    AFTER_FILE="${TMPDIR:-/tmp}/jira-workflow-apply.$PROJECT_KEY.$SNAPSHOT_STAMP.after.json"
    printf '%s\n' "$AFTER_RESP" > "$AFTER_FILE" || die "could not write the post-write snapshot to $AFTER_FILE"
    echo "post-write snapshot saved: $AFTER_FILE (--show-secrets — a restore source, not merely a diff source)"

    # The baseline is the request body, not the pre-write snapshot, so
    # rules added on purpose (--rules) compare equal while a rule Jira
    # dropped, altered or never stored still fails.
    RULE_DIFF=$(jq -n --argjson sent "$final_body" --argjson after "$AFTER_RESP" --arg wfname "$WORKFLOW_NAME" '
        # Strip each rule entrys own id before comparing: Jira regenerates
        # a uuid rule id on every write regardless of content.
        def without_ids: map(del(.id));
        def rules: {
            actions:    ((.actions    // []) | without_ids),
            validators: ((.validators // []) | without_ids),
            triggers:   ((.triggers   // []) | without_ids),
            links:      ((.links      // []) | without_ids)
        };
        ($sent.workflows[0].transitions | map({id, r: rules})) as $sentT
        | ($after.workflows[] | select(.name == $wfname) | .transitions | map({id, r: rules})) as $afterT
        | [ $sentT[] as $s | ($afterT[] | select(.id == $s.id)) as $a
            | select($s.r != $a.r)
            | {id: $s.id, sent: $s.r, stored: $a.r}
          ]
        ') || die "could not compute the per-transition rule deep-diff"
    echo
    echo "per-transition rule DEEP DIFF, sent vs stored (every transition in the request, matched by id, rule ids ignored; an empty [] means Jira stored exactly the rules that were sent):"
    printf '%s\n' "$RULE_DIFF" | jq .

    CHANGED_ID=$(printf '%s' "$RULE_DIFF" | jq -r '.[0].id // empty')
    if [ -n "$CHANGED_ID" ]; then
        warn "stored rules differ from what the update sent on transition $CHANGED_ID — see the deep diff above."
        warn "before file: $BEFORE_FILE"
        warn "after file:  $AFTER_FILE"
        exit 2
    fi

    assert_readback
}


# do_restore_from <path> — re-POST the exact workflow document in PATH with
# a freshly-fetched `version`. A literal restore, no missing-set step.
do_restore_from() {
    local path="$1" restore_json restore_wf restore_statuses fresh_resp fresh_version restore_body
    [ -f "$path" ] || die "--restore-from file not found: '$path'"
    restore_json=$(cat "$path") || die "could not read --restore-from file '$path'"
    printf '%s' "$restore_json" | jq -e . >/dev/null 2>&1 \
        || die "--restore-from file '$path' is not valid JSON"

    WORKFLOW_NAME="Software Simplified Workflow for Project $PROJECT_KEY"
    restore_wf=$(printf '%s' "$restore_json" | jq -c --arg n "$WORKFLOW_NAME" '[.workflows[] | select(.name == $n)][0] // empty') \
        || die "could not parse --restore-from file '$path'"
    [ -n "$restore_wf" ] || die "--restore-from file '$path' does not contain workflow '$WORKFLOW_NAME' — is this the right file for project '$PROJECT_KEY'?"
    restore_statuses=$(printf '%s' "$restore_json" | jq -c '.statuses // []') \
        || die "could not read the top-level 'statuses' array from --restore-from file '$path'"

    # A document captured WITHOUT --show-secrets carries "<redacted>" in
    # place of every rule value; restoring it reproduces the exact
    # stripped-rules bug this flag exists to fix.
    case "$restore_wf" in
        *'<redacted>'*)
            die "--restore-from file '$path' was captured WITHOUT --show-secrets (it contains the literal string \"<redacted>\") — restoring it would reproduce the exact rules-stripping bug this flag exists to fix, just once more. There is no way to recover a rule value that was only ever seen redacted. Capture a fresh --show-secrets snapshot (every before/after file this script writes now qualifies) and use THAT as the restore source instead. This project's rules from before that fix cannot be recovered from this file."
            ;;
    esac

    VERSION_BULKGET_BODY=$(jq -n --arg n "$WORKFLOW_NAME" '{workflowNames: [$n]}') \
        || die "could not build /workflows bulk-get request body"
    fresh_resp=$(jira_bulkget "$VERSION_BULKGET_BODY") \
        || die "could not fetch a fresh version for the restore target — refusing to restore without one"
    fresh_version=$(printf '%s' "$fresh_resp" | jq -c --arg n "$WORKFLOW_NAME" '[.workflows[] | select(.name == $n)][0].version // null') \
        || die "could not parse the fresh bulk-get response while looking for '$WORKFLOW_NAME'"
    [ "$fresh_version" != "null" ] || die "the fresh bulk-get returned no 'version' for '$WORKFLOW_NAME' — refusing to restore with no version to guard against a stale-write conflict"

    restore_body=$(jq -n --argjson wf "$restore_wf" --argjson statuses "$restore_statuses" --argjson version "$fresh_version" '
        { statuses: $statuses, workflows: [ ($wf + {version: $version}) ] }
        ') || die "could not render the restore request body"

    echo "restoring workflow '$WORKFLOW_NAME' from '$path' (version refreshed to the current one just fetched):"
    validate_write_and_diff "$restore_body" "$fresh_resp"
}

# The version bulk-get and the validation call are both read-only by
# semantics and both run unconditionally, before the --yes gate. Only
# /workflows/update itself is gated.

if [ -n "$RESTORE_FROM" ]; then
    do_restore_from "$RESTORE_FROM"
    exit 0
fi

resolve_status_ids
read_workflow "$PROJECT_KEY"
compute_missing
if [ -n "$RULES_PATH" ]; then
    resolve_rules
    check_rule_transitions
fi

if [ -z "$RULES_PATH" ] && [ -z "$MISSING_STATUS_NAMES" ] && [ -z "$MISSING_TRANSITION_NAMES" ]; then
    # NAME-level only: a transition named "Open" pointing at the WRONG
    # status still reads "already complete". This adds what is missing by
    # name/id; it never repairs a wrong toStatusReference.
    echo "already complete: workflow '$WORKFLOW_NAME' already carries every target status and transition (by name/id only — this does not verify each existing transition still points at the right status)."
    exit 0
fi

VERSION_BULKGET_BODY=$(jq -n --arg n "$WORKFLOW_NAME" '{workflowNames: [$n]}') \
    || die "could not build /workflows bulk-get request body"
VERSION_RESP=$(jira_bulkget "$VERSION_BULKGET_BODY") \
    || die "could not obtain the workflow's current version via POST /workflows — refusing to build an update body without it"
# POST /workflows keys each workflow by a plain string `name`, not the
# {name, entityId} id object workflow/search nests it under.
VERSION_JSON=$(printf '%s' "$VERSION_RESP" | jq -c --arg n "$WORKFLOW_NAME" '[.workflows[] | select(.name == $n)][0].version // null') \
    || die "could not parse POST /workflows response while looking for '$WORKFLOW_NAME'"
[ "$VERSION_JSON" != "null" ] || die "POST /workflows returned no 'version' for '$WORKFLOW_NAME' — refusing to write with no version to guard against a stale-write conflict"

# Cross-check two independent reads of "the same workflow" against a name
# collision or a stale cache on either side.
BULKGET_WF_ID=$(printf '%s' "$VERSION_RESP" | jq -r --arg n "$WORKFLOW_NAME" '[.workflows[] | select(.name == $n)][0].id // empty') \
    || die "could not read the workflow id from POST /workflows response"
[ "$BULKGET_WF_ID" = "$WORKFLOW_ENTITY_ID" ] \
    || die "workflow/search's entityId ('$WORKFLOW_ENTITY_ID') does not match POST /workflows's id ('$BULKGET_WF_ID') for '$WORKFLOW_NAME' — refusing to build an update body against a possibly-wrong workflow"

if [ -n "$RULES_PATH" ]; then
    compute_missing_rules "$VERSION_RESP"
    if [ -z "$MISSING_STATUS_NAMES" ] && [ -z "$MISSING_TRANSITION_NAMES" ] && [ "$MISSING_RULES_JSON" = "[]" ]; then
        echo "already complete: workflow '$WORKFLOW_NAME' already carries every target status and transition, and every rule in '$RULES_PATH' (rules matched by ruleKey + parameters): 0 changes."
        exit 0
    fi
fi

echo "workflow '$WORKFLOW_NAME' is missing:"
[ -z "$MISSING_STATUS_NAMES" ] || echo "  statuses:    $(printf '%s' "$MISSING_STATUS_NAMES" | tr '\n' ',' | sed 's/,$//')"
[ -z "$MISSING_TRANSITION_NAMES" ] || echo "  transitions: $(printf '%s' "$MISSING_TRANSITION_NAMES" | tr '\n' ',' | sed 's/,$//')"
if [ "$MISSING_RULES_JSON" != "[]" ]; then
    RULES_SUMMARY=$(printf '%s' "$MISSING_RULES_JSON" | jq -r '.[] | "  rules:       \(.name): \([.validators[].ruleKey] | join(", "))"') \
        || die "could not summarise the missing rules"
    printf '%s\n' "$RULES_SUMMARY"
fi

FINAL_BODY=$(build_update_body "$VERSION_RESP" "$VERSION_JSON") \
    || die "could not render the /workflows/update request body"

validate_write_and_diff "$FINAL_BODY" "$VERSION_RESP"
