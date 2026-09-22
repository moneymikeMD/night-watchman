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
# CLAUDE_PLUGIN_ROOT and SCRIPT_EVENTS_EXTRACTOR are unset on every run
# unless a case sets them deliberately, so an ambient value from the shell
# running this selftest can never decide which extractor the hook picks.
#
# $SCRIPT_EVENTS_HOOK_SCRIPT overrides the hook under test, so the NWM-156
# cases can be run red against an older revision of it.
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
  printf '%s' "$_payload" | env -u CLAUDE_PLUGIN_ROOT -u SCRIPT_EVENTS_EXTRACTOR \
    PATH="$_env_path" CLAUDE_PROJECT_DIR="$PROJECT_ROOT" \
    SCRIPT_EVENTS_PROJECTS_DIR="$FIXTURE_PROJECTS" $_timeout_env "$SCRIPT" \
    >"$WORKDIR/.last_stdout" 2>"$WORKDIR/.last_stderr"
  echo "RC=$?"
}

payload_for() {
  # $1 = agent_id, $2 = agent_type. SubagentStop, no extra fields.
  jq -n --arg aid "$1" --arg atype "$2" \
    '{hook_event_name: "SubagentStop", agent_id: $aid, agent_type: $atype, session_id: "sess-x", transcript_path: "/tmp/fake-transcript.jsonl", cwd: "/tmp"}'
}

run_hook_resolve() {
  # Extractor-resolution cases (NWM-156, NWM-130). $1 = hook script,
  # $2 = agent_id, $3 = CLAUDE_PROJECT_DIR, $4 = CLAUDE_PLUGIN_ROOT
  # ("" = unset), $5 = SCRIPT_EVENTS_EXTRACTOR ("" = unset),
  # $6 = AI_TOOLKIT_ROOT ("" = unset).
  _hook="$1"; _aid="$2"; _proj="$3"; _plugin="$4"; _extractor="$5"; _aitk="${6:-}"

  set -- env -u CLAUDE_PLUGIN_ROOT -u SCRIPT_EVENTS_EXTRACTOR -u AI_TOOLKIT_ROOT \
    PATH="$STUBBIN:$MINIMAL_PATH" CLAUDE_PROJECT_DIR="$_proj" \
    SCRIPT_EVENTS_PROJECTS_DIR="$FIXTURE_PROJECTS"
  [ -n "$_plugin" ] && set -- "$@" CLAUDE_PLUGIN_ROOT="$_plugin"
  [ -n "$_extractor" ] && set -- "$@" SCRIPT_EVENTS_EXTRACTOR="$_extractor"
  [ -n "$_aitk" ] && set -- "$@" AI_TOOLKIT_ROOT="$_aitk"

  payload_for "$_aid" "script-author" | "$@" "$_hook" \
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

# ---- NWM-156: the extractor resolution chain ---------------------------

# A consumer project with NO scripts/script-analytics.py, plus a scratch
# plugin root that has one. The old $PROJECT_DIR-only resolution fail_opened
# here, so the hook went silently dark for every installer.
CONSUMER_ROOT="$WORKDIR/consumer"
mkdir -p "$CONSUMER_ROOT/docs"
CONSUMER_EVENTS="$CONSUMER_ROOT/docs/script-events.jsonl"

PLUGIN_ROOT="$WORKDIR/plugin"
mkdir -p "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/hooks"
PLUGIN_EXTRACTOR="$PLUGIN_ROOT/scripts/script-analytics.py"
: > "$PLUGIN_EXTRACTOR"
cp "$SCRIPT" "$PLUGIN_ROOT/hooks/script-events-hook.sh"
chmod +x "$PLUGIN_ROOT/hooks/script-events-hook.sh"

# A copy of the hook with no sibling ../scripts/ at all, so the last chain
# step cannot accidentally satisfy the "nothing resolves" case.
ORPHAN_ROOT="$WORKDIR/orphan"
mkdir -p "$ORPHAN_ROOT/hooks"
cp "$SCRIPT" "$ORPHAN_ROOT/hooks/script-events-hook.sh"
chmod +x "$ORPHAN_ROOT/hooks/script-events-hook.sh"

ARGV="$WORKDIR/argv.11"; rm -f "$ARGV"
OUT="$(STUB_ARGV_FILE="$ARGV" STUB_OUT="# extract: 1 new, 0 already present" STUB_EXIT="0" \
  run_hook_resolve "$SCRIPT" "agent-11" "$CONSUMER_ROOT" "$PLUGIN_ROOT" "")"
