#!/bin/bash
#
# read-shunt-selftest.sh — assertions for read-shunt.sh.
#
# Feeds the hook synthetic PreToolUse JSON on stdin: the
# `.tool_name`/`.tool_input`/`.session_id`/`.cwd` shape documented for
# Claude Code's PreToolUse hooks, exercising `.tool_input.file_path` for
# Read and `.session_id` for the escape-hatch dedupe.
#
# The `claude -p --model haiku "..." < /dev/null` invocation is never run
# for real here — every test below stubs `claude` on PATH instead, per this
# project's testing-philosophy.md: negative-path tests never call the real
# binary in a hot loop.
#
# Per this project's testing-philosophy.md self-verification-independence
# rule ("a check that has only ever passed has not actually been tested"):
# this selftest was proven discriminating during authoring, not just
# exercised.
#
# The mutant that DOES discriminate, and is the one to reproduce: remove
# read-shunt.sh's `if is_secret_path "$LOWER_PHYSICAL"; then exit 0; fi`
# block entirely. Run against the resulting mutant, this selftest's group 7
# assertions ("secrets-bearing .env file is never shunted" and its
# siblings) fail red (rc mismatches, summariser invoked when it must not
# be); run against the real, unmutated script, the same assertions pass
# green. READ_SHUNT_SCRIPT lets any mutant be pointed at without editing
# this file, e.g.:
#   cp read-shunt.sh /tmp/mutant.sh && <remove the is_secret_path block>
#   READ_SHUNT_SCRIPT=/tmp/mutant.sh ./read-shunt-selftest.sh   # expect FAIL
#   ./read-shunt-selftest.sh                                    # expect PASS
#
# Exit 0 if every assertion passes, 1 on the first failure summary printed.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

SCRIPT="${READ_SHUNT_SCRIPT:-$HERE/read-shunt.sh}"

[ -x "$SCRIPT" ] || { echo "read-shunt-selftest.sh: $SCRIPT not found or not executable" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "read-shunt-selftest.sh: jq required" >&2; exit 1; }

SCRATCH="${CLAUDE_SCRATCHPAD:-${TMPDIR:-/tmp}/read-shunt-selftest.$$}"
WORKDIR="$SCRATCH/read-shunt-selftest.$$"
mkdir -p "$WORKDIR"
# shellcheck disable=SC2329 # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

STATE_ROOT="$WORKDIR/state"
STUBBIN="$WORKDIR/stubbin"
mkdir -p "$STATE_ROOT" "$STUBBIN"

# A minimal, explicit PATH containing only what read-shunt.sh and this
# selftest actually need (jq/wc/awk/sed/env, plus bash builtins) and
# deliberately excluding wherever the REAL `claude` binary lives on this
# machine. Prepending a stub dir to the ambient $PATH is not enough for the
# "claude is unreachable" scenario — the ambient $PATH still resolves the
# real binary right behind the stub dir, which would make that test invoke
# the real network-calling `claude -p --model haiku` (found the hard way:
# the first run of this selftest hung past its own foreground timeout on
# exactly this).
MINIMAL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# --- Stub `claude` binaries --------------------------------------------------

STUB_OK="$STUBBIN/claude"
cat > "$STUB_OK" << 'EOF'
#!/bin/bash
# Records that it was invoked (proves/disproves whether the hook actually
# called out to the summariser), then prints a canned summary.
[ -n "${STUB_SENTINEL:-}" ] && : > "$STUB_SENTINEL"
echo "STUB SUMMARY: canned haiku response, never a real API call."
EOF
chmod +x "$STUB_OK"

STUB_FAIL="$WORKDIR/stubbin-fail/claude"
mkdir -p "$(dirname "$STUB_FAIL")"
cat > "$STUB_FAIL" << 'EOF'
#!/bin/bash
[ -n "${STUB_SENTINEL:-}" ] && : > "$STUB_SENTINEL"
exit 1
EOF
chmod +x "$STUB_FAIL"

