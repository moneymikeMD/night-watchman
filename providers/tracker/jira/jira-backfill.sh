#!/bin/bash
#
# jira-backfill.sh — PUTs each local ticket's body (as the issue
# description), its five text/select custom fields (touches, verify,
# human_steps, appends, executor) and its Jira status, into the Jira issue
# jira-import.sh already created for it. Merges the source project's
# jira-backfill.sh (issues/ stage tree) and dotissues-jira-backfill.sh
# (chronicle .issues/ tree) into one script behind --schema
# issues|dotissues, de-identified.
#
# Assumes jira-import.sh created issues in ascending numeric-id order
# starting from an empty project, so local ticket id NNN's Jira key is
# PROJECT-NNN (see jira-import.sh's header) — no separate id->key map is
# kept; verify-jira-keys.sh makes and checks the same assumption.
#
# Custom field ids are resolved BY NAME at runtime via GET /field (the
# same technique jira-space-create.sh's field_lookup already uses), never
# hardcoded as constants — this is what the ticket text asks for
# ("custom field ids come from config (T5), not constants"): runtime
# discovery gets the same property without waiting on T5's config work,
# and matches the only other script in this directory that already needs
# it. A field this Jira site does not have (T5 not run, or a name typo)
# is skipped with a warning, not a fatal error — see field_id below.
#
# This is NOT the `tracker` provider seam's `transition`/`comment`/
# `create`: an arbitrary-fields issue PUT is not one of the four tracker
# verbs (providers/README.md), so — like jira-space-create.sh — this
# script talks to jira-api.sh directly rather than inventing a fifth verb.
#
# Jira Cloud's PUT /issue/{key} returns 204 No Content by default (jq/
# redact_json on that empty body is harmless — `jq .` on empty stdin exits
# 0, prints nothing). This script still asks for the updated issue back
# (?returnIssue=true) rather than trust a silent 204, so a caller reading
# this script's stdout has the written fields to check against, not just
# an exit code — confirmed live on the ZZSPK2 loop.
#
# Usage:
#   jira-backfill.sh --project KEY DIR [--schema issues|dotissues] [--dry-run]
#                     [--jira-api PATH]
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

# shellcheck disable=SC1091  # sourced at a path computed from $0, not visible to shellcheck's static resolution
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_ROOT="$(cd "$DIR/../.." && pwd)"
# shellcheck source=../../lib/kit.sh
. "$PROVIDERS_ROOT/lib/kit.sh"
# shellcheck source=lib/jira-common.sh
. "$DIR/lib/jira-common.sh"

FRONTMATTER_PY="$DIR/lib/frontmatter.py"
JIRA_API="$DIR/jira-api.sh"

need python3 jq

PROJECT=""
TICKETS_DIR=""
SCHEMA="issues"
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --project)
            [ $# -ge 2 ] || die "--project needs a value, e.g. --project PROJ"
            PROJECT="$2"; shift 2 ;;
        --schema)
            [ $# -ge 2 ] || die "--schema needs a value: issues or dotissues"
            SCHEMA="$2"; shift 2 ;;
        --jira-api)
            [ $# -ge 2 ] || die "--jira-api needs a path"
            JIRA_API="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) show_help ;;
        --*) die "unknown flag: $1" ;;
        *)
            [ -z "$TICKETS_DIR" ] || die "unexpected extra argument: $1"
            TICKETS_DIR="$1"; shift ;;
    esac
done

[ -n "$PROJECT" ] || die "--project KEY is required, e.g. jira-backfill.sh --project PROJ issues/"
case "$PROJECT" in [A-Z]*) ;; *) die "--project must look like a Jira project key (e.g. PROJ), got '$PROJECT'" ;; esac
case "$(printf '%s' "$PROJECT" | tr -d 'A-Z0-9')" in
    "") ;;
    *) die "--project must be A-Z0-9 only (starting with a letter), got '$PROJECT'" ;;
esac
[ -n "$TICKETS_DIR" ] || die "tickets directory is required, e.g. jira-backfill.sh --project PROJ issues/"
[ -d "$TICKETS_DIR" ] || die "not a directory: $TICKETS_DIR"
case "$SCHEMA" in issues|dotissues) ;; *) die "--schema must be 'issues' or 'dotissues' (got '$SCHEMA')" ;; esac
[ -x "$JIRA_API" ] || die "jira-api.sh not found or not executable: $JIRA_API"