assert_rc "consumer project with no extractor: hook exits 0" "0" "$OUT"
if [ -e "$ARGV" ]; then
  pass "CLAUDE_PLUGIN_ROOT: extractor was called although \$PROJECT_DIR/scripts/ has none"
  _argv="$(cat "$ARGV")"
  case "$_argv" in
    *"$PLUGIN_EXTRACTOR"*)
      pass "CLAUDE_PLUGIN_ROOT: argv names the plugin-root extractor"
      ;;
    *)
      fail "CLAUDE_PLUGIN_ROOT: argv did not name $PLUGIN_EXTRACTOR: $_argv"
      ;;
  esac
  case "$_argv" in
    *"--events"*"$CONSUMER_EVENTS"*)
      pass "CLAUDE_PLUGIN_ROOT: --events still points at the CONSUMING project, not the plugin"
      ;;
    *)
      fail "CLAUDE_PLUGIN_ROOT: --events was not $CONSUMER_EVENTS: $_argv"
      ;;
  esac
else
  fail "CLAUDE_PLUGIN_ROOT: extractor was NOT called (the hook went dark)"
fi

# $SCRIPT_EVENTS_EXTRACTOR beats both other candidates.
OVERRIDE_EXTRACTOR="$WORKDIR/override-script-analytics.py"
: > "$OVERRIDE_EXTRACTOR"
ARGV="$WORKDIR/argv.12"; rm -f "$ARGV"
OUT="$(STUB_ARGV_FILE="$ARGV" STUB_OUT="# extract: 1 new, 0 already present" STUB_EXIT="0" \
  run_hook_resolve "$SCRIPT" "agent-12" "$PROJECT_ROOT" "$PLUGIN_ROOT" "$OVERRIDE_EXTRACTOR")"
assert_rc "SCRIPT_EVENTS_EXTRACTOR: hook exits 0" "0" "$OUT"
_argv="$(cat "$ARGV" 2>/dev/null)"
case "$_argv" in
  *"$OVERRIDE_EXTRACTOR"*)
    pass "SCRIPT_EVENTS_EXTRACTOR: wins over both \$CLAUDE_PLUGIN_ROOT and \$PROJECT_DIR"
    ;;
  *)
    fail "SCRIPT_EVENTS_EXTRACTOR: did not win (argv: ${_argv:-<none>})"
    ;;
esac

# $PROJECT_DIR still wins when no override and no plugin root is set, so
# this repo's own loop and homelab are unaffected by the chain.
ARGV="$WORKDIR/argv.13"; rm -f "$ARGV"
OUT="$(STUB_ARGV_FILE="$ARGV" STUB_OUT="# extract: 1 new, 0 already present" STUB_EXIT="0" \
  run_hook_resolve "$SCRIPT" "agent-13" "$PROJECT_ROOT" "" "")"
assert_rc "PROJECT_DIR fallback: hook exits 0" "0" "$OUT"
_argv="$(cat "$ARGV" 2>/dev/null)"
case "$_argv" in
  *"$PROJECT_ROOT/scripts/script-analytics.py"*)
    pass "PROJECT_DIR fallback: still resolves the project's own extractor when nothing else is set"
    ;;
  *)
    fail "PROJECT_DIR fallback: did not resolve the project extractor (argv: ${_argv:-<none>})"
    ;;
esac

