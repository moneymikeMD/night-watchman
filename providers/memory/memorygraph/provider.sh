#!/bin/bash
#
# provider.sh — memorygraph's implementation of the `memory` provider kind
# (verbs: store, recall — see ../../README.md for the contract). Dispatch
# only; the work is in the sibling script named after each verb.
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

verb="${1:-}"
[ -n "$verb" ] && shift

case "$verb" in
    store)  exec "$DIR/store.sh" "$@" ;;
    recall) exec "$DIR/recall.sh" "$@" ;;
    "")     echo "Error: usage: provider.sh VERB [ARG...] (verbs: store, recall)" >&2; exit 1 ;;
    *)      echo "Error: unknown memory verb: $verb (contract: store, recall)" >&2; exit 1 ;;
esac
