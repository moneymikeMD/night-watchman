#!/bin/bash
#
# jira-space-create.sh — one-run bootstrap for a new Jira Space (company-
# managed, "simplified scrum classic" template): project + the six custom
# fields + those fields on every screen the project's issue types use. Each step is idempotent; a re-run converges.
#
# Never hardcode a field id, status id, screen id or lead accountId — all
# are per-site and resolved live, by name, at runtime.
#
# Steps 1-2 create-or-verify the project, then ASSERT on the readback that
# it is a classic software project with an Epic issue type: `style` is a
# computed property of the template with no request-time equivalent, so a
# stale template key silently yields a Business project instead.
# Step 3 is only the statuses hook: work-order owns the workflow, and
# plugins/work-order-jira/universal-switch.sh moves the project onto the
# shared Universal Managed workflows. --workflow-apply PATH runs a script
# here instead; without it, step 3 prints that pointer and continues.
# Step 4 discovers-or-creates the six fields, adds executor's options, and
# probes each field's JQL-searchability (repairing via PUT searcherKey).
# Step 5 walks issuetypescreenscheme -> mapping -> screenscheme -> screens
# -> tabs and adds each field to every tab that lacks it: a field created
# but never placed on a screen accepts no value at all.
# Step 6 prints the six customfield ids.
#
# Usage:
#   jira-space-create.sh KEY "Name" --dry-run
#   jira-space-create.sh KEY "Name" --yes [--lead ACCOUNT_ID]
#                         [--jira-api PATH] [--workflow-apply PATH]
#
#   KEY              2-10 uppercase letters/digits, starting with a letter.
#                    A deleted project's key stays reserved site-wide.
#   "Name"           the project's display name, quoted if it has spaces.
#   --dry-run        print every planned request and exit 0, reaching no
#                    network. Step 3 is announced, never invoked: a
#                    workflow script's reads need not honour --dry-run.
#   --yes            actually run it. Without --yes, on a terminal, this
#                    asks y/N once up front, before any write.
#   --lead ACCOUNT_ID  the project lead's Jira accountId. Default: this
#                    script's own `jira-api.sh whoami`.
#   --jira-api PATH  path to a jira-api.sh-shaped wrapper. Defaults to
#                    $ISSUES_JIRA_API, else jira-api.sh beside this file.
#   --workflow-apply PATH  step 3's script, called as PATH KEY --jira-api
#                    WRAPPER --yes. Default: none (step 3 prints a pointer
#                    to work-order's universal-switch.sh).
#
# Board and the first sprint are OUT OF SCOPE.
#
# Exit status:
#   0   every step converged, or --dry-run completed.
#   1   a read failed, the step-2 assert failed, a later step failed, or a
#       field name already exists under the wrong schema type.
#   3   no --yes and no terminal to ask on, or the answer was not y/yes.
#       Nothing was sent: a refusal, not a failure.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/http.sh
. "$DIR/lib/http.sh"
# shellcheck source=../../lib/kit.sh
. "$(cd "$DIR/../../lib" && pwd)/kit.sh"

# Parallel, newline-separated (bash 3.2: no associative arrays), exact
# table order.
FIELD_NAMES='touches
executor
verify
human_steps
appends
defer_until'
FIELD_TYPE_KEYS='com.atlassian.jira.plugin.system.customfieldtypes:textarea
com.atlassian.jira.plugin.system.customfieldtypes:select
com.atlassian.jira.plugin.system.customfieldtypes:textarea
com.atlassian.jira.plugin.system.customfieldtypes:textarea
com.atlassian.jira.plugin.system.customfieldtypes:textarea
com.atlassian.jira.plugin.system.customfieldtypes:datepicker'
# executor's searcherKey is multiselectsearcher, NOT selectsearcher: a
# select field's PUT with selectsearcher is HTTP 400 (measured live).
FIELD_SEARCHER_KEYS='com.atlassian.jira.plugin.system.customfieldtypes:textsearcher
com.atlassian.jira.plugin.system.customfieldtypes:multiselectsearcher
com.atlassian.jira.plugin.system.customfieldtypes:textsearcher
com.atlassian.jira.plugin.system.customfieldtypes:textsearcher
com.atlassian.jira.plugin.system.customfieldtypes:textsearcher
com.atlassian.jira.plugin.system.customfieldtypes:daterange'
EXECUTOR_OPTIONS='agent
human
mixed'


