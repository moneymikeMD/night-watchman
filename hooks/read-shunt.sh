#!/bin/bash
#
# read-shunt.sh — Claude Code PreToolUse hook for Read (and simple `cat`
# Bash calls). Copies Portal by Spotify's read-shunt mechanism
# (https://engineering.atspotify.com/2026/9/portal-by-spotify-cut-my-claude-code-token-usage-by-90),
# deliberately scoped narrow: READS ONLY, never edits, reasoning, or safety
# review.
#
# Files over the line threshold (owner-approved: 400) are summarised by a
# stateless `claude -p --model haiku` subprocess instead of being returned
# to the calling (expensive) model in full. Deterministic dispatch, not a
# prose instruction — the same rationale as guard-fs-writes.sh, which this
# script follows as its structural model: standalone (a PreToolUse hook
# runs on every matched tool call in the session, so it stays small, fast,
# and dependency-light), `fail_open` helper, hook JSON read once from
# stdin via jq.
#
# ---------------------------------------------------------------------------
# Mechanism: how a hook substitutes a summary for real file content
# ---------------------------------------------------------------------------
#
# There is no "rewrite the tool's return value" hook primitive. Instead this
# reuses the exact mechanism guard-fs-writes.sh already relies on in
# production: a PreToolUse hook that exits 2 BLOCKS the tool call entirely,
# and Claude Code surfaces this script's stderr back to the calling model as
# the tool's result (guard-fs-writes.sh's own header documents the same
# contract; this is not a new assumption about the hook system, it is the
# identical contract an already-shipped hook depends on). So: when a file
# qualifies for shunting, this script prints the haiku summary to stderr and
# exits 2 — the model never sees the real Read/cat output, only the summary,
# framed as the tool's result rather than as an error. Exiting 0 means
# "allow" — the tool runs normally and the model sees the real content.
#
# ---------------------------------------------------------------------------
# Reachability: the shunt is NOT silently lossy
# ---------------------------------------------------------------------------
#
# Every shunted (path, session_id) pair is recorded in a one-line marker
# file under $READ_SHUNT_STATE_ROOT/<session_id>/<key>. The FIRST Read (or
# `cat`-equivalent) of a given absolute path in a given hook session is
# summarised. If the calling model asks for the SAME path again in the SAME
# session — because it decided the summary was not enough — this script
# finds the marker, does not re-summarise, and exits 0: the second request
# is served with the real, unshunted content. This is the escape hatch
# named in the ticket ("the hook only fires once per file per session").
# Nothing is ever permanently unreadable; asking twice always works.
#
# ---------------------------------------------------------------------------
# What gets matched
# ---------------------------------------------------------------------------
#
# - tool_name == "Read": the file at .tool_input.file_path.
# - tool_name == "Bash": ONLY when the entire command is a bare `cat` of one
#   file with no pipes, redirects, substitutions, or a second argument
#   (best-effort, deliberately narrow — this is not a shell parser, see
#   guard-fs-writes.sh's own header for why that line is drawn there too).
#   Anything else (`cat a b`, `cat f | grep x`, `cat "$VAR"`, `cat -- $(...)`)
#   is left alone and passes through unshunted (fail open).
# - Every other tool_name: exit 0 immediately, this hook has nothing to do.
#
# ---------------------------------------------------------------------------
# Never shunts a secrets-bearing path
# ---------------------------------------------------------------------------
#
# This is a cost optimisation, not a security control — but a false
# negative here (shunting a secret file, i.e. sending its content to the
# haiku subprocess and printing a summary of it to stderr, which lands in
# the transcript) is the only failure mode that matters, so is_secret_path()
# below is deliberately broad and checked BEFORE anything else about the
# file. Modeled on (not sourced from — this is a different job: gating a
# READ, not blocking a WRITE outside a tree) guard-fs-writes.sh's own
# normalize_path/expand_tilde path-handling style. Excluded at minimum:
#
#   - any *.env / *.env.* file, and everything under a docker/env/-style
#     directory (including any .tpl templates — they may carry op://-style
#     references rather than values, but are excluded anyway, biasing the
#     exclusion list broad)
#   - any path whose basename contains "secret", "credential", or "token"
#     (covers ad-hoc dumps of credential-fetching output, plus password
#     manager exports)
#   - key material: *.pem, *.key, *.p12, *.pfx, *.pkcs12, *.kdbx, id_rsa*,
#     id_ed25519*, id_ecdsa*, id_dsa*
#   - anything under a .op/ or .config/op/ directory, or naming 1password
#
# A file matching none of these can still legitimately hold a secret this
# list didn't anticipate — the list is a guard against the routine,
# already-known leak vectors, not a guarantee. Widen it rather than narrow
# it if a new vector turns up.
#
# The check runs against a path that has been through BOTH of these first
# (the un-fixed version checked the literal, unresolved, case-preserved
# path text, which is defeatable):
#
#   1. physical_path(): the directory portion is re-resolved with
#      `cd ... && pwd -P` (same technique guard-fs-writes.sh's PWD_PHYS
#      uses) and the LEAF component's own symlink chain is followed by hand
#      (pwd -P alone only resolves symlinks in the directories you cd
#      through, never the final path segment itself) — because
#      `cat`/summarisation reads whatever the symlink ultimately points at,
#      not the name it was reached by. Without this, `ln -s prod.env
#      notes.txt; Read notes.txt` passed the name-based check on
#      "notes.txt" and then genuinely read+summarised prod.env's content.
#   2. Case-folding: on a machine where the default filesystem is
#      case-insensitive but case-PRESERVING (macOS APFS is the common case),
#      `docker/env/x.txt` and `DOCKER/ENV/x.txt` name the
#      same inode, but only step 1's `pwd -P` corrects that (it returns
#      whatever case the filesystem actually stored). Case-folding here is
#      a SEPARATE, additional need: a literal, single, real file legitimately
#      named `MySecreT.txt` or `DbToKen-dump.txt` is not an aliasing
#      question at all, and the original `*secret*|*Secret*|*SECRET*`-style
#      patterns only covered three fixed forms out of the many real mixed
#      casings — case-folding both the check target and every pattern below
#      to lowercase covers all of them at once instead of enumerating more
#      forms.
#
# ---------------------------------------------------------------------------
# Fails open, always
# ---------------------------------------------------------------------------
#
# Missing jq, an unreadable file, a line count that can't be determined, a
# missing session_id (shunting without one can't be reliably un-shunted, so
# it's treated as ambiguous), a symlink chain that doesn't resolve within a
# bounded number of hops (possible loop), no path-hashing tool available to
# derive a collision-resistant state-marker key, a `claude` binary not on
# PATH, or the haiku subprocess timing out or exiting non-zero: every one of
# these allows the real Read/cat through unshunted rather than blocking or
# silently losing content. A false negative (a big file makes it through
# whole) only costs tokens; a false positive that ever ate content someone
# needed would be a correctness bug in a repo whose docs are trusted as
# ground truth.
#
# NOT a separate "stdin is not valid JSON" check: this hook used to run one,
# but review rebuilt the exact single-line-removal mutant and
# confirmed all 31 selftest assertions still pass without it — every field
# this script reads comes through `jq -r '... // empty'` followed by its own
# `[ -n "$X" ] || fail_open`, so malformed/truncated/multi-document stdin
# already fails open via those, and the extra check was proven dead rather
# than merely suspected. Removed rather than kept as an untested assertion —
# see this project's testing-philosophy.md self-verification-independence rule.
#
# ---------------------------------------------------------------------------
# Overridable for testing (defaults are what a real session actually uses)
# ---------------------------------------------------------------------------
#
#   READ_SHUNT_THRESHOLD    line count above which a file is shunted (400)
#   READ_SHUNT_CLAUDE_BIN   the summariser binary (claude)
#   READ_SHUNT_MODEL        the summariser model (haiku) — reading this from
#                           a project config file (providers/config.toml)
#                           instead is not landed yet; the env var
#                           stays the override in the meantime.
#   READ_SHUNT_TIMEOUT      seconds before the summariser subprocess is
#                           killed and this hook fails open (45)
#   READ_SHUNT_STATE_ROOT   root dir for per-session shunt markers
#                           (${TMPDIR:-/tmp}/read-shunt-state)
#
# Dependencies: bash 3.2, jq, readlink, and one of shasum/md5/openssl (all
# ship on macOS). The `claude` binary and the hashing tool are both only
# required on the shunt path itself — their absence fails open, neither
# errors the hook.

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