# Nothing resolves anywhere: still exit 0, and the diagnostic must name
# EVERY path tried rather than only one.
ARGV="$WORKDIR/argv.14"; rm -f "$ARGV"
OUT="$(STUB_ARGV_FILE="$ARGV" run_hook_resolve "$ORPHAN_ROOT/hooks/script-events-hook.sh" \
  "agent-14" "$CONSUMER_ROOT" "" "")"
assert_rc "no extractor anywhere: still fails open" "0" "$OUT"
if [ -e "$ARGV" ]; then
  fail "no extractor anywhere: extractor was called (should not be)"
else
  pass "no extractor anywhere: extractor not called"
fi
_err="$(last_stderr)"
case "$_err" in
  *"$CONSUMER_ROOT/scripts/script-analytics.py"*)
    pass "no extractor anywhere: diagnostic names the \$PROJECT_DIR candidate"
    ;;
  *)
    fail "no extractor anywhere: diagnostic omits the \$PROJECT_DIR candidate: $_err"
    ;;
esac
# Matched as a suffix, not against $ORPHAN_ROOT: the hook resolves its own
# directory through cd+pwd, which normalises away a trailing slash TMPDIR may
# carry, so the two prefixes are not textually equal.
case "$_err" in
  *"/orphan/hooks/../scripts/script-analytics.py"*)
    pass "no extractor anywhere: diagnostic names the hook-relative candidate too"
    ;;
  *)
    fail "no extractor anywhere: diagnostic omits the hook-relative candidate: $_err"
    ;;
esac

# ---- NWM-130: the extractor now lives in ai-toolkit --------------------

# A plugin tree that carries ai-toolkit-root.sh but NO scripts/script-analytics.py
# — exactly what this repo looks like after the donate half landed.
DONATED_PLUGIN="$WORKDIR/donated-plugin"
mkdir -p "$DONATED_PLUGIN/scripts" "$DONATED_PLUGIN/hooks" "$DONATED_PLUGIN/templates"
cp "$SCRIPT" "$DONATED_PLUGIN/hooks/script-events-hook.sh"
chmod +x "$DONATED_PLUGIN/hooks/script-events-hook.sh"
printf 'plugin table\n' >"$DONATED_PLUGIN/templates/claude-prices.tsv"

FAKE_AITK="$WORKDIR/fake-ai-toolkit"
mkdir -p "$FAKE_AITK/scripts"
AITK_EXTRACTOR="$FAKE_AITK/scripts/script-analytics.py"
: > "$AITK_EXTRACTOR"

# A stand-in resolver: the real scripts/ai-toolkit-root.sh needs lib/kit.sh
# and a checkout, neither of which belongs in a hook selftest.
cat > "$DONATED_PLUGIN/scripts/ai-toolkit-root.sh" << EOF
#!/bin/bash
[ "\$1" = "--script-analytics" ] || exit 1
printf '%s\\n' "\${AI_TOOLKIT_ROOT:-}/scripts/script-analytics.py"
EOF
chmod +x "$DONATED_PLUGIN/scripts/ai-toolkit-root.sh"

ARGV="$WORKDIR/argv.15"; rm -f "$ARGV"
OUT="$(STUB_ARGV_FILE="$ARGV" STUB_OUT="# extract: 1 new, 0 already present" STUB_EXIT="0" \
  run_hook_resolve "$DONATED_PLUGIN/hooks/script-events-hook.sh" "agent-15" \
  "$CONSUMER_ROOT" "$DONATED_PLUGIN" "" "$FAKE_AITK")"
assert_rc "ai-toolkit step: hook exits 0" "0" "$OUT"
if [ -e "$ARGV" ]; then
  pass "ai-toolkit step: extractor was called although no path candidate holds one"
  _argv="$(cat "$ARGV")"
  case "$_argv" in
    *"$AITK_EXTRACTOR"*)
      pass "ai-toolkit step: argv names the extractor ai-toolkit-root.sh resolved"
      ;;
    *)
      fail "ai-toolkit step: argv did not name $AITK_EXTRACTOR: $_argv"
      ;;
  esac
