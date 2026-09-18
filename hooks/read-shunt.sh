#!/bin/bash
#
# read-shunt.sh — Claude Code PreToolUse hook for Read (and simple `cat` Bash
# calls). A file over the line threshold is summarised by a stateless
# `claude -p --model haiku` subprocess instead of being returned to the
# calling model in full. READS ONLY: never edits, reasoning, or safety review.
#
# Usage: not a CLI. Fed the PreToolUse payload on stdin.
#
# Exit codes:
#   0  allow — the tool runs and the model sees the real content
#   2  block, with the summary on stderr, which Claude Code surfaces to the
#      model as the tool's result rather than as an error
#
# What gets matched:
#   - `.tool_name == "Read"`: the file at `.tool_input.file_path`.
#   - `.tool_name == "Bash"`: ONLY a bare `cat` of one file, with no pipes,
#     redirects, substitutions or second argument. `cat a b`, `cat f | grep x`
#     and `cat "$VAR"` are left alone. This is not a shell parser.
#   - anything else: exit 0 immediately.
#
# Escape hatch: the FIRST read of a given path in a given hook session is
# summarised and recorded under $READ_SHUNT_STATE_ROOT/<session_id>/<key>.
# Asking for the same path again in the same session returns the real,
# unshunted content. Nothing is ever permanently unreadable; asking twice
# always works.
#
# Never shunts a secrets-bearing path. The check runs BEFORE anything else
# about the file, and against the symlink-resolved, case-folded PHYSICAL path
# — never the name it was reached by. Excluded: `*.env`/`*.env.*`, anything
# under a docker/env/-style directory (`.tpl` templates included), a basename
# containing secret/credential/token/1password, anything under `.op/` or
# `.config/op/`, and key material (*.pem, *.key, *.p12, *.pfx, *.pkcs12,
# *.kdbx, id_rsa*, id_ed25519*, id_ecdsa*, id_dsa*). A file matching none of
# these can still hold a secret this list did not anticipate — widen it
# rather than narrow it if a new vector turns up.
#
# Fails open on every ambiguity: missing jq, an unreadable file, an
# undeterminable line count, a missing session_id (it could not then be
# reliably un-shunted), a symlink chain that will not resolve in a bounded
# number of hops, no path-hashing tool, no `claude` on PATH, or a summariser
# that times out or exits non-zero. A big file getting through whole only
# costs tokens; eating content someone needed would be a correctness bug.
#
# Overridable for testing (the defaults are what a real session uses):
#   READ_SHUNT_THRESHOLD    line count above which a file is shunted (400)
#   READ_SHUNT_CLAUDE_BIN   the summariser binary (claude)
#   READ_SHUNT_MODEL        the summariser model (haiku)
#   READ_SHUNT_TIMEOUT      seconds before the summariser subprocess is
#                           killed and this hook fails open (45)
#   READ_SHUNT_STATE_ROOT   root dir for per-session shunt markers
#                           (${TMPDIR:-/tmp}/read-shunt-state)
#
# Dependencies: bash 3.2, jq, readlink, and one of shasum/md5/openssl (all
# ship on macOS). The `claude` binary and the hashing tool are needed only on
# the shunt path itself; their absence fails open.

set -u

THRESHOLD="${READ_SHUNT_THRESHOLD:-400}"
CLAUDE_BIN="${READ_SHUNT_CLAUDE_BIN:-claude}"
SUMMARY_MODEL="${READ_SHUNT_MODEL:-haiku}"
SUMMARY_TIMEOUT="${READ_SHUNT_TIMEOUT:-45}"
STATE_ROOT="${READ_SHUNT_STATE_ROOT:-${TMPDIR:-/tmp}/read-shunt-state}"

fail_open() {
  echo "read-shunt.sh: $1 — failing open (allow)" >&2
  exit 0
}

command -v jq >/dev/null 2>&1 || fail_open "jq not found on PATH"

INPUT="$(cat)"
[ -n "$INPUT" ] || fail_open "empty stdin"

TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"

[ -n "$TOOL_NAME" ] || fail_open "no .tool_name in hook payload"

