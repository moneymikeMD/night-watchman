#!/bin/bash
#
# guard-fs-writes.sh — Claude Code PreToolUse hook for the Bash tool.
#
# Enforces "agents write only inside their own trees" deterministically
# instead of relying on prose in a project's own CLAUDE.md, which a fresh
# subagent has been observed to read, understand, and violate anyway (a
# verify test once had an agent issue `rm -rf $TMPDIR/tmp.*` after being
# briefed on the rule in full, and then report the removal as done even
# though an auto-mode classifier silently blocked it — the honest-mistake
# case this hook exists to catch deterministically).
#
# Reads the hook's JSON payload on stdin, pulls out `.tool_input.command`
# (the literal, pre-expansion Bash command text Claude Code is about to
# run) and `.cwd` (the real recorded working directory the tool call runs
# from; falls back to this process's own `pwd -P` only when `.cwd` is
# absent). Exits 2 — with the rule text on stderr, which Claude Code
# surfaces back to the model as the tool result — when the command:
#
#   - tokenises as `git [global-opts] {stash|reset|clean}`, or
#     `git [global-opts] checkout [...] -- [...]` (a literal `--` token
#     anywhere after `checkout`), AND the target repo (resolved through
#     any `-C`/`--git-dir`/`--work-tree`/`-c` the command itself carries,
#     else the resolved cwd) is the MAIN worktree, not a linked one — a
#     linked worktree (as used by an optional worktree-dispatch tool, if
#     one is installed) only touches its own tree, so it's allowed there.
#     `git stash list`/`git stash show` are read-only and are never blocked
#     — every OTHER stash form (bare `stash`, `push`, `pop`, `apply`,
#     `drop`, `clear`, `branch`) still is. Ambiguous git-dir resolution
#     blocks, same as the main worktree, OR
#   - tokenises as `find [paths...] ... {-delete|-exec|-execdir|-ok|-okdir}`
#     with any leading path resolving outside worktree+scratchpad — checked
#     BEFORE an `-exec`/`-execdir`/`-ok` command list is ever looked at (the
#     leading-path check used to run only for `-delete`, so `find <outside>
#     -exec rm -rf {} +` was never checked at all), OR
#   - tokenises as `xargs [opts] {rm|mv}` at all, unconditionally — xargs's
#     real arguments are usually stdin-sourced and this hook cannot see
#     stdin data, so it blocks rather than guess, OR
#   - contains an `rm -r`/`rm -rf`, `mv`, or `>`/`>>` redirection whose
#     target resolves outside BOTH the current worktree AND the session
#     scratchpad AND is not one of a fixed device-path allowlist (`/dev/
#     null`, `/dev/stdout`, `/dev/stderr`, `/dev/tty` — NOT a `/dev/*`
#     glob, `/dev/disk0` still blocks).
#
# Exits 0 (allow) otherwise, including whenever the hook cannot make sense
# of its own input — see "Fails open" below.
#
# ---------------------------------------------------------------------------
# Quoting and re-execution contexts
# ---------------------------------------------------------------------------
#
# A word that starts with `'` or `"` — a fully quoted shell argument — is
# DATA, not further command syntax: it is never inspected for `rm`/`mv`/
# `git`/`find`/`xargs`, and a `>` inside it is never treated as a redirect.
# This is what stops `some-tool prompt-agent ticket-1 "... blocks '> $VAR'
# ..."` and a commit message mentioning "git stash" in prose from being
# misdetected as the command doing those things — they're just the TEXT of
# an argument to a command (a remote/wrapper executor, `git commit -m`)
# that isn't a shell re-executor at all. Remote/wrapper-executor tools
# (e.g. one that dispatches a prompt into another agent process) are
# explicitly NOT treated as re-execution contexts here (this hook only has
# visibility into what runs as a `Bash` tool call on THIS machine, and has
# no way to know what a remote agent will actually do with the text).
#
# The ONLY quoted arguments still recursively scanned as commands are the
# ones actually handed to a shell for re-execution: `bash -c "<script>"`,
# `sh -c "<script>"`, `eval <script...>`, `xargs`'s target command when it
# is itself `bash -c`/`sh -c`/`eval`, and a `find ... -exec <cmd> ... \;`
# argument list. `bash -c "git stash"` is still blocked — the quoted
# argument there really is the command being run.
#
# `ssh`, `scp`, `rsync`, and `mosh` are the opposite of a re-execution
# context: once one of them is this segment's OWN command word (not just
# anywhere in the segment — see _ss_cmd_word_idx in scan_segment), every
# word AFTER it is that command's own argv, not a further command this
# hook should dispatch on. This covers the common UNQUOTED form
# (`ssh host mv x $HOME/.local/bin/rtk`), where a bare `mv`/`git`/`rm` word
# inside the remote command used to be misread as a real LOCAL invocation
# of that tool, and `$HOME` used to resolve against THIS machine's
# environment instead of the remote one's. A trailing LOCAL redirect on
# the same line (`ssh host cmd > file`) is still checked — an unquoted
# `>`/`>>` is real shell syntax the local shell parses before ssh/scp/
# rsync/mosh ever see their own argv, regardless of what precedes it.
#
# A QUOTED remote payload (`ssh host 'git stash drop'`) is inert via the
# quoted-word rule above ONLY when it contains no unescaped `;`/`&&`/`||`/
# `|` — this hook's own segment splitting on those four operators (see
# scan_command_text) runs on the RAW command text BEFORE quote-aware
# tokenization, so it does not know those characters are inside a quoted
# string at all. `ssh host "cd /tmp && rm -rf build"` is torn into TWO
# segments — `ssh host "cd /tmp ` and ` rm -rf build"` — and the second one
# is then scanned as its own, unquoted, top-level command, with `rm` as
# ITS OWN command word: a genuinely remote `rm -rf` gets blocked as if it
# were local (the false positive this ticket exists to remove, still
# present for this one shape), or, if its target happens to look local,
# silently misread as an inside-worktree `rm`. Left unfixed here — see the
# scan_command_text header comment on quote-unaware segment splitting, and
# docs/known-issues/ for the open entry — fixing it means teaching the
# segment splitter to be quote-aware, a larger change than this ticket's
# scope (an earlier fix is the command-word opacity above, not the
# splitter).
#
# A word is only treated as "fully quoted" if it STARTS with a quote
# character — a quoted command name like `"rm" -rf /` is not recognised as
# invoking `rm` (a real shell would still run it). This is an accepted,
# documented gap: nobody routinely quotes a bare command name, and the
# false-positive class this fix targets (prose arguments to unrelated
# commands) is the one that actually shipped.
#
# One exception inside "fully quoted": command substitution still executes
# inside DOUBLE quotes in real bash — only single quotes suppress it.
# `echo "result: $(git stash)"` genuinely runs `git stash` (round 3 finding
# 3, CRITICAL). Every `$( ... )` body inside a double-quoted word (nested
# parens included, e.g. `$(echo $(date))`) is extracted and scanned as a
# nested command; the surrounding text of that word is still data. A
# single-quoted word gets none of this — single quotes really do suppress
# command substitution too. `` `...` `` backtick-style substitution is a
# documented gap, not extracted.
#
# Same-command variable substitution now runs on the text handed to a
# re-execution context too (round 3 finding 2, CRITICAL), not only on
# rm/mv/find/redirect targets — `CMD="git stash"; bash -c "$CMD"` resolves
# `$CMD` before the nested scan ever tokenizes it, the same way `find
# ... -exec` resolves a same-command variable in its own argument list.
#
# ---------------------------------------------------------------------------
# Redirect target extraction: trailing punctuation and same-command
# variables (2026-09-09 re-verification, findings A and B)
# ---------------------------------------------------------------------------
#
# A redirect target is extracted by this hook's own naive, quote-unaware
# tokenizer, so it can pick up trailing shell syntax that belongs to
# something ELSE wrapping the redirect — a closing `)` from an enclosing
# `$(...)`, a closing `"` from an enclosing string, a stray `'` left over
# from an unmatched single-quoted string this hook's word-splitter cannot
# see the far end of, `;`, `&`, or `|`. `x=$(op read foo 2>/dev/null)`
# extracted `/dev/null)` as the target, which is not the literal string
# `/dev/null` the device allowlist checks for — every extracted target has
# this trailing punctuation stripped before anything else happens to it.
# Stripping is punctuation-only (never touches path/identifier characters),
# so a genuinely outside path with trailing punctuation is still correctly
# classified outside after stripping, not accidentally read as inside.
#
# A target may also reference a variable assigned EARLIER IN THE SAME
# command (`P=/private/tmp/.../scratchpad/x.tsv; ... > "$P"`) — this hook's
# own `;`/`&&`/`||`/`|` segment splitting means the assignment and the use
# can land in different segments, so this can't be read off the running
# process's real environment (the assignment was never actually executed —
# only scanned). Every `NAME=value` token found anywhere in the command
# text is recorded before segment scanning begins, and `$NAME`/`${NAME}`
# references — bare or embedded in a larger string, e.g. `$L/land.log` —
# are substituted from that table before the normal tilde/environment
# expansion pipeline runs. `$TMPDIR`, `$HOME`, `$PWD`, `$CLAUDE_SCRATCHPAD`
# continue to resolve from this process's real environment as before, same
# as any other real env var. A target that is STILL unresolvable after all
# of this — same-command table, environment, tilde — still blocks (the
# conservative default is unchanged), but the block message now says
# "unresolvable variable" rather than misreporting the raw, un-expanded
# text as if it were the path that was checked. When a target DOES resolve
# but is genuinely outside, the block message names both the raw token and
# the resolved path it checked (round 3, LOW finding) — `P=/etc; cmd >
# "$P/x"` now says it resolved to `/etc/x`, not just the confusing raw
# `"$P/x"`.
#
# ---------------------------------------------------------------------------
# Broad roots
# ---------------------------------------------------------------------------
#
# When cwd is not inside a git repo, WORKTREE falls back to cwd itself. If
# that cwd is one of a small set of well-known shared/system directories
# (`/`, `/tmp`, `/private/tmp`, `/var`, `/private/var`, `/Users`, `/home`,
# `/private`, or bare `$HOME`), treating it as "my own worktree" would let
# ANY target textually under it read as "inside." These roots never count
# as a legitimate worktree; only the scratchpad exemption can allow a
# target there.
#
# ---------------------------------------------------------------------------
# What this does NOT do (read before trusting it for more than it promises)
# ---------------------------------------------------------------------------
#
# This is a text scanner, not a shell parser. Heredoc BODIES are stripped
# before scanning (heredoc content is literal data, not further commands).
# Command-separator splitting on `;`/`&&`/`||`/`|` is itself quote-unaware
# — it runs BEFORE tokenization, so a `;` inside a quoted string can still
# mis-split a segment even though word-level quoting is now understood
# within each segment. Same-command variable resolution has no real
# per-subshell scoping: an assignment made inside a recursively-scanned
# `bash -c "..."` argument is visible for the rest of this hook's run too,
# wider than real shell scoping — accepted, since it can only make the
# guard MORE permissive in a narrow, unrealistic case. Variable
# substitution is boundary-naive (a name that is a prefix of another
# collected name can over-match).
#
# ---------------------------------------------------------------------------
# Deliberately not handled: obfuscation (round 3, 2026-09-09)
# ---------------------------------------------------------------------------
#
# It is a deterministic guard against the HONEST-MISTAKE case described in
# the header above, not a sandbox — the same framing CLAUDE.md already gives
# redaction ("Redaction is a guard against accident, not access control").
# Named, tested, and left unfixed on purpose, because closing them would
# mean parsing and partially executing arbitrary shell — the thing this
# hook exists specifically NOT to become:
#
#   - `eval "git ""stash"` / `eval "git" " " "stash"` — adjacent-string
#     concatenation inside `eval`'s arguments, which real bash joins back
#     into one word before evaluating.
#   - Backslash-escaped quote games (`g\it st\ash`, `"g""it" stash`, etc).
#   - `$(echo git) stash` — the COMMAND NAME itself built by a nested
#     substitution, as opposed to a target/argument (finding 3 above only
#     extracts `$(...)` bodies for scanning; it does not evaluate what one
#     would print and re-parse the result as command syntax).
#   - `x=stash; git $x` — a same-command variable used as part of the git
#     SUBCOMMAND word (this hook's variable substitution runs on
#     rm/mv/find/redirect TARGETS and on re-execution-context script
#     text, not on individual words mid-tokenization before the
#     command-head dispatch has already classified them).
#
# Proof this is the right line, not a gap found too late: during this same
# round, the reviewer (itself an agent) needed to probe the LIVE hook and
# routed its own driver scripts through base64 encoding to do it — i.e.
# the very obfuscation this hook does not chase. That is the hook working
# as designed: it catches the command that LOOKS innocuous and isn't
# (`rm -rf $TMPDIR/tmp.*`, the honest-mistake case from the header above),
# not a command built specifically to defeat inspection. A determined
# bypass was never the threat model here.
#
# ---------------------------------------------------------------------------
# Fails open (mostly) — the git-worktree check fails closed instead
# ---------------------------------------------------------------------------
#
# If `jq` is missing, stdin is not valid JSON, or `.tool_input.command` is
# absent, this prints a note to stderr and exits 0 — a hook that dies on
# malformed input blocks every Bash call in the session, worse than the
# rare destructive command slipping through once. A single `rm`/`mv`/
# redirect target this hook can't resolve to a real path still blocks
# (fail-*closed* for that one target). The main-vs-linked-worktree check is
# the one place ambiguity is resolved fail-closed at the whole-command
# level too: if the target repo's git-dir can't be determined at all, the
# stash/reset/clean/checkout-- block stays in force.
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

