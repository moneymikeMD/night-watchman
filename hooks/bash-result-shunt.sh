#!/bin/bash
#
# bash-result-shunt.sh — Claude Code PreToolUse hook for Bash. Gates the
# largest known-noisy Bash tool results (uncapped `git log`, unfiltered
# `jira-api.sh board`/`raw` search pulls) before they reach the calling
# model's context.
#
# Usage: not a CLI. Fed the PreToolUse payload on stdin; reads `.tool_name`
# and `.tool_input.command`. Nothing is ever summarised and no command output
# is ever inspected — PreToolUse fires BEFORE the command runs, so the only
# size signal available is the command string itself. Deliberately less
# powerful than read-shunt.sh; see memory-graph on why no hook primitive can
# substitute a command's real output.
#
# Exit codes:
#   0  allow
#   2  block, with guidance naming the flag or pipe to add, on stderr —
#      Claude Code surfaces a PreToolUse hook's stderr as the tool's result
#
# Pipeline, in order: strip_heredocs() first, then a `;`/`&&`/`||`/`&`/newline
# split into statements, each into `|`-separated stages, each into
# quote-aware words. Every detector reads $STRIPPED_CMD, never the raw
# command. A shape matches only when a stage's own WORDS say so, so "git log"
# in prose or in a grep pattern does not match, and capping flags are read
# only from that stage. A stage piped to ANYTHING counts as already capped.
#
# Gated shapes, checked in order, first match wins:
#
#   1. `git log` with none of: --oneline, -n<N>/-n N/--max-count[=N], a bare
#      numeric limit (`-5`, `-20`), or a pipe. `--since`/`--until` bound
#      TIME, not output SIZE, and do not count as caps.
#   2. `jira-api.sh board`, or `jira-api.sh raw <path>` where <path> contains
#      `/search` or `/issue`, with no --limit and no pipe. `raw /myself` and
#      other single-object reads are not gated.
#
# Deliberately NOT gated: `issues.py board`/`waves` — it has no filter flag
# at all, so gating it would block the exact command every session-start is
# told to run, with nothing available to add.
#
# Escape hatch: the first (session_id, exact command string) is blocked; the
# identical command again in the same session is allowed through. Nothing is
# ever permanently un-runnable.
#
# Never gates a command naming a credential tool or token (op/1Password, a
# literal `.env` file, an actual `docker inspect`, or a word containing
# secret/credential/token) as one of its own shell WORDS. A courtesy skip,
# not a security control: this hook never reads or prints a command's output,
# and the block message never echoes the command text back.
#
# Fails open on malformed input: missing jq, an empty or absent tool_name or
# command, a missing or path-unsafe session_id, no hashing tool on PATH. A
# false negative only costs tokens; a false positive stalls an agent.
#
# HAZARD: that guarantee covers malformed input to a WORKING script. A bash
# parse error in this file exits non-zero before any fail_open() runs, and
# PreToolUse reads a non-zero exit as BLOCK — shellcheck and the selftest
# before deployment are the only guard against it.
#
# Overridable for testing:
#   BASH_SHUNT_STATE_ROOT   root dir for per-session gate markers
#                           (${TMPDIR:-/tmp}/bash-result-shunt-state)
#
# Dependencies: bash 3.2, jq, and one of shasum/md5/openssl (all ship on
# macOS). No `claude` binary dependency at all — this hook never summarises.

set -u

STATE_ROOT="${BASH_SHUNT_STATE_ROOT:-${TMPDIR:-/tmp}/bash-result-shunt-state}"

fail_open() {
  echo "bash-result-shunt.sh: $1 — failing open (allow)" >&2
  exit 0
}

command -v jq >/dev/null 2>&1 || fail_open "jq not found on PATH"

INPUT="$(cat)"
[ -n "$INPUT" ] || fail_open "empty stdin"

TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"

[ -n "$TOOL_NAME" ] || fail_open "no .tool_name in hook payload"
[ "$TOOL_NAME" = "Bash" ] || exit 0

CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$CMD" ] || exit 0

