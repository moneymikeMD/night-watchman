#!/bin/bash
#
# kit.sh — the minimal shared shell helpers night-watchman's own scripts
# source. Deliberately small and dependency-free. bash 3.2 compatible
# (no associative arrays, no `${var^^}`, no `readarray`/`mapfile`).
#
# Usage: source this file, then call die/warn/need/show_help/tmpfile.

# die MESSAGE... — print to stderr, exit 1.
die() { echo "Error: $*" >&2; exit 1; }

# warn MESSAGE... — print to stderr, keep going.
warn() { echo "$*" >&2; }

# need CMD... — die if any named command is not on PATH.
need() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "required command not found on PATH: $cmd"
    done
}

# show_help — print the calling script's own leading '#'-comment header
# (everything from the first line after the shebang up to the first
# non-comment, non-blank line) with the leading '# ' stripped, then exit 0.
show_help() {
    awk '
        NR == 1 && /^#!/ { next }
        /^#/ { sub(/^# ?/, ""); print; next }
        /^[[:space:]]*$/ { next }
        { exit }
    ' "$0"
    exit 0
}

# known_command WANT CANDIDATE... — 0 if WANT is one of the candidates.
known_command() {
    local want="$1" c
    shift
    for c in "$@"; do [ "$c" = "$want" ] && return 0; done
    return 1
}

# tmpfile — create a 0600 tempfile, removed on exit. Safe to call more than
# once: each call appends to the cleanup list rather than replacing the trap.
_KIT_TMPFILES=""
_kit_cleanup() {
    [ -n "$_KIT_TMPFILES" ] || return 0
    # shellcheck disable=SC2086  # word splitting is the point
    rm -f $_KIT_TMPFILES 2>/dev/null || true
}
tmpfile() {
    local f
    f=$(mktemp "${TMPDIR:-/tmp}/kit.XXXXXX") || return 1
    chmod 600 "$f" || { rm -f "$f"; return 1; }
    if [ -z "$_KIT_TMPFILES" ]; then
        trap _kit_cleanup EXIT
    fi
    _KIT_TMPFILES="$_KIT_TMPFILES
$f"
    printf '%s\n' "$f"
}