PROJECT_KEY=""
PROJECT_NAME=""
DRY_RUN=0
ASSUME_YES=0
LEAD_ACCOUNT_ID=""
JIRA_API_PATH="${ISSUES_JIRA_API:-}"
WORKFLOW_APPLY_PATH=""
UNIVERSAL_SWITCH_HINT="work-order owns the workflow; run work-order's plugins/work-order-jira/universal-switch.sh for this project"

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|help) show_help ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        --lead)
            [ $# -ge 2 ] || die "--lead needs an accountId"
            LEAD_ACCOUNT_ID="$2"; shift 2
            ;;
        --jira-api)
            [ $# -ge 2 ] || die "--jira-api needs a path"
            JIRA_API_PATH="$2"; shift 2
            ;;
        --workflow-apply)
            [ $# -ge 2 ] || die "--workflow-apply needs a path"
            WORKFLOW_APPLY_PATH="$2"; shift 2
            ;;
        --) shift; break ;;
        -*) die "unknown flag '$1' — run with --help" ;;
        *)
            if [ -z "$PROJECT_KEY" ]; then
                PROJECT_KEY="$1"
            elif [ -z "$PROJECT_NAME" ]; then
                PROJECT_NAME="$1"
            else
                die "unexpected extra argument '$1' (KEY and Name already given: '$PROJECT_KEY' '$PROJECT_NAME')"
            fi
            shift
            ;;
    esac
done

[ -n "$PROJECT_KEY" ] || die "a project KEY is required, e.g. $(basename "$0") CHR2 \"Chronicle 2\" --dry-run"
[ -n "$PROJECT_NAME" ] || die "a project Name is required (quoted if it has spaces), e.g. $(basename "$0") $PROJECT_KEY \"Some Name\" --dry-run"

# Three independent checks, not one regex: bash 3.2's `case` glob has no
# {2,10} quantifier, and [A-Z]* validates only the first character.
case "$PROJECT_KEY" in
    [A-Z]*) ;;
    *) die "KEY must start with an uppercase letter, got '$PROJECT_KEY'" ;;
esac
case "$(printf '%s' "$PROJECT_KEY" | tr -d 'A-Z0-9')" in
    "") ;;
    *) die "KEY must be uppercase letters/digits only, got '$PROJECT_KEY'" ;;
