#!/bin/bash
#
# script-events-hook.sh — Claude Code SubagentStop hook.
# Feeds every finished `script-author`/`script-reviewer` Agent-tool
# subagent into the existing lifecycle extractor
# (scripts/script-analytics.py extract, see docs/cost.md "Script
# lifecycle analytics") automatically, so the events log stops depending
# on someone remembering to run `extract` by hand after the fact.
#
# --help
#   Not a CLI — this is a Claude Code hook, invoked with the SubagentStop
#   payload on stdin (see below), never run directly with flags. Read this
#   header for the contract; there is no interactive usage.
#
# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------
#
# Claude Code fires SubagentStop once per finished Agent-tool subagent, with
# a JSON payload on stdin carrying (per the hooks reference, verified live
# 2026-09-10): session_id, transcript_path, cwd, hook_event_name, agent_id,
# agent_type. `agent_transcript_path` is NOT documented and this script does
# not depend on it — the extractor resolves the subagent's own transcript
# itself, by agent_id, under --projects-dir.
#
# This hook only acts when BOTH hold:
#   - .hook_event_name == "SubagentStop"
#   - .agent_type matches script-author|script-reviewer (belt: the matcher
#     in .claude-plugin/plugin.json already restricts which calls reach this
#     script at all — this is suspenders, in case the matcher is ever
#     loosened without updating this script, or the hook is invoked some
#     other way)
#
# Anything else exits 0 immediately, silently — this hook has nothing to do
# for any other subagent type, or for any other hook event.
#
# When it acts, it shells out to the SAME extractor a human runs by hand
# (docs/cost.md):
#
#   python3 scripts/script-analytics.py extract \
#     --agent-id "$agent_id" --events "$EVENTS_FILE" --quiet \
#     [--projects-dir "$SCRIPT_EVENTS_PROJECTS_DIR"]   # test seam only
#
# --agent-id targets the single subagent that just finished (per the
# extractor's own doc comment: "resolve by glob only, never walk every
# session" — this stays fast, no full-store scan per SubagentStop firing).
# The extractor is idempotent by its own `key` field, so a hook that fires
# twice for the same agent_id (retries, a duplicate event, a re-run of this
# same hook by hand) is safe — the second call appends nothing new.
#
# ---------------------------------------------------------------------------
# Never blocks, never prints stdin or transcript content
# ---------------------------------------------------------------------------
#
# A hook that returns non-zero on SubagentStop could interfere with the
# agent's stop — every failure path in this script exits 0. Diagnostics go
# to stderr, one line, prefixed "script-events-hook:", and carry only
# agent_id, agent_type, and the extractor's exit code — never the stdin
# payload, never the extractor's own stdout/stderr text (which could echo
# file paths or, in principle, a proxied error from deeper in the
# transcript store).
#
# ---------------------------------------------------------------------------
# Portable timeout (no `timeout`/`gtimeout` on macOS by default)
# ---------------------------------------------------------------------------
#
# Same hand-rolled background-job + watcher pattern this repo's own
# read-shunt.sh already uses: the extractor runs in a backgrounded subshell
# with its own stdout captured to a file and stderr discarded; a second
# backgrounded `sleep $TIMEOUT; kill $PID` watcher is raced against it via
# `wait`; the watcher is killed once the extractor returns so it never
# outlives this script. Both background jobs redirect their own stdin/stdout
# away from this script's inherited fds — read-shunt.sh's header documents
# why that redirect matters for a caller capturing this script's own output.
#
# ---------------------------------------------------------------------------
# Retry-once-on-zero-new (UNVERIFIED hypothesis, flush timing)
# ---------------------------------------------------------------------------
#
# The subagent's own transcript file may still be flushing to disk at the
# instant SubagentStop fires (untested — no live SubagentStop firing has yet
# been observed against a genuinely-lagging transcript write). Called with
# --quiet, the extractor prints NOTHING on stdout when zero new events were
# found (see script-analytics.py cmd_extract: the summary line is gated on
# `new_events or not args.quiet`) — so "extractor exited 0, stdout empty" is
# read here as "zero new events, possibly a flush race" and retried once
# after a 2s sleep (budget permitting, see below), then given up on silently
# (not a failure: a script-author invocation that genuinely produced no
# attributable events, e.g. one whose brief-parsing heuristics found
# nothing, looks identical from here to a flush race, and this hook has no
# way to tell them apart). Confirm or correct this on the first live
# SubagentStop firing — if it always resolves on the first attempt, the
# retry is dead code and should be removed with the same evidence
# discipline as the shell-scripting skill's "why a self-check is not
# evidence" section describes.
#
# ---------------------------------------------------------------------------
# Wall-clock budget: the retry never pushes total runtime past the hook
# timeout
# ---------------------------------------------------------------------------
#
# .claude-plugin/plugin.json declares this hook's own timeout. Two uncapped
# attempts at the default 20s child timeout, plus the 2s sleep between them,
# is ~42s worst case — past a 30s declared timeout, meaning Claude Code
# could kill this script mid-retry rather than it ever reaching its own
# `exit 0`. $SCRIPT_EVENTS_HOOK_BUDGET (default 25s, margin under a 30s
# declared timeout for jq/mktemp/process overhead outside the timed calls)
# is a wall-clock ceiling tracked via bash's builtin `$SECONDS` (reset to 0
# right before the timed loop starts, so earlier jq parsing isn't charged
# against it):
#
#   - Each attempt's OWN per-call timeout is `min($SCRIPT_EVENTS_HOOK_TIMEOUT,
#     budget remaining)`, so a single slow attempt is killed at whatever is
#     left of the budget even if that is less than the configured timeout.
#   - Before committing to the retry sleep, the remaining budget must exceed
#     2s (the sleep itself) — otherwise the retry is skipped and this hook
#     gives up silently, exiting 0 well inside the declared timeout, same as
#     "ATTEMPT >= 2" already does.
#
# This bounds total wall time at approximately $SCRIPT_EVENTS_HOOK_BUDGET
# regardless of how the two attempts split it.
#
# ---------------------------------------------------------------------------
# Overridable for testing
# ---------------------------------------------------------------------------
#
#   SCRIPT_EVENTS_PROJECTS_DIR   passed through as the extractor's
#                                --projects-dir when set — the ONLY way this
#                                hook is pointed at a fixture transcript
#                                store instead of the real
#                                ~/.claude/projects; never invoke this hook,
#                                even in a selftest, without setting this to
#                                a scratch directory
#   SCRIPT_EVENTS_PYTHON_BIN     interpreter to invoke (python3)
#   SCRIPT_EVENTS_HOOK_TIMEOUT   seconds before a single extractor subprocess
#                                attempt is killed and treated as a failure
#                                (20) — see the wall-clock budget section
#                                above for how this interacts with retry
#   SCRIPT_EVENTS_HOOK_BUDGET    total wall-clock ceiling in seconds across
#                                both attempts and the retry sleep (25)
#   CLAUDE_PROJECT_DIR           repo root; falls back to two directories
#                                above this script (hooks/..) when unset
#
# Dependencies: bash 3.2, jq, python3 (or $SCRIPT_EVENTS_PYTHON_BIN), and
# scripts/script-analytics.py under the resolved project dir. Absence of
# any of these fails open (exit 0, one-line diagnostic) rather than erroring
# the hook.

