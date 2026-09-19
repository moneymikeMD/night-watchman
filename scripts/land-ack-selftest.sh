#!/bin/bash
#
# Selftest for land-ack.sh. Structurally offline: the script only creates a
# file, and every case runs against a mktemp directory removed on exit.
#
# Usage: scripts/land-ack-selftest.sh [path-to-land-ack.sh]

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ACK="${1:-$HERE/land-ack.sh}"
[ -x "$ACK" ] || { echo "cannot execute $ACK" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# run_ack ARGS... — sets RC, OUT and ERR from one invocation.
run_ack() {
    set +e
    "$ACK" "$@" >"$WORK/out" 2>"$WORK/err"
    RC=$?
    set -e
    OUT=$(cat "$WORK/out")
    ERR=$(cat "$WORK/err")
}

run_ack "$WORK/nw-ack-PROJ-1-abc12345"
if [ "$RC" -eq 0 ] && [ -e "$WORK/nw-ack-PROJ-1-abc12345" ] && [ -z "$ERR" ] \
    && [ "$OUT" = "acknowledged: $WORK/nw-ack-PROJ-1-abc12345" ]; then
    ok "well-named ack file is created, exit 0, confirmation on stdout, stderr empty"
else
    bad "well-named ack: rc=$RC out='$OUT' err='$ERR'"
fi

run_ack "$WORK/other-file"
if [ "$RC" -eq 1 ] && [ ! -e "$WORK/other-file" ] && [ -z "$OUT" ] \
    && [[ "$ERR" == *"refusing '$WORK/other-file': an ack file is named nw-ack-"* ]]; then
    ok "a name outside nw-ack-* is refused: exit 1, stderr names the rule, nothing created"
else
    bad "name refusal: rc=$RC out='$OUT' err='$ERR' exists=$([ -e "$WORK/other-file" ] && echo yes || echo no)"
fi

run_ack "$WORK/x-nw-ack-PROJ-1"
if [ "$RC" -eq 1 ] && [ ! -e "$WORK/x-nw-ack-PROJ-1" ] && [[ "$ERR" == *"refusing"* ]]; then
    ok "nw-ack- must be the prefix of the basename, not merely contained in it"
else
    bad "prefix refusal: rc=$RC err='$ERR'"
fi

mkdir -p "$WORK/dir-nw-ack-x"
run_ack "$WORK/dir-nw-ack-x/plain"
if [ "$RC" -eq 1 ] && [ ! -e "$WORK/dir-nw-ack-x/plain" ] && [[ "$ERR" == *"refusing"* ]]; then
    ok "only the basename counts: an nw-ack- directory does not legitimise a plain file"
else
    bad "basename-only refusal: rc=$RC err='$ERR'"
fi

run_ack "$WORK/no-such-dir/nw-ack-PROJ-1-abc"
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"no such directory for the ack file: $WORK/no-such-dir"* ]]; then
    ok "a missing parent directory is refused with exit 1 and a stderr message"
else
    bad "missing directory: rc=$RC err='$ERR'"
fi

run_ack
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"usage: land-ack.sh <ack-file>"* ]]; then
    ok "no argument: exit 1 with usage on stderr"
else
    bad "no argument: rc=$RC err='$ERR'"
fi

run_ack ""
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"usage: land-ack.sh <ack-file>"* ]]; then
    ok "an empty argument is a usage error, not an attempt to touch ''"
else
    bad "empty argument: rc=$RC err='$ERR'"
fi

run_ack "$WORK/nw-ack-a" "$WORK/nw-ack-b"
if [ "$RC" -eq 1 ] && [ ! -e "$WORK/nw-ack-a" ] && [[ "$ERR" == *"got 2 arguments"* ]]; then
    ok "two arguments: exit 1, nothing created"
else
    bad "two arguments: rc=$RC err='$ERR'"
fi

run_ack --help
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"Usage: land-ack.sh <ack-file>"* ]] && [ -z "$ERR" ]; then
    ok "--help prints the header on stdout, exit 0"
else
    bad "--help: rc=$RC out='$OUT' err='$ERR'"
fi

echo
echo "$PASS passed, $FAIL failed (against: $ACK)"
[ "$FAIL" -eq 0 ]