esac
KEY_LEN=${#PROJECT_KEY}
{ [ "$KEY_LEN" -ge 2 ] && [ "$KEY_LEN" -le 10 ]; } \
    || die "KEY must be 2-10 characters long, got '$PROJECT_KEY' ($KEY_LEN characters)"

[ -n "$JIRA_API_PATH" ] || JIRA_API_PATH="$DIR/jira-api.sh"
[ -x "$JIRA_API_PATH" ] || die "--jira-api path is not an executable file: '$JIRA_API_PATH'"

[ -z "$WORKFLOW_APPLY_PATH" ] || [ -x "$WORKFLOW_APPLY_PATH" ] || die "--workflow-apply path is not an executable file: '$WORKFLOW_APPLY_PATH'"

need jq

have_terminal() { [ -t 0 ] && [ -r /dev/tty ]; }


if [ "$DRY_RUN" = "1" ]; then
    echo "PLANNED — jira-space-create.sh $PROJECT_KEY \"$PROJECT_NAME\" (nothing below was sent; no credential was resolved):"
    echo
    echo "1. read-or-create the project:"
    "$JIRA_API_PATH" --dry-run raw GET "/project/$PROJECT_KEY"
    if [ -n "$LEAD_ACCOUNT_ID" ]; then
        echo "   lead: --lead $LEAD_ACCOUNT_ID (given)"
    else
        echo "   lead: would resolve via:"
        "$JIRA_API_PATH" --dry-run whoami
    fi
    CREATE_BODY=$(jq -cn --arg key "$PROJECT_KEY" --arg name "$PROJECT_NAME" \
        --arg lead "${LEAD_ACCOUNT_ID:-<accountId from whoami>}" \
        '{key: $key, name: $name, projectTypeKey: "software",
          projectTemplateKey: "com.pyxis.greenhopper.jira:gh-simplified-scrum-classic",
          leadAccountId: $lead}') || die "could not render the planned create-project body"
    "$JIRA_API_PATH" --dry-run write POST /project "$CREATE_BODY"
    echo
    echo "2. would then ASSERT on the read-back project: .style == \"classic\", .projectTypeKey == \"software\", an Epic issue type at .hierarchyLevel == 1."
    echo
    if [ -n "$WORKFLOW_APPLY_PATH" ]; then
        echo "3. would run (not invoked here — see this script's own header on why):"
        echo "   $WORKFLOW_APPLY_PATH $PROJECT_KEY --jira-api $JIRA_API_PATH --yes"
    else
        echo "3. statuses: not invoked here — $UNIVERSAL_SWITCH_HINT"
    fi
    echo
    echo "4. discover-or-create these custom fields (id TBD — per-site, never hardcoded):"
    "$JIRA_API_PATH" --dry-run raw GET /field
    PASTE_NAMES_TYPES=$(paste <(printf '%s\n' "$FIELD_NAMES") <(printf '%s\n' "$FIELD_TYPE_KEYS") <(printf '%s\n' "$FIELD_SEARCHER_KEYS"))
    while IFS="$(printf '\t')" read -r fname ftype fsearcher; do
        [ -n "$fname" ] || continue
        FIELD_BODY=$(jq -cn --arg name "$fname" --arg type "$ftype" --arg searcher "$fsearcher" \
            '{name: $name, type: $type, searcherKey: $searcher}') || die "could not render planned field body for '$fname'"
        "$JIRA_API_PATH" --dry-run write POST /field "$FIELD_BODY"
    done <<EOF
$PASTE_NAMES_TYPES
EOF
    echo "   executor would additionally get options: $(printf '%s' "$EXECUTOR_OPTIONS" | tr '\n' '/' | sed 's#/$##')"
    echo
    echo "   then, for each field, would probe searchability via (id not yet known — shown against the not-yet-created field's name):"
    while IFS= read -r fname; do
        [ -n "$fname" ] || continue
        probe_jql="project = $PROJECT_KEY AND \"$fname\" is EMPTY"
        probe_enc=$(jq -rn --arg v "$probe_jql" '$v|@uri') || die "could not url-encode the planned probe JQL for '$fname'"
        "$JIRA_API_PATH" --dry-run raw GET "/search/jql?jql=$probe_enc&fields=key&maxResults=1"
    done <<EOF
$FIELD_NAMES
EOF
    echo "   on HTTP 400 (the real signal — the API's own 400 body names no 'not searchable' text), would repair with (id not yet known):"
    while IFS="$(printf '\t')" read -r fname fsearcher; do
        [ -n "$fname" ] || continue
        put_body=$(jq -cn --arg s "$fsearcher" '{searcherKey: $s}') \
            || die "could not render planned searcherKey PUT body for '$fname'"
        "$JIRA_API_PATH" --dry-run write PUT "/field/<id-of-$fname>" "$put_body"
    done <<EOF
$(paste <(printf '%s\n' "$FIELD_NAMES") <(printf '%s\n' "$FIELD_SEARCHER_KEYS"))
EOF
    echo
    echo "5. would add each of the six fields to every screen of the project's issue-type screen scheme (screen/tab ids are only knowable from a live read; announced generically here):"
    echo "   GET /issuetypescreenscheme/project?projectId=<project id>"
    echo "   GET /issuetypescreenscheme/mapping?issueTypeScreenSchemeId=<id>  (one or more)"
    echo "   GET /screenscheme?id=<a>&id=<b>&...  (one call, repeated id= params — no per-id GET exists)"
    echo "   GET /screens/<id>/tabs  (one or more)"
    echo "   POST /screens/<id>/tabs/<tab>/fields  {fieldId: <customfield id>}  (skipped if already present)"
    echo
    echo "6. would print a table of the six customfield ids."
    exit 0
fi

# One gate, up front, before ANY write in this run: every write below then
# passes the wrapper's own --yes unconditionally.
if [ "$ASSUME_YES" != "1" ]; then
    if ! have_terminal; then
        warn "no --yes and no terminal to confirm on — refusing to bootstrap a Jira Space unattended. Re-run with --yes."
        exit 3
    fi
    warn "About to bootstrap Jira Space '$PROJECT_KEY' (\"$PROJECT_NAME\"): create-or-verify the project, apply six statuses, create six custom fields, and add them to every project screen. Proceed? [y/N]"
    ANSWER=""
    IFS= read -r ANSWER < /dev/tty || die "could not read confirmation"
    case "$ANSWER" in
        y|Y|yes|YES) ;;
        *) warn "not confirmed — nothing was sent."; exit 3 ;;
    esac
