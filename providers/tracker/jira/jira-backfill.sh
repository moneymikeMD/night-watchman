#!/bin/bash
#
# jira-backfill.sh — PUTs each local ticket's body (as the issue
# description), its six custom fields (touches, verify, human_steps,
# appends, executor, defer_until) and its Jira status, into the Jira issue
# jira-import.sh already created for it.
#
# Assumes jira-import.sh created issues in ascending numeric-id order
# starting from an empty project, so local ticket id NNN's Jira key is
# PROJECT-NNN (see jira-import.sh's header) — no separate id->key map is
# kept; verify-jira-keys.sh makes and checks the same assumption.
#
# Custom field ids are resolved BY NAME at runtime via GET /field, never
# hardcoded. A field this Jira site does not have is skipped with a
# warning, not a fatal error — see field_id below.
#
# An arbitrary-fields issue PUT is not one of the four tracker verbs, so
# this talks to jira-api.sh directly rather than through the seam.
#
# The PUT asks for ?returnIssue=true — a deliberate confirmation read, not
# a workaround: Jira returns 204 No Content by default.
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

# One GET /field, cached; field_id NAME below searches it in-process.
FIELD_NAMES="touches
verify
human_steps
appends
executor
defer_until"

# A Jira Cloud text/textarea field's stored value caps at 32767
# characters, `description` included.
MAX_DESC_CHARS=32767
TRUNCATE_POINTER="[truncated — see the local ticket file for the full body]"

if [ "$DRY_RUN" = "1" ]; then
    ALL_FIELDS_JSON="[]"
else
    ALL_FIELDS_JSON=$("$JIRA_API" raw GET /field) || die "could not read /field — cannot discover custom field ids by name"
fi

# field_id NAME -> prints the customfield id and returns 0 when exactly one
# custom field has this name; prints NOTHING and returns 0 when none do
# (absent is not a failure); warns and returns 1 when more than one does.
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
# textarea custom field's value (it rejects a plain string) and for
# `description`. Unwraps jira_comment_body's {body: ...} envelope, which is
# comment's shape, not a plain field value's.
adf_from_text() {
    jira_comment_body "$1" | jq -c '.body'
}

# lines_field JSONLINE KEY — a frontmatter list or block-scalar field as
# one newline-separated string, what adf_from_text expects.
lines_field() {
    printf '%s' "$1" | jq -r --arg k "$2" '
        .[$k] as $v
        | if ($v | type) == "array" then ($v | join("\n"))
          elif ($v | type) == "string" then $v
          else "" end'
}

# truncate_body TEXT -> TEXT unchanged if it is at or under
# MAX_DESC_CHARS; otherwise the longest prefix of whole blank-line-
# separated blocks that fits alongside TRUNCATE_POINTER, plus that pointer.
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

# stage_status_name STAGE -> the Jira status NAME for that local stage, or
# nothing for "open" and any unrecognised stage. "open" is left alone: a
# fresh issue lands on Jira's own "To Do", not the custom "Open".
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

# transition_issue KEY WANT_STATUS_NAME — move KEY there if it is not
# already, matching by NAME against GET /issue/KEY/transitions. A status
# with no transition from the current one warns and skips, never dies.
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
# shell, or FAILED's count is lost when the pipeline subshell ends.
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

    # A PUT that OMITS a field key leaves the stored value untouched, so
    # every field this script owns sends an explicit null when empty.
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
                # A datepicker field takes a plain "YYYY-MM-DD" string,
                # never the ADF wrapper the textarea fields need.
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
        # A dry run resolves no credential, so the issue's current status
        # cannot be read: this always names the stage's target status.
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