# --- Normalize a path without requiring it to exist (bash 3.2, no realpath
# dependency) — same collapse-. -and-.. approach as guard-fs-writes.sh's own
# normalize_path, reimplemented here rather than sourced, since this script
# has no dependency on that one otherwise. -----------------------------------
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

# physical_path: resolve $1 to its real, symlink-free, filesystem-canonical
# form. $1 must already exist (caller checks -e first). Two things a plain
# lexical normalize_path() cannot do (review, both live-repro'd):
#
#   1. Directory components may themselves be symlinks, or on a
#      case-insensitive-but-case-preserving filesystem (macOS APFS default)
#      may have been spelled in a different case than the filesystem stored
#      them in — `cd "$dir" && pwd -P` resolves both at once, the same
#      technique guard-fs-writes.sh's own PWD_PHYS relies on.
#   2. The FINAL path component may itself be a symlink — `pwd -P` on its
#      containing directory does not follow that, so it's resolved here by
#      hand, one hop at a time, re-canonicalizing the directory portion
#      after every hop (a relative symlink target is relative to the
#      symlink's OWN directory, which can change hop to hop). Bounded at 40
#      hops so a symlink loop fails (prints nothing, returns 1) rather than
#      spinning forever — the caller treats that as "cannot resolve, fail
#      open", the same posture as every other ambiguous case in this script.
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