fi


# jira_get PATH — a real GET, dies on any failure.
jira_get() { "$JIRA_API_PATH" raw GET "$1"; }

# jira_get_soft PATH — a real GET treating HTTP 404 as "not found" rather
# than fatal. Prints the body and returns 0 when found; prints NOTHING and
# returns 1 on a 404; prints the wrapper's error to stderr and returns 2
# on anything else, for the caller to die on at the top level.
jira_get_soft() {
    local path="$1" out err
    out=$(tmpfile) || return 2
    err=$(tmpfile) || return 2
    if "$JIRA_API_PATH" raw GET "$path" >"$out" 2>"$err"; then
        cat "$out"
        return 0
    fi
    if grep -q "HTTP 404" "$err"; then
        return 1
    fi
    cat "$err" >&2
    return 2
}

# jira_write METHOD PATH BODY — a real, confirmed write. --yes here is
# THIS script's own gate having already passed, not a fresh ask.
jira_write() { "$JIRA_API_PATH" --yes write "$1" "$2" "${3:-}"; }

# in_list VALUE LIST — bash 3.2 literal-line membership test.
in_list() {
    local value="$1" list="$2"
    printf '%s\n' "$list" | grep -qxF "$value"
}


resolve_lead() {
    [ -n "$LEAD_ACCOUNT_ID" ] && return 0
    local who
    who=$(jira_get /myself) || die "could not resolve the project lead: /myself failed, and no --lead was given"
    LEAD_ACCOUNT_ID=$(printf '%s' "$who" | jq -r '.accountId // empty') \
        || die "could not parse accountId from /myself"
    [ -n "$LEAD_ACCOUNT_ID" ] || die "/myself returned no accountId — cannot resolve a project lead without --lead"
}

# assert_project_shape <project-json> — die unless the readback shows a
# classic software project with an Epic issue type.
assert_project_shape() {
    local proj_json="$1" style ptype epic_ok
    style=$(printf '%s' "$proj_json" | jq -r '.style // empty') \
        || die "could not parse .style from the project readback"
    ptype=$(printf '%s' "$proj_json" | jq -r '.projectTypeKey // empty') \
        || die "could not parse .projectTypeKey from the project readback"
    epic_ok=$(printf '%s' "$proj_json" | jq -r '[.issueTypes[]? | select(.hierarchyLevel == 1)] | length > 0') \
        || die "could not parse .issueTypes from the project readback"
    [ "$style" = "classic" ] \
        || die "project '$PROJECT_KEY' has style '$style', not 'classic' — a stale/wrong projectTemplateKey silently yields a Business project; this recipe does not apply to it"
    [ "$ptype" = "software" ] \
        || die "project '$PROJECT_KEY' has projectTypeKey '$ptype', not 'software'"
    [ "$epic_ok" = "true" ] \
        || die "project '$PROJECT_KEY' has no issue type at hierarchyLevel 1 (Epic) — this recipe does not apply to it"
}