# split_segments: quote-aware split of a command string into pipeline stages.
# Populates SEG_TEXT[] and SEG_SEP[] (the operator ending each stage, "" for
# the last). Quoted separators never split.
split_segments() {
  _ss_s="$1"
  SEG_TEXT=()
  SEG_SEP=()
  _ss_cur=""
  _ss_q=""
  _ss_len=${#_ss_s}
  _ss_i=0
  while [ "$_ss_i" -lt "$_ss_len" ]; do
    _ss_c="${_ss_s:$_ss_i:1}"
    if [ -n "$_ss_q" ]; then
      _ss_cur="$_ss_cur$_ss_c"
      [ "$_ss_c" = "$_ss_q" ] && _ss_q=""
      _ss_i=$((_ss_i + 1))
      continue
    fi
    case "$_ss_c" in
      "'" | '"')
        _ss_q="$_ss_c"
        _ss_cur="$_ss_cur$_ss_c"
        _ss_i=$((_ss_i + 1))
        ;;
      ";")
        SEG_TEXT+=("$_ss_cur"); SEG_SEP+=(";")
        _ss_cur=""
        _ss_i=$((_ss_i + 1))
        ;;
      $'\n')
        SEG_TEXT+=("$_ss_cur"); SEG_SEP+=(";")
        _ss_cur=""
        _ss_i=$((_ss_i + 1))
        ;;
      "&")
        # An '&' adjacent to '>' or '<' is part of a redirection operator, not
        # a separator — bash never splits a statement there, and neither must we.
        _ss_prevc=""
        [ "${#_ss_cur}" -gt 0 ] && _ss_prevc="${_ss_cur:$((${#_ss_cur} - 1)):1}"
        _ss_nextc="${_ss_s:$((_ss_i + 1)):1}"
        if [ "$_ss_prevc" = ">" ] || [ "$_ss_prevc" = "<" ] || [ "$_ss_nextc" = ">" ]; then
          _ss_cur="$_ss_cur$_ss_c"
          _ss_i=$((_ss_i + 1))
        elif [ "$_ss_nextc" = "&" ]; then
          SEG_TEXT+=("$_ss_cur"); SEG_SEP+=("&&")
          _ss_cur=""
          _ss_i=$((_ss_i + 2))
        else
          SEG_TEXT+=("$_ss_cur"); SEG_SEP+=("&")
          _ss_cur=""
          _ss_i=$((_ss_i + 1))
        fi
        ;;
      "|")
        if [ "${_ss_s:$((_ss_i + 1)):1}" = "|" ]; then
          SEG_TEXT+=("$_ss_cur"); SEG_SEP+=("||")
          _ss_i=$((_ss_i + 2))
        else
          SEG_TEXT+=("$_ss_cur"); SEG_SEP+=("|")
          _ss_i=$((_ss_i + 1))
        fi
        _ss_cur=""
        ;;
      *)
        _ss_cur="$_ss_cur$_ss_c"
        _ss_i=$((_ss_i + 1))
        ;;
    esac
  done
  SEG_TEXT+=("$_ss_cur")
  SEG_SEP+=("")
}

# tokenize: quote-aware split of one segment/stage into shell words, into
# TOKENS[]. An unquoted '#' starting a fresh word begins a comment, and
# everything from there to the end of the stage is dropped.
tokenize() {
  _tk_s="$1"
  TOKENS=()
  _tk_cur=""
  _tk_have=0
  _tk_q=""
  _tk_len=${#_tk_s}
  _tk_i=0
  while [ "$_tk_i" -lt "$_tk_len" ]; do
    _tk_c="${_tk_s:$_tk_i:1}"
    if [ -n "$_tk_q" ]; then
      _tk_cur="$_tk_cur$_tk_c"
      _tk_have=1
      [ "$_tk_c" = "$_tk_q" ] && _tk_q=""
      _tk_i=$((_tk_i + 1))
      continue
    fi
    case "$_tk_c" in
      "'" | '"')
        _tk_q="$_tk_c"
        _tk_cur="$_tk_cur$_tk_c"
        _tk_have=1
        _tk_i=$((_tk_i + 1))
        ;;
      " " | $'\t')
        [ "$_tk_have" -eq 1 ] && TOKENS+=("$_tk_cur")
        _tk_cur=""
        _tk_have=0
        _tk_i=$((_tk_i + 1))
        ;;
      "#")
        if [ "$_tk_have" -eq 0 ]; then
          break
        else
          _tk_cur="$_tk_cur$_tk_c"
          _tk_have=1
          _tk_i=$((_tk_i + 1))
        fi
        ;;
      *)
        _tk_cur="$_tk_cur$_tk_c"
        _tk_have=1
        _tk_i=$((_tk_i + 1))
        ;;
    esac
  done
  [ "$_tk_have" -eq 1 ] && TOKENS+=("$_tk_cur")
}

