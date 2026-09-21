#!/bin/bash
#
# guard-fs-writes.sh — Claude Code PreToolUse hook for the Bash tool.
# Enforces "agents write only inside their own trees" deterministically,
# rather than as prose in a CLAUDE.md a fresh subagent can read and violate.
#
# Usage: not a CLI. Claude Code feeds it the PreToolUse payload on stdin; it
# reads `.tool_input.command` (literal, pre-expansion text) and `.cwd` (the
# recorded working directory the call ran from, falling back to this
# process's own `pwd -P`).
#
# Exit codes:
#   0  allow — including every case it cannot make sense of (see Fail posture)
#   2  block — $RULE_TEXT plus the offending construct on stderr, which
#      Claude Code surfaces to the calling model as the tool's result
#
# Blocks when the command:
#
#   - is `git [global-opts] {stash|reset|clean}`, or `git [global-opts]
#     checkout [...] -- [...]`, against the MAIN worktree. A linked worktree
#     only touches its own tree, so it is allowed there. `git stash list`
#     and `git stash show` are read-only and are never blocked; every other
#     stash form is.
#   - is `find [paths...] {-delete|-exec|-execdir|-ok|-okdir}` with a leading
#     path resolving outside worktree+scratchpad. The path is checked BEFORE
#     any -exec/-execdir/-ok command list is looked at.
#   - is `xargs [opts] {rm|mv}` at all, unconditionally: xargs's real targets
#     are stdin-sourced and this hook cannot see stdin, so it blocks rather
#     than guess.
#   - carries an `rm -r`/`rm -rf`, `mv`, or `>`/`>>` whose target resolves
#     outside BOTH the current worktree AND the session scratchpad, and is
#     not one of /dev/null, /dev/stdout, /dev/stderr, /dev/tty — a fixed
#     list, not a `/dev/*` glob, so `/dev/disk0` still blocks.
#
# Quoting, in one paragraph: a word STARTING with `'` or `"` is data and is
# never rescanned — except a `$( ... )` body inside a DOUBLE-quoted word,
# which really does execute. The only quoted text still scanned as commands
# is what a shell re-executes: `bash -c`, `sh -c`, `eval`, xargs's target,
# `find ... -exec`. ssh/scp/rsync/mosh are the opposite — once one is a
# segment's own command word its argv is opaque, though an unquoted trailing
# LOCAL redirect on that line is still checked.
#
# Own tree: with a git repo at cwd, EVERY worktree of that repo (`git
# worktree list`) counts as "my own tree", not just the one cwd itself sits
# in — a call whose cwd drifted to a sibling worktree, or to the main one,
# can still write into a linked worktree it owns. With no repo at cwd,
# WORKTREE falls back to cwd alone. Either way, `/`, /tmp, /private/tmp,
# /var, /private/var, /Users, /home, /private and a bare $HOME never count
# as "my own tree" — only the scratchpad exemption can allow a target there.
#
# Fail posture: missing jq, invalid JSON on stdin, or no `.tool_input.command`
# prints a note and exits 0 — a hook that dies on malformed input blocks every
# Bash call in the session. Two deliberate fail-CLOSED exceptions: a single
# rm/mv/redirect target that cannot be resolved to a real path still blocks,
# and if the target repo's git-dir cannot be determined the stash/reset/
# clean/checkout-`--` block stays in force.
#
# Command heads are matched by typed name (`rm`, and `*/rm` so an absolute or
# relative path still matches) against every word. A word in COMMAND position
# that matches no such name is then resolved on disk and matched by the
# basename it resolves to, so a shim named anything is caught as what it runs.
#
# This is a text scanner, not a shell parser, and a guard against the
# honest-mistake case, not a sandbox. Segment splitting on `;`/`&&`/`||`/`|`
# is quote-aware: a separator inside a single- or double-quoted span is data,
# never a boundary. The named bypasses it does not chase, and the reasoning
# behind every rule above, are in memory-graph (tag guard-fs-writes) and
# docs/known-issues/.
#
# Dependencies: bash 3.2, jq, git. Nothing else — this runs on every Bash
# call in the session, so it stays small and it stays fast.

set -u

RULE_TEXT='guard-fs-writes guard: this command is blocked. git stash/checkout --/reset/clean against the MAIN worktree (not a linked one) mutate the CURRENT tree, which may be shared with sibling agents doing uncommitted work ("agents write only inside their own trees") — use a WIP commit or a worktree instead (git stash list/show are read-only and are not blocked). find -delete and any xargs rm/mv are blocked the same way (xargs targets are stdin-sourced and unverifiable). An rm -r/-rf, mv, or > redirect whose target resolves outside both this worktree and the session scratchpad is blocked too — write only inside your own tree.'

fail_open() {
  echo "guard-fs-writes.sh: $1 — failing open (allow)" >&2
  exit 0
}

command -v jq >/dev/null 2>&1 || fail_open "jq not found on PATH"
command -v git >/dev/null 2>&1 || fail_open "git not found on PATH"

INPUT="$(cat)"
[ -n "$INPUT" ] || fail_open "empty stdin"

echo "$INPUT" | jq -e . >/dev/null 2>&1 || fail_open "stdin is not valid JSON"

CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$CMD" ] || fail_open "no .tool_input.command in hook payload"

PAYLOAD_CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"

block() {
  echo "$RULE_TEXT" >&2
  echo "guard-fs-writes.sh: blocked on: $1" >&2
  exit 2
}

# Resolve to the physical (symlink-resolved) form: `git rev-parse
# --show-toplevel` always returns one, a bare cd/$PWD does not (on macOS
# $TMPDIR resolves under /var/folders, itself a symlink to /private/var).
if [ -n "$PAYLOAD_CWD" ]; then
  PWD_PHYS="$(cd "$PAYLOAD_CWD" 2>/dev/null && pwd -P)"
  [ -n "$PWD_PHYS" ] || PWD_PHYS="$(pwd -P)"
else
  PWD_PHYS="$(pwd -P)"
fi

# Broad-root guard (see header): a shallow, shared/system directory never
# counts as "my own worktree" even as a fallback.
is_broad_root() {
  case "$1" in
    ""|"/") return 0 ;;
    "/tmp"|"/private/tmp"|"/var"|"/private/var"|"/Users"|"/home"|"/private") return 0 ;;
    *)
      if [ -n "${HOME:-}" ] && [ "$1" = "$HOME" ]; then
        return 0
      fi
      return 1
      ;;
  esac
}