PROJECT_ID=""
ensure_project() {
    local existing rc create_body created
    # `cmd && rc=0 || rc=$?`, not two statements: `rc=$?` after a closing
    # `fi` reads the if-COMPOUND's status (0), not the command's, and a
    # bare failing assignment exits under `set -e` before `rc=$?` runs.
    existing=$(jira_get_soft "/project/$PROJECT_KEY") && rc=0 || rc=$?
    if [ "$rc" = "0" ]; then
        # Must not contain the substring "creating": callers grep a run's
        # log for it to confirm an idempotent rerun created nothing.
        echo "project '$PROJECT_KEY' already exists — verifying, no create needed."
        assert_project_shape "$existing"
        PROJECT_ID=$(printf '%s' "$existing" | jq -r '.id // empty') \
            || die "could not parse .id from the existing project"
        [ -n "$PROJECT_ID" ] || die "existing project '$PROJECT_KEY' readback carried no .id"
        return 0
    fi
    [ "$rc" = "1" ] || die "GET /project/$PROJECT_KEY failed with an unexpected error (see above) — refusing to guess whether it exists"

    resolve_lead
    create_body=$(jq -cn --arg key "$PROJECT_KEY" --arg name "$PROJECT_NAME" --arg lead "$LEAD_ACCOUNT_ID" \
        '{key: $key, name: $name, projectTypeKey: "software",
          projectTemplateKey: "com.pyxis.greenhopper.jira:gh-simplified-scrum-classic",
          leadAccountId: $lead}') || die "could not render the create-project body"
    echo "project '$PROJECT_KEY' does not exist — creating it."
    created=$(jira_write POST /project "$create_body") \
        || die "POST /project failed — see the wrapper's own error output above"
    PROJECT_ID=$(printf '%s' "$created" | jq -r '.id // empty') \
        || die "could not parse .id from the create-project response"
    [ -n "$PROJECT_ID" ] || die "POST /project succeeded but returned no .id"

    existing=$(jira_get "/project/$PROJECT_KEY") || die "could not read back the just-created project '$PROJECT_KEY'"
    assert_project_shape "$existing"
}


apply_statuses() {
    if [ -z "$WORKFLOW_APPLY_PATH" ]; then
        echo "statuses: skipped — $UNIVERSAL_SWITCH_HINT"
        return 0
    fi
    echo "applying statuses via $WORKFLOW_APPLY_PATH ..."
    "$WORKFLOW_APPLY_PATH" "$PROJECT_KEY" --jira-api "$JIRA_API_PATH" --yes \
        || die "$WORKFLOW_APPLY_PATH failed for '$PROJECT_KEY' — see its own output above"
}


# probe_field_searchable NAME — one real JQL search; prints nothing, returns
# 0 searchable, 1 not, 2 caller-dies. The 400 body carries no "not
# searchable" text, so any 400 here IS that case.
probe_field_searchable() {
    local name="$1" jql enc out err
    jql="project = $PROJECT_KEY AND \"$name\" is EMPTY"
    enc=$(jq -rn --arg v "$jql" '$v|@uri') || return 2
    out=$(tmpfile) || return 2
    err=$(tmpfile) || return 2
    if "$JIRA_API_PATH" raw GET "/search/jql?jql=$enc&fields=key&maxResults=1" >"$out" 2>"$err"; then
        # A 2xx alone is not proof: the body must actually be a search
        # result, not just any 2xx JSON shape.
        if jq -e '.issues | type == "array"' "$out" >/dev/null 2>&1; then
            return 0
        fi
        echo "probe_field_searchable: HTTP 2xx for '$name' but the body has no .issues array — refusing to treat this as searchable:" >&2
        cat "$out" >&2
        return 2
    fi
    if grep -q "HTTP 400" "$err"; then
        return 1
    fi
    cat "$err" >&2
    return 2
}

