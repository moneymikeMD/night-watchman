#!/bin/bash
#
# jira-space-create.sh — one-run bootstrap for a new Jira Space (company-
# managed, "simplified scrum classic" template): project + the six stage
# statuses + the six custom fields + those fields on every screen the
# project's issue types use.
#
# WHY: Spaces created 2026-09-10/11 straight from
# com.pyxis.greenhopper.jira:gh-simplified-scrum-classic came out with only
# To Do/In Progress/Done and no custom fields; the statuses were repaired
# afterwards, by hand, via providers/tracker/jira/jira-workflow-apply.sh. This
# script is that whole bootstrap as ONE run instead of a create-then-patch
# dance, so a new Space starts complete.
#
# THE RECIPE (each step idempotent — a re-run converges, it does not fail
# on "already there"):
#   1. GET /rest/api/3/project/<KEY>. 404 -> POST /rest/api/3/project
#      {key, name, projectTypeKey: "software",
#       projectTemplateKey: "com.pyxis.greenhopper.jira:gh-simplified-scrum-classic",
#       leadAccountId}. leadAccountId is --lead ACCOUNT_ID if given, else
#      this script's own call to `jira-api.sh whoami`'s accountId — NEVER a
#      hardcoded id, it is per-site and per-caller. Already-present ->
#      skip creation, still read it back (step 2 still runs — a
#      previously-mis-templated Space is exactly what step 2 exists to
#      catch, whether this run created it or not).
#   2. ASSERT on the (fresh-or-existing) project: .style == "classic",
#      .projectTypeKey == "software", and at least one .issueTypes[] with
#      .hierarchyLevel == 1 (Epic). Jira's "project" style field has no
#      request-time equivalent — it is a computed property of the
#      TEMPLATE used, so the only way to catch a stale/wrong template key
#      is to read it back and fail loudly (a lesson learned live: a stale
#      template key silently yields a Business project, which has no
#      workflow/status/screen surface this recipe's later steps expect).
#   3. providers/tracker/jira/jira-workflow-apply.sh <KEY> --jira-api <this
#      script's own --jira-api> --yes — adds the six stage statuses (Open,
#      Triage, Awaiting Deployment, Deferred, Completed, Cancelled). See
#      that script's own header for its recipe; it is already idempotent
#      ("already complete" exits 0 doing nothing). --workflow-apply PATH
#      overrides where this script finds it (default: computed relative to
#      this file, see below).
#   4. GET /rest/api/3/field once; for each of touches (textarea), executor
#      (select), verify (textarea), human_steps (textarea), appends
#      (textarea), defer_until (datepicker): if a custom field with that
#      EXACT name already exists, use its id (dying if its schema.custom
#      does not match the expected type — the field cannot both already
#      exist under this name and be a fresh creation with the wanted
#      shape). If absent, POST /rest/api/3/field {name, type, searcherKey}.
#      Field ids are per-SITE — never hardcode one (a production deployment
#      happens to be 10043..10048; that is not a fact this script may
#      depend on).
#      executor additionally gets its three options (agent, human, mixed)
#      via its field context's option endpoint, added only if missing.
#      Then, for EACH of the six fields (found or created): probe it with
#      one JQL search, `project = <KEY> AND "<name>" is EMPTY` fields=key
#      maxResults 1 — measured live: GET /field's own searcherKey
#      comes back null both before and after a working PUT, so it is not
#      evidence either way; POST /field {searcherKey: ...} at create time
#      can ALSO leave a field unsearchable — measured on NWM's own six
#      fields, all created that way (a field created WITH a valid
#      searcherKey is searchable immediately — the repair path below only
#      fires for a field created without one, or with a rejected key).
#      HTTP 400 on this probe IS "not searchable" — the real API body
#      carries no such text (that wording is the Automation UI's, a
#      different surface); the only signal is the 400 itself, on a probe
#      of a field this script just found-or-created with well-formed JQL.
#      NOT MET: PUT /field/<id> {searcherKey: <the same FIELD_SEARCHER_
#      KEYS entry>} and re-probe once; die if still unsearchable. Any
#      other probe failure (a non-400, or a 2xx whose body is not an
#      actual search result) is a hard die — never guessed past.
#   5. Add each of the six fields to EVERY screen the project's
#      issue-type screen scheme actually uses (a field created but never
#      placed on a screen accepts no value at all when a caller tries to
#      write it — the 2026-09-10 SPK lesson). Walked live, not assumed:
#      GET /issuetypescreenscheme/project?projectId=<id> ->
#      GET /issuetypescreenscheme/mapping?issueTypeScreenSchemeId=<id> (one
#      or more issueTypeScreenScheme entries can map to different
#      screenSchemeIds) -> GET /screenscheme?id=<a>&id=<b>&id=<c> (default/
#      create/edit/view screen ids, deduplicated) -> GET /screens/<id>/tabs
#      -> for each tab, GET its fields and POST the missing ones. A field
#      already on a tab is skipped, not re-added.
#      CONFIRMED LIVE (ZZSPIKE, run 2): there is no per-id GET
#      /screenscheme/<id> at all — HTTP 405 "Method 'GET' is not
#      supported". The bulk GET /screenscheme takes REPEATED `id=`
#      query params, one per screen scheme id — `id=10049&id=10050&
#      id=10051` — NOT a comma-joined list (`id=10049,10050,10051` is
#      HTTP 400 "Failed to convert 'id'"). collect_screen_ids issues
#      exactly one such call for however many distinct screenSchemeIds
#      the mapping returned.
#   6. Print the six customfield ids as a table (ID, NAME, TYPE).
#
# Usage:
#   jira-space-create.sh KEY "Name" --dry-run
#   jira-space-create.sh KEY "Name" --yes [--lead ACCOUNT_ID]
#                         [--jira-api PATH] [--workflow-apply PATH]
#
#   KEY              2-10 uppercase letters/digits, starting with a letter
#                    (e.g. CHR, TDO2). A deleted project's key stays
#                    reserved site-wide — re-running this script against a
#                    key that 404s on create because of that is a Jira-side
#                    fact this script cannot work around; pick a different
#                    key.
#   "Name"           the project's display name, quoted if it has spaces.
#   --dry-run        print every planned request and exit 0. Reaches NO
#                     network at all for the one step that cannot be made
#                     safe any other way (step 3 — jira-workflow-apply.sh's
#                     OWN reads are not gated by its --dry-run flag, see
#                     its header; calling it from here under our --dry-run
#                     would issue real, credentialed GETs against whatever
#                     KEY was given). Every other step is announced via
#                     this script's own `jira-api.sh --dry-run ...` calls,
#                     which resolve no credential either.
#   --yes            actually run it. Without --yes, on a terminal, this
#                     script asks y/N once, up front, before any write;
#                     without a terminal and without --yes, it refuses.
#   --lead ACCOUNT_ID  the project lead's Jira accountId. Default: this
#                     script's own `jira-api.sh whoami`.
#   --jira-api PATH  path to a jira-api.sh-shaped wrapper (raw GET, write
#                     POST, --dry-run, --yes — see jira-api.sh's own
#                     header). Defaults to $ISSUES_JIRA_API, or
#                     jira-api.sh next to this script if that is unset.
#   --workflow-apply PATH  path to a jira-workflow-apply.sh-shaped script
#                     for step 3. Default: jira-workflow-apply.sh next to
#                     this file.
#
# Env vars:
#   ISSUES_JIRA_API   default --jira-api path, same convention as
#                     jira-workflow-apply.sh and land-branch.sh's jira mode.
#   NW_CONFIG         honoured by the wrapper (jira-api.sh's own config
#                     reader), not read directly here.
#
# Board and the first sprint are OUT OF SCOPE.
#
# Exit status:
#   0   every step converged (created fresh, or already-present and
#       verified), or --dry-run completed.
#   1   a read failed, an ASSERT in step 2 failed, step 3/4/5 failed, or a
#       field name already exists under the wrong schema type.
#   3   stopped because --yes was not given and there was no terminal to
#       ask on, or the terminal answered anything other than y/yes — same
#       meaning as jira-workflow-apply.sh's own exit 3: nothing was sent,
#       this is a refusal, not a failure.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/http.sh
. "$DIR/lib/http.sh"
# shellcheck source=../../lib/kit.sh
. "$(cd "$DIR/../../lib" && pwd)/kit.sh"

