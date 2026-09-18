#!/bin/bash
#
# script-events-hook-selftest.sh — assertions for script-events-hook.sh.
#
# Feeds the hook synthetic SubagentStop JSON on stdin (session_id,
# transcript_path, cwd, hook_event_name, agent_id, agent_type — the shape
# verified live 2026-09-10 against Claude Code 2.1.267, see the hook's own
# header). `python3` is stubbed on PATH throughout: the extractor
# (scripts/script-analytics.py) is never invoked for real here — negative-
# and positive-path tests alike drive a fake interpreter that records its
# own argv and returns a scripted exit code/stdout.
#
# CLAUDE_PROJECT_DIR always points at a scratch tree built by this selftest
# (WORKDIR), never the real repo, and SCRIPT_EVENTS_PROJECTS_DIR always
# points at a scratch fixture directory under WORKDIR — never
# ~/.claude/projects. This is the seam the shell-scripting skill requires:
# the hook is never invoked against the real transcript store from a test.
#
# Exit 0 if every assertion passes, 1 on the first failure summary printed.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

SCRIPT="${SCRIPT_EVENTS_HOOK_SCRIPT:-$HERE/script-events-hook.sh}"

[ -x "$SCRIPT" ] || { echo "script-events-hook-selftest.sh: $SCRIPT not found or not executable" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "script-events-hook-selftest.sh: jq required" >&2; exit 1; }

SCRATCH="${CLAUDE_SCRATCHPAD:-${TMPDIR:-/tmp}/script-events-hook-selftest.$$}"
WORKDIR="$SCRATCH/script-events-hook-selftest.$$"
mkdir -p "$WORKDIR"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Only the two paths the hook itself stats need to exist; the extractor's
# content is irrelevant because python3 is stubbed and never parses it.
PROJECT_ROOT="$WORKDIR/project"
mkdir -p "$PROJECT_ROOT/docs" "$PROJECT_ROOT/scripts"
: > "$PROJECT_ROOT/scripts/script-analytics.py"
EVENTS_FILE="$PROJECT_ROOT/docs/script-events.jsonl"

FIXTURE_PROJECTS="$WORKDIR/fixture-projects"
mkdir -p "$FIXTURE_PROJECTS"

STUBBIN="$WORKDIR/stubbin"
mkdir -p "$STUBBIN"

# A minimal PATH that deliberately excludes wherever a real `python3` lives: a
# stub dir prepended to the ambient PATH still resolves the real one behind it.
MINIMAL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# The stub mirrors script-analytics.py's contract: under --quiet, zero new
# events prints nothing. $STUB_SLEEP completes slowly; $STUB_HANG gets killed.
STUB_PY="$STUBBIN/python3"
cat > "$STUB_PY" << 'EOF'
#!/bin/bash
if [ -n "${STUB_ARGV_FILE:-}" ]; then
  : > "$STUB_ARGV_FILE"
  for a in "$@"; do printf '%s\n' "$a" >> "$STUB_ARGV_FILE"; done
fi
[ -n "${STUB_CALL_COUNT_FILE:-}" ] && printf 'x\n' >> "$STUB_CALL_COUNT_FILE"
if [ "${STUB_HANG:-0}" = "1" ]; then
  sleep 60
fi
if [ -n "${STUB_SLEEP:-}" ]; then
  sleep "$STUB_SLEEP"
fi
if [ -n "${STUB_OUT:-}" ]; then
  echo "$STUB_OUT"
fi
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$STUB_PY"

run_hook() {
  # $1 = hook_event_name, $2 = agent_id, $3 = agent_type, $4 = stub bin dir to
  # prepend to PATH (empty = no python3 at all), $5 = HOOK_TIMEOUT override,
  # $6 = extra payload field (used for the "fake secret in stdin" case).
  _event="$1"; _aid="$2"; _atype="$3"; _stubdir="$4"; _timeout="$5"; _extra="$6"

  _payload="$(jq -n --arg ev "$_event" --arg aid "$_aid" --arg atype "$_atype" \
    '{hook_event_name: $ev, agent_id: $aid, agent_type: $atype, session_id: "sess-x", transcript_path: "/tmp/fake-transcript.jsonl", cwd: "/tmp"}')"
  if [ -n "$_extra" ]; then
    _payload="$(printf '%s' "$_payload" | jq --arg v "$_extra" '. + {fake_field: $v}')"
  fi

  if [ -n "$_stubdir" ]; then
    _env_path="$_stubdir:$MINIMAL_PATH"
  else
    _env_path="$MINIMAL_PATH"
  fi

  _timeout_env=""
  [ -n "$_timeout" ] && _timeout_env="SCRIPT_EVENTS_HOOK_TIMEOUT=$_timeout"

  # shellcheck disable=SC2086 # deliberate word-split: an empty _timeout_env must vanish, not pass "" as an env(1) arg
  printf '%s' "$_payload" | env PATH="$_env_path" CLAUDE_PROJECT_DIR="$PROJECT_ROOT" \
    SCRIPT_EVENTS_PROJECTS_DIR="$FIXTURE_PROJECTS" $_timeout_env "$SCRIPT" \
    >"$WORKDIR/.last_stdout" 2>"$WORKDIR/.last_stderr"
  echo "RC=$?"
}