# --- Resolve the cwd this command is really running from --------------------
#
# Prefer the hook payload's own `.cwd`. Fall back to this process's own
# physical cwd only when `.cwd` is absent or empty. Either way, resolve to
# the physical (symlink-resolved) form: `git rev-parse --show-toplevel`
# always returns a symlink-resolved path, but a bare cd/$PWD does not — on
# macOS $TMPDIR resolves under /var/folders/..., itself a symlink to
# /private/var/folders/..., so comparing a non-canonical cwd against git's
# canonical worktree root would silently mismatch every relative target.
if [ -n "$PAYLOAD_CWD" ]; then
  PWD_PHYS="$(cd "$PAYLOAD_CWD" 2>/dev/null && pwd -P)"
  [ -n "$PWD_PHYS" ] || PWD_PHYS="$(pwd -P)"
else
  PWD_PHYS="$(pwd -P)"
fi

# Current worktree root, normalized. Falls back to the physical cwd if it
# is not inside a git repo (e.g. a scratch dir with no .git at all).
WORKTREE="$(git -C "$PWD_PHYS" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$WORKTREE" ] || WORKTREE="$PWD_PHYS"

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
if is_broad_root "$WORKTREE"; then
  WORKTREE="/__guard-fs-writes-no-valid-worktree__"