# is_stdin_executor_stage: does the current stage's TOKENS[] name a command
# that reads its heredoc body as COMMANDS (ssh, a bare shell, python), not as
# data? Every token is checked, to catch `pct exec 100 -- bash` and `sudo sh`.
is_stdin_executor_stage() {
  _ise_i=0
  while [ "$_ise_i" -lt "${#TOKENS[@]}" ]; do
    case "${TOKENS[$_ise_i]}" in
      ssh | bash | sh | zsh | dash | python | python3 | */ssh | */bash | */sh | */zsh | */dash | */python | */python3)
        return 0
        ;;
    esac
    _ise_i=$((_ise_i + 1))
  done
  return 1
}

# strip_heredocs: remove heredoc BODY text attached to a command that merely
# READS the body as data, so prose is never parsed as further shell syntax. A
# stdin-executing interpreter's body is left in place (its body IS commands).
strip_heredocs() {
  _sh_s="$1"
  _sh_out=""
  _sh_len=${#_sh_s}
  _sh_i=0
  _sh_q=""
  _sh_stage_start=0
  _sh_word_start=1
  _sh_in_comment=0
  while [ "$_sh_i" -lt "$_sh_len" ]; do
    _sh_c="${_sh_s:$_sh_i:1}"

    if [ -n "$_sh_q" ]; then
      _sh_out="$_sh_out$_sh_c"
      [ "$_sh_c" = "$_sh_q" ] && _sh_q=""
      _sh_i=$((_sh_i + 1))
      _sh_word_start=0
      continue
    fi

    if [ "$_sh_in_comment" -eq 1 ]; then
      _sh_out="$_sh_out$_sh_c"
      _sh_i=$((_sh_i + 1))
      if [ "$_sh_c" = $'\n' ]; then
        _sh_in_comment=0
        _sh_stage_start=$_sh_i
        _sh_word_start=1
      fi
      continue
    fi

    case "$_sh_c" in
      "'" | '"')
        _sh_q="$_sh_c"
        _sh_out="$_sh_out$_sh_c"
        _sh_i=$((_sh_i + 1))
        _sh_word_start=0
        ;;
      "#")
        _sh_out="$_sh_out$_sh_c"
        _sh_i=$((_sh_i + 1))
        [ "$_sh_word_start" -eq 1 ] && _sh_in_comment=1
        _sh_word_start=0
        ;;
      ";")
        _sh_out="$_sh_out$_sh_c"
        _sh_i=$((_sh_i + 1))
        _sh_stage_start=$_sh_i
        _sh_word_start=1
        ;;
      $'\n')
        _sh_out="$_sh_out$_sh_c"
        _sh_i=$((_sh_i + 1))
        _sh_stage_start=$_sh_i
        _sh_word_start=1
        ;;
      " " | $'\t')
        _sh_out="$_sh_out$_sh_c"
        _sh_i=$((_sh_i + 1))
        _sh_word_start=1
        ;;
      "&")
        _sh_prevc=""
        [ "${#_sh_out}" -gt 0 ] && _sh_prevc="${_sh_out:$((${#_sh_out} - 1)):1}"
        _sh_nextc="${_sh_s:$((_sh_i + 1)):1}"
        if [ "$_sh_prevc" = ">" ] || [ "$_sh_prevc" = "<" ] || [ "$_sh_nextc" = ">" ]; then
          _sh_out="$_sh_out$_sh_c"
          _sh_i=$((_sh_i + 1))
          _sh_word_start=0
        elif [ "$_sh_nextc" = "&" ]; then
          _sh_out="$_sh_out&&"
          _sh_i=$((_sh_i + 2))
          _sh_stage_start=$_sh_i
          _sh_word_start=1
        else
          _sh_out="$_sh_out$_sh_c"
          _sh_i=$((_sh_i + 1))
          _sh_stage_start=$_sh_i
          _sh_word_start=1
        fi
        ;;
      "|")
        if [ "${_sh_s:$((_sh_i + 1)):1}" = "|" ]; then
          _sh_out="$_sh_out||"
          _sh_i=$((_sh_i + 2))
        else
          _sh_out="$_sh_out|"
          _sh_i=$((_sh_i + 1))
        fi
        _sh_stage_start=$_sh_i
        _sh_word_start=1
        ;;
      "<")
        _sh_n1="${_sh_s:$((_sh_i + 1)):1}"
        if [ "$_sh_n1" != "<" ]; then
          _sh_out="$_sh_out$_sh_c"
          _sh_i=$((_sh_i + 1))
          _sh_word_start=0
        else
          _sh_n2="${_sh_s:$((_sh_i + 2)):1}"
          if [ "$_sh_n2" = "<" ]; then
            # <<< here-string: its argument is on this same line, no body
            # to strip.
            _sh_out="$_sh_out<<<"
            _sh_i=$((_sh_i + 3))
            _sh_word_start=0
          else
            _sh_stage_text="${_sh_s:$_sh_stage_start:$((_sh_i - _sh_stage_start))}"
            tokenize "$_sh_stage_text"
            if is_stdin_executor_stage; then
              _sh_out="$_sh_out<<"
              _sh_i=$((_sh_i + 2))
              _sh_word_start=0
            else
              _sh_k=$((_sh_i + 2))
              _sh_dash=0
              if [ "${_sh_s:$_sh_k:1}" = "-" ]; then
                _sh_dash=1
                _sh_k=$((_sh_k + 1))
              fi
              while [ "${_sh_s:$_sh_k:1}" = " " ] || [ "${_sh_s:$_sh_k:1}" = $'\t' ]; do
                _sh_k=$((_sh_k + 1))
              done
              _sh_dq=""
              case "${_sh_s:$_sh_k:1}" in
                "'" | '"' | "\\")
                  _sh_dq="${_sh_s:$_sh_k:1}"
                  _sh_k=$((_sh_k + 1))
                  ;;
              esac
              _sh_delim=""
              if [ "$_sh_dq" = "'" ] || [ "$_sh_dq" = '"' ]; then
                # Quoted delimiter word: every character up to the matching
                # quote — a delimiter is a shell word, not [A-Za-z0-9_] only.
                while :; do
                  _sh_dc="${_sh_s:$_sh_k:1}"
                  if [ -z "$_sh_dc" ] || [ "$_sh_dc" = "$_sh_dq" ]; then
                    break
                  fi
                  _sh_delim="$_sh_delim$_sh_dc"
                  _sh_k=$((_sh_k + 1))
                done
                if [ "${_sh_s:$_sh_k:1}" = "$_sh_dq" ]; then
                  _sh_k=$((_sh_k + 1))
                else
                  _sh_delim="" # unterminated quote: not a real delimiter
                fi
              else
                while :; do
                  _sh_dc="${_sh_s:$_sh_k:1}"
                  case "$_sh_dc" in
                    "" | " " | $'\t' | $'\n') break ;;
                    *)
                      _sh_delim="$_sh_delim$_sh_dc"
                      _sh_k=$((_sh_k + 1))
                      ;;
                  esac
                done
              fi
              if [ -z "$_sh_delim" ]; then
                # Not a recognisable heredoc delimiter — pass '<<' through
                # unchanged rather than guess.
                _sh_out="$_sh_out<<"
                _sh_i=$((_sh_i + 2))
                _sh_word_start=0
              else
                _sh_out="$_sh_out${_sh_s:$_sh_i:$((_sh_k - _sh_i))}"
                _sh_i=$_sh_k
                while [ "$_sh_i" -lt "$_sh_len" ] && [ "${_sh_s:$_sh_i:1}" != $'\n' ]; do
                  _sh_out="$_sh_out${_sh_s:$_sh_i:1}"
                  _sh_i=$((_sh_i + 1))
                done
                if [ "$_sh_i" -lt "$_sh_len" ]; then
                  _sh_out="$_sh_out"$'\n'
                  _sh_i=$((_sh_i + 1))
                fi
                # $_sh_body_start marks the discarded span so it can be
                # restored verbatim if the terminator is never found.
                _sh_body_start=$_sh_i
                _sh_found_term=0
                while [ "$_sh_i" -lt "$_sh_len" ]; do
                  _sh_line_start=$_sh_i
                  while [ "$_sh_i" -lt "$_sh_len" ] && [ "${_sh_s:$_sh_i:1}" != $'\n' ]; do
                    _sh_i=$((_sh_i + 1))
                  done
                  _sh_line="${_sh_s:$_sh_line_start:$((_sh_i - _sh_line_start))}"
                  if [ "$_sh_i" -lt "$_sh_len" ]; then
                    _sh_i=$((_sh_i + 1))
                  fi
                  _sh_check="$_sh_line"
                  if [ "$_sh_dash" -eq 1 ]; then
                    while [ "${_sh_check:0:1}" = $'\t' ]; do
                      _sh_check="${_sh_check#?}"
                    done
                  fi
                  if [ "$_sh_check" = "$_sh_delim" ]; then
                    _sh_found_term=1
                    break
                  fi
                done
                if [ "$_sh_found_term" -eq 0 ]; then
                  # Restore the whole discarded span rather than let an
                  # unmatched heredoc silently vanish to end-of-string.
                  _sh_out="$_sh_out${_sh_s:$_sh_body_start:$((_sh_i - _sh_body_start))}"
                fi
                _sh_stage_start=$_sh_i
                _sh_word_start=1
              fi
            fi
          fi
        fi
        ;;
      *)
        _sh_out="$_sh_out$_sh_c"
        _sh_i=$((_sh_i + 1))
        _sh_word_start=0
        ;;
    esac
  done
  printf '%s' "$_sh_out"
}

