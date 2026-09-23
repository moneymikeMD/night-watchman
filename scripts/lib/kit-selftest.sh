#!/bin/bash
#
# Assertions for kit.sh's tmpfile registry and exit hooks (NWM-155).
#
# The defect this pins: tmpfile() registered its cleanup trap inside the
# $(tmpfile) subshell, so the trap fired on the subshell's exit, the file was
# removed before the caller saw the path, and the caller recreated it with a
# plain redirect at the default umask. 0644 instead of 0600, and a leak into
# TMPDIR on every run.
#
# Run with no argument, every assertion runs against all three copies of
# kit.sh, which must stay code-identical apart from herdr_notify. Run with a
# pre-fix copy as the argument, the same assertions run against that copy and
# fail, which is what makes a clean run mean something.
#
# Every case points TMPDIR at a scratch directory. macOS `mktemp -d` with no
# template ignores TMPDIR and would make that vacuous; kit.sh passes a
# template, which is honoured — asserted below rather than assumed.
#
# Usage: ./scripts/lib/kit-selftest.sh [pre-fix-kit.sh]
# Offline: no network, no credential, no shared state. Exit 0 if every
# assertion passes, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

FAIL=0
FAILED_NUMS=""
N=0
pass() { N=$((N + 1)); echo "PASS $N: $1"; }
fail() {
  N=$((N + 1)); echo "FAIL $N: $1" >&2
  FAIL=$((FAIL + 1))
  FAILED_NUMS="${FAILED_NUMS:+$FAILED_NUMS,}$N"
}
assert_eq() {
  desc="$1"; want="$2"; got="$3"
  if [ "$want" = "$got" ]; then
    pass "$desc (want '$want', got '$got')"
  else
    fail "$desc (want '$want', got '$got')"
  fi
}

WORK="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
# shellcheck disable=SC2329  # invoked indirectly by the EXIT trap below
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Each stub sources the kit under test, does something, and records what it
# saw from INSIDE the run. A mode read after exit is a mode read on a file
# that should not exist, so the stub reads it, not the harness.

write_stub() {
  cat > "$WORK/stub.sh"
  chmod +x "$WORK/stub.sh"
}

TD=""
RC=0
# run_stub KIT — fresh scratch TMPDIR in $TD, run the stub against KIT.
run_stub() {
  TD="$WORK/td"
  rm -rf "$TD"; mkdir -p "$TD"
  rm -f "$WORK/result" "$WORK/mark"
  # An inner bash does the waiting: a shell that waits on a signal-killed
  # child prints "Terminated: 15" to ITS OWN stderr, which no redirection on
  # the command suppresses.
  RC=$(TMPDIR="$TD" KIT="$1" RESULT="$WORK/result" MARK="$WORK/mark" \
       bash -c '"$0" >/dev/null 2>&1; echo $?' "$WORK/stub.sh" 2>/dev/null)
}
td_count() { find "$TD" -mindepth 1 2>/dev/null | wc -l | tr -d ' '; }

