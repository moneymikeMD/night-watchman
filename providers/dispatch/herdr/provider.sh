#!/bin/bash
#
# provider.sh — herdr's implementation of the `dispatch` provider kind
# (verbs: start, watch, stop — see ../../README.md for the contract).
# `start` is in the sibling herdr-ticket-start.sh, independently runnable
# with its own selftest; `watch` and `stop` are implemented here.
#
# <ticket-id> is matched to a herdr agent the same way herdr-ticket-start.sh
# names one: the LOWERCASED ticket id (e.g. `nwm-44`) is the agent name.
#
# `watch` = `herdr agent get <name>` (a clear "no such agent" beats an
# ambiguous wait timeout) then `herdr agent wait <name> [--until STATE...]
# [--timeout MS]`, printing the final agent JSON. Both flags pass straight
# through; see fixtures/agent-wait-help.txt for their semantics.
#
# `stop` = `herdr agent get <name>` for the workspace_id, then `herdr
# workspace close <workspace_id>`. There is no `herdr agent stop` — closing
# the owning workspace is how a herdr-managed agent pane goes away. An agent
# with no workspace_id is a stop2: that shape has never been captured, so
# this refuses rather than guessing at a `herdr pane close` call.
#
# Usage:
#   provider.sh start <ticket-id> [--model sonnet|opus|haiku] [--wait|--no-wait] [--dry-run]
#   provider.sh watch <ticket-id> [--until STATE ...] [--timeout MS]
#   provider.sh stop <ticket-id>
#
# Exit codes:
#   0   verb completed.
#   1   a check failed (unknown agent, herdr call failed, bad args).
#   2   a precondition could not even be evaluated (missing herdr/jq,
#       unparseable JSON, an agent with no workspace_id to close).
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kit.sh
. "$DIR/lib/kit.sh"

# stop2 — exit 2: a precondition could not be evaluated at all.
stop2() { echo "Error: $*" >&2; exit 2; }

# lowercase_branch TICKET_ID — the herdr agent/branch name for a ticket.
lowercase_branch() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

verb="${1:-}"
case "$verb" in
    -h|--help|help) show_help ;;
esac
[ -n "$verb" ] && shift

case "$verb" in
    start)
        exec "$DIR/herdr-ticket-start.sh" "$@"
        ;;
    watch)
        TICKET_ID="${1:-}"
        [ -n "$TICKET_ID" ] || die "usage: provider.sh watch <ticket-id> [--until STATE ...] [--timeout MS]"
        shift
        need herdr
        need jq
        BRANCH=$(lowercase_branch "$TICKET_ID")

        WAIT_ARGS=()
        while [ $# -gt 0 ]; do
            case "$1" in
                --until)
                    [ -n "${2:-}" ] || die "--until requires a value"
                    WAIT_ARGS+=(--until "$2")
                    shift 2
                    ;;
                --timeout)
                    [ -n "${2:-}" ] || die "--timeout requires a value"
                    WAIT_ARGS+=(--timeout "$2")
                    shift 2
                    ;;
                *)
                    die "unknown option to 'watch': $1"
                    ;;
            esac
        done

        herdr agent get "$BRANCH" >/dev/null 2>&1 \
            || die "no herdr agent named '$BRANCH' — is it running? ('herdr agent list' to check)"

        if [ ${#WAIT_ARGS[@]} -gt 0 ]; then
            WAIT_JSON=$(herdr agent wait "$BRANCH" "${WAIT_ARGS[@]}") \
                || die "'herdr agent wait $BRANCH ${WAIT_ARGS[*]}' failed"
        else
            WAIT_JSON=$(herdr agent wait "$BRANCH") \
                || die "'herdr agent wait $BRANCH' failed"
        fi
        printf '%s' "$WAIT_JSON" | jq -e . >/dev/null 2>&1 \
            || stop2 "'herdr agent wait' did not return valid JSON: $WAIT_JSON"
        printf '%s\n' "$WAIT_JSON"
        ;;
    stop)
        TICKET_ID="${1:-}"
        [ -n "$TICKET_ID" ] || die "usage: provider.sh stop <ticket-id>"
        need herdr
        need jq
        BRANCH=$(lowercase_branch "$TICKET_ID")

        AGENT_JSON=$(herdr agent get "$BRANCH") \
            || die "no herdr agent named '$BRANCH' — is it running? ('herdr agent list' to check)"
        printf '%s' "$AGENT_JSON" | jq -e . >/dev/null 2>&1 \
            || stop2 "'herdr agent get $BRANCH' did not return valid JSON: $AGENT_JSON"

        WORKSPACE_ID=$(printf '%s' "$AGENT_JSON" | jq -r '.result.agent.workspace_id // empty') \
            || stop2 "could not read .result.agent.workspace_id from 'herdr agent get $BRANCH' output"
        [ -n "$WORKSPACE_ID" ] \
            || stop2 "agent '$BRANCH' has no workspace_id — the paneless case is unrecorded (no fixture exists for it); see this file's header"

        CLOSE_JSON=$(herdr workspace close "$WORKSPACE_ID") \
            || die "'herdr workspace close $WORKSPACE_ID' failed"
        printf '%s' "$CLOSE_JSON" | jq -e . >/dev/null 2>&1 \
            || stop2 "'herdr workspace close' did not return valid JSON: $CLOSE_JSON"
        printf '%s\n' "$CLOSE_JSON"
        ;;
    "")
        echo "Error: usage: provider.sh VERB [ARG...] (verbs: start, watch, stop)" >&2
        exit 1
        ;;
    *)
        echo "Error: unknown dispatch verb: $verb (contract: start, watch, stop)" >&2
        exit 1
        ;;
esac