# --- token_is_cmd: does token $1 name command $2, bare or by path
# (`git`, `/usr/bin/git`; `issues.py`, `scripts/dev/issues.py`)? -----------
token_is_cmd() {
  case "$1" in
    "$2" | *"/$2") return 0 ;;
  esac
  return 1
}

# is_secret_command: never gate a credential-handling command (see header).
# Matches actual shell WORDS in each stage, never substrings of the raw text.
is_secret_command() {
  split_segments "$1"
  _isc_i=0
  while [ "$_isc_i" -lt "${#SEG_TEXT[@]}" ]; do
    tokenize "${SEG_TEXT[$_isc_i]}"
    _isc_j=0
    while [ "$_isc_j" -lt "${#TOKENS[@]}" ]; do
      _isc_tok="$(printf '%s' "${TOKENS[$_isc_j]}" | tr '[:upper:]' '[:lower:]')"
      case "$_isc_tok" in
        op | 1password) return 0 ;;
        *.env) return 0 ;;
        *secret* | *credential* | *token*) return 0 ;;
        docker)
          _isc_next=$((_isc_j + 1))
          if [ "$_isc_next" -lt "${#TOKENS[@]}" ]; then
            _isc_nt="$(printf '%s' "${TOKENS[$_isc_next]}" | tr '[:upper:]' '[:lower:]')"
            [ "$_isc_nt" = "inspect" ] && return 0
          fi
          ;;
      esac
      _isc_j=$((_isc_j + 1))
    done
    _isc_i=$((_isc_i + 1))
  done
  return 1
}
# Every check from here on reads $STRIPPED_CMD, never raw $CMD.
STRIPPED_CMD="$(strip_heredocs "$CMD")"

