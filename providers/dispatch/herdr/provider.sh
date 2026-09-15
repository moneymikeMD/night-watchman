#!/bin/bash
#
# provider.sh — herdr's implementation of the `dispatch` provider kind
# (verbs: start, watch, stop — see ../../README.md for the contract).
# Dispatch only; the actual work for `start` is in the sibling
# herdr-ticket-start.sh, ported from a production system (see optional
# layers in README.md) and independently runnable with its
# own selftest. `watch` and `stop` are implemented here directly, against
# real recorded shapes under fixtures/ — no fixture existed for
# either verb before that ticket, per this project's fixture rule
# ("fixtures are recorded, never authored").
#
# <ticket-id> is matched to a herdr agent/workspace the same way
# herdr-ticket-start.sh names one when it opens it: the LOWERCASED ticket
# id (e.g. `nwm-44`) is the herdr agent name.
#
# `watch` = `herdr agent get <name>` (confirm the agent exists at all —
# a clear "no such agent" beats an ambiguous wait timeout) followed by
# `herdr agent wait <name> [--until STATE...] [--timeout MS]`, printing
# the final agent JSON. `--until`/`--timeout` are passed straight through
# to `herdr agent wait`; see fixtures/agent-wait-help.txt for their
# semantics (no `--until` waits for idle/done/blocked; no `--timeout`
# waits indefinitely).
#
# `stop` = `herdr agent get <name>` to find the agent's workspace_id,
# then `herdr workspace close <workspace_id>` (fixtures/workspace-close.json
# recorded against a throwaway target: `{"id":"cli:workspace:close",
# "result":{"type":"ok"}}`). There is no `herdr agent stop` — closing the
# owning workspace is how a herdr-managed agent pane goes away. An agent
# with no workspace_id (a bare pane never opened as a workspace) is a
# stop2 — no live capture of that shape exists, so this refuses loudly
# instead of guessing at a `herdr pane close` call nothing here has ever
# recorded. Wiring a pane-close fallback is a documented follow-up, not
# code, until a real spike records what that response looks like.
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
#       unparseable JSON, an agent with no workspace_id to close) — same
#       stop2 split herdr-ticket-start.sh and land-branch.sh use.
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kit.sh
. "$DIR/lib/kit.sh"

# stop2 — a precondition could not be evaluated at all (tool missing,
# unparseable JSON, an agent with no workspace_id). Distinct from die()
# (exit 1, "a check failed") — see this file's own exit-code contract.
stop2() { echo "Error: $*" >&2; exit 2; }

# lowercase_branch TICKET_ID — the herdr agent/branch name for a ticket,
# matching herdr-ticket-start.sh's own convention.
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