fi

# Normalize a path (absolute or relative-to-cwd) without requiring it to
# exist — realpath/readlink -f are not guaranteed dependencies here, so this
# is a pure-bash collapse of . and .. segments.
normalize_path() {
  _np_in="$1"
  # bash 3.2's "${arr[@]}" throws "unbound variable" under `set -u` for a
  # truly EMPTY array — guard defensively even though no known caller
  # passes an empty string here.
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

# Expand a word-initial ~ or ~/... to $HOME. ~user/... is not resolved —
# treated as unresolved, same conservative default as everything else this
# hook refuses to expand.
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

# Trim leading/trailing plain whitespace (space, tab). Fix for a live
# regression reported after round 3 landed: a device-allowlist target
# ending up with trailing whitespace made the exact-string allowlist check
# miss (`/dev/null ` != `/dev/null`), which reads as "outside" and blocks
# a routine, harmless redirect. None of the existing strip_* helpers touch
# plain space/tab — they only remove shell-syntax punctuation — so this is
# a distinct step, run FIRST, before anything else in the pipeline (quote
# stripping, trailing-punctuation stripping, same-command substitution,
# tilde/env expansion). One concretely reproduced source: a quoted
# same-command assignment VALUE that legitimately contains trailing
# whitespace INSIDE its own quotes (`P="/dev/null "; ... > "$P"`) —
# strip_surrounding_quotes correctly unwraps the quotes but was never
# responsible for trimming what was legitimately inside them, so the space
# survived into the substituted value untouched until this fix.
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

# Strip ONE layer of matched surrounding quotes ("..." or '...'), e.g. the
# token "$P" (as tokenized from `> "$P"`) becomes $P. A no-op if the token
# is not a single fully-quoted span.
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

# Strip trailing shell-syntax punctuation this hook's own quote-unaware
# extraction can pick up from whatever wraps a redirect target — see the
# header. Punctuation-only: never touches path/identifier characters, so a
# genuinely outside path with trailing punctuation is still outside after
# stripping.
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

# Strip trailing segment-separator characters ONLY (`;`, `&`, `|` — never
# quotes or parens). Used before unwrapping a quoted assignment VALUE
# (`CMD="git stash";`), where a plain strip_trailing_punct would also eat
# the value's own legitimate closing quote before strip_surrounding_quotes
# ever gets to see a matched pair.
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

# --- Same-command variable assignments (finding B) --------------------------

_AC_NAMES=()
_AC_VALUES=()

# --- ssh/scp/rsync/mosh opacity stack (script-review fix) -----------
#
# scan_segment's own state (_ss_words, _ss_n, _ss_i, and _ss_opaque) is held
# in plain globals, not `local`s — matching this file's existing style for
# every other _ss_* variable — because scan_segment recurses through
# scan_command_text for every re-execution context (bash -c/sh -c/eval/
# xargs's target/find -exec/a double-quoted word's $( ... ), NOT because it
# calls itself directly. _ss_opaque specifically needs to survive a nested
# scan_command_text call unchanged: the outer segment's own opacity state
# (did IT see ssh/scp/rsync/mosh as ITS OWN command word) must not be
# overwritten by whatever the nested segment's independent scan leaves
# behind. A flat single save/restore variable is NOT safe here — a second
# nested call at a deeper recursion level would clobber the outer's saved
# value before the outer ever restores it — so this is a real stack
# (bash 3.2 has no negative array indices, so the top is tracked by length,
# not `${arr[-1]}`).
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

# Recursion-safe state frames: scan_segment, scan_dollar_parens_in_word and
# scan_command_text keep per-call state in globals and re-enter each other,
# so each saves its own variables on entry and restores them on exit.
_FRAME_STACK=()
_ss_words=()
_ss_find_paths=()
_ss_git_opts=()
_frame_push() {
  local _fp_v _fp_a _fp_n _fp_i
  for _fp_v in $1; do
    if [ -n "${!_fp_v+x}" ]; then
      _FRAME_STACK+=("1" "${!_fp_v}")
    else
      _FRAME_STACK+=("0" "")
    fi
  done
  for _fp_a in $2; do
    eval "_fp_n=\${#${_fp_a}[@]}"
    _fp_i=0
    while [ "$_fp_i" -lt "$_fp_n" ]; do
      eval "_FRAME_STACK+=(\"\${${_fp_a}[${_fp_i}]}\")"
      _fp_i=$((_fp_i + 1))
    done
    _FRAME_STACK+=("$_fp_n")
  done
}
_frame_pop() {
  local _fq_v _fq_a _fq_n _fq_last _fq_start _fq_i _fq_rev=""
  for _fq_a in $2; do _fq_rev="$_fq_a $_fq_rev"; done
  for _fq_a in $_fq_rev; do
    _fq_last=$((${#_FRAME_STACK[@]} - 1))
    _fq_n="${_FRAME_STACK[$_fq_last]}"
    unset "_FRAME_STACK[$_fq_last]"
    _fq_start=$((_fq_last - _fq_n))
    eval "$_fq_a=()"
    _fq_i=0
    while [ "$_fq_i" -lt "$_fq_n" ]; do
      eval "$_fq_a+=(\"\${_FRAME_STACK[$((_fq_start + _fq_i))]}\")"
      _fq_i=$((_fq_i + 1))
    done
    _fq_i=$((_fq_n - 1))
    while [ "$_fq_i" -ge 0 ]; do
      unset "_FRAME_STACK[$((_fq_start + _fq_i))]"
      _fq_i=$((_fq_i - 1))
    done
  done
  _fq_rev=""
  for _fq_v in $1; do _fq_rev="$_fq_v $_fq_rev"; done
  for _fq_v in $_fq_rev; do
    _fq_last=$((${#_FRAME_STACK[@]} - 1))
    if [ "${_FRAME_STACK[$((_fq_last - 1))]}" = "1" ]; then
      printf -v "$_fq_v" '%s' "${_FRAME_STACK[$_fq_last]}"
    else
      unset "$_fq_v"
    fi
    unset "_FRAME_STACK[$_fq_last]" "_FRAME_STACK[$((_fq_last - 1))]"
  done
}
_SS_FRAME_ARRAYS="_ss_words _ss_find_paths _ss_git_opts"
_SS_FRAME_VARS="_ss_after _ss_cmd_word_idx _ss_ek _ss_et _ss_eval_rest _ss_exec_cmd _ss_find_has_action _ss_fk2 _ss_flag _ss_ftok _ss_git_block _ss_git_linked _ss_git_subcmd _ss_gj _ss_gk _ss_gk2 _ss_gtok _ss_i _ss_j _ss_k _ss_line _ss_n _ss_next_i _ss_opaque _ss_saw_recursive _ss_stash_action _ss_tgt _ss_word _ss_xargs_cmd _ss_xeval _ss_xj2 _ss_xk _ss_xtok"
_SDP_FRAME_VARS="_sdp_body _sdp_c _sdp_c2 _sdp_cj _sdp_depth _sdp_i _sdp_j _sdp_len _sdp_text"
_SCT_FRAME_VARS="_sct_no_heredoc _sct_old_ifs _sct_seg _sct_segments _sct_text"

# tokenize_quoted_cca: a private, quote-aware tokenizer identical in logic
# to tokenize_quoted, but writing to its OWN global array (_CCA_WORDS)
# rather than _ss_words. collect_same_command_assignments can be called
# WHILE an outer scan_segment loop is mid-iteration (a nested re-execution
# context calls scan_command_text, which calls this) — reusing tokenize_quoted's
# _ss_words/_ss_n directly would clobber the outer loop's own state out
# from under it. Newlines are folded to spaces first (assignment scanning
# doesn't care about line structure, and this avoids a third whitespace
# case inside the loop).
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

# collect_same_command_assignments: scans the given (whole, unsplit) command
# text for simple `NAME=value` tokens anywhere — not just command-initial,
# a deliberately broad heuristic — and records them in the GLOBAL
# _AC_NAMES/_AC_VALUES tables, so a target in a LATER segment (this hook's
# own `;`/`&&`/`||`/`|` splitting can put the assignment and the use in
# different segments) can still resolve. Quote-aware (round 3, 2026-09-09):
# `CMD="git stash"` must record the WHOLE two-word value, not fragment at
# its internal space — plain IFS splitting would have captured only
# `"git` for the name CMD, silently truncating the value.
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
        # Order matters: strip trailing SEPARATOR punctuation only
        # (`;`/`&`/`|`, e.g. the common `P=/path;` with no preceding
        # space) before attempting to unwrap a matched surrounding quote
        # pair — a plain strip_trailing_punct here would also eat the
        # value's own legitimate closing quote before
        # strip_surrounding_quotes ever saw a matched pair to unwrap.
        # strip_trailing_punct runs once more after, to catch any
        # remaining stray/unmatched punctuation.
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

# substitute_same_command_vars: textual replacement of ${NAME}/$NAME for
# every NAME collected so far, whole-string or embedded (e.g. $L/land.log).
# Boundary-naive (a name that is a prefix of another collected name can
# over-match) — documented in the header rather than solved with a heavier
# boundary-aware loop, per "simple assignments" in the finding.
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

# _TIO_LAST_REASON communicates WHY target_is_outside returned "outside" so
# the caller's block message can say "unresolvable variable" instead of
# misreporting an unresolved raw string as if it were the checked path
# (finding B). _TIO_LAST_RESOLVED carries the actual resolved, normalized
# path once one was successfully computed, so a genuinely-outside block
# message can name what was actually checked (round 3, LOW finding) instead
# of only the raw, possibly variable-laden token.
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
  # Trim again after substitution: a same-command variable VALUE can carry
  # whitespace that was legitimately inside its own quotes
  # (`P="/dev/null "; ... > "$P"`) — substitute_same_command_vars is a
  # plain textual replacement, so that whitespace survives into $_tio_s
  # until trimmed here.
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

  _tio_worktree_norm="$(normalize_path "$WORKTREE")"

  if is_under "$_tio_norm" "$_tio_worktree_norm"; then
    return 1
  fi

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

# check_and_block_target: the shared target_is_outside -> block() wire-up
# used by every kind of target (rm/mv/find/redirect), so the
# "unresolvable variable" vs "outside worktree and scratchpad" message
# distinction (finding B) is applied consistently everywhere instead of
# being repeated (and risking drifting out of sync) at each call site.
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

# git_global_opt_takes_value: true for the handful of `git` global options
# that consume a SEPARATE following token as their value when written
# without an attached `=` (e.g. `-C dir`, but not `--git-dir=dir`, which is
# already self-contained and won't match this exact-token check at all).
git_global_opt_takes_value() {
  case "$1" in
    -C|-c|--config|--git-dir|--work-tree|--namespace|--super-prefix) return 0 ;;
    *) return 1 ;;
  esac
}

# git_target_is_linked_worktree: $@ = the git global-option tokens collected
# between `git` and its subcommand. Replays them to a real `git rev-parse
# --git-dir` probe from this hook's own resolved cwd, so directory
# resolution (-C chaining, relative --git-dir, etc.) is exactly what git
# itself would do — not reimplemented here. A git-dir under
# <common-dir>/worktrees/<name> is git's own convention for a linked
# worktree. Returns 1 (not a confirmed linked worktree, i.e. block stays
# conservative) if the probe fails for any reason.
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
# token as their value when written without an attached value (mirrors
# git_global_opt_takes_value's exact-token-only matching).
xargs_opt_takes_value() {
  case "$1" in
    -I|-n|-P|-L|-s|-E|-d|--delimiter|--max-args|--max-procs|--max-lines|--replace) return 0 ;;
    *) return 1 ;;
  esac
}

# is_quoted_word: true if $1 STARTS with a quote character — a fully
# quoted shell argument, e.g. the whole of `"... prose ..."` as extracted
# by tokenize_quoted. See the header's "Quoting and re-execution contexts"
# section. Deliberately start-of-word only: `"rm" -rf /` is not recognised
# as invoking rm (documented gap, not the false-positive class this exists
# to fix).
is_quoted_word() {
  case "$1" in
    \'*|\"*) return 0 ;;
    *) return 1 ;;
  esac
}

# scan_dollar_parens_in_word: a DOUBLE-quoted word is DATA per
# is_quoted_word/finding D, EXCEPT for one construct — command
# substitution still executes inside double quotes in real bash (only
# single quotes suppress it). `echo "result: $(git stash)"` genuinely
# runs `git stash`; round 3 finding 3 (CRITICAL) is that treating the
# whole double-quoted word as inert skipped this entirely. Extracts every
# top-level `$( ... )` body (paren-depth-aware, so nested substitutions
# like `$(echo $(date))` extract correctly) and scans each as a nested
# command via scan_command_text; the rest of the word is still data and is
# not otherwise inspected. Single-quoted words are NOT passed through
# this — single quotes really do suppress command substitution too, so
# they stay fully inert, matching real shell semantics. Backtick-style
# `` `...` `` substitution is a documented gap, not handled here.
_scan_dollar_parens_in_word_body() {
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

scan_dollar_parens_in_word() {
  local _fw_rc
  _frame_push "$_SDP_FRAME_VARS" ""
  _scan_dollar_parens_in_word_body "$@"
  _fw_rc=$?
  _frame_pop "$_SDP_FRAME_VARS" ""
  return "$_fw_rc"
}

# tokenize_quoted: quote-AWARE word splitting (unlike the old IFS-based
# split this replaces). Populates the global array _ss_words. A '...' or
# "..." span becomes part of the CURRENT word without ending it at
# internal whitespace, so a prose argument like `"... blocks '> $VAR' ..."`
# stays ONE token instead of fragmenting into synthetic words that
# individually look like redirects or command names (2026-09-09
# re-verification, finding D). An unterminated quote consumes to the end
# of the segment rather than looping forever.
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

_scan_segment_body() {
  _ss_line="$1"
  tokenize_quoted "$_ss_line"
  _ss_n="${#_ss_words[@]}"
  [ "$_ss_n" -eq 0 ] && return 0

  # _ss_opaque: once a remote-executor command (ssh/scp/rsync/mosh) is seen
  # as this segment's OWN COMMAND WORD (not just anywhere in the segment —
  # script-review finding: matching the bare word "ssh" at ANY
  # position let `echo ssh rm -rf /etc` slip a real local `rm -rf /etc`
  # through unblocked, since the word "ssh" appearing as, say, an argument
  # to an unrelated command set opacity for the rest of the segment too),
  # every word AFTER it is that command's own argv — a remote host's
  # worktree layout, or a remote shell's own $HOME, neither of which this
  # hook can resolve (see header, "Quoting and re-execution contexts").
  # Guards ONLY the command-head dispatch below (rm/mv/find/xargs/bash/
  # eval/git) so a bare `mv`/`git`/`rm` word inside an UNQUOTED remote
  # command (`ssh host mv x $HOME/...`) is not misread as a real local
  # invocation of that tool — a quoted remote payload (`ssh host 'git
  # stash drop'`) was already inert via is_quoted_word before this existed.
  # Deliberately does NOT guard the redirect check at the bottom of the
  # loop: an unquoted `>`/`>>` is real shell syntax wherever it appears on
  # the line, parsed by the LOCAL shell before ssh/scp/rsync/mosh ever sees
  # argv, so a trailing local redirect (`ssh host cmd > file`) is still
  # checked correctly.
  #
  # _ss_opaque is saved/restored (via _ss_opaque_push/_ss_opaque_pop, a
  # real stack) around every nested scan_command_text call below —
  # script-review finding: without this, a nested re-execution
  # context's own scan (which always starts this segment's _ss_opaque at 0
  # and may set it to 1 for ITS OWN command word) would silently overwrite
  # THIS segment's opacity state for every word still to come after the
  # nested call returns, in either direction.
  _ss_opaque=0

  # _ss_cmd_word_idx: the index of THIS segment's own command word — the
  # first word that is not a leading `NAME=value` assignment (`FOO=bar ssh
  # host ...`) and not one of the two transparent prefixes that pass their
  # argv through unchanged: `env` (with its own NAME=value words) and
  # `command`. Only a ssh/scp/rsync/mosh word AT this index sets
  # _ss_opaque; the same word appearing later in the segment (an -exec
  # command's own script text, a `-name ssh` argument, a value handed to
  # some other flag) is just another word, not this segment's command.
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
      # Fully quoted argument: data, not command syntax. Skip both the
      # command-head dispatch below and the redirect check that follows it
      # for this word entirely (finding D). Target-collection loops
      # (the words AFTER a real, unquoted rm/mv/redirect) are unaffected —
      # they run independently and still quote-strip+resolve normally.
      # EXCEPT: command substitution still executes inside DOUBLE quotes
      # (round 3 finding 3) — extract and scan any $( ... ) bodies before
      # moving on; single-quoted words get no such treatment, since single
      # quotes really do suppress it.
      case "$_ss_word" in
        \"*) scan_dollar_parens_in_word "$_ss_word" ;;
      esac
      _ss_i=$((_ss_i + 1))
      continue
    fi

    # basename match so /bin/rm, /usr/bin/mv etc. are still caught.
    if [ "$_ss_opaque" -eq 0 ]; then
    case "$_ss_word" in
      ssh|*/ssh|scp|*/scp|rsync|*/rsync|mosh|*/mosh)
        # Only at THIS segment's own command-word position (see
        # _ss_cmd_word_idx above) — everything after it is then that
        # command's own argv, opaque remote payload (see _ss_opaque
        # comment above).
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

        # Does this find command carry ANY action that touches what it
        # finds — -delete, -exec, -execdir, -ok, -okdir? Round 3 finding 1
        # (CRITICAL): the leading-path check used to run ONLY for -delete,
        # so `find <outside> -exec rm -rf {} +` was never checked against
        # its own search root at all.
        _ss_find_has_action=0
        _ss_k="$_ss_j"
        while [ "$_ss_k" -lt "$_ss_n" ]; do
          case "${_ss_words[$_ss_k]}" in
            -delete|-exec|-execdir|-ok|-okdir) _ss_find_has_action=1 ;;
          esac
          _ss_k=$((_ss_k + 1))
        done

        # Check find's own search root BEFORE ever looking at what an
        # -exec/-execdir/-ok argument list says to do with what it finds.
        # This is also what makes `{}` (find's "the matched file" token)
        # safe to leave as ordinary text in the nested -exec scan below: by
        # the time that scan runs, the root has already been confirmed
        # NOT outside (an outside root already exited via block() above),
        # so treating `{}` as just another relative-to-cwd word there is
        # no longer a bypass — anything find could hand it is, by
        # definition, already inside a root this hook accepted.
        if [ "$_ss_find_has_action" -eq 1 ]; then
          # bash 3.2: "${arr[@]}" on a truly EMPTY array throws under
          # `set -u` — check the count before ever expanding it.
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
            # A re-execution context (finding D): scan the collected
            # command as a nested command. Reached only when the find
            # root was already confirmed safe above.
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

        # Everything from find's own leading paths through the end of the
        # segment has now been consumed by find's own processing above —
        # advance the OUTER word pointer past all of it (the loop's own
        # trailing `_ss_i += 1` runs next), not just past the `find` word
        # itself. Without this, the outer per-word dispatch independently
        # re-visits "rm"/"mv"/etc INSIDE an -exec's own argument list as
        # if they were bare top-level words — discovered as a real false
        # positive, not a hypothetical: `find ./inside -exec rm -rf {} \;`
        # (the single most common real `-exec` terminator form) blocked a
        # legitimate inside-worktree command, because segment-splitting on
        # the literal `;` inside `\;` left a stray trailing `\` token that
        # this duplicate top-level pass fed to `rm`'s target check as if
        # it were a real path.
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
          rm|*/rm|mv|*/mv)
            block "xargs invokes $_ss_xargs_cmd on stdin-sourced arguments this hook cannot statically verify"
            ;;
          bash|*/bash|sh|*/sh)
            # xargs's target command is itself a re-execution context
            # (finding D): `xargs ... sh -c "..."`.
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
        # `bash -c "<script>"` / `sh -c "<script>"` is a re-execution
        # context (finding D): the quoted argument IS a command to run —
        # recursively scan it, quote-stripped, rather than skip it as
        # prose the way a generically-quoted argument is skipped.
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
        # `eval "<script>"` / `eval <script...>` — join everything after
        # `eval` on this segment as the nested command text (finding D).
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
              # git stash list/show are read-only (2026-09-09
              # re-verification, finding C) — every other stash form
              # (bare, push, pop, apply, drop, clear, branch) still blocks.
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
            # bash 3.2 (macOS /bin/bash): "${arr[@]}" on an EMPTY array
            # throws "unbound variable" under `set -u`, unlike bash 4.4+ —
            # branch around the expansion entirely rather than expand it.
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

    # Redirection: ">file", ">>file", ">", ">>", "N>file", "N>>file", and
    # the same with the target as the next word. "&N" / "&-" (as in
    # "2>&1", a file-descriptor duplication/close) is NOT a filesystem
    # target at all — it is not resolved as a path.
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

