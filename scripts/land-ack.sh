#!/bin/bash
#
# land-ack.sh — the consumer end of land-branch.sh's orchestrator notification.
#
# Usage: land-ack.sh <ack-file>
#   Creates the ack file named in a "closing state is in the tracker"
#   notification so the waiting land-branch.sh sees the acknowledgement.
#   Refuses any path whose basename does not start with nw-ack-, so a
#   mistyped or hostile notification cannot make it touch arbitrary files.

set -euo pipefail
# shellcheck source=lib/kit.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/kit.sh"

case "${1:-}" in
    -h|--help) show_help ;;
    "") die "usage: land-ack.sh <ack-file>" ;;
esac
[ $# -eq 1 ] || die "usage: land-ack.sh <ack-file> (got $# arguments)"

ACK_FILE="$1"
case "$(basename "$ACK_FILE")" in
    nw-ack-*) ;;
    *) die "refusing '$ACK_FILE': an ack file is named nw-ack-<ticket>-<sha>" ;;
esac
[ -d "$(dirname "$ACK_FILE")" ] || die "no such directory for the ack file: $(dirname "$ACK_FILE")"
: > "$ACK_FILE" || die "could not create '$ACK_FILE'"
echo "acknowledged: $ACK_FILE"
