#!/bin/bash
#
# script-events-hook.sh — Claude Code SubagentStop hook. Feeds every finished
# `script-author`/`script-reviewer` subagent into the lifecycle extractor
# (scripts/script-analytics.py extract, see docs/cost.md) automatically, so
# the events log stops depending on someone remembering to run `extract` by
# hand after the fact.
#
# Usage: not a CLI. Fed the SubagentStop payload on stdin — session_id,
# transcript_path, cwd, hook_event_name, agent_id, agent_type (verified live
# 2026-09-10). `agent_transcript_path` is NOT documented and is not used; the
# extractor resolves the subagent's own transcript itself, by agent_id.
#
# Acts only when `.hook_event_name` is "SubagentStop" AND `.agent_type`
# matches script-author|script-reviewer. Anything else exits 0 immediately
# and silently. The agent_type check is suspenders — plugin.json's matcher
# already restricts which calls reach this script at all.
#
# Exit code is ALWAYS 0: a non-zero SubagentStop hook could interfere with
# the agent's stop. Diagnostics are one stderr line prefixed
# "script-events-hook:", carrying only agent_id, agent_type and the
# extractor's exit code — never the stdin payload, never the extractor's own
# stdout/stderr text.
#
# When it acts, it shells out to the SAME extractor a human runs by hand:
#
#   python3 scripts/script-analytics.py extract \
#     --agent-id "$agent_id" --events "$EVENTS_FILE" --quiet \
#     [--projects-dir "$SCRIPT_EVENTS_PROJECTS_DIR"]   # test seam only
#
# --agent-id targets the one subagent that just finished, so this stays fast
# (glob, never a full-store scan), and the extractor is idempotent by its own
# `key`, so a duplicate firing appends nothing new.
#
# Under --quiet the extractor prints nothing when zero new events were found,
# so "exit 0, stdout empty" is read here as a possible transcript-flush race
# and retried once after 2s, then given up on silently. That race is an
# UNVERIFIED hypothesis — confirm or delete the retry on the first live
# firing. Both attempts plus the sleep are bounded by a wall-clock budget so
# the retry can never push this past the hook timeout plugin.json declares.
#
# Overridable for testing:
#
#   SCRIPT_EVENTS_PROJECTS_DIR   passed through as the extractor's
#                                --projects-dir — the ONLY way this hook is
#                                pointed at a fixture transcript store
#                                instead of the real ~/.claude/projects.
#                                Never invoke this hook, even in a selftest,
#                                without setting it to a scratch directory.
#   SCRIPT_EVENTS_PYTHON_BIN     interpreter to invoke (python3)
#   SCRIPT_EVENTS_HOOK_TIMEOUT   seconds before a single extractor attempt is
#                                killed and treated as a failure (20)
#   SCRIPT_EVENTS_HOOK_BUDGET    total wall-clock ceiling in seconds across
#                                both attempts and the retry sleep (25)
#   CLAUDE_PROJECT_DIR           repo root; falls back to two directories
#                                above this script (hooks/..) when unset
#
# Dependencies: bash 3.2, jq, python3 (or $SCRIPT_EVENTS_PYTHON_BIN), and
# scripts/script-analytics.py under the resolved project dir. Absence of any
# of these fails open (exit 0, one-line diagnostic) rather than erroring.

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
  # $1 = this attempt's own timeout, already capped at what remains of $BUDGET.
  # `set +e` so an expected non-zero exit cannot abort this script under `set -e`.
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

SECONDS=0

ATTEMPT=1
while :; do
  REMAINING=$((BUDGET - SECONDS))
  if [ "$REMAINING" -le 0 ]; then
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

  REMAINING=$((BUDGET - SECONDS))
  [ "$REMAINING" -le 2 ] && break

  ATTEMPT=$((ATTEMPT + 1))
  # An interrupted sleep returns non-zero; under `set -e` that would abort
  # this script, breaking its "every path exits 0" invariant.
  sleep 2 || true
done

rm -f "$STDOUT_FILE"
exit 0