STUB_HANG="$WORKDIR/stubbin-hang/claude"
mkdir -p "$(dirname "$STUB_HANG")"
cat > "$STUB_HANG" << 'EOF'
#!/bin/bash
[ -n "${STUB_SENTINEL:-}" ] && : > "$STUB_SENTINEL"
sleep 60
echo "should never be seen — killed by the hook's own timeout first"
EOF
chmod +x "$STUB_HANG"

# --- Fixture files ------------------------------------------------------------

mk_lines() {
  # $1 = path, $2 = line count
  awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "line " i }' > "$1"
}

F399="$WORKDIR/f399.txt";      mk_lines "$F399" 399
F400="$WORKDIR/f400.txt";      mk_lines "$F400" 400
F401="$WORKDIR/f401.txt";      mk_lines "$F401" 401
F_ZERO="$WORKDIR/zero.txt";    : > "$F_ZERO"
F_SECRET="$WORKDIR/creds.env"; mk_lines "$F_SECRET" 900
F_UNREADABLE="$WORKDIR/no-read.txt"; mk_lines "$F_UNREADABLE" 900; chmod 000 "$F_UNREADABLE"

# --- run_hook: build a Read-tool payload and run the hook under a given
# claude-stub directory, session id, and (optional) extra env. Prints the
# hook's exit code on stdout as "RC=<n>" first line, then its stderr. ------

run_hook() {
  # $1 = tool_name, $2 = file_path or command (per tool), $3 = session_id,
  # $4 = stub bin dir to prepend to PATH (empty = no claude on PATH at all),
  # $5 = extra timeout override (seconds, empty = default)
  _tool="$1"; _target="$2"; _session="$3"; _stubdir="$4"; _timeout="$5"

  if [ "$_tool" = "Read" ]; then
    _payload="$(jq -n --arg tn "$_tool" --arg sid "$_session" --arg fp "$_target" --arg cwd "$WORKDIR" \
      '{tool_name: $tn, session_id: $sid, cwd: $cwd, tool_input: {file_path: $fp}}')"
  else
    _payload="$(jq -n --arg tn "$_tool" --arg sid "$_session" --arg cmd "$_target" --arg cwd "$WORKDIR" \
      '{tool_name: $tn, session_id: $sid, cwd: $cwd, tool_input: {command: $cmd}}')"
  fi

  if [ -n "$_stubdir" ]; then
    _env_path="$_stubdir:$MINIMAL_PATH"
  else
    # No stub at all: deliberately the minimal PATH, not the ambient one,
    # so the REAL claude binary is genuinely unreachable (see MINIMAL_PATH
    # comment above) rather than silently found further down $PATH.
    _env_path="$MINIMAL_PATH"
  fi

  _timeout_env=""
  [ -n "$_timeout" ] && _timeout_env="READ_SHUNT_TIMEOUT=$_timeout"

  # shellcheck disable=SC2086 # deliberate word-split: an empty _timeout_env must vanish, not pass "" as an env(1) arg
  echo "$_payload" | env PATH="$_env_path" READ_SHUNT_STATE_ROOT="$STATE_ROOT" $_timeout_env "$SCRIPT" 2>"$WORKDIR/.last_stderr"
  echo "RC=$?"
}

last_stderr() { cat "$WORKDIR/.last_stderr" 2>/dev/null; }

assert_rc() {
  # $1 = description, $2 = expected rc, $3 = actual run_hook() combined output
  _desc="$1"; _expect="$2"; _out="$3"
  _rc="$(printf '%s\n' "$_out" | tail -n1 | sed -n 's/^RC=//p')"
  if [ "$_rc" = "$_expect" ]; then
    pass "$_desc (rc=$_rc)"
  else
    fail "$_desc (expected rc=$_expect, got rc=${_rc:-<none>})"
  fi
}

# =============================================================================
# 1. Corrupt / truncated hook-input JSON -> fails open (rc=0)
# =============================================================================

