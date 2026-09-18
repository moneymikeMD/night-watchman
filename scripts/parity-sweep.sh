#!/bin/bash
#
# Recurring drift check between this repo and a source project it was
# extracted from (see docs/parity/2026-09-13.md). Reads a
# committed map file (source path TAB local path, or a bare '-' for
# "deliberately not ported") and reports, read-only:
#
#   drift     mapped pairs (local != '-') whose files differ, with a diff
#             line count; a mapped local file that is entirely missing
#             counts as drift too
#   new       files that exist under a mapped source directory but have no
#             row in the map at all (candidates for a parity ticket)
#   vanished  map rows whose source file no longer exists in the source
#             tree (the map itself has gone stale)
#
# This script never writes to the source tree, the local repo, or the map
# file — it only reads and reports. Update the map by hand (or via a
# parity-ticket workflow) after reading its output.
#
# With --source-root DIR it also runs a fourth, bottom-up pass: it greps the
# source project's orchestration surface — CLAUDE.md, .claude/skills/*/SKILL.md,
# .claude/agents/*.md, .claude/settings*.json, docs/scripts.md,
# docs/cost/README.md — for every scripts/**.sh, scripts/**.py, agent and skill
# it references or defines, and reports as "unmapped" (with file:line) any
# reference with no row in the map's source column and no match in
# ROOT/templates/parity-allowlist.txt. A scripts/**.sh or scripts/**.py
# reference whose file does not exist under --source-root is reported
# separately as "dangling" and does not affect the exit code. Hook commands in
# .claude/settings*.json are their own reference class, extracted explicitly;
# a hook command that is not a scripts/ path at all is still reported, as that
# literal command.
#
# Usage:
#   parity-sweep.sh [--source DIR] [--map FILE] [--root DIR] [--source-root DIR]
#   parity-sweep.sh --help
#
# --source DIR  the source project's working tree to compare against.
#               Falls back to $NW_PARITY_SOURCE if not given. Required
#               one way or the other.
# --map FILE    the map file to read. Defaults to ROOT/templates/parity-map.tsv.
# --root DIR    this repo's root, for resolving the default --map and every
#               local path in it. Defaults to the directory above this
#               script. For tests only.
# --source-root DIR  enable the bottom-up enumeration pass against this
#               source-project tree (usually the same path as --source).
#               Optional; the pass is skipped entirely when omitted.
#
# Exit codes: 0 clean (drift/new/vanished/unmapped buckets all empty — the
# dangling bucket never affects this), 1 drift or unmapped references found
# (any of drift/new/vanished/unmapped non-empty), 2 could not evaluate (bad
# --source, missing/malformed map, bad --source-root).

set -euo pipefail

# pipe_ok — no-op marking a pipeline whose leading command (diff) exits
# non-zero to mean "files differ", which `pipefail` would otherwise treat as
# a failure before the `[ ... ]` check written to handle it runs.
pipe_ok() { return 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

need awk diff find mktemp sort

ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="${NW_PARITY_SOURCE:-}"
MAP=""
SOURCE_ROOT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --source)
            [ $# -ge 2 ] || die "--source requires a DIR argument"
            SOURCE="$2"; shift 2 ;;
        --map)
            [ $# -ge 2 ] || die "--map requires a FILE argument"
            MAP="$2"; shift 2 ;;
        --root)
            [ $# -ge 2 ] || die "--root requires a DIR argument"
            ROOT="$2"; shift 2 ;;
        --source-root)
            [ $# -ge 2 ] || die "--source-root requires a DIR argument"
            SOURCE_ROOT="$2"; shift 2 ;;
        -h|--help) show_help ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

MAP="${MAP:-$ROOT/templates/parity-map.tsv}"
ALLOWLIST="$ROOT/templates/parity-allowlist.txt"

fail_eval() {
    echo "parity-sweep.sh: could not evaluate: $*" >&2
    exit 2
}

[ -n "$SOURCE" ] || fail_eval "no source tree given (--source DIR or \$NW_PARITY_SOURCE)"
[ -d "$SOURCE" ] || fail_eval "no such source directory: $SOURCE"
[ -f "$MAP" ] || fail_eval "no such map file: $MAP"
[ -d "$ROOT" ] || fail_eval "no such root directory: $ROOT"
[ -z "$SOURCE_ROOT" ] || [ -d "$SOURCE_ROOT" ] || fail_eval "no such --source-root directory: $SOURCE_ROOT"

