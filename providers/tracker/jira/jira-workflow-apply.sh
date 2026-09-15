#!/bin/bash
#
# One-shot fixup for a Jira company-managed project created from the
# "simplified scrum classic" template: that template ships a workflow with
# only To Do/In Progress/Done, but this plugin's stage set needs six more
# (Open, Triage, Awaiting Deployment, Deferred, Completed, Cancelled), each
# reachable from any status via a GLOBAL transition. Found 2026-09-11
# that every per-repo Jira Space created from that template lacks LAB's
# extra statuses, so issues.py mis-stages Done tickets
# (jira-unknown-status:Done) and Awaiting Deployment/Deferred are unusable.
#
# This is a recipe proven live on a scratch project, 2026-09-09; see
# docs/services-and-accounts.md in the source project and the memory-graph
# entry it was recorded from), turned into a script that can be re-run
# against any other project's own copy of the template workflow rather than
# hand-typed again per project.
#
# THE RECIPE:
#   1. Resolve each target status name to its site-wide global status id AND
#      its statusCategory (TODO/IN_PROGRESS/DONE — a required enum on any
#      newly-declared status) via GET /rest/api/3/statuses/search?
#      maxResults=100 — NEVER hardcode an id or a category, because both are
#      assigned per Jira SITE, not per project, and differ between sites.
#      Fail loudly if a name is missing rather than guessing.
#   2. Read the project's own editable default workflow, named exactly
#      "Software Simplified Workflow for Project <KEY>", via
#      GET /rest/api/3/workflow/search?workflowName=<urlencoded>&expand=
#      transitions,statuses (the wrapper's `raw GET`). Confirmed live
#      (2026-09-11) that this endpoint's OWN read shape (`to` as a bare
#      status-id string, `type` lower-cased "global"/"initial", no
#      `version` field at all) is NOT the shape /workflows/update needs —
#      it is used ONLY for the workflow's entityId and for computing the
#      missing-status/missing-transition sets by name, never as the base
#      the update body is rendered from (see step 3).
#   3. Fetch the workflow's FULL editable representation AND its `version`
#      via POST /rest/api/3/workflows {workflowNames:[NAME]} — a bulk-get
#      that does not mutate anything on Jira's side despite the POST verb
#      (the request body is a name list, not a document to persist), so it
#      is issued unconditionally, even under --dry-run, the same as the
#      read GETs above. It goes through the wrapper's `write` because the
#      wrapper's own verb allowlist has no other category for a POST; see
#      jira_write_readonly_semantics below. Confirmed live (2026-09-11,
#      both NWM and a throwaway scratch project SPK4) that THIS response —
#      not workflow/search's — is the correct base to build an update body
#      from: `toStatusReference` (not `to`), `type` UPPER-cased ("GLOBAL"/
#      "INITIAL"), a workflow-level `scope`, and each workflow keyed by a
#      plain string `name` with a plain string `id` (its entityId) — see
#      fixtures/workflows.bulkget.{nwm,spk4}.txt.
#   4. Validate the fully-rendered body via
#      POST /rest/api/3/workflows/update/validation — also non-mutating,
#      also issued unconditionally — and abort non-zero on any ERROR-level
#      finding, before ever showing the "about to write" preview.
#      CONFIRMED LIVE (2026-09-11, against both SPK4 and NWM — see
#      fixtures/workflows.update.validation.{spk4,nwm}.txt): this endpoint
#      does NOT take the bare update body — it takes an envelope,
#      {"payload": <the update body>, "validationOptions":
#      {"levels": ["ERROR","WARNING"]}}. Sending the bare body 400s with a
#      useless generic message; the envelope gets a real, field-level
#      {"errors": [{"code","message","level","type","elementReference"}]}
#      response (empty `errors` = valid) — see validate_update_body.
#   5. Only past that point, gated on --yes, POST the SAME (unwrapped)
#      body to /rest/api/3/workflows/update. Every ADDED status is
#      declared once at the request's top level with BOTH `id` AND
#      `statusReference` set to the real global status id ({id,
#      statusReference, name, statusCategory} — CONFIRMED LIVE that
#      omitting `id` there makes Jira treat the entry as a brand-new
#      status CREATE, which then collides with the name already existing
#      site-wide: "Status name ... already in use", code
#      NON_UNIQUE_STATUS_NAME) and referenced from the workflow's own
#      statuses list (confirmed minimal shape: {statusReference} alone);
#      every ADDED transition carries a caller-assigned numeric `id`
#      (Jira does not generate one — omitting it produced the
#      recipe's original unexplained HTTP 400 on an older API surface) in
#      the confirmed minimal shape {id, name, type, toStatusReference}.
#   6. Read back and assert every target name is present.
#
# CONFIRMED LIVE, 2026-09-11: a full live spike against a real, disposable
# scratch project (SPK4, same template as NWM, owner-authorized) plus a
# repeat against NWM. Iterated one change at a time against SPK4 (each
# recorded in fixtures/workflows.update.validation.spk4.txt's own header):
#   (a) a bare round-trip of the bulk-get read (no additions, wrapped in
#       the envelope) with an EMPTY top-level `statuses` array -> HTTP 400
#       "payload.statuses : must not be empty" (envelope accepted; this
#       specific content rejected).
#   (a2) the same, with every EXISTING status re-declared in `statuses`
#       using only {statusReference, name, statusCategory, scope} (no
#       `id`) -> HTTP 200, but 3 ERRORs, one per existing status:
#       "Status name \"To Do\" already in use. Try a different name."
#       (code NON_UNIQUE_STATUS_NAME) — declaring an EXISTING status
#       without its `id` gets treated as creating a NEW one with the same
#       (already-taken) name.
#   (b) the six target statuses added to `statuses` the same
#       (`id`-less) way -> HTTP 200, 9 ERRORs (3 existing + 6 new, all
#       NON_UNIQUE_STATUS_NAME) — confirms this is a general rule, not
#       specific to the three template statuses.
#   (b2) every status declaration (existing AND new) given BOTH `id` and
#       `statusReference` (same value) -> HTTP 200, 0 ERRORs, 6 WARNINGs
#       (code NO_INBOUND_TRANSITIONS_TO_STATUS — expected, the new
#       transitions had not been added to the workflow's own
#       `transitions` list yet at this point in the iteration).
#   (c) the six target transitions added -> HTTP 200, `{"errors": []}` —
#       ZERO errors, ZERO warnings. Re-ran the IDENTICAL body (workflow
#       id/version substituted) against NWM -> also HTTP 200,
#       `{"errors": []}`.
#   (min) a further-trimmed body (workflow-level statuses as bare
#       {statusReference}; transitions without `description`; the
#       workflow object without `name`/`scope`; status DEFINITIONS
#       without `scope`/`description`) -> STILL HTTP 200, `{"errors": []}`
#       for both SPK4 and NWM — this is the shape build_update_body now
#       renders; see its own header comment.
# POST /workflows/update itself (the one call that actually mutates
# state) was still NEVER issued against any project in this session, LAB
# included, per instruction — this script's own --dry-run and the
# selftest's stub both stop before it.
#
# RESOLVED LIVE (2026-09-11, round-2 review's SPK4 apply — the first, and
# so far only, real POST /workflows/update this recipe has ever issued):
# the question the previous revision of this section left open —
# "does /workflows/update default a dropped field the way /validation
# apparently does, or is it pickier?" — has an answer, and it is the worse
# one: NEITHER. It REPLACES. A minimal-but-validating request for an
# EXISTING transition (the shape this script used to send: {id, name,
# type, toStatusReference}, missing actions/validators/triggers/links/
# properties/description) does not get those missing fields defaulted —
# it gets them DELETED, because Jira treats the whole transition object as
# the new source of truth, not a patch. Every one of SPK4's four original
# transitions (11/21/31/1) came back with empty actions/validators/
# properties after that apply — see jira_bulkget's header and
# fixtures/workflows.bulkget.spk4-secrets-postapply.txt. This is why
# build_update_body now carries every existing status/transition forward
# with EVERY field the bulk-get returned, not a reshaped subset — full
# passthrough is not a style preference, it is the only safe way to call
# this endpoint at all. --restore-from exists because that first apply's
# damage cannot be undone from its own (pre-fix, redacted) before-file;
# see --restore-from's own header entry above.
#
# The initial-transition-target flag this script originally shipped
# (`--initial-status`) remains REMOVED rather than fixed: its field name
# was an unproven guess and its argument plumbing was independently
# broken. The initial transition (Create, id 1) is always carried forward
# unmodified — new issues keep landing on the template's own To Do exactly
# as before. Re-add it only once a real field name has been confirmed
# against a live /workflows/update run.
#
# Usage:
#   ./jira-workflow-apply.sh <PROJECT_KEY> [--jira-api PATH] [--dry-run]
#                             [--yes] [--restore-from PATH] [--rules PATH]
#
#   PROJECT_KEY      the Jira project key, e.g. NWM
#   --jira-api PATH  path to a jira-api.sh-shaped wrapper (raw GET,
#                     write POST/PUT/PATCH, --dry-run, --yes, --show-secrets
#                     — see $ISSUES_JIRA_API / land-branch.sh's jira mode
#                     for the convention this mirrors). Defaults to
#                     $ISSUES_JIRA_API; one of the two is required.
#   --dry-run        run every read-only-by-semantics call (the two GETs,
#                     the version bulk-get, and the /validation call) and
#                     print the exact FINAL request body (including the
#                     real version and whatever the validation call
#                     reported), then exit 0 without ever calling
#                     /workflows/update itself.
#   --yes            actually issue the /workflows/update write. Without
#                     it, this script still runs every read-only-by-
#                     semantics call and prints the same final body, then
#                     stops with exit code 3 (see "Exit status" below).
#                     THIS SCRIPT'S OWN --yes IS THE ONLY GATE on the
#                     mutating call: jira_write_mutating passes the
#                     wrapper's own --yes through UNCONDITIONALLY once
#                     this script's gate is satisfied, so the wrapper's
#                     own interactive y/N confirmation never actually
#                     fires for that call. (An earlier revision of this
#                     comment claimed the wrapper's confirmation "still
#                     applies on top" — it does not; corrected 2026-09-11
#                     round-2 review.)
#   --restore-from PATH   ROUND-3 REVIEW ITEM 4. Re-POST the exact
#                     workflow document found in PATH (a before/after
#                     snapshot this script itself wrote — see
#                     jira_bulkget's header) back to /workflows/update,
#                     with a FRESH `version` (the file's own version has
#                     necessarily moved by the time you run this). Skips
#                     the missing-set computation entirely — this is a
#                     literal restore, not "add whatever's missing". REFUSES
#                     outright if PATH contains the literal string
#                     "<redacted>" — a snapshot captured before this
#                     script always read with --show-secrets would restore
#                     the exact stripped-rules bug this flag exists to fix.
#                     There is no way to recover a rule value that was
#                     only ever seen redacted; that snapshot cannot be
#                     used as a restore source, full stop.
#   --rules PATH     Also ensure the transition validators listed in
#                     PATH (see workflow-rules.json beside this script) are
#                     present. Additive only: a rule already on the
#                     transition by ruleKey + parameters is left alone, a
#                     missing one is appended, none is ever removed. Field
#                     and status names in parameters resolve to site ids at
#                     runtime. With --rules the bulk-get always runs, and
#                     "already complete" means statuses, transitions AND
#                     rules. Not combinable with --restore-from.
#
# Examples:
#   ./jira-workflow-apply.sh NWM --dry-run
#   ./jira-workflow-apply.sh NWM --yes
#   ./jira-workflow-apply.sh SPK4 --rules workflow-rules.json --dry-run
#   ./jira-workflow-apply.sh SPK4 --restore-from /tmp/jira-workflow-apply.SPK4.<epoch>.before.json --yes
#
# Env vars:
#   ISSUES_JIRA_API   default path to the jira-api.sh-shaped wrapper, same
#                     convention as land-branch.sh's jira mode. --jira-api
#                     overrides it.
#
# Exit status:
#   0   the target set was already complete, OR --dry-run completed, OR
#       the write (under --yes) succeeded and the read-back/deep-diff
#       both prove it.
#   1   a general failure — a read failed, resolution failed, validation
#       reported an ERROR, the empty-additions guard fired, a transition-
#       id collision was found, or read-back still shows something
#       missing after a write.
#   2   the write itself succeeded but the post-write deep-diff (ROUND-3
#       REVIEW ITEM 3 — a full jq equality check per existing transition's
#       actions/validators/triggers/links, not merely a count) shows an
#       existing transition's rules CHANGED — the workflow was changed,
#       but not safely; see the before/after files this run printed the
#       paths to (now --show-secrets snapshots — see jira_bulkget's
#       header — so they double as a restore source for --restore-from).
#   3   stopped because --yes was not given (distinct from 1: this is not
#       a failure, it is this script correctly refusing to write without
#       explicit confirmation — a caller scripting around this tool can
#       tell "nothing happened, rerun with --yes" apart from "something
#       actually went wrong").

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib/kit.sh
. "$DIR/../../lib/kit.sh"
# shellcheck source=lib/http.sh
. "$DIR/lib/http.sh"

