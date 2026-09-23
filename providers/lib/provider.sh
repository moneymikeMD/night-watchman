#!/bin/bash
#
# provider.sh — the one seam every night-watchman script goes through to
# reach an outside tool. Nothing in this plugin calls a Jira client, a
# 1Password binary, a worktree dispatcher, or a memory CLI directly; it
# resolves a KIND to an IMPLEMENTATION here and calls a fixed VERB on it.
#
# KINDS and their fixed verb sets. The verb set is the contract: an
# implementation of a kind must accept exactly these verbs, and callers
# must not invent new ones for one implementation's benefit.
#
#   tracker    fetch | transition | comment | create
#   secrets    read
#   dispatch   start | watch | stop
#   memory     store | recall
#   publish    publish-brief | post-headline
#
# LAYOUT. One directory per implementation, holding an executable
# `provider.sh` that takes the verb as its first argument:
#
#   providers/
#     README.md                     the contract, in prose
#     lib/provider.sh               this file — resolve + dispatch
#     lib/config.sh                 the .night-watchman/config.toml reader
#     lib/kit.sh                    die/warn/need/... (a copy; see its header)
#     config-selftest.sh            selftest for the two lib files
#     tracker/jira/provider.sh
#     secrets/op/provider.sh
#     secrets/env/provider.sh
#     dispatch/workflow/provider.sh
#     dispatch/herdr/provider.sh
#     memory/memorygraph/provider.sh
#     publish/atlassian/provider.sh
#
# SELECTION, highest priority first:
#   1. `NW_TRACKER` / `NW_SECRETS` / `NW_DISPATCH` / `NW_MEMORY` — a
#      per-run override, never the reviewed answer.
#   2. `[providers]` in the nearest committed `.night-watchman/config.toml`
#      (see config.sh for the discovery walk).
#   3. The built-in defaults below, so a fresh adopter with no config still
#      gets a working system.
#
# Every nw_* function warns and RETURNS non-zero, never `die`: inside a
# command substitution `die` exits only the subshell and the caller
# proceeds with an empty implementation name.
#
# Commands:
#   resolve KIND              print the implementation name in effect
#   origin KIND               print env | config | default
#   verbs KIND                print that kind's fixed verb set
#   kinds                     print every known kind
#   dir KIND                  print the implementation's directory
#   config KEY [DEFAULT]      print a dotted key from the config in effect
#   run KIND VERB [ARG...]    exec the implementation with VERB
#   doctor                    a table of kind/impl/origin/installed
#   --help                    this header
#
# `nw_run` ends in `exec`, replacing the calling process. Sourced callers
# that do not want that should use `nw_resolve`/`nw_dir` and invoke the
# entry point themselves.
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

# `set -e` only when RUN: sourcing a library must not change the
# error-handling mode of the script that sourced it.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
fi

PROVIDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$(dirname "$PROVIDER_LIB_DIR")"

# shellcheck source=lib/kit.sh
. "$PROVIDER_LIB_DIR/kit.sh"
# shellcheck source=lib/config.sh
. "$PROVIDER_LIB_DIR/config.sh"

NW_KINDS="tracker secrets dispatch memory publish"

# nw_verbs KIND — the fixed verb set. The single place one is written down.
nw_verbs() {
    case "$1" in
        tracker)  echo "fetch transition comment create" ;;
        secrets)  echo "read" ;;
        dispatch) echo "start watch stop" ;;
        memory)   echo "store recall" ;;
        publish)  echo "publish-brief post-headline" ;;
        *)        return 1 ;;
    esac
}

# nw_default_impl KIND — what ships, used when nothing selects otherwise.
nw_default_impl() {
    case "$1" in
        tracker)  echo "jira" ;;
        secrets)  echo "op" ;;
        dispatch) echo "workflow" ;;
        memory)   echo "memorygraph" ;;
        publish)  echo "atlassian" ;;
        *)        return 1 ;;
    esac
}

# nw_kind_env KIND — the override variable's name (NW_TRACKER, ...).
nw_kind_env() {
    printf 'NW_%s\n' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
}

# nw_commas "a b c" — "a, b, c", for error messages listing a legal set.
nw_commas() { local s="$1"; printf '%s\n' "${s// /, }"; }

nw_require_kind() {
    # shellcheck disable=SC2086  # deliberate word splitting: the kind list
    if ! known_command "$1" $NW_KINDS; then
        warn "Error: unknown provider kind: $1 (known: $(nw_commas "$NW_KINDS"))"
        return 1
    fi
}

# nw_valid_impl NAME — a single lowercase path segment. A SECURITY check:
# the name is concatenated into a path and executed, so `../..` is refused here.
nw_valid_impl() {
    case "$1" in
        *[!a-z0-9_-]* | "" | -* | _*) return 1 ;;
        *) return 0 ;;
    esac
}

# nw_resolve KIND — the implementation in effect.
nw_resolve() {
    local kind="$1" var val
    nw_require_kind "$kind" || return 1
    var=$(nw_kind_env "$kind")
    eval "val=\${$var:-}"
    if [ -z "$val" ]; then
        val=$(nw_config_get "providers.$kind" "") || { warn "Error: cannot read config"; return 1; }
    fi
    if [ -z "$val" ]; then
        val=$(nw_default_impl "$kind")
    fi
    nw_valid_impl "$val" || {
        warn "Error: malformed implementation name for $kind: '$val' (expected lowercase [a-z0-9_-], no path separators)"
        return 1
    }
    printf '%s\n' "$val"
}