set -euo pipefail

diag() {
  echo "script-events-hook: $1" >&2
}

fail_open() {
  diag "$1"
  exit 0
}

command -v jq >/dev/null 2>&1 || fail_open "jq not found on PATH"

INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0

HOOK_EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
[ "$HOOK_EVENT" = "SubagentStop" ] || exit 0

AGENT_ID="$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)"
[ -n "$AGENT_ID" ] || exit 0

AGENT_TYPE="$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null || true)"
case "$AGENT_TYPE" in
  script-author|script-reviewer) : ;;
  *) exit 0 ;;
esac

# --- Resolve the repo root ---------------------------------------------------

if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  PROJECT_DIR="$CLAUDE_PROJECT_DIR"
else
  SELF_DIR="$(cd "$(dirname "$0")" && pwd)" || fail_open "could not resolve own script directory"
  PROJECT_DIR="$(cd "$SELF_DIR/.." && pwd)" || fail_open "could not resolve project dir from script location"
fi

EVENTS_FILE="$PROJECT_DIR/docs/script-events.jsonl"
EVENTS_DIR="$(dirname "$EVENTS_FILE")"
[ -d "$EVENTS_DIR" ] || fail_open "events directory does not exist: $EVENTS_DIR"

EXTRACTOR="$PROJECT_DIR/scripts/script-analytics.py"
[ -f "$EXTRACTOR" ] || fail_open "extractor not found: $EXTRACTOR"