# --------------------------------------------------------------- target set
#
# Do NOT hardcode a status id anywhere below this point — every id used in
# a request body is resolved by NAME at runtime via resolve_status_ids.
# TARGET_STATUS_LIST / TARGET_TRANSITION_IDS are parallel, newline-separated
# lists in exact table order (bash 3.2 has no associative arrays, and a
# space-split string would break on the two names that contain a space,
# e.g. "Awaiting Deployment").
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

# --------------------------------------------------------------- flags

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

# jira_raw_get <path> — GET through the wrapper, redacted output already
# (the wrapper's own `raw` guarantees that). Dies on failure (top-level
# call, not inside a pipe's subshell). No --yes here: `raw` is GET/HEAD
# only in every wrapper this script targets and needs no confirmation at
# all, so passing --yes to it said nothing true.
jira_raw_get() {
    "$JIRA_API_PATH" raw GET "$1"
}

# jira_write_readonly_semantics <method> <path> <body> — a POST that does
# NOT mutate anything on Jira's side despite the verb (the
# validation-only endpoint) but has to go through the wrapper's `write`
# because the wrapper's own verb allowlist has no other category for a
# POST. Always passes the wrapper's OWN --yes, unconditionally, because
# THIS script's --yes/--dry-run gate is about the one call that actually
# mutates state (/workflows/update itself, see jira_write_mutating below)
# — not about this one, which runs even under --dry-run.
jira_write_readonly_semantics() {
    local method="$1" path="$2" body="$3"
    "$JIRA_API_PATH" --yes write "$method" "$path" "$body"
}