scan_segment() {
  local _fw_rc
  _frame_push "$_SS_FRAME_VARS" "$_SS_FRAME_ARRAYS"
  _scan_segment_body "$@"
  _fw_rc=$?
  _frame_pop "$_SS_FRAME_VARS" "$_SS_FRAME_ARRAYS"
  return "$_fw_rc"
}

# Strip heredoc BODIES (everything between a <<WORD/<<-WORD/<<'WORD'/<<"WORD"
# opener and its terminator line, inclusive of the terminator) before this
# text is split into segments and scanned — heredoc content is literal
# data, not further shell commands. Only the first `<<` marker per physical
# line is recognised.
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

# scan_command_text: the shared entry point for both the top-level command
# and any nested re-execution context (bash -c/sh -c/eval/xargs's target/
# find -exec, finding D) — heredoc-strip, collect same-command variable
# assignments (finding B, extended to nested scripts too), split into
# segments, scan each. Recursion (a nested script that itself contains
# another bash -c, say) is ordinary bash function-call recursion, not
# subshells, so a block() deep inside still `exit`s the whole hook.
#
# A literal `\;` is protected from the `;`-split first (placeholder, then
# restored) — it is find's own ESCAPED terminator (`find ... -exec ... \;`
# is the single most common `-exec` form), not a real command separator.
# Discovered as a real false positive fixing round 3 finding 1: without
# this, `find ./inside -exec rm -rf {} \;` (a legitimate inside-worktree
# command) split into a segment ending in a stray trailing `\`, which then
# reached `rm`'s own target check as if it were a real path and blocked.
_scan_command_text_body() {
  _sct_text="$1"
  _sct_no_heredoc="$(strip_heredocs "$_sct_text")"
  collect_same_command_assignments "$_sct_no_heredoc"
  _sct_segments="$(printf '%s\n' "$_sct_no_heredoc" | sed -e 's/\\;/@@GUARD_ESC_SEMI@@/g' -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/;/\n/g' -e 's/|/\n/g' -e 's/@@GUARD_ESC_SEMI@@/\\;/g')"
  _sct_old_ifs="$IFS"
  IFS='
'
  for _sct_seg in $_sct_segments; do
    IFS="$_sct_old_ifs"
    scan_segment "$_sct_seg"
    IFS='
'
  done
  IFS="$_sct_old_ifs"
  return 0
}

scan_command_text() {
  local _fw_rc
  _frame_push "$_SCT_FRAME_VARS" ""
  _scan_command_text_body "$@"
  _fw_rc=$?
  _frame_pop "$_SCT_FRAME_VARS" ""
  return "$_fw_rc"
}

scan_command_text "$CMD"

exit 0