WORKTREE="$(git -C "$PWD_PHYS" rev-parse --show-toplevel 2>/dev/null)"

# WORKTREE_ROOTS: every worktree of the repo at cwd (main + linked), not
# just the one cwd sits in (WO-023) — from `git worktree list --porcelain`,
# broad roots filtered same as the single-root fallback below. No repo at
# cwd means no enumeration; that fallback stays exactly as narrow as before.
WORKTREE_ROOTS=()
if [ -n "$WORKTREE" ]; then
  while IFS= read -r _wtl_line; do
    case "$_wtl_line" in
      "worktree "*)
        _wtl_path="${_wtl_line#worktree }"
        _wtl_phys="$(cd "$_wtl_path" 2>/dev/null && pwd -P)"
        [ -n "$_wtl_phys" ] || _wtl_phys="$_wtl_path"
        is_broad_root "$_wtl_phys" || WORKTREE_ROOTS+=("$_wtl_phys")
        ;;
    esac
  done <<WTLIST
$(git -C "$PWD_PHYS" worktree list --porcelain 2>/dev/null)
WTLIST
fi

if [ "${#WORKTREE_ROOTS[@]}" -eq 0 ]; then
  [ -n "$WORKTREE" ] || WORKTREE="$PWD_PHYS"
  if is_broad_root "$WORKTREE"; then
    WORKTREE="/__guard-fs-writes-no-valid-worktree__"
  fi
  WORKTREE_ROOTS=("$WORKTREE")
fi

