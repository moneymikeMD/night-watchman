#!/bin/bash
#
# store.sh — the `store` verb: wraps `memorygraph store` so every memory is
# tagged with its project, component and kind of change, which is what makes
# the graph filterable later.
#
# bash 3.2 compatible.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/kit.sh
. "$DIR/../../lib/kit.sh"

usage() {
    cat >&2 <<'EOF'
usage: store.sh --type TYPE --title TITLE --content CONTENT --project PROJECT
                 [--component COMPONENT] [--kind KIND] [--tags EXTRA,TAGS]
                 [--importance N] [--dry-run]

TYPE is one of memorygraph's own --type values (problem, solution, error,
fix, code_pattern, workflow, command, technology, task, project,
file_context, general, conversation).

The stored memory's --tags is built from PROJECT, then COMPONENT (if
given), then KIND (if given), then any comma-separated EXTRA,TAGS — the
"project, component, kind of change" convention every memory here should
carry. --dry-run prints the `memorygraph store` command that would run,
shell-quoted, instead of running it.
EOF
    exit 1
}

type=""; title=""; content=""; project=""; component=""; kind=""; extra_tags=""; importance=""; dry_run=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --type)       [ "$#" -ge 2 ] || usage; type="$2"; shift 2 ;;
        --title)      [ "$#" -ge 2 ] || usage; title="$2"; shift 2 ;;
        --content)    [ "$#" -ge 2 ] || usage; content="$2"; shift 2 ;;
        --project)    [ "$#" -ge 2 ] || usage; project="$2"; shift 2 ;;
        --component)  [ "$#" -ge 2 ] || usage; component="$2"; shift 2 ;;
        --kind)       [ "$#" -ge 2 ] || usage; kind="$2"; shift 2 ;;
        --tags)       [ "$#" -ge 2 ] || usage; extra_tags="$2"; shift 2 ;;
        --importance) [ "$#" -ge 2 ] || usage; importance="$2"; shift 2 ;;
        --dry-run)    dry_run=1; shift ;;
        -h | --help)  usage ;;
        *)            echo "Error: unknown argument: $1" >&2; usage ;;
    esac
done

[ -n "$type" ]    || { echo "Error: --type is required" >&2; usage; }
[ -n "$title" ]   || { echo "Error: --title is required" >&2; usage; }
[ -n "$content" ] || { echo "Error: --content is required" >&2; usage; }
[ -n "$project" ] || { echo "Error: --project is required" >&2; usage; }

tags="$project"
[ -n "$component" ]  && tags="$tags,$component"
[ -n "$kind" ]       && tags="$tags,$kind"
[ -n "$extra_tags" ] && tags="$tags,$extra_tags"

cmd=(memorygraph store --type "$type" --title "$title" --content "$content" --tags "$tags")
[ -n "$importance" ] && cmd=("${cmd[@]}" --importance "$importance")

if [ "$dry_run" -eq 1 ]; then
    printf '%q ' "${cmd[@]}"
    echo
    exit 0
fi

need memorygraph
"${cmd[@]}"