# jira_bulkget <workflowNames-body> — POST /workflows, with --show-secrets.
# ROUND-3 REVIEW ITEM 1 — the wrapper's default redaction blanks any field
# NAME containing "key", including actions[].ruleKey and
# validators[].parameters.permissionKey. Those are Jira-internal RULE
# IDENTIFIERS (e.g. "system:update-field", "CREATE_ISSUES" — see
# fixtures/workflows.bulkget.zzprobe-secrets.txt), not credentials — but
# read WITHOUT --show-secrets they arrive as the literal string
# "<redacted>", and round-tripping that string back into a future
# /workflows/update request REPLACES the real rule with a bogus one (or,
# if the field is dropped instead, strips it outright). CONFIRMED LIVE,
# 2026-09-11: the SPK4 apply run done before this fix used exactly that
# redacted read, and Jira's own update semantics turned out to REPLACE
# each transition wholesale with whatever the request contained — every
# existing transition's actions/validators/properties came back empty
# afterward (see fixtures/workflows.bulkget.spk4-secrets-postapply.txt's
# header for the full before/after). --show-secrets is used ONLY here —
# never for validate_update_body's envelope, never for the two `raw GET`
# reads, both of which carry no rule data to round-trip. The response is
# piped straight into a variable or a file at every call site below;
# nothing this function returns is ever echoed to the terminal for its
# own sake — the only things actually printed from it are the derived,
# jq-rendered request body (still real rule identifiers, still not
# credentials) and the before/after snapshot FILE PATHS. Because the
# snapshots this script now writes carry real rule definitions instead of
# "<redacted>", they are a RESTORE source, not merely a diff source — see
# --restore-from below.
jira_bulkget() {
    local body="$1"
    "$JIRA_API_PATH" --show-secrets --yes write POST /workflows "$body"
}

