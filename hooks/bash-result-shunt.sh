#!/bin/bash
#
# bash-result-shunt.sh — Claude Code PreToolUse hook for Bash. Attacks the
# largest known-noisy Bash tool results (uncapped `git log`, `jira-api.sh
# board`/`raw` search pulls) before they land in the calling model's
# context.
#
# ---------------------------------------------------------------------------
# Mechanism, and why this is NOT read-shunt.sh's mechanism (confirm first)
# ---------------------------------------------------------------------------
#
# read-shunt.sh (see its own header) works because a Read/`cat` target is a FILE THAT
# ALREADY EXISTS: the hook can run `wc -l` on it, know its exact size before
# the tool call happens, and — if it decides to shunt — actually READ the
# file itself, hand its full content to a haiku subprocess, and substitute
# haiku's summary for the real content by blocking the tool (exit 2) and
# printing the summary to stderr, which Claude Code surfaces as the tool's
# result.
#
# A Bash command has no such artifact. PreToolUse fires BEFORE the command
# runs, on `tool_input.command` alone — the command's stdout does not exist
# yet, cannot be sized, and cannot be read for a haiku prompt. There is no
# PostToolUse (or any) hook primitive in Claude Code that intercepts a
# command's actual output after execution and substitutes a summary before
# the calling model sees it; PostToolUse hooks exist for observation
# (transcript/telemetry side-effects) but nothing in the documented hook
# contract lets them rewrite or replace the tool result already returned to
# the model. This was confirmed by re-reading read-shunt.sh's own gate
# (`wc -l < "$PHYSICAL"` — only possible because the target pre-exists) and
# finding no PostToolUse usage in this plugin's hooks/ that does result
# substitution — a PostToolUse hook, if one existed here, would only ever
# extract and record events; it never blocks or rewrites anything a model
# sees.
#
# So there is no "run the command, then summarise it" mechanism to build.
# What IS buildable, and what this script does: gate on a size PROXY that
# IS knowable in advance — the command string itself. A short, curated set
# of known-noisy command *shapes* (bare `git log`, unfiltered `jira-api.sh
# board`/`raw` search) is pattern-matched against
# tool_input.command. A match that lacks a recognised output-capping flag
# is BLOCKED (exit 2, same "PreToolUse exit 2 blocks and stderr becomes the
# tool result" contract read-shunt.sh and guard-fs-writes.sh already rely
# on) with guidance telling the calling model which flag/pipe to add and
# re-run with. The command never executes; nothing is summarised; no
# output is ever inspected, because at this point in the lifecycle there
# is no output to inspect. This is deliberately less powerful than
# read-shunt.sh and is documented as such rather than claiming otherwise.
#
# ---------------------------------------------------------------------------
# Never gates a secrets-bearing command
# ---------------------------------------------------------------------------
#
# This hook never executes, reads, or prints a command's OUTPUT (there isn't
# any yet), so the read-shunt.sh secrets concern (summarising a credential
# file's content) does not apply here, and the blocking message never
# echoes the offending command string back to the model — it only ever
# prints the fixed $GUIDANCE text for the shape that matched (see the
# block below, ~line 252). The residual risk this hook still guards is
# narrower: is_secret_command() skips gating entirely (exit 0, allow, no
# message) for any command that NAMES a credential-handling tool or token
# (op/1Password, a literal `.env` file, an actual `docker inspect`, or a
# token whose text is exactly/contains secret/credential/token) as one of
# its own shell WORDS — not as a substring anywhere in the command text,
# which previously false-positived on ordinary comments (`# note: token
# budget`) and unrelated paths (`docker/env/plex.env.tpl`, which ends in
# `.tpl`, not `.env`). This is a courtesy skip, not a security control.
#
# is_secret_command() (and every is_uncapped_*
# detector below) reads $STRIPPED_CMD — the output of strip_heredocs(), see
# its own header comment further down — not the raw command. For a heredoc
# attached to a command that only READS its body as data (`git commit -F -
# <<'EOF'`), the body is gone by the time is_secret_command() runs, so a
# heredoc body merely containing the word "token" no longer suppresses
# gating the way it did before this hook existed in its current form —
# strictly more correct (gating never prints command text either way, so
# nothing that was ever a real secret leak stops being caught), just a
# scope change worth naming rather than leaving implicit. For a heredoc
# attached to a STDIN-EXECUTING interpreter (ssh/bash/sh/zsh/dash/python/
# python3), strip_heredocs() leaves the body untouched, so is_secret_command
# still sees it in full for that channel.
#
# ---------------------------------------------------------------------------
# What gets matched (deliberately narrow, deliberately a starter set)
# ---------------------------------------------------------------------------
#
# tool_name != "Bash": exit 0 immediately (nothing to do).
#
# The FIRST transform applied to the raw
# command is strip_heredocs() (see its own header comment further down):
# it removes heredoc BODY text attached to a command that only reads that
# body as its own data (a `git commit -F -`/`jira-api.sh comment -`/`cat`
# message or file body), because that text is free-form prose, not further
# shell syntax, and could otherwise be split into fake statements below. It
# leaves a heredoc body untouched when the attached command is a
# STDIN-EXECUTING interpreter (ssh/bash/sh/zsh/dash/python/python3) instead,
# because that body genuinely IS a command list. Everything from here on —
# every is_uncapped_* detector and is_secret_command() — reads the output of
# that pass ($STRIPPED_CMD), never the raw command string.
#
# The (already heredoc-stripped) command string is then split into
# `;`/`&&`/`||`/`&`/newline-separated statements, each of those into
# `|`-separated pipeline stages, and each
# stage into shell words (quote-aware, so a quoted phrase like `"git log"`
# is one word, not two) — see split_segments()/tokenize() below. A shape
# only matches when its own invocation's WORDS say so (word 1 is `git`,
# word 2 is `log`; some word is `jira-api.sh` by basename and
# the next word is its subcommand), so a command that merely mentions
# "git log" in a comment, a grep pattern, or an unrelated later statement
# in the same line does not match, and capping flags are read only from
# that invocation's own stage, not the whole command line. A stage that is
# piped to ANYTHING (`| grep ...`, `| head`, `| jq ...`) is treated as
# already capped, on the theory that a deliberate second pipeline stage is
# itself the capping step, whatever it's named.
#
# Two known-noisy shapes, checked in order; first match wins:
#
#   1. `git log` with none of: --oneline, -n<N>/-n N/--max-count[=N], a
#      bare numeric limit (`-5`, `-20`), or a pipe to a later stage.
#      (`--since`/`--until` bound TIME, not OUTPUT SIZE, and are no longer
#      treated as caps — `git log --since=2020-01-01` can still return
#      years of uncapped history.)
#   2. `jira-api.sh board`, or `jira-api.sh raw <path>` where <path> looks
#      like a collection/search endpoint (contains `/search` or `/issue`,
#      e.g. `/search`, `/board/12/issue` — NOT `/myself`, a single-object
#      read that was previously gated along with everything else under
#      `raw`), with none of: --limit, a pipe to a later stage.
#
# Deliberately NOT gated: `issues.py board`/`waves` (this plugin's own
# to-issues issue tracker). Unlike the Jira-backed `jira-api.sh`, this
# repo's `skills/to-issues/scripts/issues.py` has no --tag/--status/
# --assignee/--wave/--limit filter at all (only --source/--jira-api/
# --jira-project/--fixture) — every session-start and tickets-protocol
# call to `issues.py board`/`waves` is necessarily "unfiltered", so gating
# it would block the exact commands those skills tell every session to
# run, with no capping flag available to add. Revisit if/when issues.py
# grows a real filter.
#
# Anything else — including any command already piped, redirected, or
# otherwise complex — is left alone. This is a starter set; widen the
# case/pattern list rather than rearchitect when the next noisy command
# shape turns up.
#
# ---------------------------------------------------------------------------
# Reachability: the gate is not silently permanent
# ---------------------------------------------------------------------------
#
# Same escape hatch shape as read-shunt.sh: the FIRST time a given
# (session_id, exact command string) is gated, it is blocked with guidance.
# If the calling model runs the EXACT SAME command again in the SAME
# session — because it decided the guidance did not apply, or the command
# cannot practically be capped — this script finds the marker and allows it
# through unshunted. Nothing is ever permanently un-runnable.
#
# ---------------------------------------------------------------------------
# Fails open on malformed input
# ---------------------------------------------------------------------------
#
# Missing jq, a missing/empty tool_name or command, a missing or
# path-unsafe session_id (can't dedupe safely), no path-hashing tool on
# PATH: every one of these allows the command through unblocked rather than
# gating it. A false negative here only costs tokens on a large result; a
# false positive that ever blocked a legitimate, already-capped command
# would cost a stalled agent.
#
# This guarantee covers malformed INPUT to a working script, not a broken
# script itself: a bash parse error in this file would make bash exit
# non-zero before a single line of fail_open() logic ever ran, and
# PreToolUse treats that as BLOCK, not allow. There is no in-script fix for
# that failure mode (a trap can't run if the file never parses) — the
# guard against it is shellcheck + the selftest before this script is
# deployed, same residual-risk framing as read-shunt.sh.
#
# ---------------------------------------------------------------------------
# Overridable for testing
# ---------------------------------------------------------------------------
#
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