# normalize_path: collapse . and .. in $1 lexically, without requiring it to
# exist. bash 3.2, no realpath dependency.
normalize_path() {
  _np_in="$1"
  [ -n "$_np_in" ] || { printf '/'; return 0; }
  case "$_np_in" in
    /*) : ;;
    *) _np_in="$(pwd -P)/$_np_in" ;;
  esac
  _np_out=""
  _np_save_ifs="$IFS"
  IFS='/'
  # shellcheck disable=SC2206 # deliberate word split on IFS=/ to walk path segments
  _np_segs=($_np_in)
  IFS="$_np_save_ifs"
  for _np_seg in "${_np_segs[@]}"; do
    case "$_np_seg" in
      ""|".") continue ;;
      "..") _np_out="${_np_out%/*}" ;;
      *) _np_out="$_np_out/$_np_seg" ;;
    esac
  done
  [ -n "$_np_out" ] || _np_out="/"
  printf '%s' "$_np_out"
}

# Expand a word-initial ~ or ~/... to $HOME. ~user/... is left unresolved.
expand_tilde() {
  _et_in="$1"
  # shellcheck disable=SC2088 # matching the literal characters ~/..., not asking the shell to expand them
  case "$_et_in" in
    '~')
      printf '%s' "${HOME:-}"
      ;;
    '~/'*)
      if [ -n "${HOME:-}" ]; then
        printf '%s' "$HOME/${_et_in#\~/}"
      else
        printf '%s' "$_et_in"
      fi
      ;;
    *)
      printf '%s' "$_et_in"
      ;;
  esac
}

# physical_path: resolve $1 (which must already exist) to its real,
# symlink-free, filesystem-canonical form. Bounded at 40 hops, so a symlink
# loop returns 1 rather than spinning forever.
physical_path() {
  _pp_cur="$1"
  _pp_hops=40
  while [ "$_pp_hops" -gt 0 ]; do
    _pp_dir="$(dirname "$_pp_cur")"
    _pp_base="$(basename "$_pp_cur")"
    _pp_dir_phys="$(cd "$_pp_dir" 2>/dev/null && pwd -P)" || return 1
    _pp_cur="$_pp_dir_phys/$_pp_base"
    if [ -L "$_pp_cur" ]; then
      _pp_link="$(readlink "$_pp_cur")" || return 1
      case "$_pp_link" in
        /*) _pp_cur="$_pp_link" ;;
        *) _pp_cur="$_pp_dir_phys/$_pp_link" ;;
      esac
      _pp_cur="$(normalize_path "$_pp_cur")"
      _pp_hops=$((_pp_hops - 1))
      continue
    fi
    printf '%s' "$_pp_cur"
    return 0
  done
  return 1
}

# key_for_path: a collision-resistant state-marker key for $1, hashed with
# shasum, then md5, then openssl. Returns 1 if none of those are on PATH, so
# the caller fails open rather than dedupe unsafely.
key_for_path() {
  _kfp_p="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$_kfp_p" | shasum -a 256 2>/dev/null | awk '{print $1}'
    return 0
  fi
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$_kfp_p" | md5 2>/dev/null
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$_kfp_p" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
    return 0
  fi
  return 1
}

# is_secret_path: $1 must already be a physical_path()-resolved, lowercased
# string; this function neither resolves nor folds. See the header's "Never
# shunts a secrets-bearing path" section for the list and the rationale.
is_secret_path() {
  _isp_lower="$1"
  _isp_base="${_isp_lower##*/}"

  case "$_isp_lower" in
    */docker/env/*) return 0 ;;
    */.op/*|*/.config/op/*) return 0 ;;
  esac

  case "$_isp_base" in
    *.env|*.env.*) return 0 ;;
    *secret*) return 0 ;;
    *credential*) return 0 ;;
    *token*) return 0 ;;
    *.pem|*.key|*.p12|*.pfx|*.pkcs12|*.kdbx) return 0 ;;
    id_rsa*|id_ed25519*|id_ecdsa*|id_dsa*) return 0 ;;
    *1password*) return 0 ;;
  esac

  return 1
}

case "$TOOL_NAME" in
  Read)
    FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    [ -n "$FILE_PATH" ] || fail_open "no .tool_input.file_path for Read"
    ;;
  Bash)
    CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [ -n "$CMD" ] || exit 0

    # shellcheck disable=SC2016 # literal patterns being matched against, not expanded
    case "$CMD" in
      *'|'*|*';'*|*'&'*|*'>'*|*'<'*|*'$('*|*'`'*|*'$'*)
        exit 0
        ;;
    esac

    # shellcheck disable=SC2086 # deliberate unquoted word-split, narrow best-effort matcher
    set -- $CMD
    [ "${1:-}" = "cat" ] || exit 0
    shift
    _cat_path=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -*) ;;
        *)
          if [ -n "$_cat_path" ]; then
            exit 0
          fi
          _cat_path="$1"
          ;;
      esac
      shift
    done
    [ -n "$_cat_path" ] || exit 0
    FILE_PATH="$_cat_path"
    ;;
  *)
    exit 0
    ;;
esac

# Order matters: the secrets check runs against the fully symlink-resolved,
# case-folded PHYSICAL path, never the raw FILE_PATH the caller supplied.

RESOLVED="$(expand_tilde "$FILE_PATH")"
RESOLVED="$(normalize_path "$RESOLVED")"

[ -e "$RESOLVED" ] || fail_open "target does not exist: $RESOLVED"
[ -f "$RESOLVED" ] || exit 0

PHYSICAL="$(physical_path "$RESOLVED")" || fail_open "could not resolve real path (possible symlink loop) for $RESOLVED"
LOWER_PHYSICAL="$(printf '%s' "$PHYSICAL" | tr '[:upper:]' '[:lower:]')"

if is_secret_path "$LOWER_PHYSICAL"; then
  exit 0
fi

[ -r "$PHYSICAL" ] || fail_open "target not readable: $PHYSICAL"

LINE_COUNT="$(wc -l < "$PHYSICAL" 2>/dev/null | tr -d '[:space:]')"
case "$LINE_COUNT" in
  ''|*[!0-9]*) fail_open "could not determine line count for $PHYSICAL" ;;
esac

[ "$LINE_COUNT" -gt "$THRESHOLD" ] || exit 0

[ -n "$SESSION_ID" ] || fail_open "no .session_id in hook payload, cannot dedupe safely"

SESSION_DIR="$STATE_ROOT/$SESSION_ID"
mkdir -p "$SESSION_DIR" 2>/dev/null || fail_open "could not create state dir $SESSION_DIR"

KEY="$(key_for_path "$PHYSICAL")" || fail_open "no path-hashing tool (shasum/md5/openssl) on PATH, cannot dedupe safely"
[ -n "$KEY" ] || fail_open "empty key derived for $PHYSICAL"
MARKER="$SESSION_DIR/$KEY"

if [ -e "$MARKER" ]; then
  # Already shunted once this session — this is the explicit re-read.
  exit 0
fi

# Hand-rolled timeout: macOS ships no `timeout`/`gtimeout` by default.

command -v "$CLAUDE_BIN" >/dev/null 2>&1 || fail_open "$CLAUDE_BIN not found on PATH"

PROMPT="Summarise the following file for a coding agent that needs to know its structure and key content without reading it in full. Note: file path, total line count, purpose, and any functions/sections/classes present. Keep it under 250 words. Do not reproduce the raw file content verbatim.

FILE: $PHYSICAL ($LINE_COUNT lines)

$(cat "$PHYSICAL" 2>/dev/null)"

SUMMARY_OUT="$SESSION_DIR/.summary.$$"
( "$CLAUDE_BIN" -p --model "$SUMMARY_MODEL" "$PROMPT" < /dev/null > "$SUMMARY_OUT" 2>/dev/null ) &
SUMMARY_PID=$!
# Both background jobs redirect their own fds away from this script's:
# command substitution blocks until every process holding the pipe exits.
( sleep "$SUMMARY_TIMEOUT"; kill "$SUMMARY_PID" 2>/dev/null ) < /dev/null > /dev/null 2>&1 &
WATCHER_PID=$!

wait "$SUMMARY_PID" 2>/dev/null
SUMMARY_RC=$?
kill "$WATCHER_PID" 2>/dev/null
wait "$WATCHER_PID" 2>/dev/null

if [ "$SUMMARY_RC" -ne 0 ]; then
  rm -f "$SUMMARY_OUT"
  fail_open "haiku summariser exited non-zero or timed out"
fi

SUMMARY="$(cat "$SUMMARY_OUT" 2>/dev/null)"
rm -f "$SUMMARY_OUT"
[ -n "$SUMMARY" ] || fail_open "haiku summariser returned no output"

# Mark before printing: a crash after this point still leaves the escape
# hatch usable, at worst re-shunting once more.
: > "$MARKER" 2>/dev/null || fail_open "could not write shunt marker $MARKER"

{
  echo "[read-shunt] $PHYSICAL is $LINE_COUNT lines (over the $THRESHOLD-line"
  echo "threshold) — summarised below instead of returned in full to save"
  echo "tokens. To see the exact original content, read this same path again;"
  echo "the second read in this session is served unshunted."
  echo ""
  echo "$SUMMARY"
} >&2

exit 2