TICKETS_JSONL=$(python3 "$FRONTMATTER_PY" "$TICKETS_DIR" --schema "$SCHEMA") \
    || die "could not parse tickets under $TICKETS_DIR"
[ -n "$TICKETS_JSONL" ] || die "no tickets found under $TICKETS_DIR (schema $SCHEMA)"

# --------------------------------------------------------------- field discovery
#
# One GET /field, cached; field_id NAME below searches it in-process — no
# second network call per ticket, matching jira-space-create.sh's
# "one read, many lookups" shape.
#
# All six of jira-space-create.sh's custom fields, defer_until included
# (script-reviewer round on 71e649c: it was silently missing).
FIELD_NAMES="touches
verify
human_steps
appends
executor
defer_until"

# A Jira Cloud text/textarea custom field's stored value is capped at
# 32767 characters (a recorded precedent) — this applies to
# `description` here. Reserve room for the pointer line appended when
# truncating.
MAX_DESC_CHARS=32767
TRUNCATE_POINTER="[truncated — see the local ticket file for the full body]"

if [ "$DRY_RUN" = "1" ]; then
    ALL_FIELDS_JSON="[]"
else
    ALL_FIELDS_JSON=$("$JIRA_API" raw GET /field) || die "could not read /field — cannot discover custom field ids by name"
fi

# field_id NAME -> prints the customfield id on stdout and returns 0 when
# exactly one custom field has this name; prints NOTHING and returns 0
# when none do (the field does not exist on this site yet — the caller
# skips it, matching field_lookup's "absent is not a failure" rule in
# jira-space-create.sh); warns and returns 1 when MORE THAN ONE does.
field_id() {
    local name="$1" count ids
    count=$(printf '%s' "$ALL_FIELDS_JSON" | jq -r --arg n "$name" \
        '[.[] | select(.custom == true and .name == $n)] | length') || return 1
    if [ "$count" -gt 1 ]; then
        ids=$(printf '%s' "$ALL_FIELDS_JSON" | jq -r --arg n "$name" \
            '[.[] | select(.custom == true and .name == $n)] | map(.id) | join(", ")')
        warn "field_id: '$name' matches $count custom fields (ids: $ids) — skipping, cannot guess which one"
        return 1
    fi
    printf '%s' "$ALL_FIELDS_JSON" | jq -r --arg n "$name" \
        '[.[] | select(.custom == true and .name == $n)][0].id // empty'
}

# adf_from_text TEXT — the ADF document Jira's v3 API requires for a
# textarea custom field's value (rejects a plain string) and for
# `description`: one paragraph per input line. Reuses jira_comment_body's
# builder (lib/jira-common.sh) and unwraps its {body: ...} envelope, which
# is comment's shape, not a plain field value's.
adf_from_text() {
    jira_comment_body "$1" | jq -c '.body'
}

# lines_field JSONLINE KEY — a frontmatter list field ('.touches',
# '.appends', '.human_steps') joined into one newline-separated string, or
# a frontmatter block-scalar field already stored as a string — either way,
# what adf_from_text expects.
lines_field() {
    printf '%s' "$1" | jq -r --arg k "$2" '
        .[$k] as $v
        | if ($v | type) == "array" then ($v | join("\n"))
          elif ($v | type) == "string" then $v
          else "" end'
}

# truncate_body TEXT -> TEXT unchanged if it is at or under
# MAX_DESC_CHARS; otherwise the longest PREFIX of whole "\n\n"-separated
# blocks that fits alongside TRUNCATE_POINTER, plus that pointer line —
# never a block cut in half. A single block bigger than the whole budget
# on its own yields just the pointer line.
truncate_body() {
    local text="$1" len
    len=$(printf '%s' "$text" | jq -Rs 'length')
    [ "$len" -le "$MAX_DESC_CHARS" ] && { printf '%s' "$text"; return 0; }
    printf '%s' "$text" | jq -Rs --argjson budget "$((MAX_DESC_CHARS - ${#TRUNCATE_POINTER} - 2))" --arg pointer "$TRUNCATE_POINTER" '
        split("\n\n") as $blocks
        | reduce $blocks[] as $b ({acc: [], used: 0, stopped: false};
            if .stopped then .
            elif (.used + ($b | length) + 2) <= $budget then
                {acc: (.acc + [$b]), used: (.used + ($b | length) + 2), stopped: false}
            else {acc: .acc, used: .used, stopped: true} end)
        | if (.acc | length) == 0 then $pointer
          else (.acc | join("\n\n")) + "\n\n" + $pointer end'
}

