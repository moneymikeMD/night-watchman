#!/bin/bash
#
# jira-import.sh — bulk-create local frontmatter tickets (see the
# tickets-protocol skill) as Jira issues in a target project, one `create`
# per ticket in ascending numeric-id order. Starting from an EMPTY
# project, this makes the key Jira assigns land at the same number as the
# local id: local ticket id NNN -> Jira issue PROJECT-NNN. jira-backfill.sh
# and verify-jira-keys.sh both assume this holds; neither keeps or needs a
# separate id->key map.
#
# Every create goes through the `tracker` provider seam's `create` verb,
# not jira-api.sh directly, so this works unchanged against a non-jira
# tracker. Every issue is created with type "Task".
#
# Usage:
#   jira-import.sh --project KEY DIR [--schema issues|dotissues]
#                   [--resume N] [--manifest PATH] [--progress] [--dry-run]
#
# DIR is the tickets tree — see lib/frontmatter.py --schema for the two
# supported layouts.
#
#   --resume N   skip the first N-1 tickets in id order (already created
#                by an earlier, interrupted run) and continue from the
#                Nth. Default 1 (start from the first ticket).
#   --progress   print "created KEY (i/total): id -> title" as each issue
#                is made.
#   --dry-run    every create becomes a dry-run through the seam
#                (NW_DRY_RUN=1): prints the request each create WOULD
#                issue, resolves no credential, creates nothing.
#
# A create failure stops the run immediately. Re-run with --resume <i>,
# where <i> is the position that failed. Do NOT re-run from the start: the
# tickets already created would be created a SECOND time under new keys,
# breaking every id/key correspondence after that point.
#
# Every non-dry run writes a manifest — the ordered list of ids it used —
# next to the tickets directory (default:
# DIR/.jira-import-manifest.PROJECT.json; --manifest PATH overrides). A
# --resume run requires that manifest's first N-1 ids to match the CURRENT
# ordering exactly, or it dies naming the first position that no longer
# matches, before creating anything: a directory edited between runs would
# otherwise resume against the wrong position and silently create
# duplicates or skip real tickets. --dry-run touches no manifest.
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
RESUME=1
PROGRESS=0
DRY_RUN=0
MANIFEST=""

while [ $# -gt 0 ]; do
    case "$1" in
        --project)
            [ $# -ge 2 ] || die "--project needs a value, e.g. --project PROJ"
            PROJECT="$2"; shift 2 ;;
        --schema)
            [ $# -ge 2 ] || die "--schema needs a value: issues or dotissues"
            SCHEMA="$2"; shift 2 ;;
        --resume)
            [ $# -ge 2 ] || die "--resume needs a value, e.g. --resume 5"
            RESUME="$2"; shift 2 ;;
        --manifest)
            [ $# -ge 2 ] || die "--manifest needs a path"
            MANIFEST="$2"; shift 2 ;;
        --progress) PROGRESS=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  show_help ;;
        --*) die "unknown flag: $1" ;;
        *)
            [ -z "$TICKETS_DIR" ] || die "unexpected extra argument: $1"
            TICKETS_DIR="$1"; shift ;;
    esac
done

[ -n "$PROJECT" ] || die "--project KEY is required, e.g. jira-import.sh --project PROJ issues/"
case "$PROJECT" in [A-Z]*) ;; *) die "--project must look like a Jira project key (e.g. PROJ), got '$PROJECT'" ;; esac
case "$(printf '%s' "$PROJECT" | tr -d 'A-Z0-9')" in
    "") ;;
    *) die "--project must be A-Z0-9 only (starting with a letter), got '$PROJECT'" ;;
esac
[ -n "$TICKETS_DIR" ] || die "tickets directory is required, e.g. jira-import.sh --project PROJ issues/"
[ -d "$TICKETS_DIR" ] || die "not a directory: $TICKETS_DIR"
case "$SCHEMA" in issues|dotissues) ;; *) die "--schema must be 'issues' or 'dotissues' (got '$SCHEMA')" ;; esac
case "$RESUME" in ''|*[!0-9]*) die "--resume must be a positive integer, got '$RESUME'" ;; esac
[ "$RESUME" -ge 1 ] || die "--resume must be >= 1, got '$RESUME'"
[ -x "$PROVIDER_LIB" ] || die "provider dispatcher not found or not executable: $PROVIDER_LIB"