# --- split_segments: quote-aware split of a command string into pipeline
# stages. Populates SEG_TEXT[] (the stage text) and SEG_SEP[] (the operator
# that ENDS that stage: ";", "&&", "||", "&", "|", or "" for the last
# stage). Recognises ';', '&', '&&', '|', '||', and newline as unquoted
# separators only — inside a single or double quote, none of these split.
# This is what lets `git log; grep -n foo bar` NOT hand grep's `-n` to the
# git-log capping check, and `git log --format=%H | grep abc` be told it
# IS piped (SEG_SEP for the git-log stage is "|"). -------------------------
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
        # A '&' immediately after '>' or '<' (2>&1, >&2, <&3), or immediately
        # before '>' (&>, &>>), is part of a redirection operator, not a
        # pipeline/background separator — bash never splits a statement
        # there, and neither must we (: 'cmd 2>&1 | head' was
        # split into "cmd 2>" (SEG_SEP="&") and "1 | head", so the
        # invocation's own SEG_SEP read "&" instead of "|" and an
        # already-piped command was reported uncapped).
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

# --- tokenize: quote-aware split of one segment/stage into shell words,
# populating TOKENS[]. A quoted phrase (`"git log"`) is one token, not two.
# An unquoted '#' that starts a fresh word begins a comment (real bash
# behaviour) — everything from there to the end of the stage is dropped,
# so a trailing `# note: token budget` never contributes tokens for the
# secrets check or any capping-flag check. ---------------------------------
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