# --------------------------------------------------------------- status
#
# stage_status_name STAGE -> the Jira status NAME a ticket in that local
# stage belongs in, or nothing for "open" and for any stage this script
# does not recognise (dotissues' "imported" included) — no transition is
# attempted for those, same "not every ticket needs this" shape as
# field_id above. "open" is deliberately left alone: a freshly created
# issue's actual initial status is Jira's own default ("To Do" — recorded
# live in fixtures/issue.status.live.json, NOT the custom "Open" status
# jira-space-create.sh also creates), and this script does not try to
# pick a winner between the two for the common case.
#
# Names, never ids: a transition id is per-site (see
# jira-space-create.sh's own header on this); the six stage statuses that
# script creates are named exactly these (Open, Triage, Awaiting
# Deployment, Deferred, Completed, Cancelled), plus Jira's own built-in
# "In Progress" — this is the forward direction of the same mapping
# to-issues/scripts/issues.py's JIRA_STATUS_TO_STAGE reads backward.
stage_status_name() {
    case "$1" in
        in-progress)         echo "In Progress" ;;
        awaiting-deployment) echo "Awaiting Deployment" ;;
        deferred)             echo "Deferred" ;;
        completed)            echo "Completed" ;;
        cancelled)            echo "Cancelled" ;;
        *)                    ;;
    esac
}

# transition_issue KEY WANT_STATUS_NAME — moves KEY to WANT_STATUS_NAME if
# it is not there already. Never hardcodes a transition id: reads the
# issue's current status first (skip if already WANT_STATUS_NAME — an
# idempotent re-run), then GET /issue/KEY/transitions for the live,
# per-site list of {id, name, to.name} and matches WANT_STATUS_NAME by
# name. A status this workflow has no direct transition into from the
# current one is warned about and skipped, not fatal — a ticket's fields
# still got backfilled even if its status could not be moved.
transition_issue() {
    local key="$1" want="$2" current_json current tjson tid tbody
    current_json=$("$JIRA_API" raw GET "/issue/$key?fields=status" 2>"$ERRFILE") \
        || { cat "$ERRFILE" >&2; warn "could not read current status for $key — skipping status backfill"; return 0; }
    current=$(printf '%s' "$current_json" | jq -r '.fields.status.name // empty')
    [ "$current" = "$want" ] && return 0

    tjson=$("$JIRA_API" raw GET "/issue/$key/transitions" 2>"$ERRFILE") \
        || { cat "$ERRFILE" >&2; warn "could not read transitions for $key — skipping status backfill"; return 0; }
    tid=$(printf '%s' "$tjson" | jq -r --arg w "$want" \
        '[.transitions[] | select((.to.name // .name) == $w)][0].id // empty')
    if [ -z "$tid" ]; then
        warn "no transition to '$want' available for $key (current: $current) — skipping status backfill"
        return 0
    fi

    tbody=$(jq -cn --arg id "$tid" '{transition: {id: $id}}')
    "$JIRA_API" --yes write POST "/issue/$key/transitions" "$tbody" >/dev/null 2>"$ERRFILE" \
        || { cat "$ERRFILE" >&2; warn "transition POST failed for $key ($current -> $want)"; return 1; }
    echo "transitioned $key: $current -> $want"
}

TOTAL=$(printf '%s\n' "$TICKETS_JSONL" | wc -l | tr -d ' ')
warn "jira-backfill.sh: backfilling $TOTAL ticket(s) into project $PROJECT"