TICKETS_JSONL=$(python3 "$FRONTMATTER_PY" "$TICKETS_DIR" --schema "$SCHEMA") \
    || die "could not parse tickets under $TICKETS_DIR"
[ -n "$TICKETS_JSONL" ] || die "no tickets found under $TICKETS_DIR (schema $SCHEMA)"

TOTAL=$(printf '%s\n' "$TICKETS_JSONL" | wc -l | tr -d ' ')
[ "$RESUME" -le "$TOTAL" ] || die "--resume $RESUME is past the last ticket ($TOTAL total)"

[ -n "$MANIFEST" ] || MANIFEST="$TICKETS_DIR/.jira-import-manifest.$PROJECT.json"
CURRENT_IDS_JSON=$(printf '%s\n' "$TICKETS_JSONL" | jq -s '[.[].id]') \
    || die "could not build the id ordering for the manifest"

if [ "$DRY_RUN" != "1" ]; then
    if [ "$RESUME" -gt 1 ]; then
        [ -f "$MANIFEST" ] || die "--resume $RESUME given but no manifest at $MANIFEST — cannot verify the ordering positions 1..$((RESUME - 1)) were really already created. Run without --resume against this directory to (re)establish one, or pass --manifest to point at the one an earlier run wrote."
        OLD_IDS_JSON=$(cat "$MANIFEST") || die "could not read manifest $MANIFEST"
        MISMATCH_IDX=$(jq -n --argjson old "$OLD_IDS_JSON" --argjson new "$CURRENT_IDS_JSON" --argjson n "$((RESUME - 1))" \
            '[range(0; $n)] | map(select($old[.] != $new[.])) | first // empty') \
            || die "manifest $MANIFEST is not valid JSON"
        if [ -n "$MISMATCH_IDX" ]; then
            pos=$((MISMATCH_IDX + 1))
            old_id=$(printf '%s' "$OLD_IDS_JSON" | jq -r --argjson i "$MISMATCH_IDX" '.[$i] // "(none)"')
            new_id=$(printf '%s' "$CURRENT_IDS_JSON" | jq -r --argjson i "$MISMATCH_IDX" '.[$i] // "(none)"')
            die "--resume $RESUME: the ticket ordering changed before position $RESUME — position $pos was '$old_id' in $MANIFEST, is now '$new_id'. The directory changed since the run that manifest describes; re-run without --resume, or restore the directory to match it."
        fi
    fi
    printf '%s' "$CURRENT_IDS_JSON" > "$MANIFEST" || die "could not write manifest $MANIFEST"
fi

ERRFILE=$(tmpfile) || die "could not create temp file"

printf '%s\n' "$TICKETS_JSONL" | {
    i=0
    while IFS= read -r line; do
        i=$((i + 1))
        [ "$i" -ge "$RESUME" ] || continue

        id=$(printf '%s' "$line" | jq -r '.id // empty')
        title=$(printf '%s' "$line" | jq -r '.title // empty')
        [ -n "$id" ] && [ -n "$title" ] || die "ticket at position $i has no id/title — check $TICKETS_DIR"

        if [ "$DRY_RUN" = "1" ]; then
            NW_DRY_RUN=1 "$PROVIDER_LIB" run tracker create "$PROJECT" Task "$title" \
                >/dev/null 2>"$ERRFILE" || { cat "$ERRFILE" >&2; die "dry-run create failed for local id '$id' (position $i)"; }
            [ "$PROGRESS" = "1" ] && warn "would create ($i/$TOTAL): $id -> $title"
            continue
        fi

        resp=$("$PROVIDER_LIB" run tracker create "$PROJECT" Task "$title" 2>"$ERRFILE") \
            || { cat "$ERRFILE" >&2; die "create failed for local id '$id' (position $i) — re-run with --resume $i"; }
        key=$(printf '%s' "$resp" | jq -r '.key // empty')
        [ -n "$key" ] || die "create for local id '$id' (position $i) returned no key — response: $resp"
        [ "$PROGRESS" = "1" ] && echo "created $key ($i/$TOTAL): $id -> $title"
    done
}

if [ "$DRY_RUN" = "1" ]; then
    warn "jira-import.sh --dry-run: nothing was created, no credential was resolved."
else
    warn "jira-import.sh: created $((TOTAL - RESUME + 1)) issue(s) in project $PROJECT (positions $RESUME..$TOTAL)"
fi