OUT="$(printf '{"tool_name": "Read", "tool_in' | env PATH="$STUBBIN:$PATH" READ_SHUNT_STATE_ROOT="$STATE_ROOT" "$SCRIPT" 2>"$WORKDIR/.last_stderr"; echo "RC=$?")"
assert_rc "truncated JSON fails open" "0" "$OUT"

# =============================================================================
# 2. Empty stdin -> fails open (rc=0)
# =============================================================================

OUT="$(printf '' | env PATH="$STUBBIN:$PATH" READ_SHUNT_STATE_ROOT="$STATE_ROOT" "$SCRIPT" 2>"$WORKDIR/.last_stderr"; echo "RC=$?")"
assert_rc "empty stdin fails open" "0" "$OUT"

# =============================================================================
# 3. Zero-length file -> under threshold, never shunted (rc=0), stub NOT
#    invoked (below-threshold files never reach the summariser at all)
# =============================================================================

SENT="$WORKDIR/sentinel.zero"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Read "$F_ZERO" "sess-zero" "$STUBBIN" "")"
assert_rc "zero-length file is not shunted" "0" "$OUT"
if [ -e "$SENT" ]; then fail "zero-length file: summariser was invoked (should not be)"; else pass "zero-length file: summariser not invoked"; fi

# =============================================================================
# 4. Unreadable line count (permission denied) -> fails open (rc=0)
# =============================================================================

OUT="$(run_hook Read "$F_UNREADABLE" "sess-unreadable" "$STUBBIN" "")"
assert_rc "permission-denied file fails open" "0" "$OUT"

# =============================================================================
# 5. Threshold boundary: 399 / 400 / 401 lines
# =============================================================================

SENT="$WORKDIR/sentinel.399"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Read "$F399" "sess-399" "$STUBBIN" "")"
assert_rc "399 lines: under threshold, not shunted" "0" "$OUT"
if [ -e "$SENT" ]; then fail "399 lines: summariser was invoked (should not be)"; else pass "399 lines: summariser not invoked"; fi

SENT="$WORKDIR/sentinel.400"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Read "$F400" "sess-400" "$STUBBIN" "")"
assert_rc "400 lines: AT threshold (not OVER), not shunted" "0" "$OUT"
if [ -e "$SENT" ]; then fail "400 lines: summariser was invoked (should not be)"; else pass "400 lines: summariser not invoked"; fi

SENT="$WORKDIR/sentinel.401"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Read "$F401" "sess-401" "$STUBBIN" "")"
assert_rc "401 lines: over threshold, shunted" "2" "$OUT"
if [ -e "$SENT" ]; then pass "401 lines: summariser was invoked"; else fail "401 lines: summariser NOT invoked (should be)"; fi
case "$(last_stderr)" in
  *"STUB SUMMARY"*) pass "401 lines: shunt stderr carries the summary" ;;
  *) fail "401 lines: shunt stderr missing the summary: $(last_stderr)" ;;
esac
case "$(last_stderr)" in
  *"read this same path again"*) pass "401 lines: shunt stderr documents the escape hatch" ;;
  *) fail "401 lines: shunt stderr does not mention the escape hatch" ;;
esac

# =============================================================================
# 6. Escape hatch: same (session, path) read again -> served unshunted (rc=0)
# =============================================================================

OUT="$(run_hook Read "$F401" "sess-401" "$STUBBIN" "")"
assert_rc "escape hatch: second read of same file+session is unshunted" "0" "$OUT"

# A DIFFERENT session reading the same file is shunted again (per-session,
# not global, dedupe).
SENT="$WORKDIR/sentinel.401b"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Read "$F401" "sess-401-other" "$STUBBIN" "")"
assert_rc "escape hatch is per-session: new session re-shunts" "2" "$OUT"

# =============================================================================
# 7. Secrets path is never shunted, even huge, even first read in a fresh
#    session — summariser must not be invoked at all.
# =============================================================================

SENT="$WORKDIR/sentinel.secret"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Read "$F_SECRET" "sess-secret" "$STUBBIN" "")"
assert_rc "secrets-bearing .env file is never shunted" "0" "$OUT"
if [ -e "$SENT" ]; then fail "secrets file: summariser was invoked (should NEVER be)"; else pass "secrets file: summariser never invoked"; fi