# jira_write_mutating <method> <path> <body> — the one call in this script
# that actually changes Jira state. Gated on ASSUME_YES: passed through as
# the wrapper's own --yes so a single --yes on this script is enough end to
# end, matching every other wrapper-consuming script in this plugin. Never
# called under --dry-run or without ASSUME_YES=1 — see main below.
jira_write_mutating() {
    local method="$1" path="$2" body="$3"
    "$JIRA_API_PATH" --yes write "$method" "$path" "$body"
}

# --------------------------------------------------------------- status ids
#
# resolve_status_ids — populate RESOLVED_STATUS_IDS and
# RESOLVED_STATUS_CATEGORIES (newline-separated, same order as
# TARGET_STATUS_LIST) by NAME from GET /statuses/search?maxResults=100.
# Dies naming every status name that could not be found, rather than
# resolving the ones it can and silently skipping the rest. statusCategory
# is captured here (not left null) because it is a required enum
# (TODO/IN_PROGRESS/DONE) on any status DEFINITION in the update body — see
# BLOCKER 4.
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

# --------------------------------------------------------------- workflow read

WORKFLOW_NAME=""
WORKFLOW_ENTITY_ID=""
WORKFLOW_JSON=""

# read_workflow <project-key> — GET /workflow/search?workflowName=...&
# expand=transitions,statuses for "Software Simplified Workflow for Project
# <KEY>". Dies naming the workflow if Jira has none by that exact name (a
# project not created from this template, or already renamed/copied away
# from the editable default, is out of scope for this recipe). Captures
# the workflow's entityId (BLOCKER 6 — this is the plain string `id` an
# update request needs, not the {name, entityId} pair workflow/search's
# own read shape nests it under) alongside the full statuses/transitions.
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
# names currently present in WORKFLOW_JSON's first (only expected) value.
workflow_status_names() {
    printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].statuses[].name'
}
workflow_transition_names() {
    printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].transitions[].name'
}
# workflow_transition_id_name_pairs — "id<TAB>name" for every transition
# currently on the workflow, used by check_transition_id_collisions below.
workflow_transition_id_name_pairs() {
    printf '%s' "$WORKFLOW_JSON" | jq -r '.values[0].transitions[] | "\(.id)\t\(.name)"'
}