# --------------------------------------------------------------- target sets
#
# Parallel, newline-separated (bash 3.2: no associative arrays), exact
# table order. Never hardcode a field id, a status id, or a screen/tab id
# anywhere below — every one of those is resolved live, by name, at
# runtime.
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
# executor's searcherKey is multiselectsearcher, NOT selectsearcher — MEASURED
# measured live: a select field's PUT /field/<id> {searcherKey: selectsearcher}
# is HTTP 400; multiselectsearcher is accepted and makes the field
# JQL-searchable. Text and date keys below were also measured, both
# confirmed correct as listed.
FIELD_SEARCHER_KEYS='com.atlassian.jira.plugin.system.customfieldtypes:textsearcher
com.atlassian.jira.plugin.system.customfieldtypes:multiselectsearcher
com.atlassian.jira.plugin.system.customfieldtypes:textsearcher
com.atlassian.jira.plugin.system.customfieldtypes:textsearcher
com.atlassian.jira.plugin.system.customfieldtypes:textsearcher
com.atlassian.jira.plugin.system.customfieldtypes:daterange'
EXECUTOR_OPTIONS='agent
human
mixed'

# --------------------------------------------------------------- flags

PROJECT_KEY=""
PROJECT_NAME=""
DRY_RUN=0
ASSUME_YES=0
LEAD_ACCOUNT_ID=""
JIRA_API_PATH="${ISSUES_JIRA_API:-}"
WORKFLOW_APPLY_PATH=""

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

