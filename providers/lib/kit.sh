#!/bin/bash
#
# kit.sh — self-contained shared helpers for providers/, a code-identical
# copy of this plugin's own scripts/lib/kit.sh (die/warn/need/show_help/
# known_command/tmpfile). Identical below this header comment; the header
# itself differs, because it has to say which directory this copy serves.
#
# Copied rather than referenced, same pattern as
# providers/dispatch/herdr/lib/kit.sh: a layer that gets copied into a
# consuming project must not depend on this plugin's own scripts/lib/
# still being reachable at a relative path once copied out. providers/ is
# copied out more often than an optional layer — it is the seam an
# adopter extends — so the rule matters here most. (An earlier version dropped the
# equivalent copy the jira tracker scripts used to carry before they
# moved under providers/tracker/jira/ and started sourcing this file
# directly.)
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`, no
# `readarray`/`mapfile`).
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

# tmpfile — create a 0600 tempfile, remove it on exit. Safe to call more
# than once in one script: each call adds its own path to the cleanup list
# rather than replacing an earlier trap registration.
_KIT_TMPFILES=""
_kit_cleanup() {
    [ -n "$_KIT_TMPFILES" ] || return 0
    # shellcheck disable=SC2086  # word splitting is the point: a
    # newline-joined list of paths, none of which are expected to contain
    # whitespace.
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