# docker/env/ path form, even with an innocuous filename
SECDIR="$WORKDIR/docker/env"; mkdir -p "$SECDIR"
F_SECRET2="$SECDIR/stack.env.tpl"; mk_lines "$F_SECRET2" 900
SENT="$WORKDIR/sentinel.secret2"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Read "$F_SECRET2" "sess-secret2" "$STUBBIN" "")"
assert_rc "docker/env/ path is never shunted" "0" "$OUT"
if [ -e "$SENT" ]; then fail "docker/env/ path: summariser was invoked (should NEVER be)"; else pass "docker/env/ path: summariser never invoked"; fi

# 7a. Case-variance directory aliasing (review finding 1, CRITICAL
# repro): reading the SAME file through a differently-cased path to its
# excluded directory must still exclude it. This assumes a case-insensitive,
# case-preserving filesystem (the default macOS APFS volume this hook is
# meant to run on — see read-shunt.sh's own header on why that's the
# intended environment, not a portability gap).
F_SECRET3="$SECDIR/plain-name.txt"; mk_lines "$F_SECRET3" 900
UPPERCASED_PATH="$WORKDIR/DOCKER/ENV/plain-name.txt"
SENT="$WORKDIR/sentinel.secret3"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Read "$UPPERCASED_PATH" "sess-secret3" "$STUBBIN" "")"
assert_rc "docker/env/ via a case-varied path is still excluded" "0" "$OUT"
if [ -e "$SENT" ]; then fail "case-varied docker/env/ path: summariser was invoked (should NEVER be)"; else pass "case-varied docker/env/ path: summariser never invoked"; fi

# 7b. Literal mixed-case basename, no filesystem aliasing involved at all
# (review finding 3, HIGH repro): only three fixed case forms
# used to be matched; this is neither of them.
F_SECRET4="$WORKDIR/DbToKen-dump.txt"; mk_lines "$F_SECRET4" 900
SENT="$WORKDIR/sentinel.secret4"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Read "$F_SECRET4" "sess-secret4" "$STUBBIN" "")"
assert_rc "mixed-case 'DbToKen' basename is excluded" "0" "$OUT"
if [ -e "$SENT" ]; then fail "mixed-case basename: summariser was invoked (should NEVER be)"; else pass "mixed-case basename: summariser never invoked"; fi

# 7c. A symlink whose NAME is innocuous but whose TARGET is secrets-bearing
# (review finding 2, CRITICAL repro): the exclusion has to follow
# the symlink, not just pattern-match the name it was reached by.
F_SECRET5="$WORKDIR/prod.env"; mk_lines "$F_SECRET5" 900
SYMLINK_TO_SECRET="$WORKDIR/notes.txt"
ln -sf "$F_SECRET5" "$SYMLINK_TO_SECRET"
SENT="$WORKDIR/sentinel.secret5"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Read "$SYMLINK_TO_SECRET" "sess-secret5" "$STUBBIN" "")"
assert_rc "innocuously-named symlink to a secrets file is excluded" "0" "$OUT"
if [ -e "$SENT" ]; then fail "symlink to secret: summariser was invoked (should NEVER be)"; else pass "symlink to secret: summariser never invoked"; fi

# =============================================================================
# 7d. Marker-key collision resistance (review finding 4, MEDIUM
#     repro): two DISTINCT paths that collided under the old naive
#     `tr '/' '_'` scheme must still be tracked as two distinct shunts —
#     reading the second must NOT be silently treated as "already shunted".
# =============================================================================

mkdir -p "$WORKDIR/coll/a" "$WORKDIR/coll/a_b"
COLL_A="$WORKDIR/coll/a/b_c.txt";  mk_lines "$COLL_A" 900
COLL_B="$WORKDIR/coll/a_b/c.txt";  mk_lines "$COLL_B" 900