ERRFILE=$(tmpfile) || die "could not create temp file"
i=0
FAILED=0
TRANSITION_FAILED=0
# Process substitution, not a `| while`: the loop body must run in THIS
# shell, not a pipeline subshell, or FAILED's count is lost the moment the
# loop ends and the final exit-code decision below sees nothing.
while IFS= read -r line; do
    i=$((i + 1))
    id=$(printf '%s' "$line" | jq -r '.id // empty')
    num=$(printf '%s' "$line" | jq -r '._num // empty')
    [ -n "$id" ] && [ -n "$num" ] || die "ticket at position $i has no id — check $TICKETS_DIR"
    key="$PROJECT-$num"

    body_text=$(printf '%s' "$line" | jq -r '._body // "" | gsub("\r"; "") | sub("^\n+"; "") | sub("\n+$"; "")')
    tags_json=$(printf '%s' "$line" | jq -c '.tags // []')
    executor=$(printf '%s' "$line" | jq -r '.executor // empty')
    stage=$(printf '%s' "$line" | jq -r '._stage // empty')
    target_status=$(stage_status_name "$stage")

    # A PUT that OMITS a field key leaves whatever value is already
    # stored — recorded live (a spike). A re-run after a local
    # field was emptied must therefore send an explicit JSON null for
    # every field THIS script owns, not skip the key, or the stale
    # remote value never clears. Only a field genuinely absent from this
    # Jira site (field_id found nothing) is left out — there is no id to
    # address it by.
    custom_parts=""
    for name in $FIELD_NAMES; do
        fid=$(field_id "$name") || continue
        [ -n "$fid" ] || continue
        case "$name" in
            executor)
                if [ -n "$executor" ]; then
                    part=$(jq -cn --arg id "$fid" --arg v "$executor" '{($id): {value: $v}}')
                else
                    part=$(jq -cn --arg id "$fid" '{($id): null}')
                fi
                ;;
            defer_until)
                # A datepicker field: a plain "YYYY-MM-DD" string, never
                # the ADF wrapper the textarea fields need.
                defer_until_val=$(printf '%s' "$line" | jq -r '.defer_until // empty')
                if [ -n "$defer_until_val" ]; then
                    part=$(jq -cn --arg id "$fid" --arg v "$defer_until_val" '{($id): $v}')
                else
                    part=$(jq -cn --arg id "$fid" '{($id): null}')
                fi
                ;;
            *)
                text=$(lines_field "$line" "$name")
                if [ -n "$text" ]; then
                    adf=$(adf_from_text "$text")
                    part=$(jq -cn --arg id "$fid" --argjson v "$adf" '{($id): $v}')
                else
                    part=$(jq -cn --arg id "$fid" '{($id): null}')
                fi
                ;;
        esac
        custom_parts="$custom_parts
$part"
    done

    if [ -n "$custom_parts" ]; then
        custom_json=$(printf '%s\n' "$custom_parts" | jq -s 'add // {}')
    else
        custom_json="{}"
    fi

    if [ -n "$body_text" ]; then
        desc_adf=$(adf_from_text "$(truncate_body "$body_text")")
    else
        desc_adf="null"
    fi
    fields_json=$(jq -cn --argjson custom "$custom_json" --argjson desc "$desc_adf" --argjson labels "$tags_json" \
        '$custom + {description: $desc, labels: $labels}')
    put_body=$(jq -cn --argjson fields "$fields_json" '{fields: $fields}')

    path="/issue/$key?returnIssue=true"
    if [ "$DRY_RUN" = "1" ]; then
        "$JIRA_API" --dry-run write PUT "$path" "$put_body" >/dev/null 2>"$ERRFILE" \
            || { cat "$ERRFILE" >&2; die "dry-run backfill failed for $key (local id $id)"; }
        warn "would backfill ($i/$TOTAL): $key <- $id"
        # No credential is resolved for a dry run, so there is no way to
        # read the issue's CURRENT status here (that read needs auth) —
        # this always names the stage's target status, even if the issue
        # happens to be there already; the live path below is the one
        # that actually checks and skips.
        [ -n "$target_status" ] && warn "would transition ($i/$TOTAL): $key -> $target_status"
        continue
    fi

    "$JIRA_API" --yes write PUT "$path" "$put_body" >/dev/null 2>"$ERRFILE" \
        || { cat "$ERRFILE" >&2; warn "backfill FAILED for $key (local id $id, position $i) — continuing"; FAILED=$((FAILED + 1)); continue; }
    echo "backfilled $key ($i/$TOTAL): $id"

    if [ -n "$target_status" ]; then
        transition_issue "$key" "$target_status" || TRANSITION_FAILED=$((TRANSITION_FAILED + 1))
    fi
done < <(printf '%s\n' "$TICKETS_JSONL")

if [ "$DRY_RUN" = "1" ]; then
    warn "jira-backfill.sh --dry-run: nothing was written, no credential was resolved."
elif [ "$FAILED" -gt 0 ] || [ "$TRANSITION_FAILED" -gt 0 ]; then
    die "jira-backfill.sh: $FAILED of $TOTAL ticket(s) failed field backfill, $TRANSITION_FAILED failed to transition, in project $PROJECT"
else
    warn "jira-backfill.sh: backfilled $TOTAL ticket(s) into project $PROJECT"
fi