last_stdout() { cat "$WORKDIR/.last_stdout" 2>/dev/null; }
last_stderr() { cat "$WORKDIR/.last_stderr" 2>/dev/null; }

assert_rc() {
  # $1 = description, $2 = expected rc, $3 = actual run_hook() output (just "RC=n")
  _desc="$1"; _expect="$2"; _out="$3"
  _rc="$(printf '%s\n' "$_out" | tail -n1 | sed -n 's/^RC=//p')"
  if [ "$_rc" = "$_expect" ]; then
    pass "$_desc (rc=$_rc)"
  else
    fail "$_desc (expected rc=$_expect, got rc=${_rc:-<none>})"
  fi
}

ARGV="$WORKDIR/argv.1"; rm -f "$ARGV"
OUT="$(STUB_ARGV_FILE="$ARGV" run_hook "PreToolUse" "agent-1" "script-author" "$STUBBIN" "" "")"
assert_rc "non-SubagentStop event: not acted on" "0" "$OUT"
if [ -e "$ARGV" ]; then fail "non-SubagentStop event: extractor was called (should not be)"; else pass "non-SubagentStop event: extractor not called"; fi

ARGV="$WORKDIR/argv.2"; rm -f "$ARGV"
OUT="$(STUB_ARGV_FILE="$ARGV" run_hook "SubagentStop" "" "script-author" "$STUBBIN" "" "")"
assert_rc "missing agent_id: not acted on" "0" "$OUT"
if [ -e "$ARGV" ]; then fail "missing agent_id: extractor was called (should not be)"; else pass "missing agent_id: extractor not called"; fi

ARGV="$WORKDIR/argv.3"; rm -f "$ARGV"
OUT="$(STUB_ARGV_FILE="$ARGV" run_hook "SubagentStop" "agent-3" "triage" "$STUBBIN" "" "")"
assert_rc "non-matching agent_type: not acted on" "0" "$OUT"
if [ -e "$ARGV" ]; then fail "non-matching agent_type: extractor was called (should not be)"; else pass "non-matching agent_type: extractor not called"; fi

ARGV="$WORKDIR/argv.4"; rm -f "$ARGV"
OUT="$(STUB_ARGV_FILE="$ARGV" STUB_OUT="# extract: 1 new, 0 already present" STUB_EXIT="0" \
  run_hook "SubagentStop" "agent-4" "script-author" "$STUBBIN" "" "")"
assert_rc "matching script-author: hook exits 0" "0" "$OUT"

if [ -e "$ARGV" ]; then
  pass "matching script-author: extractor was called"
  _argv="$(cat "$ARGV")"
  case "$_argv" in
    *"extract"*"--agent-id"*"agent-4"*"--events"*"$EVENTS_FILE"*"--quiet"*"--projects-dir"*"$FIXTURE_PROJECTS"*)
      pass "matching script-author: argv carries extract/--agent-id/--events/--quiet/--projects-dir as expected"
      ;;
    *)
      fail "matching script-author: unexpected argv: $_argv"
      ;;
  esac
else
  fail "matching script-author: extractor was NOT called (should be)"
fi

ARGV="$WORKDIR/argv.5"; rm -f "$ARGV"
OUT="$(STUB_ARGV_FILE="$ARGV" STUB_EXIT="2" run_hook "SubagentStop" "agent-5" "script-reviewer" "$STUBBIN" "" "")"
assert_rc "extractor exit 2: hook still exits 0" "0" "$OUT"
_err="$(last_stderr)"
case "$_err" in
  *"script-events-hook:"*"exited 2"*"agent-5"*"script-reviewer"*)
    pass "extractor exit 2: diagnostic carries agent_id, agent_type, exit code"
    ;;
  *)
    fail "extractor exit 2: diagnostic missing expected content: $_err"
    ;;