# normalize_path: pure-bash collapse of . and .. in $1, without requiring it
# to exist — realpath/readlink -f are not guaranteed dependencies here.
normalize_path() {
  _np_in="$1"
  # bash 3.2: "${arr[@]}" on a truly EMPTY array throws under `set -u`.
  [ -n "$_np_in" ] || { printf '/'; return 0; }
  case "$_np_in" in
    /*) : ;;
    *) _np_in="$PWD_PHYS/$_np_in" ;;
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

# Expand a word-initial ~ or ~/... to $HOME. ~user/... is left unresolved,
# the same conservative default as everything else this hook will not expand.
expand_tilde() {
  _et_in="$1"
  # shellcheck disable=SC2088 # matching the literal characters ~/..., not asking the shell to expand them
  case "$_et_in" in
    '~')
      printf '%s' "${HOME:-}"
      [ -n "${HOME:-}" ]
      return $?
      ;;
    '~/'*)
      if [ -n "${HOME:-}" ]; then
        printf '%s' "$HOME/${_et_in#\~/}"
        return 0
      fi
      printf '%s' "$_et_in"
      return 1
      ;;
    '~'*)
      printf '%s' "$_et_in"
      return 1
      ;;
    *)
      printf '%s' "$_et_in"
      return 0
      ;;
  esac
}

# Trim leading/trailing space and tab. Runs FIRST in the pipeline: a
# device-allowlist target with trailing whitespace misses the exact-string
# check, reads as outside, and blocks a harmless redirect.
trim_whitespace() {
  _tw_s="$1"
  while true; do
    case "$_tw_s" in
      [\ \	]*) _tw_s="${_tw_s#?}" ;;
      *) break ;;
    esac
  done
  while true; do
    case "$_tw_s" in
      *[\ \	]) _tw_s="${_tw_s%?}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$_tw_s"
}

# Strip ONE layer of matched surrounding quotes ("..." or '...'). A no-op if
# the token is not a single fully-quoted span.
strip_surrounding_quotes() {
  _ssq_s="$1"
  case "$_ssq_s" in
    \"*\")
      _ssq_s="${_ssq_s#\"}"
      _ssq_s="${_ssq_s%\"}"
      ;;
    \'*\')
      _ssq_s="${_ssq_s#\'}"
      _ssq_s="${_ssq_s%\'}"
      ;;
  esac
  printf '%s' "$_ssq_s"
}

# Strip trailing shell-syntax punctuation this hook's quote-unaware extraction
# can pick up from whatever wraps a redirect target. Punctuation-only: a
# genuinely outside path with trailing punctuation is still outside after it.
strip_trailing_punct() {
  _stp_s="$1"
  while true; do
    case "$_stp_s" in
      *[\)\'\"\;\&\|]) _stp_s="${_stp_s%?}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$_stp_s"
}

# Strip trailing segment separators only (`;`, `&`, `|`), never quotes or
# parens: a quoted assignment VALUE's own closing quote must survive this.
strip_trailing_separators() {
  _sts_s="$1"
  while true; do
    case "$_sts_s" in
      *[\;\&\|]) _sts_s="${_sts_s%?}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$_sts_s"
}

_AC_NAMES=()
_AC_VALUES=()

# _ss_opaque needs a real STACK, not one save/restore variable: a second
# nested call would clobber the outer's saved value before it restores it.
_SS_OPAQUE_STACK=()
_ss_opaque_push() {
  _SS_OPAQUE_STACK+=("$_ss_opaque")
}
_ss_opaque_pop() {
  _sop_n="${#_SS_OPAQUE_STACK[@]}"
  _sop_last=$((_sop_n - 1))
  _ss_opaque="${_SS_OPAQUE_STACK[$_sop_last]}"
  unset "_SS_OPAQUE_STACK[$_sop_last]"
}

# Re-entrancy: the three mutually recursive scanners declare their per-call
# state `local`, which bash scopes DYNAMICALLY — a callee writes the
# declaring frame's copy, and a re-entry gets its own. See docs/decisions.md.

# tokenize_quoted_cca: tokenize_quoted's logic writing to its OWN _CCA_WORDS —
# reusing _ss_words would clobber an outer scan_segment loop mid-iteration.
_CCA_WORDS=()
tokenize_quoted_cca() {
  _cqa_line="${1//$'\n'/ }"
  _CCA_WORDS=()
  _cqa_cur=""
  _cqa_in_word=0
  _cqa_len=${#_cqa_line}
  _cqa_i=0
  while [ "$_cqa_i" -lt "$_cqa_len" ]; do
    _cqa_c="${_cqa_line:$_cqa_i:1}"
    case "$_cqa_c" in
      ' '|'	')
        if [ "$_cqa_in_word" -eq 1 ]; then
          _CCA_WORDS+=("$_cqa_cur")
          _cqa_cur=""
          _cqa_in_word=0
        fi
        _cqa_i=$((_cqa_i + 1))
        ;;
      "'")
        _cqa_in_word=1
        _cqa_cur="$_cqa_cur'"
        _cqa_i=$((_cqa_i + 1))
        while [ "$_cqa_i" -lt "$_cqa_len" ]; do
          _cqa_c2="${_cqa_line:$_cqa_i:1}"
          _cqa_cur="$_cqa_cur$_cqa_c2"
          _cqa_i=$((_cqa_i + 1))
          [ "$_cqa_c2" = "'" ] && break
        done
        ;;
      '"')
        _cqa_in_word=1
        _cqa_cur="$_cqa_cur\""
        _cqa_i=$((_cqa_i + 1))
        while [ "$_cqa_i" -lt "$_cqa_len" ]; do
          _cqa_c2="${_cqa_line:$_cqa_i:1}"
          _cqa_cur="$_cqa_cur$_cqa_c2"
          _cqa_i=$((_cqa_i + 1))
          [ "$_cqa_c2" = '"' ] && break
        done
        ;;
      *)
        _cqa_in_word=1
        _cqa_cur="$_cqa_cur$_cqa_c"
        _cqa_i=$((_cqa_i + 1))
        ;;
    esac
  done
  if [ "$_cqa_in_word" -eq 1 ]; then
    _CCA_WORDS+=("$_cqa_cur")
  fi
  return 0
}

# collect_same_command_assignments: records every `NAME=value` token anywhere
# in the command text into _AC_NAMES/_AC_VALUES, so a target in a LATER segment
# still resolves. Quote-aware, so `CMD="git stash"` is captured whole.
collect_same_command_assignments() {
  _cca_text="$1"
  tokenize_quoted_cca "$_cca_text"
  _cca_n="${#_CCA_WORDS[@]}"
  [ "$_cca_n" -eq 0 ] && return 0
  _cca_i=0
  while [ "$_cca_i" -lt "$_cca_n" ]; do
    _cca_w="${_CCA_WORDS[$_cca_i]}"
    case "$_cca_w" in
      [A-Za-z_]*=*)
        _cca_name="${_cca_w%%=*}"
        # Separators first, then unwrap the quotes; strip_trailing_punct runs
        # once more after, for any remaining stray punctuation.
        _cca_val="${_cca_w#*=}"
        _cca_val="$(strip_trailing_separators "$_cca_val")"
        _cca_val="$(strip_surrounding_quotes "$_cca_val")"
        _cca_val="$(strip_trailing_punct "$_cca_val")"
        case "$_cca_name" in
          *[!A-Za-z0-9_]*|"") ;;
          *)
            _AC_NAMES+=("$_cca_name")
            _AC_VALUES+=("$_cca_val")
            ;;
        esac
        ;;
    esac
    _cca_i=$((_cca_i + 1))
  done
  return 0
}

# substitute_same_command_vars: textual replacement of ${NAME}/$NAME for every
# collected NAME, whole-string or embedded. Boundary-naive (see the header).
substitute_same_command_vars() {
  _sscv_s="$1"
  _sscv_n="${#_AC_NAMES[@]}"
  [ "$_sscv_n" -eq 0 ] && { printf '%s' "$_sscv_s"; return 0; }
  _sscv_i=0
  while [ "$_sscv_i" -lt "$_sscv_n" ]; do
    _sscv_name="${_AC_NAMES[$_sscv_i]}"
    _sscv_val="${_AC_VALUES[$_sscv_i]}"
    # shellcheck disable=SC2016 # literal pattern being matched against, not expanded
    case "$_sscv_s" in
      *'${'"$_sscv_name"'}'*)
        _sscv_s="${_sscv_s//\$\{$_sscv_name\}/$_sscv_val}"
        ;;
    esac
    case "$_sscv_s" in
      *'$'"$_sscv_name"*)
        _sscv_s="${_sscv_s//\$$_sscv_name/$_sscv_val}"
        ;;
    esac
    _sscv_i=$((_sscv_i + 1))
  done
  printf '%s' "$_sscv_s"
}

# Expand a bare $NAME / ${NAME} in a candidate target using this process's
# own environment. Refuses (returns the input unchanged, with a marker) if
# the string carries anything that could turn expansion into execution.
safe_expand() {
  _se_in="$1"
  # shellcheck disable=SC2016 # literal patterns being matched against, not expanded
  case "$_se_in" in
    *'$('*|*'`'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*)
      printf '%s' "$_se_in"
      return 1
      ;;
  esac
  eval "printf '%s' \"$_se_in\"" 2>/dev/null
}

is_under() {
  # $1 = normalized path, $2 = normalized prefix directory
  case "$1" in
    "$2") return 0 ;;
    "$2"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# _TIO_LAST_REASON says WHY target_is_outside returned "outside";
# _TIO_LAST_RESOLVED carries the resolved path, so a block message can name
# what was actually checked rather than the raw token.
_TIO_LAST_REASON=""
_TIO_LAST_RESOLVED=""

target_is_outside() {
  # $1 = raw (unexpanded, unnormalized) candidate target string.
  # Returns 0 (true, i.e. "outside, block it") or 1 (false, "inside, allow").
  _tio_raw="$1"
  _TIO_LAST_REASON=""
  _TIO_LAST_RESOLVED=""

  _tio_s="$(trim_whitespace "$_tio_raw")"
  _tio_s="$(strip_surrounding_quotes "$_tio_s")"
  _tio_s="$(strip_trailing_punct "$_tio_s")"
  _tio_s="$(substitute_same_command_vars "$_tio_s")"
  # Trim again: a same-command variable VALUE can carry whitespace that was
  # legitimately inside its own quotes, and substitution is purely textual.
  _tio_s="$(trim_whitespace "$_tio_s")"

  _tio_tilde="$(expand_tilde "$_tio_s")" || {
    _TIO_LAST_REASON="unresolvable"
    return 0
  }
  _tio_expanded="$(safe_expand "$_tio_tilde")" || {
    # Refused expansion: contained shell metacharacters this hook will not
    # eval. Treat as unresolved -> outside (conservative default).
    _TIO_LAST_REASON="unresolvable"
    return 0
  }
  case "$_tio_expanded" in
    *'$'*)
      # Still carries an unresolved variable reference (unset var, or one
      # not present in this process's env or the same-command table).
      _TIO_LAST_REASON="unresolvable"
      return 0
      ;;
  esac
  [ -n "$_tio_expanded" ] || return 1

  _tio_norm="$(normalize_path "$_tio_expanded")"
  _TIO_LAST_RESOLVED="$_tio_norm"

  # Fixed allowlist of standard-stream/no-op device paths — NOT a `/dev/*`
  # glob, since `/dev/disk0` (and any other real device) must still block.
  case "$_tio_norm" in
    /dev/null|/dev/stdout|/dev/stderr|/dev/tty) return 1 ;;
  esac

  _tio_wr_i=0
  _tio_wr_n="${#WORKTREE_ROOTS[@]}"
  while [ "$_tio_wr_i" -lt "$_tio_wr_n" ]; do
    _tio_worktree_norm="$(normalize_path "${WORKTREE_ROOTS[$_tio_wr_i]}")"
    if is_under "$_tio_norm" "$_tio_worktree_norm"; then
      return 1
    fi
    _tio_wr_i=$((_tio_wr_i + 1))
  done

  if [ -n "${CLAUDE_SCRATCHPAD:-}" ]; then
    _tio_scratch_norm="$(normalize_path "$CLAUDE_SCRATCHPAD")"
    if is_under "$_tio_norm" "$_tio_scratch_norm"; then
      return 1
    fi
  else
    case "$_tio_norm" in
      /private/tmp/claude-*/*) return 1 ;;
      /tmp/claude-*/*) return 1 ;;
    esac
  fi

  _TIO_LAST_REASON="outside"
  return 0
}

# check_and_block_target: the shared target_is_outside -> block() wire-up used
# by every kind of target, so the block-message distinction stays consistent.
check_and_block_target() {
  _cabt_kind="$1"
  _cabt_raw="$2"
  if target_is_outside "$_cabt_raw"; then
    if [ "$_TIO_LAST_REASON" = "unresolvable" ]; then
      block "$_cabt_kind target has an unresolvable variable: $_cabt_raw"
    elif [ -n "$_TIO_LAST_RESOLVED" ]; then
      block "$_cabt_kind target outside worktree and scratchpad: $_cabt_raw (resolves to: $_TIO_LAST_RESOLVED)"
    else
      block "$_cabt_kind target outside worktree and scratchpad: $_cabt_raw"
    fi
  fi
}

# is_recursive_rm_flag: true if a word looks like an rm flag that includes
# -r/-R (short, possibly combined: -r -rf -fr -Rf ...) or --recursive.
is_recursive_rm_flag() {
  case "$1" in
    --recursive) return 0 ;;
    -*)
      case "$1" in
        *r*|*R*) return 0 ;;
      esac
      return 1
      ;;
    *) return 1 ;;
  esac
}

# git_global_opt_takes_value: true for the `git` global options that consume a
# SEPARATE following token (`-C dir`, but not the self-contained `--git-dir=`).
git_global_opt_takes_value() {
  case "$1" in
    -C|-c|--config|--git-dir|--work-tree|--namespace|--super-prefix) return 0 ;;
    *) return 1 ;;
  esac
}

# git_target_is_linked_worktree: $@ = the git global-option tokens between
# `git` and its subcommand, replayed through a real `git rev-parse --git-dir`
# probe. Returns 1 if the probe fails at all, so the block stays conservative.
git_target_is_linked_worktree() {
  _gtlw_gd="$(git -C "$PWD_PHYS" "$@" rev-parse --git-dir 2>/dev/null)"
  _gtlw_rc=$?
  if [ "$_gtlw_rc" -ne 0 ] || [ -z "$_gtlw_gd" ]; then
    return 1
  fi
  case "$_gtlw_gd" in
    */worktrees/*|worktrees/*) return 0 ;;
    *) return 1 ;;
  esac
}

# xargs_opt_takes_value: the xargs options that consume a separate following
# token, matched exact-token only like git_global_opt_takes_value.
xargs_opt_takes_value() {
  case "$1" in
    -I|-n|-P|-L|-s|-E|-d|--delimiter|--max-args|--max-procs|--max-lines|--replace) return 0 ;;
    *) return 1 ;;
  esac
}

_RCH_MEMO=""
_RCH_OUT=""

# resolve_command_head: sets $_RCH_OUT to the basename of the binary $1 really
# names, symlinks followed, or to $1 unchanged when nothing resolves. Callers
# must only ask about a word in command position — an argument sharing a shim's
# name is not that shim. Fork-free: it runs on every Bash call in the session.
resolve_command_head() {
  _rch_w="$1"
  _RCH_OUT="$_rch_w"
  case "$_rch_w" in
    ''|-*|*=*|*'$'*|*'*'*|*'?'*|*'['*|*\'*|*'"'*|*'`'*|*'>'*|*'<'*|*'|'*|*'&'*|*'('*|*')'*|*'{'*|*'}'*|*';'*|*','*)
      return 0 ;;
  esac
  case "$_RCH_MEMO" in
    *"|$_rch_w>"*)
      _rch_rest="${_RCH_MEMO#*"|$_rch_w>"}"
      _RCH_OUT="${_rch_rest%%|*}"
      return 0
      ;;
  esac
  _rch_p=""
  case "$_rch_w" in
    '~'*) _rch_p="$(expand_tilde "$_rch_w")" ;;
    */*)  _rch_p="$_rch_w" ;;
    *)
      _rch_oifs="$IFS"
      IFS=:
      for _rch_d in $PATH; do
        [ -n "$_rch_d" ] || _rch_d="."
        if [ -x "$_rch_d/$_rch_w" ] && [ ! -d "$_rch_d/$_rch_w" ]; then
          _rch_p="$_rch_d/$_rch_w"
          break
        fi
      done
      IFS="$_rch_oifs"
      ;;
  esac
  if [ -n "$_rch_p" ] && [ -e "$_rch_p" ]; then
    _rch_hops=0
    while [ -L "$_rch_p" ] && [ "$_rch_hops" -lt 40 ]; do
      _rch_t="$(readlink "$_rch_p" 2>/dev/null)"
      [ -n "$_rch_t" ] || break
      case "$_rch_t" in
        /*) _rch_p="$_rch_t" ;;
        *)  _rch_p="${_rch_p%/*}/$_rch_t" ;;
      esac
      _rch_hops=$((_rch_hops + 1))
    done
    _RCH_OUT="${_rch_p##*/}"
  fi
  _RCH_MEMO="$_RCH_MEMO|$_rch_w>$_RCH_OUT"
  return 0
}

