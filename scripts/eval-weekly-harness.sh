#!/bin/bash
#
# eval-weekly-harness.sh — run ai-toolkit's eval-weekly.sh against this
# plugin's eval suite, inside the harness directory the baseline was taken
# from (evals/README.md, "Running a case: work-order must load alongside").
#
# Usage:
#   eval-weekly-harness.sh [eval-weekly.sh options]   # e.g. --max-cost-usd 40
#   eval-weekly-harness.sh --build-only DIR            # build the harness, run nothing
#
# Run straight on this checkout, `claude plugin eval` loads only this plugin,
# reports its work-order dependency unsatisfied, and loads none of its agents.
# So this builds a temp directory named night-watchman holding:
#   plugins/night-watchman    this checkout's tracked files, evals/ left out
#   plugins/work-order        the installed user-scope work-order
#   plugins/moneymike-skills  the installed user-scope copy, only when a case
#                             is tagged needs-moneymike-skills
#   evals/<folder>            every evals/ folder holding a case.yaml, each
#                             case.yaml given a `plugins:` list at its depth
#   evals/results/baseline.tsv
# then runs eval-weekly.sh with every argument given here followed by that
# directory, removes the directory, and exits with eval-weekly.sh's code.
#
# Exit: eval-weekly.sh's code (0 nothing fell, 1 something fell, 64 usage);
# 1 when the harness cannot be built.
#
# EVAL_HARNESS_CLAUDE overrides the claude binary used to find the installed
# plugins, EVAL_HARNESS_WEEKLY the eval-weekly.sh run (the selftest's stubs).

set -euo pipefail
# shellcheck source=lib/kit.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/kit.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLAUDE="${EVAL_HARNESS_CLAUDE:-claude}"
MM_TAG="needs-moneymike-skills"

BUILD_ONLY=""
case "${1:-}" in
    -h|--help) show_help ;;
    --build-only)
        [ $# -eq 2 ] || die "usage: eval-weekly-harness.sh --build-only DIR"
        BUILD_ONLY="$2"
        ;;
esac

need git python3 tar

# installed_path ID — the install path of plugin ID at user scope.
installed_path() {
    local out
    out=$("$CLAUDE" plugin list --json | python3 -c '
import json, sys
want = sys.argv[1]
for p in json.load(sys.stdin):
    if p.get("id") == want and p.get("scope") == "user" and p.get("installPath"):
        print(p["installPath"]); break
' "$1") || die "could not read \`$CLAUDE plugin list --json\`"
    [ -n "$out" ] && [ -d "$out" ] || die "$1 is not installed at user scope (claude plugin install $1)"
    printf '%s\n' "$out"
}

# patch_case FILE PREFIX WITH_MM — append a plugins: list to one case.yaml.
patch_case() {
    local f="$1" pre="$2" mm="$3" t
    if grep -q '^plugins:' "$f"; then
        die "$f already has a plugins: list; the harness would overwrite it"
    fi
    t=$(tmpfile)
    awk -v pre="$pre" -v mm="$mm" '
        { print }
        END {
            print "plugins:"
            print "- " pre "plugins/night-watchman"
            print "- " pre "plugins/work-order"
            if (mm == 1) print "- " pre "plugins/moneymike-skills"
        }
    ' "$f" > "$t"
    cat "$t" > "$f"
}

build() {
    local dir="$1" d f rel prefix depth i mm_needed=0 mm
    [ ! -e "$dir" ] || [ -z "$(ls -A "$dir")" ] || die "$dir exists and is not empty"
    mkdir -p "$dir/plugins/night-watchman" "$dir/evals/results"
    [ -f "$ROOT/evals/results/baseline.tsv" ] || die "no baseline at $ROOT/evals/results/baseline.tsv"

    git -C "$ROOT" ls-files -z -- . ':(exclude)evals' \
        | python3 -c '
import os, sys
root = sys.argv[1]
for p in sys.stdin.buffer.read().split(b"\0"):
    if p and os.path.lexists(os.path.join(root.encode(), p)):
        sys.stdout.buffer.write(p + b"\0")
' "$ROOT" \
        | (cd "$ROOT" && tar --null -T - -cf -) \
        | tar -xf - -C "$dir/plugins/night-watchman"

    for d in "$ROOT"/evals/*/; do
        d="${d%/}"
        [ "$(basename "$d")" = results ] && continue
        [ -n "$(find "$d" -name case.yaml -print | head -n 1)" ] || continue
        cp -R "$d" "$dir/evals/"
    done
    [ -n "$(find "$dir/evals" -name case.yaml -print | head -n 1)" ] || die "no case.yaml under $ROOT/evals"
    cp "$ROOT/evals/results/baseline.tsv" "$dir/evals/results/baseline.tsv"

    if grep -rlqx -- "- $MM_TAG" "$dir/evals" --include=case.yaml; then
        mm_needed=1
    fi
    cp -R "$(installed_path work-order@moneymike-plugins)" "$dir/plugins/work-order"
    if [ "$mm_needed" = 1 ]; then
        cp -R "$(installed_path moneymike-skills@moneymike-plugins)" "$dir/plugins/moneymike-skills"
    fi

    while IFS= read -r f; do
        rel="${f#"$dir"/}"
        depth=$(printf '%s' "$(dirname "$rel")" | awk -F/ '{print NF}')
        prefix=""
        i=0
        while [ "$i" -lt "$depth" ]; do prefix="../$prefix"; i=$((i + 1)); done
        mm=0
        grep -qx -- "- $MM_TAG" "$f" && mm=1
        patch_case "$f" "$prefix" "$mm"
    done < <(find "$dir/evals" -name case.yaml -print)
}

if [ -n "$BUILD_ONLY" ]; then
    build "$BUILD_ONLY"
    printf '%s\n' "$BUILD_ONLY"
    exit 0
fi

WEEKLY="${EVAL_HARNESS_WEEKLY:-}"
[ -n "$WEEKLY" ] || WEEKLY=$("$HERE/ai-toolkit-root.sh" --eval-weekly)
[ -f "$WEEKLY" ] || die "eval-weekly.sh not found at $WEEKLY"

PARENT=$(mktemp -d "${TMPDIR:-/tmp}/nw-eval-harness.XXXXXX")
# shellcheck disable=SC2329  # called indirectly via kit_on_exit
remove_harness() { rm -rf "$PARENT"; }
kit_on_exit remove_harness
build "$PARENT/night-watchman"
echo "harness: $PARENT/night-watchman"

rc=0
bash "$WEEKLY" "$@" "$PARENT/night-watchman" || rc=$?
exit "$rc"