# ensure_field_searchable NAME FIELD_ID SEARCHER_KEY — probe via JQL, then
# PUT the searcherKey and re-probe once, dying if still unsearchable. The
# probe is the only evidence; GET /field's searcherKey always reads null.
ensure_field_searchable() {
    local name="$1" field_id="$2" searcher="$3" rc put_body
    probe_field_searchable "$name" && rc=0 || rc=$?
    if [ "$rc" = "0" ]; then
        echo "field '$name' ($field_id) is JQL-searchable."
        return 0
    fi
    [ "$rc" = "1" ] || die "could not evaluate JQL-searchability for field '$name' ($field_id) — see above"
    # Capture the body BEFORE the write: a `die` inside a `$( )` used as
    # an argument only ends that subshell, so an inline jq that failed
    # would send a write with an EMPTY body instead of stopping.
    put_body=$(jq -cn --arg s "$searcher" '{searcherKey: $s}') \
        || die "could not render searcherKey PUT body for '$name'"
    echo "field '$name' ($field_id) is NOT searchable (confirmed via HTTP 400) — repairing: PUT searcherKey=$searcher."
    jira_write PUT "/field/$field_id" "$put_body" >/dev/null \
        || die "PUT /field/$field_id (searcherKey=$searcher) failed for '$name' — see the wrapper's own error output above"
    probe_field_searchable "$name" && rc=0 || rc=$?
    [ "$rc" = "0" ] || die "field '$name' ($field_id) is still not JQL-searchable after PUT searcherKey=$searcher — refusing to guess further"
    echo "field '$name' ($field_id) is JQL-searchable after repair."
}

ALL_FIELDS_JSON=""
# field_lookup NAME -> "id<TAB>schemaCustom" and 0 for exactly one match,
# nothing and 0 for none (absent is not a failure), 1 for several. Jira
# does not enforce unique custom field names, so it refuses to guess.
field_lookup() {
    local name="$1" count ids
    count=$(printf '%s' "$ALL_FIELDS_JSON" | jq -r --arg n "$name" \
        '[.[] | select(.custom == true and .name == $n)] | length') || return 1
    if [ "$count" -gt 1 ]; then
        ids=$(printf '%s' "$ALL_FIELDS_JSON" | jq -r --arg n "$name" \
            '[.[] | select(.custom == true and .name == $n)] | map(.id) | join(", ")')
        echo "field_lookup: '$name' matches $count custom fields (ids: $ids) — refusing to guess which one" >&2
        return 1
    fi
    printf '%s' "$ALL_FIELDS_JSON" | jq -r --arg n "$name" \
        '[.[] | select(.custom == true and .name == $n)][0] | select(. != null) | "\(.id)\t\(.schema.custom // "")"'
}

# RESOLVED_FIELD_IDS — parallel to FIELD_NAMES, populated by ensure_fields.
RESOLVED_FIELD_IDS=""

ensure_fields() {
    ALL_FIELDS_JSON=$(jira_get /field) || die "could not read /field — cannot discover custom field ids by name"
    local triples name type searcher found_id found_type new_json ids=""
    triples=$(paste <(printf '%s\n' "$FIELD_NAMES") <(printf '%s\n' "$FIELD_TYPE_KEYS") <(printf '%s\n' "$FIELD_SEARCHER_KEYS"))
    while IFS="$(printf '\t')" read -r name type searcher; do
        [ -n "$name" ] || continue
        local lookup
        lookup=$(field_lookup "$name") || die "could not look up field '$name' (see above)"
        if [ -n "$lookup" ]; then
            found_id="${lookup%%$'\t'*}"
            found_type="${lookup#*$'\t'}"
            [ "$found_type" = "$type" ] \
                || die "a custom field named '$name' already exists ($found_id) but its type ('$found_type') is not the expected '$type' — refusing to reuse it"
            echo "field '$name' already present: $found_id"
        else
            new_json=$(jq -cn --arg name "$name" --arg type "$type" --arg searcher "$searcher" \
                '{name: $name, type: $type, searcherKey: $searcher}') || die "could not render field body for '$name'"
            echo "field '$name' absent — creating."
            new_json=$(jira_write POST /field "$new_json") \
                || die "POST /field failed for '$name' — see the wrapper's own error output above"
            found_id=$(printf '%s' "$new_json" | jq -r '.id // empty') \
                || die "could not parse .id from the create-field response for '$name'"
            [ -n "$found_id" ] || die "POST /field succeeded for '$name' but returned no .id"
            # Refresh the cache so a later duplicate name in this same run
            # is not silently recreated.
            ALL_FIELDS_JSON=$(jira_get /field) || die "could not re-read /field after creating '$name'"
        fi
        ensure_field_searchable "$name" "$found_id" "$searcher"
        ids="$ids$found_id
"
    done <<EOF
$triples
EOF
    RESOLVED_FIELD_IDS="$ids"
    local executor_lookup executor_field_id
    executor_lookup=$(field_lookup executor) || die "could not look up field 'executor' (see above)"
    executor_field_id="${executor_lookup%%$'\t'*}"
    ensure_executor_options "$executor_field_id"
}