# --- is_stdin_executor_stage: does the CURRENT STAGE's TOKENS[] (set by a
# prior tokenize() call, see strip_heredocs below) name a command that reads
# its heredoc body AS COMMANDS TO EXECUTE — ssh (remote script), a bare
# shell (bash/sh/zsh/dash reading stdin as a script), or python/python3
# reading stdin as a program — rather than as free-form data a command
# merely stores or prints (`git commit -F -`, `jira-api.sh comment -`,
# `cat`)?  review (HIGH): `ssh docker-host <<'EOF'` / `bash <<'EOF'`
# / `python3 <<'EOF'` / `pct exec 100 -- bash <<'EOF'` / `sudo sh <<'EOF'`
# heredoc bodies are a COMMAND LIST, not prose — stripping them the way a
# git-commit-message body is stripped would silently turn the gate off for
# every gated shape run through one of these channels. Deliberately checks
# every token in the stage, not just the first, so `pct exec 100 -- bash`
# and `sudo sh` are caught via their trailing interpreter word, not just a
# leading one. A false positive here (some unrelated stage that merely
# mentions "bash" as an argument) only means that heredoc is NOT stripped —
# the pre- behavior for it — never a missed real gate. -------------
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

# --- strip_heredocs (; reworked same day after
# script-reviewer HIGH+2×MEDIUM): a heredoc body attached to a command that
# merely READS the body as its own data — `git commit -F - <<'EOF'`, `cat
# <<EOF`, `./jira-api.sh comment  - <<'EOF'` — is free-form text, not
# further shell syntax. split_segments treats every newline as a
# ';'-equivalent stage separator (needed for real multi-statement scripts),
# so before this fix a heredoc BODY line that happened to quote/describe a
# gated shape as prose — e.g. a commit message body containing "| head -60;
# python3 issues.py board --source jira" as an EXAMPLE, not a command to
# run — was split into its own stage and tokenized as a live invocation,
# blocking a legitimate commit (~06:58Z, cleared only via the
# escape hatch).
#
# But a heredoc attached to ssh/bash/sh/zsh/dash/python/python3 (bare, or
# reached through `pct exec .. -- bash` / `sudo sh`) is the OPPOSITE case:
# its body IS a command list the interpreter will execute, so it must be
# left in place for split_segments/tokenize to scan — see
# is_stdin_executor_stage() above. Getting this backwards (stripping it
# too) would have silently turned the gate off for every noisy shape run
# over ssh, which is exactly the kind of undocumented gap  and
#  each left for the next wave to rediscover; it is called out here
# instead. A false positive on the executor check (treating a command as an
# executor when it wasn't one) only costs the  fix's benefit for
# that one command, never a missed gate — same "prefer a false negative"
# framing as the rest of this file.
#
# Two more traps found in the same review round, both now handled:
#   - A `<<WORD` appearing inside an actual shell COMMENT (`# example: cat
#     <<EOF`) is not a real heredoc operator at all — tokenize() already
#     knows an unquoted `#` starting a fresh word begins a comment; this
#     function now tracks the same "start of word" state so it never
#     mistakes commented-out example text for a live heredoc redirect.
#   - A heredoc delimiter is a shell WORD, not restricted to
#     `[A-Za-z0-9_]` — `<<'EOF-1'` is a completely ordinary, if unusual,
#     delimiter. The previous version only captured "EOF" out of "EOF-1",
#     never matched the real terminator line, and silently consumed
#     everything to the end of the string. Delimiter capture is now: for a
#     quoted delimiter, every character up to the matching quote; for an
#     unquoted/backslash-escaped one, every character up to the next
#     whitespace or newline. And as a backstop for any OTHER way a
#     terminator might fail to match (a genuinely malformed/truncated
#     heredoc): if the body-consuming loop reaches end-of-string without
#     ever matching the delimiter, the "stripped" text is discarded and the
#     entire body span is restored into the output UNCHANGED instead —
#     silently swallowing an unmatched heredoc to end-of-string would hide
#     everything after it from every detector, which is a worse failure
#     mode than simply not stripping.
#
# Scans the raw command text once, character-by-character, with the same
# quote-state tracking split_segments uses (so a `<<` or `#` appearing
# inside an actual quoted string is never mistaken for an operator or a
# comment) plus its own copy of split_segments' separator recognition
# (`;`, `&`/`&&` incl. the `2>&1`-is-not-a-separator case, `|`/`||`,
# newline) so it always knows where the CURRENT STAGE started — needed to
# extract that stage's own tokens for is_stdin_executor_stage(). For a
# match that is NOT a stdin-executor stage: keep the operator and the rest
# of its start line intact but drop every subsequent line up to and
# including the terminator line (matched exactly, or after stripping
# leading tabs when the operator was `<<-`) — so the body never reaches
# split_segments/tokenize at all, while a REAL command on the line
# immediately after the terminator is left untouched and still gates
# normally (selftest group 18 case "heredoc then a real gated command"
# proves this survives). is_secret_command and every is_uncapped_*
# detector below are called with this stripped text, never the raw $CMD.
#
# Scope change from the first  landing, now documented rather than
# left implicit: is_secret_command() used to see the FULL raw command,
# including heredoc bodies, so a heredoc body merely containing the word
# "token" (in a `git commit -F -` message, say) suppressed gating for the
# whole command. It now sees the STRIPPED text, so that body text no
# longer counts — gating now runs in that case where it previously did
# not. This is strictly more correct (nothing was ever a real secret leak
# either way — is_secret_command only ever decides whether to gate, and
# gating never prints command text), just a behavior change worth naming.
#
# Known limitation (deliberately NOT fixed this round,  review):
# two heredocs opened on the SAME line (`cmd <<A <<B`) only has the first
# one's body stripped, which is a pre-existing FALSE POSITIVE (gated prose
# in the second heredoc's body still trips a detector) — filed separately
# by the reviewer rather than folded into this round. ----------------------
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
              # This stage's own command reads its heredoc body as commands
              # to execute (ssh/bash/sh/zsh/dash/python/python3) — leave it
              # untouched so the real commands inside still gate normally.
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
                # Quoted delimiter word: everything up to the matching
                # quote, whatever characters it contains ( review:
                # 'EOF-1' is a completely ordinary delimiter).
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
                # Unquoted/backslash-escaped delimiter word: everything up
                # to the next whitespace or newline.
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
                # Keep the operator + rest of this line verbatim.
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
                # Consume heredoc body lines up to and including the
                # terminator line — this is what keeps body text out of
                # split_segments/tokenize entirely. $_sh_body_start marks
                # where the discarded span begins, so it can be restored
                # verbatim if the terminator is never actually found.
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
                  # Never matched — this wasn't a well-formed heredoc after
                  # all (or the delimiter parsing above still missed some
                  # shape). Restore the whole discarded span UNCHANGED
                  # rather than let it silently vanish to end-of-string.
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