# is_quoted_word: true if $1 STARTS with a quote character. Deliberately
# start-of-word only, so `"rm" -rf /` is not recognised (documented gap).
is_quoted_word() {
  case "$1" in
    \'*|\"*) return 0 ;;
    *) return 1 ;;
  esac
}

# scan_dollar_parens_in_word: command substitution still executes inside DOUBLE
# quotes, so every `$( ... )` body of such a word is extracted (paren-depth-
# aware) and scanned. Single-quoted words and backticks get none of this.
scan_dollar_parens_in_word() {
  local _sdp_body="" _sdp_c="" _sdp_c2="" _sdp_cj="" _sdp_depth=0
  local _sdp_i=0 _sdp_j=0 _sdp_len=0 _sdp_text=""
  _sdp_text="$1"
  _sdp_len=${#_sdp_text}
  _sdp_i=0
  while [ "$_sdp_i" -lt "$_sdp_len" ]; do
    _sdp_c="${_sdp_text:$_sdp_i:1}"
    _sdp_c2=""
    if [ "$((_sdp_i + 1))" -lt "$_sdp_len" ]; then
      _sdp_c2="${_sdp_text:$((_sdp_i + 1)):1}"
    fi
    if [ "$_sdp_c" = '$' ] && [ "$_sdp_c2" = '(' ]; then
      _sdp_depth=1
      _sdp_j=$((_sdp_i + 2))
      _sdp_body=""
      while [ "$_sdp_j" -lt "$_sdp_len" ] && [ "$_sdp_depth" -gt 0 ]; do
        _sdp_cj="${_sdp_text:$_sdp_j:1}"
        case "$_sdp_cj" in
          '(')
            _sdp_depth=$((_sdp_depth + 1))
            _sdp_body="$_sdp_body$_sdp_cj"
            ;;
          ')')
            _sdp_depth=$((_sdp_depth - 1))
            [ "$_sdp_depth" -gt 0 ] && _sdp_body="$_sdp_body$_sdp_cj"
            ;;
          *) _sdp_body="$_sdp_body$_sdp_cj" ;;
        esac
        _sdp_j=$((_sdp_j + 1))
      done
      if [ -n "$_sdp_body" ]; then
        _ss_opaque_push
        scan_command_text "$(substitute_same_command_vars "$_sdp_body")"
        _ss_opaque_pop
      fi
      _sdp_i="$_sdp_j"
    else
      _sdp_i=$((_sdp_i + 1))
    fi
  done
  return 0
}