run_cases() {
  KIT="$1"; LABEL="$2"

  # --- one tempfile: honoured TMPDIR, 0600 while alive, gone after ---------
  write_stub <<'STUB'
#!/bin/bash
set -uo pipefail
. "$KIT"
f=$(tmpfile)
echo "SECRET-MARKER" > "$f"
stat -f '%Lp' "$f" > "$RESULT"
printf '%s\n' "$f" >> "$RESULT"
STUB
  run_stub "$KIT"
  created="$(sed -n '2p' "$WORK/result" 2>/dev/null)"
  mode="$(sed -n '1p' "$WORK/result" 2>/dev/null)"

  case "$created" in
    "$TD"/*) pass "$LABEL: tmpfile honours TMPDIR, so the absence assertions below are not vacuous ('$created')" ;;
    *)       fail "$LABEL: tmpfile honours TMPDIR, so the absence assertions below are not vacuous ('$created')" ;;
  esac
  assert_eq "$LABEL: the tempfile is 0600 while its creator is alive" "600" "$mode"
  assert_eq "$LABEL: the tempfile is gone once its creator exits, registry included" "0" "$(td_count)"

  # --- several tempfiles in one run ----------------------------------------
  write_stub <<'STUB'
#!/bin/bash
set -uo pipefail
. "$KIT"
: > "$RESULT"
for i in 1 2 3; do
  f=$(tmpfile)
  echo "body $i" > "$f"
  stat -f '%Lp' "$f" >> "$RESULT"
done
STUB
  run_stub "$KIT"
  assert_eq "$LABEL: three tempfiles in one run are each 0600 while alive" \
    "600 600 600" "$(tr '\n' ' ' < "$WORK/result" 2>/dev/null | sed 's/ $//')"
  assert_eq "$LABEL: all three are gone once the creator exits" "0" "$(td_count)"

  # --- the count does not grow across runs ---------------------------------
  before="$(td_count)"
  TMPDIR="$TD" KIT="$KIT" RESULT="$WORK/result" MARK="$WORK/mark" "$WORK/stub.sh" >/dev/null 2>&1
  assert_eq "$LABEL: a second run leaves the TMPDIR count where it was" "$before" "$(td_count)"

  # --- SIGTERM mid-run ------------------------------------------------------
  write_stub <<'STUB'
#!/bin/bash
set -uo pipefail
. "$KIT"
f=$(tmpfile)
echo "in flight" > "$f"
kill -TERM $$
sleep 5
STUB
  run_stub "$KIT"
  assert_eq "$LABEL: a SIGTERM mid-run still cleans up" "0" "$(td_count)"
  assert_eq "$LABEL: a SIGTERM is re-raised, not swallowed — the script dies 128+15" "143" "$RC"

  # --- SIGINT mid-run -------------------------------------------------------
  write_stub <<'STUB'
#!/bin/bash
set -uo pipefail
. "$KIT"
f=$(tmpfile)
echo "in flight" > "$f"
kill -INT $$
sleep 5
STUB
  run_stub "$KIT"
  assert_eq "$LABEL: a SIGINT mid-run still cleans up" "0" "$(td_count)"
  assert_eq "$LABEL: a SIGINT is re-raised, not swallowed — the script dies 128+2" "130" "$RC"

  # --- kit_on_exit runs the caller's cleanup AND kit's ----------------------
  write_stub <<'STUB'
#!/bin/bash
set -uo pipefail
. "$KIT"
mine() { echo ran > "$MARK"; }
kit_on_exit mine
f=$(tmpfile)
echo "body" > "$f"
STUB
  run_stub "$KIT"
  assert_eq "$LABEL: a cleanup registered with kit_on_exit runs" "ran" "$(cat "$WORK/mark" 2>/dev/null)"
  assert_eq "$LABEL: kit's own cleanup still runs alongside it" "0" "$(td_count)"

  # --- sourcing stays side-effect-light ------------------------------------
  # A script that never calls tmpfile must survive a kit.sh sourced where
  # mktemp is unreachable, and one that does call it must be told why.
  write_stub <<'STUB'
#!/bin/bash
set -uo pipefail
PATH="$EMPTYBIN"
. "$KIT"
echo sourced > "$RESULT"
f=$(tmpfile) || echo "tmpfile refused" >> "$RESULT"
STUB
  mkdir -p "$WORK/emptybin"
  TD="$WORK/td"; rm -rf "$TD"; mkdir -p "$TD"; rm -f "$WORK/result"
  ( TMPDIR="$TD" KIT="$KIT" RESULT="$WORK/result" EMPTYBIN="$WORK/emptybin" \
    "$WORK/stub.sh" >/dev/null 2>&1 )
  assert_eq "$LABEL: sourcing kit.sh with mktemp unreachable does not kill the script" \
    "sourced" "$(sed -n '1p' "$WORK/result" 2>/dev/null)"
  assert_eq "$LABEL: but tmpfile itself then refuses rather than returning a path" \
    "tmpfile refused" "$(sed -n '2p' "$WORK/result" 2>/dev/null)"

  # --- exec: the path no EXIT trap survives --------------------------------
  # NWM-171. exec replaces the process image, so nothing registered on EXIT
  # runs. providers/lib/provider.sh execs on every verb call, which leaked a
  # registry file each time until kit_exec.
  write_stub <<'STUB'
#!/bin/bash
set -uo pipefail
. "$KIT"
f=$(tmpfile)
echo "body" > "$f"
exec /bin/echo bare-exec
STUB
  run_stub "$KIT"
  bare="$(td_count)"
  if [ "$bare" -gt 0 ]; then
    pass "$LABEL: a bare exec after sourcing leaks, which is why kit_exec exists ($bare file(s) left)"
  else
    fail "$LABEL: a bare exec after sourcing leaks, which is why kit_exec exists ($bare file(s) left)"
  fi

  write_stub <<'STUB'
#!/bin/bash
set -uo pipefail
. "$KIT"
f=$(tmpfile)
echo "body" > "$f"
kit_exec /bin/echo one two three > "$RESULT"
STUB
  run_stub "$KIT"
  assert_eq "$LABEL: kit_exec leaves nothing behind — no tempfile, no registry" "0" "$(td_count)"
  assert_eq "$LABEL: and the exec'd program still runs, with its arguments intact" \
    "one two three" "$(cat "$WORK/result" 2>/dev/null)"

  # A cleanup-by-not-exec'ing would pass the two above, so pin the status too.
  write_stub <<'STUB'
#!/bin/bash
set -uo pipefail
. "$KIT"
kit_exec /bin/sh -c 'exit 7'
STUB
  run_stub "$KIT"
  assert_eq "$LABEL: the exec'd program's exit status is preserved" "7" "$RC"

  write_stub <<'STUB'
#!/bin/bash
set -uo pipefail
. "$KIT"
mine() { echo ran > "$MARK"; }
kit_on_exit mine
kit_exec /bin/echo done
STUB
  run_stub "$KIT"
  assert_eq "$LABEL: a kit_on_exit cleanup runs before the exec, not never" \
    "ran" "$(cat "$WORK/mark" 2>/dev/null)"

  # --- and the hazard kit_on_exit exists for -------------------------------
  # A raw `trap ... EXIT` after sourcing replaces kit's handler. This is
  # behaviour, not a caveat in a comment, so it is asserted.
  write_stub <<'STUB'
#!/bin/bash
set -uo pipefail
. "$KIT"
trap 'echo ran > "$MARK"' EXIT
f=$(tmpfile)
echo "body" > "$f"
STUB
  run_stub "$KIT"
  clobbered="$(td_count)"
  if [ "$clobbered" -gt 0 ]; then
    pass "$LABEL: a raw 'trap ... EXIT' after sourcing clobbers kit's cleanup, which is why kit_on_exit exists ($clobbered file(s) left)"
  else
    fail "$LABEL: a raw 'trap ... EXIT' after sourcing clobbers kit's cleanup, which is why kit_on_exit exists ($clobbered file(s) left)"
  fi
}

if [ $# -ge 1 ]; then
  [ -f "$1" ] || { echo "no such kit.sh: $1" >&2; exit 1; }
  run_cases "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" "given"
else
  run_cases "$REPO/scripts/lib/kit.sh"                    "scripts/lib"
  run_cases "$REPO/providers/lib/kit.sh"                  "providers/lib"
  run_cases "$REPO/providers/dispatch/herdr/lib/kit.sh"   "herdr/lib"

  # --- the three copies have not drifted -----------------------------------
  strip() { grep -vE '^[[:space:]]*#' "$1" | grep -vE '^[[:space:]]*$'; }
  assert_eq "providers/lib/kit.sh and herdr/lib/kit.sh are code-identical" "" \
    "$(diff <(strip "$REPO/providers/lib/kit.sh") <(strip "$REPO/providers/dispatch/herdr/lib/kit.sh"))"
  assert_eq "scripts/lib/kit.sh differs from providers/lib/kit.sh only by herdr_notify" \
    "herdr_notify" \
    "$(diff <(strip "$REPO/scripts/lib/kit.sh") <(strip "$REPO/providers/lib/kit.sh") \
       | grep -E '^[<>]' | grep -oE 'herdr_notify' | head -1)"
  assert_eq "and by nothing else — three lines of difference, all herdr_notify's" "3" \
    "$(diff <(strip "$REPO/scripts/lib/kit.sh") <(strip "$REPO/providers/lib/kit.sh") \
       | grep -cE '^[<>]')"
fi

echo
echo "$N assertion(s), $((N - FAIL)) passed, $FAIL failed" >&2
if [ "$FAIL" -ne 0 ]; then
  echo "failing assertion(s): $FAILED_NUMS" >&2
  echo "kit-selftest.sh: FAILED" >&2
  exit 1
fi
echo "kit-selftest.sh: all assertions passed" >&2
exit 0
