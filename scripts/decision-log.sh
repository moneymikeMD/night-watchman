#!/bin/bash
#
# Appends one sanitised row to a wave-trail TSV (see skills/wave-trail/
# SKILL.md for the row contract: ts, phase, decision, why, evidence,
# result). Writes the header on first use. Strips embedded tabs/newlines
# so cells stay single-line, and prefixes any cell starting with = + - @
# with a single quote (spreadsheet formula injection) since the trail is
# read in spreadsheets and evidence/decision text can be attacker- or
# tool-controlled.
#
# Usage:
#   decision-log.sh --phase P --decision D [--why W] [--evidence E]
#                    [--result R] [--file FILE] [--dry-run]
#   decision-log.sh --help
#
# --phase P     required. The wave phase or workstream (orient, dispatch, ...).
# --decision D  required. What was chosen or done, one line.
# --why W       the reason, plain words. Defaults to empty.
# --evidence E  a pointer that proves it (commit SHA, ticket ID, file:line).
# --result R    the outcome or predicate state (verify MET, reverted, ...).
# --file FILE   defaults to .night-watchman/wave-trail.tsv under the repo
#               root (git rev-parse --show-toplevel).
# --dry-run     print the row that would be appended; write nothing.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

PHASE=""
DECISION=""
WHY=""
EVIDENCE=""
RESULT=""
FILE=""
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --phase)    [ $# -ge 2 ] || die "--phase requires an argument"; PHASE="$2"; shift 2 ;;
        --decision) [ $# -ge 2 ] || die "--decision requires an argument"; DECISION="$2"; shift 2 ;;
        --why)      [ $# -ge 2 ] || die "--why requires an argument"; WHY="$2"; shift 2 ;;
        --evidence) [ $# -ge 2 ] || die "--evidence requires an argument"; EVIDENCE="$2"; shift 2 ;;
        --result)   [ $# -ge 2 ] || die "--result requires an argument"; RESULT="$2"; shift 2 ;;
        --file)     [ $# -ge 2 ] || die "--file requires an argument"; FILE="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  show_help ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

[ -n "$PHASE" ] || die "--phase is required"
[ -n "$DECISION" ] || die "--decision is required"

if [ -z "$FILE" ]; then
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository (pass --file to target one directly)"
    FILE="$ROOT/.night-watchman/wave-trail.tsv"
fi

# clean CELL — strip tabs/CR/newlines so a cell stays single-line, then
# quote-prefix a value a spreadsheet would parse as a formula.
clean() {
    local v
    v=$(printf '%s' "$1" | tr '\t\n\r' '   ')
    case "$v" in
        =*|+*|-*|@*) printf "'%s" "$v" ;;
        *) printf '%s' "$v" ;;
    esac
}

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ROW="$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
    "$TS" "$(clean "$PHASE")" "$(clean "$DECISION")" "$(clean "$WHY")" "$(clean "$EVIDENCE")" "$(clean "$RESULT")")"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "$ROW"
    exit 0
fi

FILEDIR="$(dirname "$FILE")"
[ -d "$FILEDIR" ] || mkdir -p "$FILEDIR"

if [ ! -f "$FILE" ]; then
    printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n' > "$FILE"
fi

printf '%s\n' "$ROW" >> "$FILE"

# negative test line 1: this block is six lines, the cap is four
# negative test line 2: this block is six lines, the cap is four
# negative test line 3: this block is six lines, the cap is four
# negative test line 4: this block is six lines, the cap is four
# negative test line 5: this block is six lines, the cap is four
# negative test line 6: this block is six lines, the cap is four
