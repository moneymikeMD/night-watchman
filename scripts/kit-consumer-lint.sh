#!/bin/bash
#
# Fail when a kit.sh consumer silently stops kit's cleanup from running.
#
# kit.sh removes a script's tempfiles, and its own registry, from an EXIT
# trap. There are exactly two ways a consumer disables that, and this repo has
# been bitten by both:
#
#   exec   replaces the process image, so no EXIT trap runs at all. NWM-171:
#          providers/lib/provider.sh execs on every provider verb call and
#          leaked three files per call. Use kit_exec.
#   trap   bash keeps ONE handler per signal, so a `trap ... EXIT` installed
#          after sourcing kit.sh REPLACES kit's rather than adding to it
#          (LAB-104). Use kit_on_exit. A trap set BEFORE the source is not
#          reported: kit's own trap wins there, which is the other hazard and
#          not this one.
#
# A consumer is a file that SOURCES kit.sh, which excludes kit.sh itself, so
# its own `exec "$@"` inside kit_exec needs no exemption.
#
# HEREDOC BODIES ARE SKIPPED, for both the source line and the rules. Several
# selftests write fixture scripts with `cat <<EOF`, and that text is data, not
# code this file runs — scanning it reported this lint's own selftest.
#
# Escape hatch, on the line immediately before the offending line:
#   # kit-lint: allow-exec <reason>
#   # kit-lint: allow-trap <reason>
# The reason is required. An exemption nobody had to justify is how the rule
# rots; one with a reason is a decision a reviewer can disagree with.
#
# Usage:
#   kit-consumer-lint.sh [--root PATH] [--quiet]
#   kit-consumer-lint.sh --help
#
# Exit codes: 0 clean, 1 at least one violation, 2 could not evaluate.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

stop2() { echo "Error: $*" >&2; exit 2; }

ROOT="$(cd "$HERE/.." && pwd)"
QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) show_help ;;
        --root)
            [ $# -ge 2 ] || stop2 "--root needs a PATH"
            [ -n "$2" ] || stop2 "--root: PATH is empty"
            [ -d "$2" ] || stop2 "--root: no such directory: $2"
            ROOT="$(cd "$2" && pwd)"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        *) stop2 "unknown option: $1 (see --help)" ;;
    esac
done

need awk grep find

VIOLATIONS=0
CHECKED=0
SCRATCH_HITS="$(tmpfile)" || stop2 "could not create a temp file for the per-file hit list"

# report FILE LINE RULE TEXT
report() {
    VIOLATIONS=$((VIOLATIONS + 1))
    printf '%s:%s: %s\n' "${1#"$ROOT"/}" "$2" "$3" >&2
    printf '    %s\n' "$4" >&2
}

# scan FILE — print "lineno|rule|text" per violation, and "0|consumer|" if the
# file sources kit.sh. One awk pass, so heredoc state is tracked once.
scan() {
    awk '
        # No quote character appears in this function on purpose. A literal
        # one would end the shell-quoted awk program, and the escapes that
        # avoid that (\047, \x27) are not portable across awks — macOS awk
        # ignored \047 inside a bracket expression, which broke the first cut.
        function is_open_delim(line,   t) {
            if (line !~ /<</) return ""
            if (line ~ /<<</) return ""
            t = line
            sub(/^.*<<-?/, "", t)
            sub(/^[[:space:]]*/, "", t)
            sub(/^[^A-Za-z0-9_]+/, "", t)
            sub(/[^A-Za-z0-9_].*$/, "", t)
            return t
        }
        {
            if (heredoc != "") {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                if ($0 == heredoc || line == heredoc) heredoc = ""
                prev = $0
                next
            }
            d = is_open_delim($0)
            if (d != "") { pending = d }
        }
        /^[[:space:]]*(\.|source)[[:space:]]+.*kit\.sh/ && src == 0 {
            src = NR; print "0|consumer|"
        }
        /^[[:space:]]*exec[[:space:]]/ {
            if (prev ~ /kit-lint:[[:space:]]*allow-exec[[:space:]]+[^[:space:]]/) { }
            else if (prev ~ /kit-lint:[[:space:]]*allow-exec[[:space:]]*$/) print NR "|badexempt|" $0
            else print NR "|exec|" $0
        }
        /^[[:space:]]*trap[[:space:]].*EXIT/ {
            if (src != 0 && NR > src) {
                if (prev ~ /kit-lint:[[:space:]]*allow-trap[[:space:]]+[^[:space:]]/) { }
                else if (prev ~ /kit-lint:[[:space:]]*allow-trap[[:space:]]*$/) print NR "|badexempt|" $0
                else print NR "|trap|" $0
            }
        }
        {
            prev = $0
            if (pending != "") { heredoc = pending; pending = "" }
        }
    ' "$1"
}

# scripts/fixtures/ is deliberately broken test material and evals/ is
# recorded agent output; neither is script this repo runs.
CANDIDATES="$(find "$ROOT/scripts" "$ROOT/providers" "$ROOT/hooks" -name '*.sh' 2>/dev/null \
    | grep -v "^$ROOT/scripts/fixtures/" \
    | grep -v "^$ROOT/evals/" \
    | sort)"
[ -n "$CANDIDATES" ] || stop2 "found no shell script under $ROOT — the lint would pass having checked nothing"

for f in $CANDIDATES; do
    RESULT="$(scan "$f")"
    case "$RESULT" in
        *"0|consumer|"*) ;;
        *) continue ;;
    esac
    CHECKED=$((CHECKED + 1))
    printf '%s\n' "$RESULT" | while IFS='|' read -r lineno rule text; do
        [ "$rule" = consumer ] && continue
        [ -n "$rule" ] || continue
        printf '%s|%s|%s\n' "$lineno" "$rule" "$text"
    done > "$SCRATCH_HITS"
    while IFS='|' read -r lineno rule text; do
        [ -n "$lineno" ] || continue
        case "$rule" in
            exec) report "$f" "$lineno" \
                "a bare 'exec' in a kit.sh consumer: no EXIT trap runs, so kit's cleanup never happens. Use kit_exec, or exempt with '# kit-lint: allow-exec <reason>'" \
                "$text" ;;
            trap) report "$f" "$lineno" \
                "a raw 'trap ... EXIT' after sourcing kit.sh REPLACES kit's handler, so kit's cleanup stops running. Use kit_on_exit, or exempt with '# kit-lint: allow-trap <reason>'" \
                "$text" ;;
            badexempt) report "$f" "$lineno" \
                "a 'kit-lint: allow-*' comment with no reason does not exempt anything" \
                "$text" ;;
        esac
    done < "$SCRATCH_HITS"
done

if [ "$VIOLATIONS" -ne 0 ]; then
    echo "kit-consumer-lint: $VIOLATIONS violation(s) across $CHECKED consumer file(s)" >&2
    exit 1
fi
# The count is printed on success too: a lint that matched nothing would also
# exit 0, and the number is what tells them apart.
[ "$QUIET" = 1 ] || echo "kit-consumer-lint: OK, $CHECKED kit.sh consumer(s) checked"
exit 0