# name_in_list <name> <newline-list> — bash 3.2 has no arrays-as-values, so
# every "is X already present" check is a literal-line grep on a
# newline-separated string, not a hash lookup.
name_in_list() {
    local name="$1" list="$2"
    printf '%s\n' "$list" | grep -qxF "$name"
}

# --------------------------------------------------------------- missing sets

MISSING_STATUS_NAMES=""
MISSING_TRANSITION_NAMES=""

# check_transition_id_collisions — ROUND-2 REVIEW ITEM 4. For every target
# transition id (41/51/61/71/81/91), look at whatever NAME currently owns
# that id on the workflow (if any) and die if it is not the name this
# script would assign it. Runs for EVERY target pair, every call — not
# just the ones compute_missing finds "missing" — because the risk is
# caller-assigned id REUSE colliding with an unrelated, pre-existing
# transition that happens to already sit on that id, which is orthogonal
# to whether the target NAME is separately present or absent.
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

# --------------------------------------------------------------- rules
#
# Rule identity is ruleKey + parameters, never the uuid rule id
# Jira regenerates on write (see validate_write_and_diff). Parameter shapes
# were recorded live on a scratch project: fixtures/workflows.bulkget.
# spk4-rules-after.txt, from the probes in workflows.update.validation.
# spk4-rules-probe-{1,2,3}.txt.

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