is_secret_command "$STRIPPED_CMD" && exit 0

# key_for_string: collision-resistant marker key, same rationale as
# read-shunt.sh's key_for_path.
key_for_string() {
  _kfs_s="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$_kfs_s" | shasum -a 256 2>/dev/null | awk '{print $1}'
    return 0
  fi
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$_kfs_s" | md5 2>/dev/null
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$_kfs_s" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
    return 0
  fi
  return 1
}

# Each is_uncapped_* below finds the stage that IS the invocation (by shell
# word, not substring) and reads capping flags and the piped-or-not verdict
# only from that stage, never from the whole command line.

is_uncapped_git_log() {
  split_segments "$1"
  _iug_i=0
  _iug_found=0
  _iug_uncapped=0
  while [ "$_iug_i" -lt "${#SEG_TEXT[@]}" ]; do
    tokenize "${SEG_TEXT[$_iug_i]}"
    if [ "${#TOKENS[@]}" -ge 2 ] && token_is_cmd "${TOKENS[0]}" "git" && [ "${TOKENS[1]}" = "log" ]; then
      _iug_found=1
      _iug_capped=1
      _iug_j=2
      while [ "$_iug_j" -lt "${#TOKENS[@]}" ]; do
        case "${TOKENS[$_iug_j]}" in
          --oneline | --max-count | --max-count=* | -n | -n[0-9]* | -[0-9]*)
            _iug_capped=0
            ;;
        esac
        _iug_j=$((_iug_j + 1))
      done
      if [ "$_iug_capped" -eq 1 ] && [ "${SEG_SEP[$_iug_i]}" = "|" ]; then
        _iug_capped=0
      fi
      [ "$_iug_capped" -eq 1 ] && _iug_uncapped=1
    fi
    _iug_i=$((_iug_i + 1))
  done
  # Scan EVERY stage: `git log --oneline -5; git log` must still gate on the
  # uncapped one.
  [ "$_iug_found" -eq 1 ] || return 1
  [ "$_iug_uncapped" -eq 1 ] && return 0
  return 1
}