# --- Never gate a credential-handling command (see header). Matches only
# actual shell WORDS in each stage, not substrings of the raw command text
# (so a trailing comment or an unrelated `.tpl` path no longer counts). ---
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
# Strip heredoc body text out of the command before ANY tokenizing check —
# see strip_heredocs() above. Every check from here on reads
# $STRIPPED_CMD, never raw $CMD.
STRIPPED_CMD="$(strip_heredocs "$CMD")"

is_secret_command "$STRIPPED_CMD" && exit 0

# --- key_for_string: collision-resistant marker key, same rationale as
# read-shunt.sh's key_for_path (a plain char-substitution hash would collide
# on distinct command strings that differ only in the substituted char). ---
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

# --- Known-noisy shape detection --------------------------------------------
# Each function splits $1 into pipeline stages (split_segments), finds the
# stage that IS the actual invocation (by shell word, not substring), and
# reads capping flags and the piped-or-not verdict only from that stage —
# never from the whole command line. Returns 0 (match, uncapped -> gate)
# only when the invocation is found AND none of its recognised capping
# flags are present AND it isn't piped onward. Returns 1 (do not gate) if
# the invocation isn't found in any stage, or it's already capped/piped.

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
  # Scan EVERY stage rather than returning on the first match — a capped
  # first stage followed by an uncapped later stage (`git log --oneline -5;
  # git log`) must still gate on the uncapped one.
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

# --- Escape hatch: has this (session, exact command) already been gated? ---

[ -n "$SESSION_ID" ] || fail_open "no .session_id in hook payload, cannot dedupe safely"

# session_id is attacker-influenced input (it's a hook payload field) that
# is about to become a path component under $STATE_ROOT. Reject anything
# that isn't a plain path segment before it's used — a value like
# "../../../../../../tmp/pwned" must not be able to escape $STATE_ROOT.
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