# tokenize_quoted: quote-AWARE word splitting into _ss_words, which scan_segment
# declares `local` — call it only from scan_segment's dynamic extent. A quoted
# span joins the CURRENT word rather than ending it at internal whitespace; an
# unterminated quote consumes to end-of-segment, not forever.
tokenize_quoted() {
  _tq_line="$1"
  _ss_words=()
  _tq_cur=""
  _tq_in_word=0
  _tq_len=${#_tq_line}
  _tq_i=0
  while [ "$_tq_i" -lt "$_tq_len" ]; do
    _tq_c="${_tq_line:$_tq_i:1}"
    case "$_tq_c" in
      ' '|'	')
        if [ "$_tq_in_word" -eq 1 ]; then
          _ss_words+=("$_tq_cur")
          _tq_cur=""
          _tq_in_word=0
        fi
        _tq_i=$((_tq_i + 1))
        ;;
      "'")
        _tq_in_word=1
        _tq_cur="$_tq_cur'"
        _tq_i=$((_tq_i + 1))
        while [ "$_tq_i" -lt "$_tq_len" ]; do
          _tq_c2="${_tq_line:$_tq_i:1}"
          _tq_cur="$_tq_cur$_tq_c2"
          _tq_i=$((_tq_i + 1))
          [ "$_tq_c2" = "'" ] && break
        done
        ;;
      '"')
        _tq_in_word=1
        _tq_cur="$_tq_cur\""
        _tq_i=$((_tq_i + 1))
        while [ "$_tq_i" -lt "$_tq_len" ]; do
          _tq_c2="${_tq_line:$_tq_i:1}"
          _tq_cur="$_tq_cur$_tq_c2"
          _tq_i=$((_tq_i + 1))
          [ "$_tq_c2" = '"' ] && break
        done
        ;;
      *)
        _tq_in_word=1
        _tq_cur="$_tq_cur$_tq_c"
        _tq_i=$((_tq_i + 1))
        ;;
    esac
  done
  if [ "$_tq_in_word" -eq 1 ]; then
    _ss_words+=("$_tq_cur")
  fi
  return 0
}

# split_unquoted_segments: quote-aware replacement for the old raw-text
# split on ; && || | — a separator inside a quoted span is data, never a
# boundary (the fixed false positive). `\;` (find's -exec terminator) stays
# literal outside quotes; a literal newline splits too, as it did before.
split_unquoted_segments() {
  _sus_text="$1"
  _sct_seglist=()
  _sus_cur=""
  _sus_len=${#_sus_text}
  _sus_i=0
  while [ "$_sus_i" -lt "$_sus_len" ]; do
    _sus_c="${_sus_text:$_sus_i:1}"
    case "$_sus_c" in
      \\)
        _sus_c2=""
        if [ "$((_sus_i + 1))" -lt "$_sus_len" ]; then
          _sus_c2="${_sus_text:$((_sus_i + 1)):1}"
        fi
        if [ "$_sus_c2" = ';' ]; then
          _sus_cur="$_sus_cur\\;"
          _sus_i=$((_sus_i + 2))
        else
          _sus_cur="$_sus_cur\\"
          _sus_i=$((_sus_i + 1))
        fi
        ;;
      "'")
        _sus_cur="$_sus_cur'"
        _sus_i=$((_sus_i + 1))
        while [ "$_sus_i" -lt "$_sus_len" ]; do
          _sus_c2="${_sus_text:$_sus_i:1}"
          _sus_cur="$_sus_cur$_sus_c2"
          _sus_i=$((_sus_i + 1))
          [ "$_sus_c2" = "'" ] && break
        done
        ;;
      '"')
        _sus_cur="$_sus_cur\""
        _sus_i=$((_sus_i + 1))
        while [ "$_sus_i" -lt "$_sus_len" ]; do
          _sus_c2="${_sus_text:$_sus_i:1}"
          _sus_cur="$_sus_cur$_sus_c2"
          _sus_i=$((_sus_i + 1))
          [ "$_sus_c2" = '"' ] && break
        done
        ;;
      ';'|$'\n')
        _sct_seglist+=("$_sus_cur")
        _sus_cur=""
        _sus_i=$((_sus_i + 1))
        ;;
      '|')
        _sus_c2=""
        if [ "$((_sus_i + 1))" -lt "$_sus_len" ]; then
          _sus_c2="${_sus_text:$((_sus_i + 1)):1}"
        fi
        _sct_seglist+=("$_sus_cur")
        _sus_cur=""
        if [ "$_sus_c2" = '|' ]; then
          _sus_i=$((_sus_i + 2))
        else
          _sus_i=$((_sus_i + 1))
        fi
        ;;
      '&')
        _sus_c2=""
        if [ "$((_sus_i + 1))" -lt "$_sus_len" ]; then
          _sus_c2="${_sus_text:$((_sus_i + 1)):1}"
        fi
        if [ "$_sus_c2" = '&' ]; then
          _sct_seglist+=("$_sus_cur")
          _sus_cur=""
          _sus_i=$((_sus_i + 2))
        else
          _sus_cur="$_sus_cur&"
          _sus_i=$((_sus_i + 1))
        fi
        ;;
      *)
        _sus_cur="$_sus_cur$_sus_c"
        _sus_i=$((_sus_i + 1))
        ;;
    esac
  done
  _sct_seglist+=("$_sus_cur")
  return 0
}