# ensure_executor_options FIELD_ID — add agent/human/mixed, only the ones
# missing, to the field's own (first/default) context.
ensure_executor_options() {
    local field_id="$1" contexts ctx_id have_json opt missing_body
    [ -n "$field_id" ] || die "could not resolve the executor field's id — cannot set its options"
    contexts=$(jira_get "/field/$field_id/context") || die "could not read /field/$field_id/context"
    ctx_id=$(printf '%s' "$contexts" | jq -r '.values[0].id // empty') \
        || die "could not parse the executor field's default context id"
    [ -n "$ctx_id" ] || die "executor field ($field_id) has no context to attach options to"
    have_json=$(jira_get "/field/$field_id/context/$ctx_id/option") \
        || die "could not read existing options for the executor field's context"
    while IFS= read -r opt; do
        [ -n "$opt" ] || continue
        if printf '%s' "$have_json" | jq -e --arg v "$opt" '[.values[]? | select(.value == $v)] | length > 0' >/dev/null 2>&1; then
            echo "executor option '$opt' already present."
        else
            missing_body=$(jq -cn --arg v "$opt" '{options: [{value: $v}]}') \
                || die "could not render option body for '$opt'"
            echo "executor option '$opt' absent — adding."
            jira_write POST "/field/$field_id/context/$ctx_id/option" "$missing_body" >/dev/null \
                || die "POST /field/$field_id/context/$ctx_id/option failed for '$opt' — see above"
        fi
    done <<EOF
$EXECUTOR_OPTIONS
EOF
}


SCREEN_IDS=""
collect_screen_ids() {
    local itss_project itss_id mapping scheme_ids scheme_id qs scheme_json ids_here
    itss_project=$(jira_get "/issuetypescreenscheme/project?projectId=$PROJECT_ID") \
        || die "could not read /issuetypescreenscheme/project?projectId=$PROJECT_ID"
    itss_id=$(printf '%s' "$itss_project" | jq -r '.values[0].issueTypeScreenScheme.id // empty') \
        || die "could not parse the project's issueTypeScreenScheme id"
    [ -n "$itss_id" ] || die "project '$PROJECT_KEY' (id $PROJECT_ID) has no issueTypeScreenScheme — cannot place fields on any screen"

    mapping=$(jira_get "/issuetypescreenscheme/mapping?issueTypeScreenSchemeId=$itss_id") \
        || die "could not read /issuetypescreenscheme/mapping?issueTypeScreenSchemeId=$itss_id"
    scheme_ids=$(printf '%s' "$mapping" | jq -r '[.values[].screenSchemeId] | unique[]') \
        || die "could not parse screenSchemeId list from the issue-type-screen-scheme mapping"
    [ -n "$scheme_ids" ] || die "issueTypeScreenScheme '$itss_id' has no screen scheme mappings at all"

    # ONE call, repeated `id=` params. Never rebuild this as a per-id loop
    # (GET /screenscheme/<id> is HTTP 405) or a comma-joined `id=a,b,c`
    # (HTTP 400) — both are confirmed-wrong, not untried alternatives.
    qs=""
    while IFS= read -r scheme_id; do
        [ -n "$scheme_id" ] || continue
        qs="$qs&id=$(jq -rn --arg v "$scheme_id" '$v|@uri')" \
            || die "could not url-encode screen scheme id '$scheme_id'"
    done <<EOF
$scheme_ids
EOF
    qs="${qs#&}"
    scheme_json=$(jira_get "/screenscheme?$qs") || die "could not read /screenscheme?$qs"

    SCREEN_IDS=""
    ids_here=$(printf '%s' "$scheme_json" | jq -r '[.values[] | (.screens // {}) | to_entries[] | .value] | unique[]') \
        || die "could not parse screen ids out of the screen scheme response"
    while IFS= read -r sid; do
        [ -n "$sid" ] || continue
        in_list "$sid" "$SCREEN_IDS" || SCREEN_IDS="$SCREEN_IDS$sid
"
    done <<EOF
$ids_here
EOF
    [ -n "$SCREEN_IDS" ] || die "no screen ids resolved from any screen scheme mapped to '$PROJECT_KEY' — nothing to add fields to"
}