PYTHON_BIN="${SCRIPT_EVENTS_PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || fail_open "$PYTHON_BIN not found on PATH"

CHILD_TIMEOUT="${SCRIPT_EVENTS_HOOK_TIMEOUT:-20}"
BUDGET="${SCRIPT_EVENTS_HOOK_BUDGET:-25}"
case "$CHILD_TIMEOUT" in ''|*[!0-9]*) CHILD_TIMEOUT=20 ;; esac
case "$BUDGET" in ''|*[!0-9]*) BUDGET=25 ;; esac

EXTRACT_ARGS=(extract --agent-id "$AGENT_ID" --events "$EVENTS_FILE" --quiet)
if [ -n "${SCRIPT_EVENTS_PROJECTS_DIR:-}" ]; then
  EXTRACT_ARGS+=(--projects-dir "$SCRIPT_EVENTS_PROJECTS_DIR")
fi

STDOUT_FILE="$(mktemp "${TMPDIR:-/tmp}/script-events-hook.XXXXXX" 2>/dev/null)" || fail_open "could not create temp file for extractor output"
trap 'rm -f "$STDOUT_FILE"' EXIT

run_extractor_once() {
  # $1 = this attempt's own timeout (seconds) — the caller has already
  # capped it at whatever remains of $BUDGET, so a single attempt can never
  # by itself push total runtime past the wall-clock ceiling documented in
  # the header. Backgrounded extractor + watcher, raced via wait — same
  # shape as read-shunt.sh's summariser call. `set +e` around the parts
  # whose non-zero exit is expected and handled explicitly, so `set -e`
  # above cannot abort this script out from under the retry loop.
  _attempt_timeout="$1"
  : > "$STDOUT_FILE"
  set +e
  ( "$PYTHON_BIN" "$EXTRACTOR" "${EXTRACT_ARGS[@]}" >"$STDOUT_FILE" 2>/dev/null ) &
  _extract_pid=$!
  ( sleep "$_attempt_timeout"; kill "$_extract_pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  _watcher_pid=$!
  wait "$_extract_pid" 2>/dev/null
  _rc=$?
  kill "$_watcher_pid" 2>/dev/null
  wait "$_watcher_pid" 2>/dev/null
  set -e
  return "$_rc"
}

# $SECONDS is bash's builtin elapsed-time counter. Reset it here, right
# before the timed loop, so the jq parsing and path resolution already done
# above are never charged against the budget — only the parts that can
# actually run long (the extractor calls and the retry sleep) are.
SECONDS=0

ATTEMPT=1
while :; do
  REMAINING=$((BUDGET - SECONDS))
  if [ "$REMAINING" -le 0 ]; then
    # Out of budget entirely (should only happen if a prior attempt's own
    # timeout kill itself took unexpectedly long) — give up silently, same
    # posture as the normal "no more attempts" exit below.
    break
  fi

  ATTEMPT_TIMEOUT="$CHILD_TIMEOUT"
  [ "$ATTEMPT_TIMEOUT" -gt "$REMAINING" ] && ATTEMPT_TIMEOUT="$REMAINING"

  RC=0
  run_extractor_once "$ATTEMPT_TIMEOUT" || RC=$?

  if [ "$RC" -ne 0 ]; then
    diag "extractor exited $RC for agent_id=$AGENT_ID agent_type=$AGENT_TYPE"
    rm -f "$STDOUT_FILE"
    exit 0
  fi

  # --quiet means "0 new events" prints nothing at all (see cmd_extract).
  # Non-empty stdout here only ever means new_events was non-empty.
  if [ -s "$STDOUT_FILE" ]; then
    break
  fi

  [ "$ATTEMPT" -ge 2 ] && break

  # Reserve the 2s sleep itself out of what's left before committing to a
  # retry — an attempt that already consumed most of the budget skips the
  # retry rather than risk exceeding the declared hook timeout.
  REMAINING=$((BUDGET - SECONDS))
  [ "$REMAINING" -le 2 ] && break

  ATTEMPT=$((ATTEMPT + 1))
  # Guarded: an interrupted sleep returns non-zero, which under `set -e`
  # would otherwise abort the script non-zero here — breaking the "every
  # path exits 0" invariant this hook exists to guarantee.
  sleep 2 || true
done

rm -f "$STDOUT_FILE"
exit 0