# --------------------------------------------------------------- update body
#
# build_update_body <bulkget-response-json> <version-json> — the FULL
# POST /workflows/update request (BLOCKER 2: existing statuses/transitions
# carried forward, PLUS additions — never a delta). BLOCKER 1: additions is
# the UNION of MISSING_STATUS_NAMES and MISSING_TRANSITION_NAMES (a name
# can be missing its transition while its status already exists, or vice
# versa — treating only one of the two sets as authoritative silently
# dropped the other and would have sent an empty definition). Dies (via
# jq's `error`, non-zero exit) if that union is empty, which should be
# unreachable because the caller already checked "already complete" first
# — a structural second guard against ever sending an empty definition,
# not just a first check.
#
# Sources existing statuses/transitions from the POST /workflows bulk-get
# response (`bulkget_json`), NOT from GET /workflow/search's own leaner
# read shape — confirmed live (2026-09-11, both NWM and SPK4) that these
# two endpoints use DIFFERENT field names for the same information
# (workflow/search: `to` as a bare string; the bulk-get shape actually
# needed for round-tripping into an update: `toStatusReference`).
#
# CONFIRMED LIVE (2026-09-11, via /workflows/update/validation — see the
# header's validation-iteration note): the top-level `statuses` array must
# list EVERY status the workflow uses, existing ones included, each with
# BOTH `id` AND `statusReference` set to the SAME real global status id.
# Declaring a status there with `statusReference` but no matching `id`
# makes Jira treat it as a brand-new status CREATE, which then collides
# with the already-existing site-wide name ("Status name ... already in
# use", code NON_UNIQUE_STATUS_NAME) — exactly what happened before this
# was found. With `id` present, Jira instead treats the entry as a
# reference to that already-existing status, and the collision goes away.
# The minimal validated shape for each entry is just
# {id, statusReference, name, statusCategory} — `scope`/`description` are
# accepted but not required. Confirmed the workflow-level `statuses` list
# needs only {statusReference} per entry (not layout/properties/
# deprecated), transitions need only {id, name, type, toStatusReference}
# (not description), and the workflow object itself needs only
# {id, version, statuses, transitions} (not name/scope) — see
# fixtures/workflows.update.validation.{spk4,nwm}.txt, both HTTP 200 with
# `{"errors": []}` for exactly this shape.
#
# ROUND-3 REVIEW ITEM 2 (supersedes the earlier GOTCHA below): existing
# statuses AND transitions are now carried forward with EVERY field the
# --show-secrets bulk-get returned (id, type, toStatusReference, links,
# name, description, actions, validators, triggers, properties) —
# untouched, not reshaped down to a minimal subset. CONFIRMED LIVE,
# 2026-09-11: the earlier minimal-reshape design (this function used to
# rebuild each existing transition as bare {id, name, type,
# toStatusReference}) is what caused /workflows/update to silently strip
# every existing transition's rules — Jira's update REPLACES a transition
# wholesale with whatever the request sends, it does not merge, so
# omitting a field is indistinguishable from deleting it. See
# jira_bulkget's own header for the full incident and
# fixtures/workflows.bulkget.spk4-secrets-postapply.txt for the live
# evidence. The OLD gotcha this superseded — that the wrapper's default
# redaction blanks ruleKey/permissionKey to "<redacted>" — is why
# jira_bulkget always reads with --show-secrets now; that gotcha was
# never about the update endpoint's OWN requirements, only about this
# script's own read path silently corrupting what it read.
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
        # status_additions — new status DEFINITIONS (top-level "statuses"),
        # one per name still missing as a STATUS on this workflow. `id`
        # AND `statusReference` both carry the real global status id — see
        # this function'"'"'s own header comment for why `id` alone
        # (missing before) caused a false "name already in use" rejection.
        | [ $resolved[] | select(.name as $n | $missingStatusNames | index($n) != null)
            | { id: .id, statusReference: .id, name: .name, statusCategory: .category }
          ] as $status_additions
        # transition_additions — one per name still missing as a
        # TRANSITION, using the resolved id from the FULL list (a status
        # can already exist while its transition does not).
        | [ $resolved[] | select(.name as $n | $missingTransitionNames | index($n) != null)
            | { id: .transitionId, name: .name, type: "GLOBAL", toStatusReference: .id }
          ] as $transition_additions
        | if ($status_additions | length) == 0 and ($transition_additions | length) == 0 and ($missingRules | length) == 0
          then error("build_update_body: computed additions are EMPTY — refusing to send a no-op /workflows/update (this should be unreachable; the caller must check \"already complete\" before calling this)")
          else . end
        | ($bulkget.workflows[] | select(.name == $wfname)) as $wf
        # existing status DEFINITIONS — the bulk-get response'"'"'s OWN
        # top-level `statuses` (root, not $wf.statuses), carried forward
        # VERBATIM (id/statusReference/name/statusCategory/scope/
        # description, whatever it returned) — never reshaped.
        | $bulkget.statuses as $existing_status_defs
        # existing workflow-level statuses — VERBATIM
        # (statusReference/layout/properties/deprecated).
        | $wf.statuses as $existing_statuses
        # existing transitions — VERBATIM, every field the bulk-get
        # returned (id/type/toStatusReference/links/name/description/
        # actions/validators/triggers/properties). ROUND-3 REVIEW ITEM 2:
        # this is the fix — see this function'"'"'s own header comment for
        # why a reshaped (even a merely-reordered-field) minimal subset
        # silently stripped every existing transition'"'"'s rules on write.
        | $wf.transitions as $existing_transitions
        | {
            statuses: ($existing_status_defs + $status_additions),
            workflows: [ {
                id: $wf.id,
                version: $version,
                statuses: ($existing_statuses + ($status_additions | map({statusReference}))),
                # --rules: missing validators appended, existing
                # ones untouched — additive only. Rules match transitions by
                # name, so unique transition names are load-bearing here too.
                transitions: (($existing_transitions + $transition_additions)
                    | map(. as $t
                        | [$missingRules[] | select(.name == $t.name) | .validators[]] as $add
                        | if ($add | length) > 0 then .validators = ((.validators // []) + $add) else . end))
            } ]
        }
        '
}

# --------------------------------------------------------------- validation
#
# validate_update_body <update-body> — POST
# /rest/api/3/workflows/update/validation, BEFORE ever calling
# /workflows/update itself (BLOCKER 9). Non-mutating; always run, even
# under --dry-run and without --yes (jira_write_readonly_semantics). Dies
# non-zero, printing whatever Jira reported, on any error.
#
# CONFIRMED LIVE (2026-09-11, against both SPK4 and NWM): this endpoint
# does NOT take the bare WorkflowUpdateRequest (the same body
# /workflows/update itself takes) — it takes a WorkflowUpdateValidateRequest
# envelope, {"payload": <the update body>, "validationOptions":
# {"levels": ["ERROR","WARNING"]}}. Sending the bare body (no envelope)
# 400s with a flat, useless "Invalid request payload. Refer to the REST
# API documentation and try again." (see fixtures/
# workflows.update.validation.{spk4,nwm}.txt's own header for that
# earlier, wrong attempt) — wrapping it in the envelope is what turned
# that into a real, actionable, field-level response: HTTP 200 with
# `{"errors": [{"code","message","level":"ERROR"|"WARNING","type",
# "elementReference": {...}}]}`. Empty `errors` = valid. A non-2xx (e.g.
# the site rejecting the envelope itself as malformed) is still a hard
# failure via the wrapper's own `write` guard, handled by the `|| die`
# below. An ERROR-level entry dies, printing every error verbatim. A
# WARNING-level entry (observed live: NO_INBOUND_TRANSITIONS_TO_STATUS,
# while iterating toward the final body — see the header's iteration
# note) warns and continues rather than dying, since Jira itself
# classifies it below ERROR.
validate_update_body() {
    local body="$1" envelope resp errors_json error_count warning_count
    envelope=$(jq -n --argjson payload "$body" \
        '{payload: $payload, validationOptions: {levels: ["ERROR", "WARNING"]}}') \
        || die "could not build the /workflows/update/validation envelope"
    resp=$(jira_write_readonly_semantics POST /workflows/update/validation "$envelope") \
        || die "POST /workflows/update/validation failed outright — see the wrapper's own error output above"
    # ROUND-2 REVIEW ITEM 1 — an unparseable 2xx, or a 2xx with no `errors`
    # key at all, used to silently become "zero errors" via `// []`. Both
    # are now a hard die, printing the raw (already wrapper-redacted)
    # response, rather than treating "we don't understand this response"
    # the same as "Jira reported no errors".
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

# --------------------------------------------------------------- read-back

# assert_readback — re-read the workflow and confirm every target status
# name and every target transition name is present. Exits non-zero with a
# clear diff (not just "failed") otherwise.
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

# --------------------------------------------------------------- write + diff
#
# validate_write_and_diff <final-body> <pre-write-bulkget-resp> — shared by
# BOTH the normal (missing-set) path and --restore-from below, so the
# validate -> print -> gate -> write -> snapshot -> deep-diff sequence
# exists exactly once. `$VERSION_BULKGET_BODY` and `$WORKFLOW_NAME` are
# read from the caller's own already-set globals (bash 3.2 has no easy way
# to pass a closure, and both are set identically by either caller before
# this runs).
#
# ROUND-3 REVIEW ITEM 3 — the diff is now a full jq DEEP EQUALITY check per
# existing transition's actions/validators/triggers/links (defaulting a
# missing key to [] so an entirely-absent array compares equal to an
# explicitly-empty one), not merely a count. A count comparison missed the
# case where a rule's CONTENT changed without an array getting shorter —
# unlikely for this script's own additions-only writes, but the whole
# point of switching to full passthrough (build_update_body, ROUND-3
# REVIEW ITEM 2) is to stop assuming what "safe" looks like and just prove
# it, per transition, byte for byte.
#
# ROUND-4 REVIEW ITEM 1 — each rule entry's OWN `id` field is deleted
# before the comparison. CONFIRMED LIVE (2026-09-11, ZZPROBE's real
# /workflows/update apply — the first successful one, the false-positive
# it triggered is exactly what this fix addresses): Jira regenerates the
# UUID `id` on a validator/action that carries one (e.g. transition 1's
# validator went from id "b7a520de-637d-4182-a9d7-c90d799b0cfa" before to
# "1bc6918f-..." after — see fixtures/workflows.bulkget.zzprobe-secrets-
# {before,after}-apply.txt) even though its `ruleKey`
# ("system:check-permission-validator") and `parameters`
# ("permissionKey":"CREATE_ISSUES") — the actual identity of the rule —
# are byte-for-byte unchanged. The plain NUMERIC ids on the three
# update-field ACTIONS (28799106 etc.) were NOT regenerated in the same
# apply, so this fix strips an `id` wherever ANY rule entry happens to
# carry one, rather than only from validators or only from UUID-shaped
# ones — a rule that has no `id` at all (del on a nonexistent key is a
# no-op in jq) or a numeric one that Jira leaves alone both still compare
# correctly either way. A CHANGED `ruleKey` or `parameters` value still
# fails the diff — this only ignores the one field Jira is now known to
# rewrite on every write regardless of content.
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
        # ROUND-2 REVIEW ITEM 6 — exit 3, distinct from exit 1's "something
        # went wrong": this is this script correctly refusing to write
        # without explicit confirmation, not a failure. See the header's
        # "Exit status" section.
        warn "not confirmed (no --yes) — the update was never sent. Re-run with --yes to apply."
        exit 3
    fi

    # ROUND-2 REVIEW ITEM 2 (updated ROUND-3): persist the pre-write
    # document to disk BEFORE issuing the write, and print the path. This
    # snapshot was read via jira_bulkget (--show-secrets), so — unlike the
    # earlier, redacted revision of this file — it is now a RESTORE
    # source, not merely a diff source; see --restore-from and
    # jira_bulkget's own header.
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

    # the baseline is the request body, not the pre-write snapshot,
    # so rules added on purpose (--rules) compare equal while a rule Jira
    # dropped, altered, or never stored still fails. Every transition in the
    # request that the re-read also has is compared (ZZPROBE's real apply
    # shows new transitions come back with exactly the empty arrays sent); a
    # transition absent from the re-read is assert_readback's to report.
    RULE_DIFF=$(jq -n --argjson sent "$final_body" --argjson after "$AFTER_RESP" --arg wfname "$WORKFLOW_NAME" '
        # ROUND-4 REVIEW ITEM 1 — strip each rule entrys own `id` (Jira
        # regenerates a UUID rule id on every write regardless of content;
        # a numeric one is left alone, and `del` on an absent key is a
        # no-op either way) before comparing. ruleKey + parameters are the
        # rules real identity, not this id.
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
        # ROUND-2 REVIEW ITEM 6 — exit 2: the write itself SUCCEEDED (the
        # workflow was changed), it just was not safe. Distinct from exit 1
        # ("nothing was changed, something failed") and exit 3 ("nothing was
        # sent, no --yes").
        exit 2
    fi

    assert_readback
}

# --------------------------------------------------------------- restore

# do_restore_from <path> — ROUND-3 REVIEW ITEM 4. Re-POST the exact
# workflow document found in PATH, with a freshly-fetched `version`.
# Skips the missing-set computation entirely — a literal restore.
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

    # The redaction taint check: a document captured WITHOUT --show-secrets
    # (i.e. before jira_bulkget existed, or via a differently-configured
    # wrapper) has every ruleKey/permissionKey value replaced with the
    # literal string "<redacted>". Restoring that would reproduce the
    # exact stripped-rules bug this flag exists to fix — there is no way
    # to recover a rule value that was only ever seen redacted.
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

# --------------------------------------------------------------- main
#
# Order (BLOCKER 11): reads -> render body -> validation POST -> print
# final body -> gate on --yes/--dry-run -> update POST -> deep-diff ->
# read-back. The version bulk-get and the validation call are BOTH
# read-only-by-semantics and BOTH run unconditionally, before the --yes
# gate — only the actual /workflows/update call is gated.

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
    # ROUND-2 REVIEW ITEM 8 — this is a NAME-level check only:
    # compute_missing (and the transition-id collision check inside it)
    # only ever compares NAMES/ids present or absent, never each existing
    # transition's `toStatusReference`. A workflow that already has a
    # transition literally named "Open" pointing at the WRONG status
    # would still be reported "already complete" here — this script does
    # not repair a wrong toStatusReference on an existing transition, only
    # add whatever is missing by name/id.
    echo "already complete: workflow '$WORKFLOW_NAME' already carries every target status and transition (by name/id only — this does not verify each existing transition still points at the right status)."
    exit 0
fi

VERSION_BULKGET_BODY=$(jq -n --arg n "$WORKFLOW_NAME" '{workflowNames: [$n]}') \
    || die "could not build /workflows bulk-get request body"
VERSION_RESP=$(jira_bulkget "$VERSION_BULKGET_BODY") \
    || die "could not obtain the workflow's current version via POST /workflows — refusing to build an update body without it"
# BLOCKER 3 — POST /workflows returns {statuses:[...], workflows:[...]}
# where each workflow object is keyed by a plain string `name`, NOT nested
# under an {name, entityId} id object the way workflow/search's own read
# shape does it.
VERSION_JSON=$(printf '%s' "$VERSION_RESP" | jq -c --arg n "$WORKFLOW_NAME" '[.workflows[] | select(.name == $n)][0].version // null') \
    || die "could not parse POST /workflows response while looking for '$WORKFLOW_NAME'"
[ "$VERSION_JSON" != "null" ] || die "POST /workflows returned no 'version' for '$WORKFLOW_NAME' — refusing to write with no version to guard against a stale-write conflict"

# Cross-check: workflow/search's own entityId (read earlier, independently)
# must agree with the bulk-get response's plain-string workflow id — a
# consistency check between two independent reads of "the same workflow",
# cheap insurance against a name collision or a stale cache on either side.
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