SENT="$WORKDIR/sentinel.colla"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Read "$COLL_A" "sess-coll" "$STUBBIN" "")"
assert_rc "marker-collision fixture, path A: first read is shunted" "2" "$OUT"
if [ -e "$SENT" ]; then pass "marker-collision path A: summariser was invoked"; else fail "marker-collision path A: summariser NOT invoked (should be)"; fi

SENT="$WORKDIR/sentinel.collb"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Read "$COLL_B" "sess-coll" "$STUBBIN" "")"
assert_rc "marker-collision fixture, path B (same session): still shunted, not mistaken for A's marker" "2" "$OUT"
if [ -e "$SENT" ]; then pass "marker-collision path B: summariser was invoked"; else fail "marker-collision path B: summariser NOT invoked — old naive key derivation would have collided with path A and wrongly skipped this"; fi

# =============================================================================
# 8. Fail-open when the haiku subprocess is unreachable
# =============================================================================

# 8a. claude not on PATH at all
OUT="$(run_hook Read "$F401" "sess-nobin" "" "")"
assert_rc "claude not on PATH: fails open" "0" "$OUT"

# 8b. claude exits non-zero
STUB_FAIL_DIR="$(dirname "$STUB_FAIL")"
OUT="$(run_hook Read "$F401" "sess-failbin" "$STUB_FAIL_DIR" "")"
assert_rc "claude exits non-zero: fails open" "0" "$OUT"

# 8c. claude hangs past the timeout — bounded with a short READ_SHUNT_TIMEOUT
# so this test itself stays fast; proves the hand-rolled kill actually fires.
STUB_HANG_DIR="$(dirname "$STUB_HANG")"
_start=$(date +%s)
OUT="$(run_hook Read "$F401" "sess-hangbin" "$STUB_HANG_DIR" "2")"
_elapsed=$(( $(date +%s) - _start ))
assert_rc "claude hangs: fails open once timeout fires" "0" "$OUT"
if [ "$_elapsed" -le 10 ]; then
  pass "claude hangs: hook returned promptly after timeout ($_elapsed s)"
else
  fail "claude hangs: hook took too long to return ($_elapsed s) — timeout/kill not working"
fi

# =============================================================================
# 9. Bash cat-equivalent detection
# =============================================================================

SENT="$WORKDIR/sentinel.catplain"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Bash "cat $F401" "sess-catplain" "$STUBBIN" "")"
assert_rc "bare 'cat <big file>' is shunted like Read" "2" "$OUT"
if [ -e "$SENT" ]; then pass "bare cat: summariser was invoked"; else fail "bare cat: summariser NOT invoked (should be)"; fi

OUT="$(run_hook Bash "cat $F399" "sess-catsmall" "$STUBBIN" "")"
assert_rc "bare 'cat <small file>' is not shunted" "0" "$OUT"

SENT="$WORKDIR/sentinel.catpipe"; rm -f "$SENT"
OUT="$(STUB_SENTINEL="$SENT" run_hook Bash "cat $F401 | grep foo" "sess-catpipe" "$STUBBIN" "")"
assert_rc "'cat | grep' (piped) is left alone, not parsed" "0" "$OUT"
if [ -e "$SENT" ]; then fail "cat | grep: summariser was invoked (should not be, ambiguous)"; else pass "cat | grep: summariser not invoked"; fi

OUT="$(run_hook Bash "cat $F401 $F399" "sess-cattwo" "$STUBBIN" "")"
assert_rc "'cat file1 file2' (two args) is left alone" "0" "$OUT"

# shellcheck disable=SC2016 # deliberate literal $SOME_VAR text in the fake command, not expanded here
OUT="$(run_hook Bash 'cat $SOME_VAR' "sess-catvar" "$STUBBIN" "")"
assert_rc "'cat \$VAR' (unresolved variable) is left alone" "0" "$OUT"

OUT="$(run_hook Bash "grep foo $F401" "sess-grepnotcat" "$STUBBIN" "")"
assert_rc "non-cat Bash command is left alone" "0" "$OUT"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "read-shunt-selftest.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