scan_segment() {
  local _ss_words=() _ss_find_paths=() _ss_git_opts=()
  local _ss_after="" _ss_cmd_word_idx=0 _ss_ek=0 _ss_et="" _ss_eval_rest=""
  local _ss_exec_cmd="" _ss_find_has_action=0 _ss_fk2=0 _ss_flag="" _ss_fp=""
  local _ss_ftok="" _ss_git_block=0 _ss_git_linked=0 _ss_git_subcmd=""
  local _ss_gj=0 _ss_gk=0 _ss_gk2=0 _ss_gtok="" _ss_i=0 _ss_j=0 _ss_k=0
  local _ss_line="" _ss_match="" _ss_n=0 _ss_next_i=0 _ss_opaque=0
  local _ss_saw_recursive=0 _ss_stash_action="" _ss_tgt="" _ss_word=""
  local _ss_xargs_cmd="" _ss_xeval="" _ss_xj2=0 _ss_xk=0 _ss_xtok=""
  _ss_line="$1"
  tokenize_quoted "$_ss_line"
  _ss_n="${#_ss_words[@]}"
  [ "$_ss_n" -eq 0 ] && return 0

  # _ss_opaque: once ssh/scp/rsync/mosh is this segment's OWN command word (not
  # merely present in it), every later word is that command's argv. Guards the
  # command-head dispatch only — an unquoted `>` is parsed by the LOCAL shell.
  _ss_opaque=0

  # _ss_cmd_word_idx: this segment's own command word — the first word that is
  # not a leading NAME=value assignment and not a transparent `env`/`command`.
  _ss_cmd_word_idx=0
  while [ "$_ss_cmd_word_idx" -lt "$_ss_n" ]; do
    case "${_ss_words[$_ss_cmd_word_idx]}" in
      [A-Za-z_]*=*|env|command) _ss_cmd_word_idx=$((_ss_cmd_word_idx + 1)) ;;
      *) break ;;
    esac
  done

  _ss_i=0
  while [ "$_ss_i" -lt "$_ss_n" ]; do
    _ss_word="${_ss_words[$_ss_i]}"

    if is_quoted_word "$_ss_word"; then
      # Fully quoted argument: data, not command syntax — EXCEPT command
      # substitution, which still executes inside DOUBLE quotes.
      case "$_ss_word" in
        \"*) scan_dollar_parens_in_word "$_ss_word" ;;
      esac
      _ss_i=$((_ss_i + 1))
      continue
    fi

    if [ "$_ss_opaque" -eq 0 ]; then
    # Typed-name patterns are tried against EVERY word (they cover /bin/rm and
    # /usr/bin/git by path suffix). On-disk resolution is not: it runs only at
    # this segment's own command-word index, or an argument that merely shares
    # a name with some shim would be read as that shim.
    _ss_match="$_ss_word"
    if [ "$_ss_i" -eq "$_ss_cmd_word_idx" ]; then
      case "$_ss_word" in
        ssh|*/ssh|scp|*/scp|rsync|*/rsync|mosh|*/mosh|rm|*/rm|mv|*/mv|find|*/find|xargs|*/xargs|bash|*/bash|sh|*/sh|eval|*/eval|git|*/git) ;;
        *) resolve_command_head "$_ss_word"; _ss_match="$_RCH_OUT" ;;
      esac
    fi
    case "$_ss_match" in
      ssh|*/ssh|scp|*/scp|rsync|*/rsync|mosh|*/mosh)
        if [ "$_ss_i" -eq "$_ss_cmd_word_idx" ]; then
          _ss_opaque=1
        fi
        ;;
      rm|*/rm)
        _ss_saw_recursive=0
        _ss_j=$((_ss_i + 1))
        while [ "$_ss_j" -lt "$_ss_n" ]; do
          _ss_flag="${_ss_words[$_ss_j]}"
          case "$_ss_flag" in
            -*)
              if is_recursive_rm_flag "$_ss_flag"; then
                _ss_saw_recursive=1
              fi
              _ss_j=$((_ss_j + 1))
              ;;
            *) break ;;
          esac
        done
        if [ "$_ss_saw_recursive" -eq 1 ]; then
          _ss_k="$_ss_j"
          while [ "$_ss_k" -lt "$_ss_n" ]; do
            check_and_block_target "rm -r" "${_ss_words[$_ss_k]}"
            _ss_k=$((_ss_k + 1))
          done
        fi
        ;;
      mv|*/mv)
        _ss_j=$((_ss_i + 1))
        while [ "$_ss_j" -lt "$_ss_n" ]; do
          _ss_tgt="${_ss_words[$_ss_j]}"
          case "$_ss_tgt" in
            -*) ;;
            *) check_and_block_target "mv" "$_ss_tgt" ;;
          esac
          _ss_j=$((_ss_j + 1))
        done
        ;;
      find|*/find)
        _ss_j=$((_ss_i + 1))
        _ss_find_paths=()
        while [ "$_ss_j" -lt "$_ss_n" ]; do
          _ss_ftok="${_ss_words[$_ss_j]}"
          case "$_ss_ftok" in
            -*) break ;;
            *) _ss_find_paths+=("$_ss_ftok"); _ss_j=$((_ss_j + 1)) ;;
          esac
        done

        _ss_find_has_action=0
        _ss_k="$_ss_j"
        while [ "$_ss_k" -lt "$_ss_n" ]; do
          case "${_ss_words[$_ss_k]}" in
            -delete|-exec|-execdir|-ok|-okdir) _ss_find_has_action=1 ;;
          esac
          _ss_k=$((_ss_k + 1))
        done

        # Checking find's own root first is what makes `{}` safe to leave as
        # ordinary text in the nested -exec scan: an outside root already blocked.
        if [ "$_ss_find_has_action" -eq 1 ]; then
          # bash 3.2: "${arr[@]}" on a truly EMPTY array throws under `set -u`.
          if [ "${#_ss_find_paths[@]}" -eq 0 ]; then
            check_and_block_target "find" "."
          else
            for _ss_fp in "${_ss_find_paths[@]}"; do
              check_and_block_target "find" "$_ss_fp"
            done
          fi
        fi

        _ss_k="$_ss_j"
        while [ "$_ss_k" -lt "$_ss_n" ]; do
          if [ "${_ss_words[$_ss_k]}" = "-exec" ] || [ "${_ss_words[$_ss_k]}" = "-execdir" ] || [ "${_ss_words[$_ss_k]}" = "-ok" ] || [ "${_ss_words[$_ss_k]}" = "-okdir" ]; then
            _ss_exec_cmd=""
            _ss_fk2=$((_ss_k + 1))
            while [ "$_ss_fk2" -lt "$_ss_n" ]; do
              _ss_et="${_ss_words[$_ss_fk2]}"
              case "$_ss_et" in
                ';'|'\;'|'+') break ;;
              esac
              if [ -z "$_ss_exec_cmd" ]; then
                _ss_exec_cmd="$_ss_et"
              else
                _ss_exec_cmd="$_ss_exec_cmd $_ss_et"
              fi
              _ss_fk2=$((_ss_fk2 + 1))
            done
            if [ -n "$_ss_exec_cmd" ]; then
              _ss_opaque_push
              scan_command_text "$(substitute_same_command_vars "$_ss_exec_cmd")"
              _ss_opaque_pop
            fi
          fi
          _ss_k=$((_ss_k + 1))
        done

        # Advance the OUTER word pointer past everything find consumed, or the
        # per-word dispatch re-visits an -exec's own `rm`/`mv` as a top-level word.
        _ss_i=$((_ss_n - 1))
        ;;
      xargs|*/xargs)
        _ss_j=$((_ss_i + 1))
        _ss_xargs_cmd=""
        while [ "$_ss_j" -lt "$_ss_n" ]; do
          _ss_xtok="${_ss_words[$_ss_j]}"
          case "$_ss_xtok" in
            -*)
              if xargs_opt_takes_value "$_ss_xtok"; then
                _ss_j=$((_ss_j + 1))
              fi
              _ss_j=$((_ss_j + 1))
              ;;
            *) _ss_xargs_cmd="$_ss_xtok"; break ;;
          esac
        done
        case "$_ss_xargs_cmd" in
          rm|*/rm|mv|*/mv|bash|*/bash|sh|*/sh|eval|*/eval) ;;
          *) resolve_command_head "$_ss_xargs_cmd"; _ss_xargs_cmd="$_RCH_OUT" ;;
        esac
        case "$_ss_xargs_cmd" in
          rm|*/rm|mv|*/mv)
            block "xargs invokes $_ss_xargs_cmd on stdin-sourced arguments this hook cannot statically verify"
            ;;
          bash|*/bash|sh|*/sh)
            # xargs's target command is itself a re-execution context.
            _ss_xj2=$((_ss_j + 1))
            if [ "$_ss_xj2" -lt "$_ss_n" ] && [ "${_ss_words[$_ss_xj2]}" = "-c" ]; then
              _ss_xj2=$((_ss_xj2 + 1))
              if [ "$_ss_xj2" -lt "$_ss_n" ]; then
                _ss_opaque_push
                scan_command_text "$(substitute_same_command_vars "$(strip_surrounding_quotes "${_ss_words[$_ss_xj2]}")")"
                _ss_opaque_pop
              fi
            fi
            ;;
          eval|*/eval)
            _ss_xj2=$((_ss_j + 1))
            if [ "$_ss_xj2" -lt "$_ss_n" ]; then
              _ss_xeval="${_ss_words[$_ss_xj2]}"
              _ss_xk=$((_ss_xj2 + 1))
              while [ "$_ss_xk" -lt "$_ss_n" ]; do
                _ss_xeval="$_ss_xeval ${_ss_words[$_ss_xk]}"
                _ss_xk=$((_ss_xk + 1))
              done
              _ss_opaque_push
              scan_command_text "$(substitute_same_command_vars "$(strip_surrounding_quotes "$_ss_xeval")")"
              _ss_opaque_pop
            fi
            ;;
        esac
        ;;
      bash|*/bash|sh|*/sh)
        # `bash -c "<script>"` / `sh -c "<script>"` is a re-execution context:
        # the quoted argument IS a command, so scan it rather than skip it.
        _ss_j=$((_ss_i + 1))
        if [ "$_ss_j" -lt "$_ss_n" ] && [ "${_ss_words[$_ss_j]}" = "-c" ]; then
          _ss_j=$((_ss_j + 1))
          if [ "$_ss_j" -lt "$_ss_n" ]; then
            _ss_opaque_push
            scan_command_text "$(substitute_same_command_vars "$(strip_surrounding_quotes "${_ss_words[$_ss_j]}")")"
            _ss_opaque_pop
          fi
        fi
        ;;
      eval|*/eval)
        # `eval "<script>"` / `eval <script...>` — everything after `eval` on
        # this segment is the nested command text.
        _ss_j=$((_ss_i + 1))
        if [ "$_ss_j" -lt "$_ss_n" ]; then
          _ss_eval_rest="${_ss_words[$_ss_j]}"
          _ss_ek=$((_ss_j + 1))
          while [ "$_ss_ek" -lt "$_ss_n" ]; do
            _ss_eval_rest="$_ss_eval_rest ${_ss_words[$_ss_ek]}"
            _ss_ek=$((_ss_ek + 1))
          done
          _ss_opaque_push
          scan_command_text "$(substitute_same_command_vars "$(strip_surrounding_quotes "$_ss_eval_rest")")"
          _ss_opaque_pop
        fi
        ;;
      git|*/git)
        _ss_gj=$((_ss_i + 1))
        _ss_git_opts=()
        while [ "$_ss_gj" -lt "$_ss_n" ]; do
          _ss_gtok="${_ss_words[$_ss_gj]}"
          case "$_ss_gtok" in
            -*)
              _ss_git_opts+=("$_ss_gtok")
              if git_global_opt_takes_value "$_ss_gtok"; then
                _ss_gj=$((_ss_gj + 1))
                if [ "$_ss_gj" -lt "$_ss_n" ]; then
                  _ss_git_opts+=("${_ss_words[$_ss_gj]}")
                fi
              fi
              _ss_gj=$((_ss_gj + 1))
              ;;
            *) break ;;
          esac
        done
        if [ "$_ss_gj" -lt "$_ss_n" ]; then
          _ss_git_subcmd="${_ss_words[$_ss_gj]}"
          _ss_git_block=0
          case "$_ss_git_subcmd" in
            stash)
              # git stash list/show are read-only; every other stash form blocks.
              _ss_stash_action=""
              _ss_gk2=$((_ss_gj + 1))
              if [ "$_ss_gk2" -lt "$_ss_n" ]; then
                case "${_ss_words[$_ss_gk2]}" in
                  -*) ;;
                  *) _ss_stash_action="${_ss_words[$_ss_gk2]}" ;;
                esac
              fi
              case "$_ss_stash_action" in
                list|show) _ss_git_block=0 ;;
                *) _ss_git_block=1 ;;
              esac
              ;;
            reset|clean) _ss_git_block=1 ;;
            checkout)
              _ss_gk=$((_ss_gj + 1))
              while [ "$_ss_gk" -lt "$_ss_n" ]; do
                if [ "${_ss_words[$_ss_gk]}" = "--" ]; then
                  _ss_git_block=1
                  break
                fi
                _ss_gk=$((_ss_gk + 1))
              done
              ;;
          esac
          if [ "$_ss_git_block" -eq 1 ]; then
            # bash 3.2: "${arr[@]}" on an EMPTY array throws under `set -u`.
            if [ "${#_ss_git_opts[@]}" -eq 0 ]; then
              _ss_git_linked=1
              git_target_is_linked_worktree || _ss_git_linked=0
            else
              _ss_git_linked=1
              git_target_is_linked_worktree "${_ss_git_opts[@]}" || _ss_git_linked=0
            fi
            if [ "$_ss_git_linked" -eq 0 ]; then
              block "git $_ss_git_subcmd targets the main worktree (or its target repo could not be confirmed as a linked one): $_ss_line"
            fi
          fi
        fi
        ;;
    esac
    fi

    # Redirection, with the target attached or as the next word. An fd
    # duplication/close is not a filesystem target and is not resolved as one.
    case "$_ss_word" in
      *'>'*)
        _ss_after="${_ss_word#*>}"
        _ss_after="${_ss_after#>}"
        if [ -n "$_ss_after" ]; then
          case "$_ss_after" in
            '&'[0-9]*|'&-') ;;
            *) check_and_block_target "redirect" "$_ss_after" ;;
          esac
        else
          _ss_next_i=$((_ss_i + 1))
          if [ "$_ss_next_i" -lt "$_ss_n" ]; then
            _ss_tgt="${_ss_words[$_ss_next_i]}"
            case "$_ss_tgt" in
              '&'[0-9]*|'&-') ;;
              *) check_and_block_target "redirect" "$_ss_tgt" ;;
            esac
          fi
        fi
        ;;
    esac

    _ss_i=$((_ss_i + 1))
  done
  return 0
}

