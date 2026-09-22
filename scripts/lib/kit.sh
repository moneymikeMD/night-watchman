#!/bin/bash
#
# kit.sh — the minimal shared shell helpers night-watchman's own scripts
# source. A credential-store or host-conventions library belongs in a
# consuming project, not in this plugin's dependency-free core.
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

# show_help — print the calling script's leading '#'-comment header (shebang to
# the first non-comment, non-blank line) with '# ' stripped, then exit 0.
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

# herdr_notify PANE TEXT — type TEXT into a herdr pane and press enter. 0 only
# if both herdr calls succeeded; callers treat a failure as a warning.
herdr_notify() {
    herdr pane send-text "$1" "$2" >/dev/null 2>&1 && herdr pane send-keys "$1" enter >/dev/null 2>&1
}

# tmpfile — create a 0600 tempfile, removed when the calling script exits.
# The registry is a FILE, not a variable: every call site is `f=$(tmpfile)`,
# a subshell, and a variable append plus its EXIT trap die with it (NWM-155).
if [ -z "${_KIT_LOADED:-}" ]; then
_KIT_LOADED=1

# Sourcing stays side-effect-light: a missing registry is reported by
# tmpfile() at the point of use, not by killing a script that never calls it.
_KIT_TMPREG=$(mktemp "${TMPDIR:-/tmp}/kit-reg.XXXXXX" 2>/dev/null) || _KIT_TMPREG=""
[ -n "$_KIT_TMPREG" ] && chmod 600 "$_KIT_TMPREG"

_KIT_EXIT_HOOKS=""
_KIT_HOOKS_RAN=""

_kit_cleanup() {
    local f hook
    if [ -f "$_KIT_TMPREG" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] && rm -f "$f"
        done < "$_KIT_TMPREG"
        rm -f "$_KIT_TMPREG"
    fi
    # Runs twice on a signal exit. rm -f is idempotent; a hook may not be.
    if [ -z "$_KIT_HOOKS_RAN" ]; then
        _KIT_HOOKS_RAN=1
        for hook in $_KIT_EXIT_HOOKS; do
            "$hook"
        done
    fi
}

# Re-raise rather than just clean up: a trapped signal is a handled signal,
# so a cleanup-only trap would let the script survive Ctrl-C and run on.
_kit_on_signal() {
    _kit_cleanup
    trap - "$1"
    kill -"$1" $$
}

trap _kit_cleanup EXIT
for _kit_sig in INT TERM HUP; do
    # shellcheck disable=SC2064  # $_kit_sig must expand now, into the trap string
    trap "_kit_on_signal $_kit_sig" "$_kit_sig"
done
unset _kit_sig

fi

# kit_on_exit FN — register FN to run when the calling script exits. Use this
# rather than `trap ... EXIT`, which replaces kit's handler instead of adding
# to it and silently stops the cleanup above from running at all (LAB-104).
kit_on_exit() {
    _KIT_EXIT_HOOKS="$_KIT_EXIT_HOOKS $1"
}

tmpfile() {
    local f
    [ -n "$_KIT_TMPREG" ] || die "kit.sh has no tmpfile registry (mktemp unavailable when kit.sh was sourced)"
    f=$(mktemp "${TMPDIR:-/tmp}/kit.XXXXXX") || return 1
    chmod 600 "$f" || { rm -f "$f"; return 1; }
    printf '%s\n' "$f" >> "$_KIT_TMPREG"
    printf '%s\n' "$f"
}