# --- is_noisy_raw_path: only collection/search-shaped `jira-api.sh raw`
# paths are worth gating — a single-object read like `/myself` is cheap. --
is_noisy_raw_path() {
  case "$1" in
    *"/search"* | *"/issue"*) return 0 ;;
  esac
  return 1
}

is_uncapped_jira_board() {
  split_segments "$1"
  _iub_i=0
  _iub_found=0
  _iub_uncapped=0
  while [ "$_iub_i" -lt "${#SEG_TEXT[@]}" ]; do
    tokenize "${SEG_TEXT[$_iub_i]}"
    _iub_j=0
    while [ "$_iub_j" -lt "${#TOKENS[@]}" ]; do
      if token_is_cmd "${TOKENS[$_iub_j]}" "jira-api.sh"; then
        _iub_next=$((_iub_j + 1))
        _iub_applies=1
        if [ "$_iub_next" -lt "${#TOKENS[@]}" ] && [ "${TOKENS[$_iub_next]}" = "board" ]; then
          :
        elif [ "$_iub_next" -lt "${#TOKENS[@]}" ] && [ "${TOKENS[$_iub_next]}" = "raw" ]; then
          _iub_path=""
          _iub_pathidx=$((_iub_next + 1))
          [ "$_iub_pathidx" -lt "${#TOKENS[@]}" ] && _iub_path="${TOKENS[$_iub_pathidx]}"
          is_noisy_raw_path "$_iub_path" || _iub_applies=0
        else
          _iub_applies=0
        fi
        if [ "$_iub_applies" -eq 1 ]; then
          _iub_found=1
          _iub_capped=1
          _iub_k=$((_iub_next + 1))
          while [ "$_iub_k" -lt "${#TOKENS[@]}" ]; do
            case "${TOKENS[$_iub_k]}" in
              --limit) _iub_capped=0 ;;
            esac
            _iub_k=$((_iub_k + 1))
          done
          if [ "$_iub_capped" -eq 1 ] && [ "${SEG_SEP[$_iub_i]}" = "|" ]; then
            _iub_capped=0
          fi
          [ "$_iub_capped" -eq 1 ] && _iub_uncapped=1
          break
        fi
      fi
      _iub_j=$((_iub_j + 1))
    done
    _iub_i=$((_iub_i + 1))
  done
  # Scan EVERY stage rather than returning on the first match.
  [ "$_iub_found" -eq 1 ] || return 1
  [ "$_iub_uncapped" -eq 1 ] && return 0
  return 1
}

GUIDANCE=""
if is_uncapped_git_log "$STRIPPED_CMD"; then
  GUIDANCE="'git log' with no cap returns the full commit history into your context. Re-run with a cap, e.g. 'git log --oneline -20' or 'git log -n 20', or pipe through '| head -40' if you need full messages for a few commits."
elif is_uncapped_jira_board "$STRIPPED_CMD"; then
  GUIDANCE="An unfiltered 'jira-api.sh board'/'raw' pull can return a large result set into your context. Re-run with '--limit', or pipe the output through 'jq' to extract only the fields you need."
else
  exit 0
fi

[ -n "$SESSION_ID" ] || fail_open "no .session_id in hook payload, cannot dedupe safely"

# session_id is hook-payload input about to become a path component: reject
# anything that could escape $STATE_ROOT (e.g. "../../../tmp/pwned").
case "$SESSION_ID" in
  */* | *..*)
    fail_open "session_id contains a path separator or '..', refusing to use it in a path"
    ;;
esac

SESSION_DIR="$STATE_ROOT/$SESSION_ID"
mkdir -p "$SESSION_DIR" 2>/dev/null || fail_open "could not create state dir $SESSION_DIR"

KEY="$(key_for_string "$CMD")" || fail_open "no hashing tool (shasum/md5/openssl) on PATH, cannot dedupe safely"
[ -n "$KEY" ] || fail_open "empty key derived for command"
MARKER="$SESSION_DIR/$KEY"

if [ -e "$MARKER" ]; then
  # Already gated once this session with this exact command — let it run.
  exit 0
fi

: > "$MARKER" 2>/dev/null || fail_open "could not write gate marker $MARKER"

{
  echo "[bash-result-shunt] this command is a known large-output shape and was"
  echo "blocked before running, to avoid dumping an uncapped result into your"
  echo "context. $GUIDANCE"
  echo ""
  echo "If you run the EXACT SAME command again in this session, it will be"
  echo "allowed through unblocked — use that if the cap genuinely does not"
  echo "apply here."
} >&2

exit 2