# KEY: 2-10 uppercase letters/digits, starting with a letter. Three
# independent checks rather than one regex (bash 3.2's `case` glob has no
# {2,10} quantifier): first character, character set, then length.
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

[ -n "$WORKFLOW_APPLY_PATH" ] || WORKFLOW_APPLY_PATH="$DIR/jira-workflow-apply.sh"
[ -x "$WORKFLOW_APPLY_PATH" ] || die "--workflow-apply path is not an executable file: '$WORKFLOW_APPLY_PATH'"

need jq

have_terminal() { [ -t 0 ] && [ -r /dev/tty ]; }

# --------------------------------------------------------------- dry-run
#
# Every call below is `jira-api.sh --dry-run`, which resolves no
# credential and reaches no network (jira-api.sh's own guarantee — see its
# header). Step 3 (jira-workflow-apply.sh) is the one exception: THAT
# script's own reads are not gated by its --dry-run flag (see its header —
# jira_raw_get never passes --dry-run through), so invoking it here would
# issue real, credentialed GETs. It is announced only, never actually run.
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
    echo "3. would run (not invoked here — see this script's own header on why):"
    echo "   $WORKFLOW_APPLY_PATH $PROJECT_KEY --jira-api $JIRA_API_PATH --yes"
    echo "   (adds statuses: Open, Triage, Awaiting Deployment, Deferred, Completed, Cancelled)"
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

# --------------------------------------------------------------- confirm
#
# One gate, up front, before ANY write in this run — mirrors
# jira-workflow-apply.sh's single end-to-end --yes; every write below
# passes the wrapper's own --yes unconditionally once this gate passes,
# same as that script's jira_write_mutating.
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

# --------------------------------------------------------------- helpers

# jira_get PATH — a real GET, dies on any failure (this run has already
# been confirmed; every call from here on is real).
jira_get() { "$JIRA_API_PATH" raw GET "$1"; }

# jira_get_soft PATH — a real GET that treats HTTP 404 as "not found"
# rather than fatal. Prints the body and returns 0 when found; prints
# NOTHING and returns 1 on a 404 (rule: a fallible helper used inside
# $( ) prints nothing and returns non-zero — the caller decides); on any
# OTHER failure it prints the wrapper's own error to stderr (real stderr,
# not captured by a $( ) around this call) and returns 2, for the caller
# to `die` on at the top level.
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
# THIS script's own gate having already passed above, not a fresh ask.
jira_write() { "$JIRA_API_PATH" --yes write "$1" "$2" "${3:-}"; }

# in_list VALUE LIST — bash 3.2 literal-line membership test.
in_list() {
    local value="$1" list="$2"
    printf '%s\n' "$list" | grep -qxF "$value"
}