esac

ARGV="$WORKDIR/argv.6"; COUNT="$WORKDIR/count.6"; rm -f "$ARGV" "$COUNT"
OUT="$(STUB_ARGV_FILE="$ARGV" STUB_CALL_COUNT_FILE="$COUNT" STUB_OUT="" STUB_EXIT="0" \
  run_hook "SubagentStop" "agent-6" "script-author" "$STUBBIN" "" "")"
assert_rc "zero new events: hook exits 0 after retry" "0" "$OUT"
_calls="$(wc -l < "$COUNT" 2>/dev/null | tr -d '[:space:]')"
if [ "$_calls" = "2" ]; then
  pass "zero new events: extractor called exactly twice (initial + one retry)"
else
  fail "zero new events: expected 2 calls, got ${_calls:-0}"
fi

ARGV="$WORKDIR/argv.7"; rm -f "$ARGV"
SECRET="FAKE_SECRET_zzz_should_never_leak_9f31"
OUT="$(STUB_ARGV_FILE="$ARGV" STUB_OUT="# extract: 1 new, 0 already present" STUB_EXIT="0" \
  run_hook "SubagentStop" "agent-7" "script-author" "$STUBBIN" "" "$SECRET")"
assert_rc "fake secret in stdin: hook still runs normally" "0" "$OUT"
_stdout="$(last_stdout)"
_stderr="$(last_stderr)"
case "$_stdout$_stderr" in
  *"$SECRET"*) fail "fake secret in stdin: leaked into hook stdout/stderr" ;;
  *) pass "fake secret in stdin: never appears in hook stdout/stderr" ;;
esac

ARGV="$WORKDIR/argv.8"; rm -f "$ARGV"
_start=$(date +%s)
OUT="$(STUB_ARGV_FILE="$ARGV" STUB_HANG="1" run_hook "SubagentStop" "agent-8" "script-reviewer" "$STUBBIN" "2" "")"
_elapsed=$(( $(date +%s) - _start ))
assert_rc "extractor hangs: fails open once timeout fires" "0" "$OUT"
if [ "$_elapsed" -le 10 ]; then
  pass "extractor hangs: hook returned promptly after timeout ($_elapsed s)"
else
  fail "extractor hangs: hook took too long to return ($_elapsed s) — timeout/kill not working"
fi
_err="$(last_stderr)"
case "$_err" in
  *"script-events-hook:"*"exited"*"agent-8"*"script-reviewer"*)
    pass "extractor hangs: diagnostic reports a non-zero (killed) exit"
    ;;
  *)
    fail "extractor hangs: diagnostic missing expected content: $_err"
    ;;
esac

ARGV="$WORKDIR/argv.9"; COUNT="$WORKDIR/count.9"; rm -f "$ARGV" "$COUNT"
_start=$(date +%s)
OUT="$(STUB_ARGV_FILE="$ARGV" STUB_CALL_COUNT_FILE="$COUNT" STUB_SLEEP="5" STUB_OUT="" STUB_EXIT="0" \
  SCRIPT_EVENTS_HOOK_BUDGET="6" \
  run_hook "SubagentStop" "agent-9" "script-author" "$STUBBIN" "20" "")"
_elapsed=$(( $(date +%s) - _start ))
assert_rc "budget-bounded: hook exits 0 without retrying" "0" "$OUT"

_calls="$(wc -l < "$COUNT" 2>/dev/null | tr -d '[:space:]')"
if [ "$_calls" = "1" ]; then
  pass "budget-bounded: retry was skipped (extractor called exactly once)"
else
  fail "budget-bounded: expected 1 call (retry should have been skipped), got ${_calls:-0}"
fi

# Generous margin: the point being proven is "nowhere near the declared 30s
# hook timeout", not a tight bound on scheduler jitter.
if [ "$_elapsed" -le 15 ]; then
  pass "budget-bounded: total elapsed stayed well under the declared hook timeout ($_elapsed s)"
else
  fail "budget-bounded: total elapsed ($_elapsed s) exceeded the expected bound — retry was not properly skipped"
fi

OUT="$(run_hook "SubagentStop" "agent-10" "script-author" "" "" "")"
assert_rc "python3 not on PATH: fails open" "0" "$OUT"

echo ""
echo "script-events-hook-selftest.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