# key_for_path: a collision-resistant state-marker key for $1. NOT a plain
# `tr '/' '_'` — that collapsed distinct paths that already contain an
# underscore onto the same key (review, live-repro'd:
# /coll/a/b_c.txt and /coll/a_b/c.txt both became ..._coll_a_b_c.txt), which
# broke the escape-hatch guarantee in both directions (a brand-new file
# silently skipping its first, intended shunt because an unrelated path's
# marker collided with it; or a legitimately-shunted file's marker getting
# read back for the wrong path). A cryptographic hash of the full resolved
# path has no such collision in practice. Tries shasum, then md5 (BSD, ships
# on macOS at /sbin, not always on a bare PATH), then openssl; if none are on
# PATH, returns 1 — the caller fails open rather than dedupe unsafely.
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

# is_secret_path: see the header's "Never shunts a secrets-bearing path"
# section for the rationale, the list, and why $1 must already be a
# physical_path()-resolved, lowercased string by the time it gets here (this
# function does not itself resolve or fold — see the call site).
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

# --- Resolve which tool this hook call is for, and the candidate path ------

case "$TOOL_NAME" in
  Read)
    FILE_PATH="$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    [ -n "$FILE_PATH" ] || fail_open "no .tool_input.file_path for Read"
    ;;
  Bash)
    CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [ -n "$CMD" ] || exit 0

    # Reject anything with shell syntax this best-effort matcher does not
    # attempt to parse: pipes, redirects, substitutions, chaining, variables.
    # shellcheck disable=SC2016 # literal patterns being matched against, not expanded
    case "$CMD" in
      *'|'*|*';'*|*'&'*|*'>'*|*'<'*|*'$('*|*'`'*|*'$'*)
        exit 0
        ;;
    esac

    # bash 3.2: plain word-split tokenize (no quoting support — deliberately
    # narrow, see header). set -- inside a function is function-local.
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
            # more than one file argument — not a simple single-file cat
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

# --- Resolve to the real physical file, THEN check the secrets exclusion --
#
# Order matters: existence has to be confirmed lexically first (physical_path
# needs a real directory to `cd` into), but the secrets check runs against
# the fully symlink-resolved, case-folded PHYSICAL path — never the raw,
# possibly-aliased, possibly-symlinked FILE_PATH the caller supplied. See the
# header's "Never shunts a secrets-bearing path" section for why.

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

# --- Escape hatch: has this (session, path) already been shunted once? -----

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

# --- Summarise via a stateless haiku subprocess, with a hand-rolled timeout
# (macOS ships no `timeout`/`gtimeout` by default) --------------------------

command -v "$CLAUDE_BIN" >/dev/null 2>&1 || fail_open "$CLAUDE_BIN not found on PATH"

PROMPT="Summarise the following file for a coding agent that needs to know its structure and key content without reading it in full. Note: file path, total line count, purpose, and any functions/sections/classes present. Keep it under 250 words. Do not reproduce the raw file content verbatim.

FILE: $PHYSICAL ($LINE_COUNT lines)

$(cat "$PHYSICAL" 2>/dev/null)"

SUMMARY_OUT="$SESSION_DIR/.summary.$$"
( "$CLAUDE_BIN" -p --model "$SUMMARY_MODEL" "$PROMPT" < /dev/null > "$SUMMARY_OUT" 2>/dev/null ) &
SUMMARY_PID=$!
# Both background jobs redirect their OWN stdout/stderr away from this
# script's inherited fds. Without this on the watcher, a caller capturing
# this script's output via `$( ... )` blocks until the watcher's `sleep`
# actually finishes (up to $SUMMARY_TIMEOUT) even after this script has
# long since exited — command substitution waits for every process still
# holding the pipe open, not just the one it invoked. Found live: the
# selftest hung for the full default timeout on every successful shunt
# until this redirect was added.
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

# Mark shunted BEFORE printing, so a crash after this point still leaves the
# escape hatch usable (worst case: an unmarked file re-shunts once more,
# never worse than that).
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