# --------------------------------------------------------------- step 1+2: project

resolve_lead() {
    [ -n "$LEAD_ACCOUNT_ID" ] && return 0
    local who
    who=$(jira_get /myself) || die "could not resolve the project lead: /myself failed, and no --lead was given"
    LEAD_ACCOUNT_ID=$(printf '%s' "$who" | jq -r '.accountId // empty') \
        || die "could not parse accountId from /myself"
    [ -n "$LEAD_ACCOUNT_ID" ] || die "/myself returned no accountId — cannot resolve a project lead without --lead"
}

# assert_project_shape <project-json> — die() (see this file's own header,
# THE RECIPE step 2) if the readback shows anything other than a classic
# software project with an Epic issue type: a stale/wrong
# projectTemplateKey silently yields a Business project instead (the
# lesson learned live).
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
    # rc MUST be captured in the SAME statement as the call — `if cmd;
    # then ...; fi` with no `else` leaves $? as the if-COMPOUND's own
    # status once execution reaches past `fi` (0 on the untaken branch),
    # not jira_get_soft's real 1/2. That bug shipped once (found live,
    # ZZSPIKE): a real 404 read `rc=0` after the `fi` and hit the
    # "unexpected error" die below on every fresh KEY. `existing=$(...);
    # rc=$?` on two statements is not safe either — under `set -e`, a
    # failing command substitution assignment (rc 1 or 2 here) is a plain
    # simple command and exits the script immediately, before `rc=$?` is
    # ever reached, UNLESS it sits inside a conditional context (if/while,
    # or a `&&`/`||` list). `cmd && rc=0 || rc=$?` is that list — the
    # assignment is never the LAST command run, so `-e` never fires on it.
    existing=$(jira_get_soft "/project/$PROJECT_KEY") && rc=0 || rc=$?
    if [ "$rc" = "0" ]; then
        # Deliberately does not contain the substring "creating" anywhere
        # — a caller grepping a run's log for "creating" to confirm
        # nothing was created (the idempotent-rerun check) used to get a
        # false hit here (found live, ZZSPIKE run 4: matched once with
        # zero POSTs, from "...not creating.").
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

# --------------------------------------------------------------- step 3: statuses

apply_statuses() {
    echo "applying the six stage statuses via $WORKFLOW_APPLY_PATH ..."
    "$WORKFLOW_APPLY_PATH" "$PROJECT_KEY" --jira-api "$JIRA_API_PATH" --yes \
        || die "$WORKFLOW_APPLY_PATH failed for '$PROJECT_KEY' — see its own output above"
}

# --------------------------------------------------------------- step 4: custom fields