add_fields_to_screens() {
    collect_screen_ids
    local screen_id tabs tab_ids tab_id names_ids name field_id have_fields tab_name
    while IFS= read -r screen_id; do
        [ -n "$screen_id" ] || continue
        tabs=$(jira_get "/screens/$screen_id/tabs") || die "could not read /screens/$screen_id/tabs"
        # Assign and guard, never inline into the heredoc word below: a
        # command substitution there has its exit status discarded, so a
        # malformed response would silently run the loop zero times.
        tab_ids=$(printf '%s' "$tabs" | jq -r '.[].id') \
            || die "could not parse tab ids for screen $screen_id"
        while IFS= read -r tab_id; do
            [ -n "$tab_id" ] || continue
            tab_name=$(printf '%s' "$tabs" | jq -r --arg id "$tab_id" '[.[] | select((.id|tostring) == $id)][0].name // "?"')
            have_fields=$(jira_get "/screens/$screen_id/tabs/$tab_id/fields") \
                || die "could not read /screens/$screen_id/tabs/$tab_id/fields"
            names_ids=$(paste <(printf '%s\n' "$FIELD_NAMES") <(printf '%s\n' "$RESOLVED_FIELD_IDS"))
            while IFS="$(printf '\t')" read -r name field_id; do
                [ -n "$name" ] || continue
                if printf '%s' "$have_fields" | jq -e --arg id "$field_id" '[.[] | select((.id|tostring) == $id)] | length > 0' >/dev/null 2>&1; then
                    echo "field '$name' already on screen $screen_id / tab '$tab_name'."
                else
                    echo "field '$name' absent from screen $screen_id / tab '$tab_name' — adding."
                    jira_write POST "/screens/$screen_id/tabs/$tab_id/fields" "$(jq -cn --arg id "$field_id" '{fieldId: $id}')" >/dev/null \
                        || die "POST /screens/$screen_id/tabs/$tab_id/fields failed for '$name' — see above"
                fi
            done <<EOF
$names_ids
EOF
        done <<EOF
$tab_ids
EOF
    done <<EOF
$SCREEN_IDS
EOF
}


print_field_table() {
    local names_ids name field_id fid_ftype rows=""
    names_ids=$(paste <(printf '%s\n' "$FIELD_NAMES") <(printf '%s\n' "$RESOLVED_FIELD_IDS") <(printf '%s\n' "$FIELD_TYPE_KEYS"))
    while IFS="$(printf '\t')" read -r name field_id fid_ftype; do
        [ -n "$name" ] || continue
        # printf, not interpolation: a literal backslash-t inside a
        # double-quoted string is not a tab. That shipped once.
        rows="$rows$(printf '%s\t%s\t%s' "$field_id" "$name" "$fid_ftype")
"
    done <<EOF
$names_ids
EOF
    printf '%s' "$rows" | table "ID	NAME	TYPE"
}


ensure_project
apply_statuses
ensure_fields
add_fields_to_screens
echo
echo "Jira Space '$PROJECT_KEY' bootstrap complete. Custom fields:"
print_field_table
