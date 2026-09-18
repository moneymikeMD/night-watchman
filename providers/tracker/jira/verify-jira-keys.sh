#!/bin/bash
#
# verify-jira-keys.sh — for every local ticket, fetch the Jira issue at
# PROJECT-<numeric id> (the mapping jira-import.sh's create order
# establishes — see its header) and confirm the issue's summary equals the
# local ticket's title. Prints one line per mismatch or fetch failure and a
# final "N/M exact matches" summary.
#
# Fetches go through the `tracker` provider seam's `fetch` verb, not
# jira-api.sh directly, so this works unchanged against a non-jira tracker.
#
# Exit status:
#   0   every ticket matched
#   1   a title mismatch (the title is definitely wrong)
#   2   a ticket could not be fetched (says nothing about the title)
#
# Usage:
#   verify-jira-keys.sh --project KEY DIR [--schema issues|dotissues]
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

# shellcheck disable=SC1091  # sourced at a path computed from $0, not visible to shellcheck's static resolution
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_ROOT="$(cd "$DIR/../.." && pwd)"
# shellcheck source=../../lib/kit.sh
. "$PROVIDERS_ROOT/lib/kit.sh"

FRONTMATTER_PY="$DIR/lib/frontmatter.py"
PROVIDER_LIB="$PROVIDERS_ROOT/lib/provider.sh"

need python3 jq

PROJECT=""
TICKETS_DIR=""
SCHEMA="issues"

while [ $# -gt 0 ]; do
    case "$1" in
        --project)
            [ $# -ge 2 ] || die "--project needs a value, e.g. --project PROJ"
            PROJECT="$2"; shift 2 ;;
        --schema)
            [ $# -ge 2 ] || die "--schema needs a value: issues or dotissues"
            SCHEMA="$2"; shift 2 ;;
        -h|--help) show_help ;;
        --*) die "unknown flag: $1" ;;
        *)
            [ -z "$TICKETS_DIR" ] || die "unexpected extra argument: $1"
            TICKETS_DIR="$1"; shift ;;
    esac
done

[ -n "$PROJECT" ] || die "--project KEY is required, e.g. verify-jira-keys.sh --project PROJ issues/"
case "$PROJECT" in [A-Z]*) ;; *) die "--project must look like a Jira project key (e.g. PROJ), got '$PROJECT'" ;; esac
case "$(printf '%s' "$PROJECT" | tr -d 'A-Z0-9')" in
    "") ;;
    *) die "--project must be A-Z0-9 only (starting with a letter), got '$PROJECT'" ;;
esac
[ -n "$TICKETS_DIR" ] || die "tickets directory is required, e.g. verify-jira-keys.sh --project PROJ issues/"
[ -d "$TICKETS_DIR" ] || die "not a directory: $TICKETS_DIR"
case "$SCHEMA" in issues|dotissues) ;; *) die "--schema must be 'issues' or 'dotissues' (got '$SCHEMA')" ;; esac
[ -x "$PROVIDER_LIB" ] || die "provider dispatcher not found or not executable: $PROVIDER_LIB"

TICKETS_JSONL=$(python3 "$FRONTMATTER_PY" "$TICKETS_DIR" --schema "$SCHEMA") \
    || die "could not parse tickets under $TICKETS_DIR"
[ -n "$TICKETS_JSONL" ] || die "no tickets found under $TICKETS_DIR (schema $SCHEMA)"

TOTAL=$(printf '%s\n' "$TICKETS_JSONL" | wc -l | tr -d ' ')
MATCHED=0
FETCH_FAILED=0
TITLE_MISMATCHED=0
ERRFILE=$(tmpfile) || die "could not create temp file"

while IFS= read -r line; do
    id=$(printf '%s' "$line" | jq -r '.id // empty')
    num=$(printf '%s' "$line" | jq -r '._num // empty')
    local_title=$(printf '%s' "$line" | jq -r '.title // empty')
    [ -n "$id" ] && [ -n "$num" ] || die "a ticket in $TICKETS_DIR has no id — cannot check"
    key="$PROJECT-$num"

    if ! resp=$("$PROVIDER_LIB" run tracker fetch "$key" 2>"$ERRFILE"); then
        FETCH_FAILED=$((FETCH_FAILED + 1))
        echo "MISS  $key  (local $id): could not fetch — $(tr '\n' ' ' < "$ERRFILE")"
        continue
    fi
    remote_title=$(printf '%s' "$resp" | jq -r '.fields.summary // empty')
    if [ "$remote_title" = "$local_title" ]; then
        MATCHED=$((MATCHED + 1))
    else
        TITLE_MISMATCHED=$((TITLE_MISMATCHED + 1))
        echo "DIFF  $key  (local $id): local '$local_title' != remote '$remote_title'"
    fi
done < <(printf '%s\n' "$TICKETS_JSONL")

echo "$MATCHED/$TOTAL exact matches" >&2
if [ "$FETCH_FAILED" -gt 0 ]; then
    warn "verify-jira-keys.sh: $FETCH_FAILED of $TOTAL ticket(s) could not be fetched, $TITLE_MISMATCHED title mismatch(es), in project $PROJECT"
    exit 2
elif [ "$TITLE_MISMATCHED" -gt 0 ]; then
    warn "verify-jira-keys.sh: $TITLE_MISMATCHED of $TOTAL ticket(s) did not match project $PROJECT"
    exit 1
fi