# probe_field_searchable NAME — one real JQL search, `project = <KEY> AND
# "<name>" is EMPTY` maxResults 1. Prints nothing; returns 0 (searchable —
# AND the body actually parses as a search result), 1 (confirmed NOT
# searchable), or 2 (any other failure — caller dies at the top level;
# rule: a fallible helper used inside $( )/`if` prints nothing on the
# non-0/1 path it cannot explain and lets the caller die).
#
# MEASURED LIVE (fixtures/space-search-jql-not-searchable.txt):
# the real API's HTTP 400 body carries NO "not searchable" text anywhere
# — that wording belongs to the Automation UI, a different surface this
# script never touches. An earlier version of this function grepped for
# it and would have silently treated every real unsearchable field as
# "could not evaluate" (a hard die on a case this function exists to
# handle) rather than the repairable case it actually is. The only real
# signal available: HTTP 400 on a probe of a field this script itself
# just found-or-created, with a well-formed JQL clause — any 400 here IS
# the "not searchable" case, body text or not.
probe_field_searchable() {
    local name="$1" jql enc out err
    jql="project = $PROJECT_KEY AND \"$name\" is EMPTY"
    enc=$(jq -rn --arg v "$jql" '$v|@uri') || return 2
    out=$(tmpfile) || return 2
    err=$(tmpfile) || return 2
    if "$JIRA_API_PATH" raw GET "/search/jql?jql=$enc&fields=key&maxResults=1" >"$out" 2>"$err"; then
        # A 2xx alone is not proof (standing order): the body must
        # actually be a search result, not just any 2xx JSON shape.
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

# ensure_field_searchable NAME FIELD_ID SEARCHER_KEY — probe via JQL
# (GET /field's own searcherKey is null both before and after a
# working PUT, so it is not evidence — see this file's own header). On a
# confirmed-unsearchable probe, PUT the searcherKey and re-probe once;
# die if it is still unsearchable after the repair.
ensure_field_searchable() {
    local name="$1" field_id="$2" searcher="$3" rc put_body
    probe_field_searchable "$name" && rc=0 || rc=$?
    if [ "$rc" = "0" ]; then
        echo "field '$name' ($field_id) is JQL-searchable."
        return 0
    fi
    [ "$rc" = "1" ] || die "could not evaluate JQL-searchability for field '$name' ($field_id) — see above"
    # Capture the body BEFORE the write, same rule as ensure_fields' own
    # field-create call: a `die` inside a `$( )` used as an argument only
    # ends that subshell, not the script — `jira_write PUT ... "$(jq ...)"`
    # with the jq failing would send a write with an EMPTY body instead of
    # stopping.
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
# field_lookup NAME -> prints "id<TAB>schemaCustom" and returns 0 when
# exactly one custom field has this name; prints NOTHING and returns 0
# when none do (rule: absent is not a failure, the caller creates it);
# prints an explanation to STDERR (visible through a $( ) capture — only
# stdout is discarded there) and returns 1 when MORE THAN ONE does — Jira
# does not enforce unique custom field names, and silently picking "the
# first match" would point every later read/write at whichever one
# happened to sort first, not at the one this script itself manages.
# Never calls `die` itself: a fallible helper used inside $( ) must
# return non-zero and let the CALLER die at the top level, or the exit
# never actually stops the script (die inside a command-substitution
# subshell only ends that subshell).
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
            # refresh the cached field list so a later duplicate name in
            # this same run (there is none today, but a future addition to
            # FIELD_NAMES should not silently recreate) sees it too.
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

# --------------------------------------------------------------- step 5: screens

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

    # ONE call, repeated `id=` query params — CONFIRMED LIVE (ZZSPIKE, run
    # 2): GET /screenscheme/<id> does not exist (HTTP 405 "Method 'GET' is
    # not supported"), and the comma-joined form `id=a,b,c` is HTTP 400
    # ("Failed to convert 'id'"). Never rebuild this as a per-id loop or a
    # comma-joined list — both are confirmed-wrong shapes, not untried
    # alternatives.
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
        # A jq failure here MUST be caught explicitly: `done <<EOF /
        # $(...)` puts the command substitution in the heredoc's WORD,
        # where its own exit status is discarded (heredoc-word expansion,
        # not a `var=$(...)` assignment) and `set -e` never sees it —
        # a malformed tabs response would silently make this loop run
        # ZERO times for that screen, and the run would print "bootstrap
        # complete" having skipped it entirely.
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

# --------------------------------------------------------------- step 6: report

print_field_table() {
    local names_ids name field_id fid_ftype rows=""
    names_ids=$(paste <(printf '%s\n' "$FIELD_NAMES") <(printf '%s\n' "$RESOLVED_FIELD_IDS") <(printf '%s\n' "$FIELD_TYPE_KEYS"))
    while IFS="$(printf '\t')" read -r name field_id fid_ftype; do
        [ -n "$name" ] || continue
        # A literal backslash-t inside a double-quoted string is NOT a tab
        # — that shipped once (found live, ZZSPIKE run 3: the printed
        # table showed "customfield_10043\ttouches\t..." verbatim). printf
        # '%s\t%s\t%s' actually expands the escape; string interpolation
        # never does.
        rows="$rows$(printf '%s\t%s\t%s' "$field_id" "$name" "$fid_ftype")
"
    done <<EOF
$names_ids
EOF
    printf '%s' "$rows" | table "ID	NAME	TYPE"
}

# --------------------------------------------------------------- main

ensure_project
apply_statuses
ensure_fields
add_fields_to_screens
echo
echo "Jira Space '$PROJECT_KEY' bootstrap complete. Custom fields:"
print_field_table
