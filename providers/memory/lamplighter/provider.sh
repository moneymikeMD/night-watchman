#!/bin/bash
#
# provider.sh — lamplighter's implementation of the `memory` provider kind
# (verbs: store, recall — see ../../README.md for the contract), over the
# `lampl` CLI. Pushing memories into a session is lamplighter's own plugin's
# job, not this provider's.
#
#   store --title T --content C [--type T] [--project P] [--component C]
#         [--kind K] [--tags A,B] [--importance F]
#   recall --query TEXT [--project P] [--limit N] [--json]
#
# --project defaults to [memory.lamplighter] project in config. store tags
# the memory with PROJECT, COMPONENT, KIND, then any extra --tags.
# $NW_DRY_RUN=1 or --dry-run before the verb prints the `lampl` command,
# shell-quoted, instead of running it.
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

# shellcheck disable=SC1091  # sourced at paths computed from $0
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$(cd "$DIR/../.." && pwd)"
# shellcheck source=../../lib/kit.sh
. "$PROVIDERS_DIR/lib/kit.sh"
# shellcheck source=../../lib/config.sh
. "$PROVIDERS_DIR/lib/config.sh"

DRY_RUN=0
[ "${NW_DRY_RUN:-0}" = "1" ] && DRY_RUN=1
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

verb="${1:-}"
[ -n "$verb" ] && shift

usage() { echo "Error: usage: provider.sh [--dry-run] VERB [ARG...] (verbs: store, recall)" >&2; exit 1; }
need_arg() { [ "$1" -ge 2 ] || die "$2 needs a value"; }

project=$(nw_config_get memory.lamplighter.project "") || die "cannot read config"

run() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '%q ' "$@"
        echo
        exit 0
    fi
    need lampl
    kit_exec "$@"
}

case "$verb" in
    store)
        type=""; title=""; content=""; component=""; kind=""; extra=""; importance=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --type)       need_arg "$#" "$1"; type="$2"; shift 2 ;;
                --title)      need_arg "$#" "$1"; title="$2"; shift 2 ;;
                --content | --body) need_arg "$#" "$1"; content="$2"; shift 2 ;;
                --project)    need_arg "$#" "$1"; project="$2"; shift 2 ;;
                --component)  need_arg "$#" "$1"; component="$2"; shift 2 ;;
                --kind)       need_arg "$#" "$1"; kind="$2"; shift 2 ;;
                --tags)       need_arg "$#" "$1"; extra="$2"; shift 2 ;;
                --importance) need_arg "$#" "$1"; importance="$2"; shift 2 ;;
                *)            die "unknown store argument: $1" ;;
            esac
        done
        [ -n "$title" ]   || die "store: --title is required"
        [ -n "$content" ] || die "store: --content is required"
        [ -n "$project" ] || die "store: --project is required (or set [memory.lamplighter] project)"
        tags="$project"
        [ -n "$component" ] && tags="$tags,$component"
        [ -n "$kind" ]      && tags="$tags,$kind"
        [ -n "$extra" ]     && tags="$tags,$extra"
        cmd=(lampl store --title "$title" --body "$content" --project "$project" --tags "$tags")
        [ -n "$type" ]       && cmd=("${cmd[@]}" --type "$type")
        [ -n "$importance" ] && cmd=("${cmd[@]}" --importance "$importance")
        run "${cmd[@]}"
        ;;
    recall)
        query=""; limit=""; json=0
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --query)   need_arg "$#" "$1"; query="$2"; shift 2 ;;
                --project) need_arg "$#" "$1"; project="$2"; shift 2 ;;
                --limit)   need_arg "$#" "$1"; limit="$2"; shift 2 ;;
                --json)    json=1; shift ;;
                *)         die "unknown recall argument: $1" ;;
            esac
        done
        [ -n "$query" ] || die "recall: --query is required"
        cmd=(lampl recall --query "$query")
        [ -n "$project" ] && cmd=("${cmd[@]}" --project "$project")
        [ -n "$limit" ]   && cmd=("${cmd[@]}" --limit "$limit")
        [ "$json" = "1" ] && cmd=("${cmd[@]}" --json)
        run "${cmd[@]}"
        ;;
    "") usage ;;
    *)  die "unknown memory verb: $verb (contract: store, recall)" ;;
esac
