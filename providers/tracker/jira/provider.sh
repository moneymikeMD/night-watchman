#!/bin/bash
#
# provider.sh — jira's implementation of the `tracker` provider kind
# (verbs: fetch, transition, comment, create — see ../../README.md for the
# contract). Dispatch only; the actual HTTP client is jira-api.sh, which is
# also independently runnable for the raw/write/comment/view subcommands a
# script like scripts/land-branch.sh's jira mode calls directly via
# --jira-api PATH.
#
# transition/comment/create are LIVE WRITES by default (--yes is passed to
# jira-api.sh with no interactive confirmation) — deliberate, so this
# provider works unattended from automation the same way the tracker kind
# is meant to. Set $NW_DRY_RUN=1, or pass --dry-run before the verb, to
# have every verb print the exact request jira-api.sh would issue and
# exit 0 without writing or resolving a credential (see providers/README.md).
#
# Usage:
#   provider.sh [--dry-run] fetch KEY
#   provider.sh [--dry-run] transition KEY TRANSITION_ID
#   provider.sh [--dry-run] comment KEY TEXT      # TEXT may be '-' to read stdin
#   provider.sh [--dry-run] create PROJECT ISSUETYPE SUMMARY
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JIRA_API="$DIR/jira-api.sh"

DRY_RUN=0
[ "${NW_DRY_RUN:-0}" = "1" ] && DRY_RUN=1
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

verb="${1:-}"
[ -n "$verb" ] && shift

case "$verb" in
    fetch)
        [ $# -eq 1 ] || { echo "Error: usage: provider.sh [--dry-run] fetch KEY" >&2; exit 1; }
        if [ "$DRY_RUN" = "1" ]; then
            exec "$JIRA_API" --dry-run raw GET "/issue/$1"
        fi
        exec "$JIRA_API" raw GET "/issue/$1"
        ;;
    transition)
        [ $# -eq 2 ] || { echo "Error: usage: provider.sh [--dry-run] transition KEY TRANSITION_ID" >&2; exit 1; }
        body=$(jq -cn --arg id "$2" '{transition: {id: $id}}') \
            || { echo "Error: could not build the transition request body" >&2; exit 1; }
        if [ "$DRY_RUN" = "1" ]; then
            exec "$JIRA_API" --dry-run write POST "/issue/$1/transitions" "$body"
        fi
        exec "$JIRA_API" --yes write POST "/issue/$1/transitions" "$body"
        ;;
    comment)
        [ $# -eq 2 ] || { echo "Error: usage: provider.sh [--dry-run] comment KEY TEXT (TEXT may be '-' to read stdin)" >&2; exit 1; }
        if [ "$DRY_RUN" = "1" ]; then
            exec "$JIRA_API" --dry-run comment "$1" "$2"
        fi
        exec "$JIRA_API" --yes comment "$1" "$2"
        ;;
    create)
        [ $# -eq 3 ] || { echo "Error: usage: provider.sh [--dry-run] create PROJECT ISSUETYPE SUMMARY" >&2; exit 1; }
        body=$(jq -cn --arg proj "$1" --arg type "$2" --arg summary "$3" \
            '{fields: {project: {key: $proj}, issuetype: {name: $type}, summary: $summary}}') \
            || { echo "Error: could not build the create-issue request body" >&2; exit 1; }
        if [ "$DRY_RUN" = "1" ]; then
            exec "$JIRA_API" --dry-run write POST "/issue" "$body"
        fi
        exec "$JIRA_API" --yes write POST "/issue" "$body"
        ;;
    "")
        echo "Error: usage: provider.sh [--dry-run] VERB [ARG...] (verbs: fetch, transition, comment, create)" >&2
        exit 1
        ;;
    *)
        echo "Error: unknown tracker verb: $verb (contract: fetch, transition, comment, create)" >&2
        exit 1
        ;;
esac