# nw_origin KIND — env | config | default: where the selection came from.
nw_origin() {
    local kind="$1" var val
    nw_require_kind "$kind" || return 1
    var=$(nw_kind_env "$kind")
    eval "val=\${$var:-}"
    if [ -n "$val" ]; then
        nw_valid_impl "$val" || {
            warn "Error: malformed implementation name for $kind: '$val' (expected lowercase [a-z0-9_-], no path separators)"
            return 1
        }
        echo env
        return 0
    fi
    val=$(nw_config_get "providers.$kind" "") || { warn "Error: cannot read config"; return 1; }
    if [ -n "$val" ]; then
        # `origin` must never report a selection `resolve` would refuse.
        nw_valid_impl "$val" || {
            warn "Error: malformed implementation name for $kind: '$val' (expected lowercase [a-z0-9_-], no path separators)"
            return 1
        }
        echo config
        return 0
    fi
    echo default
}

nw_dir() {
    local kind="$1" impl
    impl=$(nw_resolve "$kind") || return 1
    printf '%s\n' "$PROVIDERS_DIR/$kind/$impl"
}

# nw_run KIND VERB [ARG...] — validate the verb against the kind's fixed set,
# then exec the implementation. An unknown verb is a contract error.
nw_run() {
    local kind="$1" verb="$2" impl dir entry
    shift 2 || true
    nw_require_kind "$kind" || return 1
    [ -n "$verb" ] || { warn "Error: usage: provider.sh run KIND VERB [ARG...]"; return 1; }
    # shellcheck disable=SC2046  # deliberate word splitting: the verb list
    if ! known_command "$verb" $(nw_verbs "$kind"); then
        warn "Error: unknown $kind verb: $verb (contract: $(nw_commas "$(nw_verbs "$kind")"))"
        return 1
    fi
    # `|| return 1` is load-bearing: without it nw_resolve's refusal, made
    # inside this substitution, arrives as "" and the path tests below pass.
    impl=$(nw_resolve "$kind") || return 1
    dir="$PROVIDERS_DIR/$kind/$impl"
    entry="$dir/provider.sh"
    [ -d "$dir" ] || {
        warn "Error: $kind provider '$impl' is not installed (expected directory: $dir)"
        return 1
    }
    [ -x "$entry" ] || {
        warn "Error: $kind provider '$impl' has no executable entry point (expected: $entry)"
        return 1
    }
    kit_exec "$entry" "$verb" "$@"
}

nw_doctor() {
    local kind impl origin state cfg rows row
    cfg=$(nw_config_file)
    echo "config: ${cfg:-<none found; using built-in defaults>}"
    # Rows are accumulated then piped, not generated inside `{ ... } | column`:
    # a `return 1` in that position would leave only the pipeline's subshell.
    rows=""
    for kind in $NW_KINDS; do
        impl=$(nw_resolve "$kind") || return 1
        origin=$(nw_origin "$kind") || return 1
        if [ -x "$PROVIDERS_DIR/$kind/$impl/provider.sh" ]; then
            state=installed
        elif [ -d "$PROVIDERS_DIR/$kind/$impl" ]; then
            state=no-entry-point
        else
            state=not-installed
        fi
        row=$(printf '%s\t%s\t%s\t%s\t%s' "$kind" "$impl" "$origin" "$state" "$(nw_verbs "$kind" | tr ' ' ',')")
        rows="$rows$row
"
    done
    { printf 'KIND\tIMPL\tORIGIN\tSTATE\tVERBS\n'; printf '%s' "$rows"; } \
        | column -t -s"$(printf '\t')"
}

# nw_main — the executed path only, so `die` is safe: no sourcing shell to take down.
nw_main() {
    [ "$#" -gt 0 ] || show_help
    local cmd="$1"
    shift
    case "$cmd" in
        -h | --help | help) show_help ;;
        resolve) [ "$#" -eq 1 ] || die "usage: provider.sh resolve KIND"; nw_resolve "$1" || exit 1 ;;
        origin)  [ "$#" -eq 1 ] || die "usage: provider.sh origin KIND";  nw_origin "$1" || exit 1 ;;
        verbs)   [ "$#" -eq 1 ] || die "usage: provider.sh verbs KIND"
                 nw_require_kind "$1" || exit 1
                 nw_verbs "$1" ;;
        kinds)   printf '%s\n' "$(echo "$NW_KINDS" | tr ' ' '\n')" ;;
        dir)     [ "$#" -eq 1 ] || die "usage: provider.sh dir KIND"; nw_dir "$1" || exit 1 ;;
        config)  [ "$#" -ge 1 ] || die "usage: provider.sh config KEY [DEFAULT]"
                 if [ "$#" -ge 2 ]; then nw_config_get "$1" "$2"; else nw_config_get "$1" || die "no such config key: $1"; fi
                 echo ;;
        run)     [ "$#" -ge 2 ] || die "usage: provider.sh run KIND VERB [ARG...]"; nw_run "$@" || exit 1 ;;
        doctor)  nw_doctor || exit 1 ;;
        *)
                 # KIND VERB [ARG...] — shorthand for `run KIND VERB [ARG...]`.
                 # shellcheck disable=SC2086  # deliberate word splitting: the kind list
                 if known_command "$cmd" $NW_KINDS; then
                     [ "$#" -ge 1 ] || die "usage: provider.sh $cmd VERB [ARG...]"
                     nw_run "$cmd" "$@" || exit 1
                 else
                     die "unknown command: $cmd (try --help)"
                 fi ;;
    esac
}

# Executable as a CLI, sourceable as a library.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    nw_main "$@"
fi