# A map row is SOURCE-PATH<TAB>LOCAL-PATH, LOCAL-PATH may be a literal '-'.
# A wrong field count means the map cannot be trusted at all, so it is a
# could-not-evaluate precondition rather than a warning.
BAD_LINES="$(awk -F'\t' '
    /^[[:space:]]*$/ { next }
    /^#/ { next }
    NF != 2 { print NR; bad = 1 }
    END { exit bad ? 0 : 1 }
' "$MAP")" || BAD_LINES=""
if [ -n "$BAD_LINES" ]; then
    fail_eval "$MAP: malformed row(s) (not SOURCE<TAB>LOCAL) at line(s): $(printf '%s' "$BAD_LINES" | tr '\n' ' ')"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/parity-sweep.XXXXXX")" || fail_eval "cannot create scratch directory"
trap 'rm -rf "$WORK"' EXIT

DRIFT="$WORK/drift"
NEWFILES="$WORK/new"
VANISHED="$WORK/vanished"
MAPPED_SET="$WORK/mapped-set"
DIRS="$WORK/dirs"
: >"$DRIFT"
: >"$NEWFILES"
: >"$VANISHED"
: >"$MAPPED_SET"

while IFS="$(printf '\t')" read -r src local; do
    case "$src" in
        ""|"#"*) continue ;;
    esac

    src_dir="$(dirname "$src")"
    src_base="$(basename "$src")"
    printf '%s\t%s\n' "$src_dir" "$src_base" >>"$MAPPED_SET"
    printf '%s\n' "$src_dir" >>"$DIRS"

    if [ ! -f "$SOURCE/$src" ]; then
        printf '%s\t%s\n' "$src" "$local" >>"$VANISHED"
        continue
    fi

    [ "$local" = "-" ] && continue

    if [ ! -f "$ROOT/$local" ]; then
        printf '%s\t%s\tlocal file missing\n' "$src" "$local" >>"$DRIFT"
        continue
    fi

    lines="$(diff -u "$SOURCE/$src" "$ROOT/$local" 2>/dev/null | wc -l | tr -d ' ')" || pipe_ok
    if [ "$lines" != "0" ]; then
        printf '%s\t%s\t%s lines\n' "$src" "$local" "$lines" >>"$DRIFT"
    fi
done <"$MAP"

sort -u "$DIRS" -o "$DIRS"
while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -d "$SOURCE/$dir" ] || continue
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        bn="$(basename "$f")"
        if ! grep -qF "$(printf '%s\t%s' "$dir" "$bn")" "$MAPPED_SET"; then
            printf '%s/%s\n' "$dir" "$bn" >>"$NEWFILES"
        fi
    done < <(find "$SOURCE/$dir" -maxdepth 1 -type f 2>/dev/null | sort)
done <"$DIRS"

report_section() {
    local title="$1" file="$2"
    echo "== $title =="
    if [ -s "$file" ]; then
        cat "$file"
    else
        echo "(none)"
    fi
    echo
}

report_section "drift: mapped pairs that differ" "$DRIFT"
report_section "new: source files with no map row" "$NEWFILES"
report_section "vanished: map rows whose source no longer exists" "$VANISHED"

UNMAPPED="$WORK/unmapped"
DANGLING="$WORK/dangling"
: >"$UNMAPPED"
: >"$DANGLING"