else
  fail "ai-toolkit step: extractor was NOT called — the hook went dark after the move"
fi

# The price table must be pinned explicitly, or the extractor's own search
# would resolve ai-toolkit's templates/ before this project's.
PRICED_ROOT="$WORKDIR/priced-project"
mkdir -p "$PRICED_ROOT/docs" "$PRICED_ROOT/templates"
printf 'project table\n' >"$PRICED_ROOT/templates/claude-prices.tsv"

ARGV="$WORKDIR/argv.16"; rm -f "$ARGV"
OUT="$(STUB_ARGV_FILE="$ARGV" STUB_OUT="# extract: 1 new, 0 already present" STUB_EXIT="0" \
  run_hook_resolve "$DONATED_PLUGIN/hooks/script-events-hook.sh" "agent-16" \
  "$PRICED_ROOT" "$DONATED_PLUGIN" "" "$FAKE_AITK")"
assert_rc "prices: hook exits 0" "0" "$OUT"
_argv="$(cat "$ARGV" 2>/dev/null)"
case "$_argv" in
  *"--prices"*"$PRICED_ROOT/templates/claude-prices.tsv"*)
    pass "prices: the project's own table is pinned with --prices"
    ;;
  *)
    fail "prices: --prices did not name the project's table (argv: ${_argv:-<none>})"
    ;;
esac

# With no table in the project, the plugin's shipped template is used, so an
# installer that never copied one still prices its events.
ARGV="$WORKDIR/argv.17"; rm -f "$ARGV"
OUT="$(STUB_ARGV_FILE="$ARGV" STUB_OUT="# extract: 1 new, 0 already present" STUB_EXIT="0" \
  run_hook_resolve "$DONATED_PLUGIN/hooks/script-events-hook.sh" "agent-17" \
  "$CONSUMER_ROOT" "$DONATED_PLUGIN" "" "$FAKE_AITK")"
assert_rc "prices fallback: hook exits 0" "0" "$OUT"
_argv="$(cat "$ARGV" 2>/dev/null)"
case "$_argv" in
  *"--prices"*"$DONATED_PLUGIN/templates/claude-prices.tsv"*)
    pass "prices fallback: the plugin's shipped table is used when the project has none"
    ;;
  *)
    fail "prices fallback: --prices did not name the plugin's table (argv: ${_argv:-<none>})"
    ;;
esac

# No table anywhere: --prices is omitted rather than pointed at nothing.
BARE_PLUGIN="$WORKDIR/bare-plugin"
mkdir -p "$BARE_PLUGIN/scripts" "$BARE_PLUGIN/hooks"
cp "$SCRIPT" "$BARE_PLUGIN/hooks/script-events-hook.sh"
chmod +x "$BARE_PLUGIN/hooks/script-events-hook.sh"
cp "$DONATED_PLUGIN/scripts/ai-toolkit-root.sh" "$BARE_PLUGIN/scripts/ai-toolkit-root.sh"

ARGV="$WORKDIR/argv.18"; rm -f "$ARGV"
OUT="$(STUB_ARGV_FILE="$ARGV" STUB_OUT="# extract: 1 new, 0 already present" STUB_EXIT="0" \
  run_hook_resolve "$BARE_PLUGIN/hooks/script-events-hook.sh" "agent-18" \
  "$CONSUMER_ROOT" "$BARE_PLUGIN" "" "$FAKE_AITK")"
assert_rc "no prices anywhere: hook exits 0" "0" "$OUT"
_argv="$(cat "$ARGV" 2>/dev/null)"
case "$_argv" in
  *"--prices"*)
    fail "no prices anywhere: --prices should have been omitted (argv: $_argv)"
    ;;
  *)
    pass "no prices anywhere: --prices is omitted rather than pointed at nothing"
    ;;
esac

echo ""
echo "script-events-hook-selftest.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