# Strip heredoc BODIES (opener through terminator line) before the text is
# split into segments — heredoc content is literal data, not further commands.
# Only the first `<<` marker per physical line is recognised.
strip_heredocs() {
  _sh_in="$1"
  _sh_out=""
  _sh_pending_term=""
  _sh_pending_strip_tabs=0
  _sh_old_ifs="$IFS"
  IFS='
'
  for _sh_line in $_sh_in; do
    IFS="$_sh_old_ifs"
    if [ -n "$_sh_pending_term" ]; then
      _sh_check="$_sh_line"
      if [ "$_sh_pending_strip_tabs" -eq 1 ]; then
        while [ "${_sh_check#	}" != "$_sh_check" ]; do
          _sh_check="${_sh_check#	}"
        done
      fi
      if [ "$_sh_check" = "$_sh_pending_term" ]; then
        _sh_pending_term=""
      fi
      IFS='
'
      continue
    fi
    _sh_out="$_sh_out$_sh_line
"
    case "$_sh_line" in
      *'<<'*)
        _sh_rest="${_sh_line#*<<}"
        _sh_strip_tabs=0
        case "$_sh_rest" in
          -*) _sh_strip_tabs=1; _sh_rest="${_sh_rest#-}" ;;
        esac
        while [ "${_sh_rest# }" != "$_sh_rest" ]; do
          _sh_rest="${_sh_rest# }"
        done
        case "$_sh_rest" in
          \'*)
            _sh_rest="${_sh_rest#\'}"
            _sh_word="${_sh_rest%%\'*}"
            ;;
          \"*)
            _sh_rest="${_sh_rest#\"}"
            _sh_word="${_sh_rest%%\"*}"
            ;;
          *)
            _sh_word="${_sh_rest%%[ 	]*}"
            ;;
        esac
        if [ -n "$_sh_word" ]; then
          _sh_pending_term="$_sh_word"
          _sh_pending_strip_tabs="$_sh_strip_tabs"
        fi
        ;;
    esac
    IFS='
'
  done
  IFS="$_sh_old_ifs"
  printf '%s' "$_sh_out"
}

# scan_command_text: the shared entry point for the top-level command and every
# nested re-execution context. A literal `\;` is protected from the `;`-split
# first: it is find's own escaped -exec terminator, not a command separator.
scan_command_text() {
  local _sct_seglist=()
  local _sct_n=0 _sct_no_heredoc="" _sct_seg="" _sct_text=""
  _sct_text="$1"
  _sct_no_heredoc="$(strip_heredocs "$_sct_text")"
  collect_same_command_assignments "$_sct_no_heredoc"
  split_unquoted_segments "$_sct_no_heredoc"
  _sct_n="${#_sct_seglist[@]}"
  if [ "$_sct_n" -gt 0 ]; then
    for _sct_seg in "${_sct_seglist[@]}"; do
      scan_segment "$_sct_seg"
    done
  fi
  return 0
}

scan_command_text "$CMD"

exit 0