if [ -n "$SOURCE_ROOT" ]; then
    # in_map PATH — 0 if PATH is exactly the source column of some map row.
    # awk, not grep -F, so a row whose LOCAL column holds the same string
    # cannot satisfy it.
    in_map() {
        awk -F'\t' -v p="$1" '
            /^[[:space:]]*$/ { next }
            /^#/ { next }
            $1 == p { found = 1 }
            END { exit found ? 0 : 1 }
        ' "$MAP"
    }

    # allowlisted PATH — 0 if PATH matches a shell-glob pattern in
    # templates/parity-allowlist.txt; a missing file is an empty allowlist.
    allowlisted() {
        local path="$1" pat
        [ -f "$ALLOWLIST" ] || return 1
        while IFS= read -r pat; do
            case "$pat" in
                ""|"#"*) continue ;;
            esac
            # shellcheck disable=SC2254 # $pat is a deliberate glob, not a literal
            case "$path" in
                $pat) return 0 ;;
            esac
        done <"$ALLOWLIST"
        return 1
    }

    # extract_hook_commands FILE — print every hook "command" value in a
    # .claude/settings*.json file, one per line. Malformed JSON yields
    # nothing rather than dying; the scripts/**.sh grep pass still covers it.
    extract_hook_commands() {
        local f="$1"
        if command -v jq >/dev/null 2>&1; then
            jq -r '.. | objects | select(has("command")) | .command // empty' "$f" 2>/dev/null || pipe_ok
        else
            grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
                | sed -E 's/^"command"[[:space:]]*:[[:space:]]*"(.*)"$/\1/' || pipe_ok
        fi
    }

    # The globs below assume $SOURCE_ROOT is free of shell glob metacharacters
    # (*, ?, [); an exotic path yields a mismatched scan, not a crash.
    SCANFILES="$WORK/scanfiles"
    : >"$SCANFILES"
    for f in "$SOURCE_ROOT/CLAUDE.md" "$SOURCE_ROOT/docs/scripts.md" "$SOURCE_ROOT/docs/cost/README.md"; do
        [ -f "$f" ] && printf '%s\n' "$f" >>"$SCANFILES"
    done
    for f in "$SOURCE_ROOT"/.claude/skills/*/SKILL.md "$SOURCE_ROOT"/.claude/agents/*.md "$SOURCE_ROOT"/.claude/settings*.json; do
        [ -f "$f" ] && printf '%s\n' "$f" >>"$SCANFILES"
    done

    REFS="$WORK/refs"
    : >"$REFS"

    # Pass 1: an agent/skill file's own existence is the reference (line 1).
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            "$SOURCE_ROOT"/.claude/agents/README.md) continue ;;
            "$SOURCE_ROOT"/.claude/agents/*.md|"$SOURCE_ROOT"/.claude/skills/*/SKILL.md)
                rel="${f#"$SOURCE_ROOT"/}"
                printf '%s\t%s\t1\n' "$rel" "$f" >>"$REFS"
                ;;
        esac
    done <"$SCANFILES"

    # Pass 2: one pattern covers scripts/ and hooks/ alike — this project maps
    # hooks under scripts/dev/*.sh too (see templates/parity-map.tsv).
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        while IFS=: read -r lineno match; do
            [ -n "$match" ] || continue
            printf '%s\t%s\t%s\n' "$match" "$f" "$lineno" >>"$REFS"
        done < <(grep -noE 'scripts/[A-Za-z0-9_./-]+\.(sh|py)' "$f" 2>/dev/null || pipe_ok)
    done <"$SCANFILES"

    # Pass 3: a command with no scripts/ path in it (e.g. "op item create") is
    # kept as its own literal reference, so it still surfaces as unmapped.
    for f in "$SOURCE_ROOT"/.claude/settings*.json; do
        [ -f "$f" ] || continue
        while IFS= read -r cmd; do
            [ -n "$cmd" ] || continue
            # Look up the line by the bare scripts/ path: JSON escaping means
            # the jq-decoded command is often not a literal substring of the
            # raw file text, but the path portion always is.
            path="$(printf '%s' "$cmd" | grep -oE 'scripts/[A-Za-z0-9_./-]+\.(sh|py)' | head -1)" || pipe_ok
            if [ -n "$path" ]; then
                lineno="$(grep -nF -- "$path" "$f" 2>/dev/null | head -1 | cut -d: -f1)" || pipe_ok
            else
                path="$cmd"
                lineno="$(grep -nF -- "$cmd" "$f" 2>/dev/null | head -1 | cut -d: -f1)" || pipe_ok
            fi
            [ -n "$lineno" ] || lineno="?"
            printf '%s\t%s\t%s\n' "$path" "$f" "$lineno" >>"$REFS"
        done < <(extract_hook_commands "$f")
    done

    sort -t "$(printf '\t')" -k1,1 -u "$REFS" -o "$REFS"

    while IFS="$(printf '\t')" read -r path srcfile lineno; do
        [ -n "$path" ] || continue
        rel_srcfile="${srcfile#"$SOURCE_ROOT"/}"
        case "$path" in
            scripts/*.sh|scripts/*.py)
                if [ ! -f "$SOURCE_ROOT/$path" ]; then
                    printf '%s:%s: %s\n' "$rel_srcfile" "$lineno" "$path" >>"$DANGLING"
                    continue
                fi
                ;;
        esac
        in_map "$path" && continue
        allowlisted "$path" && continue
        printf '%s:%s: %s\n' "$rel_srcfile" "$lineno" "$path" >>"$UNMAPPED"
    done <"$REFS"

    report_section "unmapped: referenced in source, no map row or allowlist entry" "$UNMAPPED"
    report_section "dangling: referenced in source, but no such file under --source-root (docs bug, not a parity gap)" "$DANGLING"
fi

if [ -s "$DRIFT" ] || [ -s "$NEWFILES" ] || [ -s "$VANISHED" ] || [ -s "$UNMAPPED" ]; then
    exit 1
fi
exit 0
