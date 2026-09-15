#!/bin/bash
#
# Assertions for guard-fs-writes.sh.
#
# Feeds the hook recorded-shape PreToolUse JSON (`.tool_input.command`,
# corroborated against Claude Code's own documented PreToolUse hook payload
# shape) and asserts:
#
#   - blocks `rm -rf $TMPDIR/tmp.*` (the honest-mistake incident command
#     described in guard-fs-writes.sh's own header)
#   - blocks a command containing `git stash`
#   - allows `rm -rf` of a path under the session scratchpad
#   - allows `rm -rf` of a path under the current worktree
#   - allows plain `ls`
#
# Per this plugin's own name-the-oracle rule (see script-reviewer.md):
# section (mutation) below is not run automatically here — it is a manual
# demonstration that a deliberately broken copy of guard-fs-writes.sh
# (e.g. exit 2 flipped to exit 0 on a block path) makes this selftest
# FAIL, and that the unmodified script passes. A selftest that has never
# been observed failing has not been tested, only exercised.
#
# Runs entirely against synthetic JSON on stdin and a throwaway scratch git
# repo this script creates and destroys itself — never the real repo, never
# a real host. Safe to run anywhere, any number of times.
#
# Usage: ./hooks/guard-fs-writes-selftest.sh
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

GUARD="${GUARD_SH:-$HERE/guard-fs-writes.sh}"
[ -f "$GUARD" ] || { echo "cannot find guard-fs-writes.sh at $GUARD" >&2; exit 1; }

FAIL=0
N=0
pass() { N=$((N + 1)); echo "PASS $N: $1"; }
fail() { N=$((N + 1)); echo "FAIL $N: $1" >&2; FAIL=1; }

assert_exit() {
  desc="$1"; want="$2"; got="$3"
  if [ "$want" = "$got" ]; then
    pass "$desc (oracle: exit code, want $want got $got)"
  else
    fail "$desc (oracle: exit code, want $want got $got)"
  fi
}

# --- Scratch fixtures: a throwaway git repo and a throwaway "scratchpad" ---
#
# Neither is the real repo worktree and neither is under this session's
# real $CLAUDE_SCRATCHPAD — both are minted fresh by this script and torn
# down on exit, so a run of this selftest never touches shared state.

SCRATCH="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
# Canonicalize once, immediately: macOS mktemp -d returns a path under
# /var/folders/..., itself a symlink to /private/var/folders/...; the guard
# always canonicalizes (it has to, to avoid a worktree/relative-path
# mismatch — see guard-fs-writes.sh's own comment on PWD_PHYS). If this
# fixture's own path variables stayed non-canonical, string-compared
# absolute targets in the .cwd assertions below would mismatch the guard's
# canonical WORKTREE for a reason that has nothing to do with what's under
# test.
SCRATCH="$(cd "$SCRATCH" && pwd -P)" || { echo "canonicalizing SCRATCH failed" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

FAKE_WORKTREE="$SCRATCH/fake-worktree"
FAKE_SCRATCHPAD="$SCRATCH/fake-scratchpad"
NOHOOKS_DIR="$SCRATCH/nohooks"
NOT_WORKTREE_NOT_SCRATCH="$SCRATCH/not-worktree-not-scratch"
mkdir -p "$FAKE_WORKTREE" "$FAKE_SCRATCHPAD" "$NOHOOKS_DIR" "$NOT_WORKTREE_NOT_SCRATCH"

# A scratch git repo is not isolated by default (core.hooksPath,
# commit.gpgsign, gpg.format, user.signingkey all fall through to global
# config) — pin every one of these to scratch-local values, per CLAUDE.md's
# "Agents write only inside their own trees" gotcha. This repo DOES need one
# commit (below) so `git worktree add` has something to check out for the
# finding-5 linked-worktree case; hooksPath points at an empty directory so
# that commit invokes no real hook.
git -C "$FAKE_WORKTREE" init -q
git -C "$FAKE_WORKTREE" config core.hooksPath "$NOHOOKS_DIR"
git -C "$FAKE_WORKTREE" config commit.gpgsign false
git -C "$FAKE_WORKTREE" config gpg.format ""
git -C "$FAKE_WORKTREE" config user.email "guard-selftest@example.invalid"
git -C "$FAKE_WORKTREE" config user.name "guard-fs-writes-selftest"
: > "$FAKE_WORKTREE/seed.txt"
git -C "$FAKE_WORKTREE" add seed.txt
git -C "$FAKE_WORKTREE" commit -q -m "seed"

# A linked worktree off the same fake repo — this is what "isolation:worktree"
# and a worktree-dispatch tool's worktrees look like on disk (review
# finding 5): its --git-dir lives under the main repo's
# .git/worktrees/<name>, distinct from --git-common-dir.
FAKE_LINKED_WORKTREE="$SCRATCH/fake-linked-worktree"
git -C "$FAKE_WORKTREE" worktree add -q -b guard-selftest-branch "$FAKE_LINKED_WORKTREE" >/dev/null

run_guard() {
  # $1 = cwd to invoke the guard from, $2 = command text.
  # Prints exit code on stdout; stderr of the guard itself is discarded (the
  # assertions below care about exit code and block/allow, not the exact
  # wording of the rule text).
  _cwd="$1"
  _cmd="$2"
  _payload="$(jq -cn --arg cmd "$_cmd" '{session_id:"test",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd}}')"
  (cd "$_cwd" && printf '%s' "$_payload" | "$GUARD" >/dev/null 2>&1)
  echo $?
}

run_guard_payload() {
  # $1 = cwd to invoke the guard FROM (the guard's own process cwd — distinct
  #      from any .cwd the payload itself claims), $2 = full JSON payload.
  _cwd="$1"
  _payload="$2"
  (cd "$_cwd" && printf '%s' "$_payload" | "$GUARD" >/dev/null 2>&1)
  echo $?
}

# --- 1. blocks the honest-mistake incident command -------------------------

# shellcheck disable=SC2016 # deliberately literal: this is the raw, pre-expansion
# command text the guard receives — $TMPDIR must reach it unexpanded.
CMD_RM_TMPDIR='rm -rf $TMPDIR/tmp.*'
GOT="$(TMPDIR="$SCRATCH/not-worktree-not-scratch-tmp" run_guard "$FAKE_WORKTREE" "$CMD_RM_TMPDIR")"
assert_exit "blocks rm -rf \$TMPDIR/tmp.* (honest-mistake incident command, TMPDIR outside worktree/scratchpad)" 2 "$GOT"

# --- 2. blocks git stash ----------------------------------------------------

CMD_STASH='git stash push -u'
GOT="$(run_guard "$FAKE_WORKTREE" "$CMD_STASH")"
assert_exit "blocks a command containing 'git stash'" 2 "$GOT"

# --- 3. allows rm -rf under the session scratchpad --------------------------

# shellcheck disable=SC2016 # deliberately literal, same reason as above
CMD_RM_SCRATCH='rm -rf $CLAUDE_SCRATCHPAD/leftover-file'
GOT="$(CLAUDE_SCRATCHPAD="$FAKE_SCRATCHPAD" run_guard "$FAKE_WORKTREE" "$CMD_RM_SCRATCH")"
assert_exit "allows rm -rf of a path under CLAUDE_SCRATCHPAD" 0 "$GOT"

# --- 4. allows rm -rf under the current worktree ----------------------------

CMD_RM_WORKTREE='rm -rf ./leftover-dir'
GOT="$(unset CLAUDE_SCRATCHPAD; run_guard "$FAKE_WORKTREE" "$CMD_RM_WORKTREE")"
assert_exit "allows rm -rf of a relative path resolving inside the worktree" 0 "$GOT"

# --- 5. allows plain ls ------------------------------------------------------

GOT="$(run_guard "$FAKE_WORKTREE" "ls -la")"
assert_exit "allows plain 'ls -la'" 0 "$GOT"

# --- 6. review round 1, finding 1: tokenised git-pattern match, not
# a literal substring — bypassed pre-fix by -C, --git-dir=, and doubled
# whitespace ------------------------------------------------------------------

CMD_STASH_DASH_C="git -C $FAKE_WORKTREE stash"
GOT="$(run_guard "$FAKE_WORKTREE" "$CMD_STASH_DASH_C")"
assert_exit "blocks 'git -C <dir> stash' (finding 1: -C bypassed the literal substring match)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git --git-dir=$FAKE_WORKTREE/.git reset")"
assert_exit "blocks 'git --git-dir=... reset' (finding 1)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git checkout --quiet -- somefile")"
assert_exit "blocks 'git checkout --quiet -- somefile' (finding 1: a flag between checkout and --)" 2 "$GOT"

# shellcheck disable=SC2016 # literal two-space command text under test, not a shell expansion
CMD_STASH_TWOSPACE='git  stash'
GOT="$(run_guard "$FAKE_WORKTREE" "$CMD_STASH_TWOSPACE")"
assert_exit "blocks 'git  stash' (finding 1: doubled whitespace bypassed the literal substring match)" 2 "$GOT"

# --- 7. review round 1, finding 5: stash/reset/clean/checkout-- are
# only blocked in the MAIN worktree; a linked worktree (isolation:worktree,
# a worktree-dispatch tool) only ever touches its own tree, so it's
# allowed there ------------------------------------------------------------

GOT="$(run_guard "$FAKE_WORKTREE" "git reset --hard")"
assert_exit "blocks 'git reset --hard' run in the MAIN worktree" 2 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git reset --hard")"
assert_exit "allows 'git reset --hard' run in a LINKED worktree (finding 5)" 0 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git stash push -u")"
assert_exit "allows 'git stash' run in a LINKED worktree (finding 5)" 0 "$GOT"

# --- 8. review round 1, finding 2: find -delete and xargs rm/mv,
# previously undisclosed and unblocked entirely -----------------------------

GOT="$(run_guard "$FAKE_WORKTREE" "find $SCRATCH/not-worktree-not-scratch -delete")"
assert_exit "blocks 'find <outside> -delete' (finding 2)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "find ./leftover-dir -type f -delete")"
assert_exit "allows 'find <inside-worktree> -delete' (finding 2, no false positive)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "echo $SCRATCH/not-worktree-not-scratch | xargs rm -rf")"
assert_exit "blocks 'echo <outside> | xargs rm -rf' (finding 2: xargs' real targets are stdin-sourced and unverifiable, so xargs rm/mv is blocked unconditionally)" 2 "$GOT"

# --- 9. review round 1, finding 3: a leading ~ must resolve to
# $HOME, not be treated as a literal path segment relative to cwd — and a
# non-git cwd that is itself a well-known shared/system root (here
# /private/tmp) must not count as "my own worktree" ------------------------

# shellcheck disable=SC2016 # literal, pre-expansion command text under test
CMD_TILDE_ESCAPE='rm -rf ~/../../../private/tmp/some-outside-target'
GOT="$(run_guard_payload /private/tmp "$(jq -cn --arg cmd "$CMD_TILDE_ESCAPE" '{tool_input:{command:$cmd}}')")"
assert_exit "blocks a ~/../.. escape run from a bare system root (finding 3)" 2 "$GOT"

# --- 10. review round 1, finding 4: a heredoc BODY is literal data,
# not further shell commands — prose that merely resembles a redirect must
# not be scanned as one ------------------------------------------------------

HEREDOC_CMD="$(printf "cat <<'EOF'\nsome doc text mentions 1 > /etc/passwd as prose, not a real redirect\nEOF\n")"
GOT="$(run_guard "$FAKE_WORKTREE" "$HEREDOC_CMD")"
assert_exit "allows a heredoc whose body merely mentions a redirect-looking string (finding 4)" 0 "$GOT"

# --- 11. review round 1, finding 6: prefer the payload's own .cwd
# over this process's pwd -P — this matters because the payload's own
# `.cwd` is the recorded working directory the Bash tool call actually ran
# from, which can differ from this hook process's own cwd ------------------

# Both cases target an ABSOLUTE path under $FAKE_WORKTREE while the guard's
# own process cwd is $FAKE_LINKED_WORKTREE (a DIFFERENT, equally legitimate
# worktree) or vice versa — a relative target or a generic non-git process
# cwd would trivially self-allow regardless of whether .cwd is read (any
# fallback cwd is, by construction, "inside itself"), so this only
# discriminates the fix because the two worktrees are distinct real
# directories and the target is absolute.

PAYLOAD_CWD_INSIDE="$(jq -cn --arg cwd "$FAKE_WORKTREE" --arg tgt "$FAKE_WORKTREE/leftover-dir" '{cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:("rm -rf " + $tgt)}}')"
GOT="$(run_guard_payload "$FAKE_LINKED_WORKTREE" "$PAYLOAD_CWD_INSIDE")"
assert_exit "uses payload .cwd (FAKE_WORKTREE) to allow a target under it, even though the guard's own process cwd is the DIFFERENT FAKE_LINKED_WORKTREE (finding 6)" 0 "$GOT"

PAYLOAD_CWD_OUTSIDE="$(jq -cn --arg cwd "$FAKE_LINKED_WORKTREE" --arg tgt "$FAKE_WORKTREE/leftover-dir" '{cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:("rm -rf " + $tgt)}}')"
GOT="$(run_guard_payload "$FAKE_WORKTREE" "$PAYLOAD_CWD_OUTSIDE")"
assert_exit "uses payload .cwd (FAKE_LINKED_WORKTREE) to block a target under the DIFFERENT FAKE_WORKTREE, even though the guard's own process cwd IS FAKE_WORKTREE (finding 6)" 2 "$GOT"

# --- 12. Re-verification finding (2026-09-09, after review round 1): a
# fixed device-path allowlist for /dev/null, /dev/stdout, /dev/stderr,
# /dev/tty — NOT a /dev/* glob, since /dev/disk0 (and friends) must still
# block. These four devices appear in most routine agent commands
# (including this selftest's own `run_guard`, which discards the guard's
# stderr/stdout via `>/dev/null 2>&1`) and were misread as outside-
# worktree writes before this fix. -------------------------------------

GOT="$(run_guard "$FAKE_WORKTREE" "echo hi 2>/dev/null")"
assert_exit "allows 'echo hi 2>/dev/null' (device allowlist)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "some-cmd >/dev/null 2>&1")"
assert_exit "allows '>/dev/null 2>&1' (device allowlist)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "echo hi > /dev/disk0")"
assert_exit "still blocks '> /dev/disk0' (device allowlist must be explicit, not a /dev/* glob)" 2 "$GOT"

run_guard_stderr() {
  # $1 = cwd, $2 = command text. Prints ONLY the guard's stderr (its block
  # message lands there), discarding stdout — deliberate order, not the
  # SC2069 mistake: `2>&1` first duplicates fd2 onto the command
  # substitution's capture target, THEN `>/dev/null` replaces fd1, so only
  # stderr is captured.
  _cwd="$1"
  _cmd="$2"
  _payload="$(jq -cn --arg cmd "$_cmd" '{session_id:"test",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd}}')"
  # shellcheck disable=SC2069 # deliberate: captures stderr only, see comment above
  (cd "$_cwd" && printf '%s' "$_payload" | "$GUARD" 2>&1 >/dev/null)
}

assert_contains() {
  _ac_desc="$1"; _ac_haystack="$2"; _ac_needle="$3"
  case "$_ac_haystack" in
    *"$_ac_needle"*) pass "$_ac_desc (oracle: substring match for '$_ac_needle')" ;;
    *)
      fail "$_ac_desc (oracle: substring match for '$_ac_needle')"
      printf '%s\n' "$_ac_haystack" | sed 's/^/    /' >&2
      ;;
  esac
}

# --- 13. Re-verification round 2, finding A: trailing shell-syntax
# punctuation this hook's own quote-unaware extraction can pick up from
# whatever wraps a redirect target (a closing `)` from an enclosing
# $(...), a stray closing `'`/`"`) must be stripped before the device
# allowlist (or anything else) classifies the target. -------------------

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT="$(run_guard "$FAKE_WORKTREE" 'x=$(op read foo 2>/dev/null)')"
assert_exit "allows 'x=\$(op read foo 2>/dev/null)' — trailing ')' stripped from the extracted target (finding A)" 0 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT="$(run_guard "$FAKE_WORKTREE" '[ "$(op read foo 2>/dev/null)" = admin ] && echo Y')"
assert_exit "allows the same inside a [ ... ] test with a trailing )\" (finding A)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "for c in 'echo hi 2>/dev/null'; do echo \$c; done")"
assert_exit "allows the same with a stray trailing ' from an unterminated-looking split (finding A)" 0 "$GOT"

# Safety check named in the finding: the SAME trailing-punctuation strip
# must not make a genuinely outside path look inside.
GOT="$(run_guard "$FAKE_WORKTREE" "x=\$(op read foo 2>$NOT_WORKTREE_NOT_SCRATCH/leak)")"
assert_exit "still blocks a genuinely outside redirect target even with trailing punctuation nearby (finding A safety check)" 2 "$GOT"

# --- 14. Re-verification round 2, finding B: same-command NAME=value
# assignments are resolved before a redirect target is classified — this
# hook's own segment splitting on ';' can put the assignment and the use
# in different segments, so it can't be read off the real environment
# (the assignment was scanned, never actually executed). --------------

CMD_SAME_CMD_VAR="P=$FAKE_WORKTREE/x.tsv; for i in 1 2; do printf '%s\n' \$i; done > \"\$P\""
GOT="$(run_guard "$FAKE_WORKTREE" "$CMD_SAME_CMD_VAR")"
assert_exit "resolves a same-command 'P=...; ... > \"\$P\"' assignment to inside the worktree (finding B)" 0 "$GOT"

CMD_SAME_CMD_VAR_EMBEDDED="L=$FAKE_SCRATCHPAD; ./x.sh > \$L/land.log 2>&1"
GOT="$(CLAUDE_SCRATCHPAD="$FAKE_SCRATCHPAD" run_guard "$FAKE_WORKTREE" "$CMD_SAME_CMD_VAR_EMBEDDED")"
assert_exit "resolves a same-command variable EMBEDDED in a larger target ('\$L/land.log') (finding B addendum)" 0 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT_ERR="$(run_guard_stderr "$FAKE_WORKTREE" 'echo hi > "$Q"')"
assert_contains "an unresolvable variable target's message says so, not the raw text (finding B)" "$GOT_ERR" "unresolvable variable"

# --- 15. Re-verification round 2, finding C: git stash list/show are
# read-only and must not be blocked; every other stash form still is. --

GOT="$(run_guard "$FAKE_WORKTREE" "git stash list")"
assert_exit "allows 'git stash list' (read-only, finding C)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git stash show")"
assert_exit "allows 'git stash show' (read-only, finding C)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git stash pop")"
assert_exit "still blocks 'git stash pop' (finding C regression check)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git stash push")"
assert_exit "still blocks 'git stash push' (finding C regression check)" 2 "$GOT"

# --- 16. Re-verification round 2, finding D: a dangerous-looking shape
# INSIDE a quoted string argument to a non-re-executing command is data,
# not a command — but the exact same shape as the literal argument of
# bash -c/sh -c/eval is still a real command and still blocks. ---------

GOT="$(run_guard "$FAKE_WORKTREE" "some-tool prompt-agent ticket-1 \"blocks '> \$VAR' redirects and rm -rf /tmp/x in prose\"")"
assert_exit "allows a dangerous-looking shape inside a quoted prompt-string argument (finding D)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'git commit -m "will run git stash next, see ticket notes"')"
assert_exit "allows 'git stash' mentioned in prose inside a commit message string (finding D)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'bash -c "git stash"')"
assert_exit "still blocks bash -c \"git stash\" — a real re-execution context, not prose (finding D)" 2 "$GOT"

# --- 17. Round 3 re-verification (2026-09-09), finding 1 (CRITICAL): the
# find leading-path check ran only on -delete, never -exec, AND {} inside
# a recursively-scanned -exec command resolved as a literal relative path.
# -------------------------------------------------------------------------

GOT="$(run_guard "$FAKE_WORKTREE" "find $NOT_WORKTREE_NOT_SCRATCH -exec rm -rf {} +")"
assert_exit "blocks 'find <outside> -exec rm -rf {} +' (finding 1)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "find ./leftover-dir -exec rm -rf {} +")"
assert_exit "allows 'find <inside-worktree> -exec rm -rf {} +' (finding 1, no false positive)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "find $NOT_WORKTREE_NOT_SCRATCH -execdir touch {} +")"
assert_exit "blocks 'find <outside> -execdir touch {} +' (finding 1, -execdir too — touch avoids the rm-specific duplicate-detection path so this isolates the find/-execdir leading-path check itself)" 2 "$GOT"

# A real false positive found (and fixed) while testing finding 1, not
# anticipated going in: `\;` is find's own ESCAPED terminator — the single
# most common real `-exec` form — but this hook's segment-splitting on a
# literal `;` used to tear it apart, leaving a stray trailing `\` token
# that then reached `rm`'s own (redundant, duplicate) top-level target
# check as if it were a real path, blocking an entirely legitimate
# inside-worktree command.
GOT="$(run_guard "$FAKE_WORKTREE" 'find ./leftover-dir -exec rm -rf {} \;')"
assert_exit 'allows find ./leftover-dir -exec rm -rf {} \; (escaped-semicolon terminator, discovered false positive)' 0 "$GOT"

# --- 18. Round 3, finding 2 (CRITICAL): substitute_same_command_vars must
# run on the text handed to a re-execution context (bash -c/sh -c/eval/
# xargs target), not only on rm/mv/find/redirect targets. -----------------

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
CMD_VAR_INTO_BASH_C='CMD="git stash"; bash -c "$CMD"'
GOT="$(run_guard "$FAKE_WORKTREE" "$CMD_VAR_INTO_BASH_C")"
assert_exit "blocks CMD=\"git stash\"; bash -c \"\$CMD\" (finding 2)" 2 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
CMD_VAR_INTO_BASH_C_BENIGN='CMD="echo hi"; bash -c "$CMD"'
GOT="$(run_guard "$FAKE_WORKTREE" "$CMD_VAR_INTO_BASH_C_BENIGN")"
assert_exit "allows CMD=\"echo hi\"; bash -c \"\$CMD\" (finding 2, no false positive)" 0 "$GOT"

# --- 19. Round 3, finding 3 (CRITICAL): command substitution still
# executes inside DOUBLE quotes — a fully-quoted word is not inert when it
# contains $( ... ). Single-quoted words genuinely are inert. -------------

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT="$(run_guard "$FAKE_WORKTREE" 'echo "result: $(git stash)"')"
# shellcheck disable=SC2016 # deliberately literal description text, not a shell expansion
assert_exit 'blocks echo "result: $(git stash)" (finding 3)' 2 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT="$(run_guard "$FAKE_WORKTREE" 'echo "result: $(echo hi)"')"
# shellcheck disable=SC2016 # deliberately literal description text, not a shell expansion
assert_exit 'allows echo "result: $(echo hi)" (finding 3, no false positive)' 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "echo 'result: \$(git stash)'")"
assert_exit "allows single-quoted 'result: \$(git stash)' (finding 3: single quotes really do suppress command substitution)" 0 "$GOT"

# --- 20. Round 3, finding 4 (LOW): the block message for a genuinely
# outside, resolvable target should name the RESOLVED path, not just the
# raw token. -----------------------------------------------------------

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
CMD_RESOLVED_MSG="P=$NOT_WORKTREE_NOT_SCRATCH; echo hi > \"\$P/x\""
GOT_ERR="$(run_guard_stderr "$FAKE_WORKTREE" "$CMD_RESOLVED_MSG")"
assert_contains "an outside, resolvable target's message names the resolved path (finding 4)" "$GOT_ERR" "resolves to: $NOT_WORKTREE_NOT_SCRATCH/x"

# --- 21. Live regression reported after round 3 landed on main (cb346f8):
# a redirect target carrying trailing whitespace missed the device
# allowlist's exact-string match. `trim_whitespace` now runs first in
# target_is_outside's pipeline (and again after same-command variable
# substitution, which can reintroduce whitespace legitimately embedded
# inside a quoted assignment VALUE). The two exact commands named in the
# report are included as regression/allow checks; NEITHER was observed to
# fail against the exact live-on-main pre-fix script in this session's own
# testing (see the ticket note for the full reproduction attempt) — a
# THIRD case, found while trying to reproduce the report, IS a genuine
# fail-first case for the same underlying mechanism (whitespace legitimately
# inside a quoted same-command assignment value surviving un-trimmed into
# a substituted target) and produces the same "resolves to: /dev/null "
# (trailing space) message signature the report described. -------------

GOT="$(run_guard "$FAKE_WORKTREE" 'some-tool agent-start x >/dev/null && sleep 8 && echo ok')"
assert_exit "allows the exact reported case 1: some-tool agent-start x >/dev/null && sleep 8 && echo ok" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'echo x >/dev/null&&echo y')"
assert_exit "allows the exact reported case 2: echo x >/dev/null&&echo y" 0 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT="$(run_guard "$FAKE_WORKTREE" 'P="/dev/null "; echo hi > "$P"')"
assert_exit 'allows a same-command variable whose QUOTED value legitimately contains trailing whitespace (the fail-first case for this fix)' 0 "$GOT"

# --- 22. A real fail-first reproduction, captured byte-for-byte rather
# than retyped by hand (see the fixture's own PROVENANCE.md entry). A long
# double-quoted argument containing single quotes, a literal `--`, and a
# literal `\$` before a later `>/dev/null` redirect. -------------------

CASE4_FIXTURE="$HERE/fixtures/guard-fs-writes/case4-long-quoted-prompt.recorded.txt"
[ -f "$CASE4_FIXTURE" ] || { echo "cannot find $CASE4_FIXTURE" >&2; exit 1; }
CMD_CASE4="$(cat "$CASE4_FIXTURE")"
GOT="$(run_guard "$FAKE_WORKTREE" "$CMD_CASE4")"
assert_exit "allows the recorded long-quoted-prompt reproduction (long double-quoted prompt with embedded single quotes/--/\\\$, then >/dev/null)" 0 "$GOT"

# --- 23. ssh/scp/rsync/mosh's own argv is opaque remote payload,
# not further local commands this hook should dispatch on. A quoted remote
# payload was already inert via finding D; the live-reported gap was the
# common UNQUOTED form, where a bare mv/git/rm word or an unresolved $HOME
# reference inside the remote command used to be misread as a real LOCAL
# operation. A trailing LOCAL redirect on the same line is still checked.
# ---------------------------------------------------------------------------

GOT="$(run_guard "$FAKE_WORKTREE" "ssh host git stash drop")"
assert_exit "allows unquoted 'ssh host git stash drop' (remote git stash, not local)" 0 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT="$(run_guard "$FAKE_WORKTREE" 'ssh host mv x $HOME/.local/bin/rtk')"
assert_exit "allows unquoted 'ssh host mv x \$HOME/...' (remote mv target, and remote's own \$HOME, not this machine's)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "ssh host jq . 2>/dev/null")"
assert_exit "allows unquoted 'ssh host jq . 2>/dev/null' (device-allowlisted, was misread as remote content)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "scp host:/etc/passwd $FAKE_WORKTREE/local-copy")"
assert_exit "allows 'scp host:/etc/passwd <inside-worktree>' (scp's own argv is opaque)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "rsync -a --delete src/ host:/some/remote/dest/")"
assert_exit "allows 'rsync -a --delete src/ host:...' (rsync's own argv is opaque)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "mosh host -- git stash drop")"
assert_exit "allows 'mosh host -- git stash drop' (mosh's own argv is opaque)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "mosh host -- true > /some/outside/local-file")"
assert_exit "blocks 'mosh host -- true > /outside' (the trailing LOCAL redirect is still checked)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "ssh host mv x y > $NOT_WORKTREE_NOT_SCRATCH/leak")"
assert_exit "still blocks a trailing LOCAL redirect after an unquoted ssh remote command (unquoted > is real local shell syntax regardless of what precedes it)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git stash drop")"
assert_exit "still blocks plain (non-ssh) 'git stash drop' against the main worktree (regression check)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "rm -rf $NOT_WORKTREE_NOT_SCRATCH")"
assert_exit "still blocks plain (non-ssh) 'rm -rf <outside>' (regression check)" 2 "$GOT"

# --- 24. prose arguments to --content/--title/--message-shaped
# flags are data, not shell — already true via the quoted-word rule
# (finding D), added here as explicit regression coverage per the ticket's
# own catalogue (an arrow in a memorygraph --content string was misread as
# a redirect). ---------------------------------------------------------------

GOT="$(run_guard "$FAKE_WORKTREE" "memorygraph store --content 'sed a -> /home/mike'")"
assert_exit "allows memorygraph store --content 'sed a -> /home/mike' (prose, not a redirect)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'git commit -m "mv the outside target -> /etc/passwd in prose"')"
assert_exit "allows git commit -m \"...mv ... -> /etc/passwd...\" (prose, not a redirect)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'gh pr create --body "rm -rf /etc mentioned in prose"')"
assert_exit "allows gh pr create --body \"rm -rf /etc mentioned in prose\" (prose, not a command)" 0 "$GOT"

# --- 25. Ticket verify block, exact command forms -------------------

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT="$(run_guard "$FAKE_WORKTREE" "ssh host 'git stash drop'")"
assert_exit "ticket verify: ssh host 'git stash drop' passes" 0 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT="$(run_guard "$FAKE_WORKTREE" 'ssh host '"'"'mv a $HOME/b'"'"'')"
assert_exit "ticket verify: ssh host 'mv a \$HOME/b' passes" 0 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT="$(run_guard "$FAKE_WORKTREE" "ssh host 'x > /dev/null 2>&1'")"
assert_exit "ticket verify: ssh host 'x > /dev/null 2>&1' passes" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "ssh host 'jq . > /tmp/x'")"
assert_exit "ticket verify: ssh host 'jq . > /tmp/x' passes" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "scp f host:.ssh/")"
assert_exit "ticket verify: scp f host:.ssh/ passes" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "memorygraph store --content 'a -> /home/x'")"
assert_exit "ticket verify: memorygraph store --content 'a -> /home/x' passes" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git stash")"
assert_exit "ticket verify: local 'git stash' (against MAIN worktree) still blocked" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "mv a $NOT_WORKTREE_NOT_SCRATCH/b")"
assert_exit "ticket verify: local 'mv' outside the tree still blocked" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "echo hi > $NOT_WORKTREE_NOT_SCRATCH/outside")"
assert_exit "ticket verify: local '> /outside' still blocked" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "ssh host 'x' > $NOT_WORKTREE_NOT_SCRATCH/outside")"
assert_exit "ticket verify: local redirect AFTER the ssh (ssh host 'x' > /outside/local) still blocked" 2 "$GOT"

# --- 26. Script-review fix: the ssh/scp/rsync/mosh word only
# opens opacity at THIS segment's own command-word position — the SAME
# bare word appearing elsewhere in the segment (a find -name value, an
# xargs flag value, or just an ordinary word before a real local command)
# must not disable local-rule scanning for the rest of the segment. Fail-
# first reproduction: `echo ssh rm -rf <outside>` was ALLOWED (0) before
# this fix, because the word "ssh" at ANY position set opacity and
# suppressed the real `rm` dispatch that followed it in the same segment.
# -----------------------------------------------------------------------

GOT="$(run_guard "$FAKE_WORKTREE" "echo ssh rm -rf $NOT_WORKTREE_NOT_SCRATCH")"
assert_exit "still blocks 'echo ssh rm -rf <outside>' — 'ssh' is not this segment's command word, so it must not open opacity for the real 'rm' that follows (fail-first reproduction)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "find $NOT_WORKTREE_NOT_SCRATCH -name ssh -delete")"
assert_exit "still blocks 'find <outside> -name ssh -delete' — 'ssh' as a -name VALUE must not disable find's own leading-path check" 2 "$GOT"

# Transparent prefixes: `command ssh ...` and `env X=1 ssh ...` run ssh as
# the segment's real command, so its argv is opaque exactly as with a bare
# `ssh` (second-round script review).
GOT="$(run_guard "$FAKE_WORKTREE" "command ssh host rm -rf $NOT_WORKTREE_NOT_SCRATCH")"
assert_exit "allows 'command ssh host rm -rf <outside>' — 'command' is a transparent prefix, ssh is still the command word" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "env X=1 ssh host mv a \$HOME/.local/bin/b")"
assert_exit "allows 'env X=1 ssh host mv a \$HOME/...' — env plus its assignment are skipped, ssh is the command word" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "env X=1 rm -rf $NOT_WORKTREE_NOT_SCRATCH")"
assert_exit "still blocks 'env X=1 rm -rf <outside>' — skipping env must not skip the real command" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "echo x | xargs -I ssh rm -rf $NOT_WORKTREE_NOT_SCRATCH")"
assert_exit "still blocks 'xargs -I ssh rm -rf <outside>' — 'ssh' as an xargs flag VALUE must not disable the unconditional xargs rm/mv block" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git stash push -u -m ssh")"
assert_exit "still blocks 'git stash push -u -m ssh' — 'ssh' as a -m VALUE after the real git command word must not retroactively un-block it" 2 "$GOT"

# --- 27. Script-review fix: _ss_opaque is now saved/restored via
# a real stack (_ss_opaque_push/_ss_opaque_pop) around every nested
# scan_command_text call, so the nested segment's own opacity state (fresh,
# and possibly itself ssh-derived) cannot overwrite the OUTER segment's
# opacity once the nested call returns. This is NOT independently
# selftest-observable end-to-end, though: scan_segment's _ss_words/_ss_n
# are plain globals too (unfixed here — see
# docs/known-issues/guard-fs-writes-sh-trailing-words-after-a-re-execution-context-in-the-same-segment-bypass-local-rules.md,
# filed while verifying this fix), so ANY word after a nested
# scan_command_text call in the same segment is already unreachable by the
# outer dispatch loop for a reason that has nothing to do with _ss_opaque —
# a same-segment "does opacity leak" probe fails for that reason before it
# could ever isolate this fix. The push/pop code itself is reviewed
# in-place instead (guard-fs-writes.sh, "ssh/scp/rsync/mosh opacity stack"
# comment). -------------------------------------------------------------

echo
echo "$N assertion(s), $((N - FAIL)) passed" >&2
if [ "$FAIL" -ne 0 ]; then
  echo "guard-fs-writes-selftest.sh: FAILED" >&2
  exit 1
fi
echo "guard-fs-writes-selftest.sh: all assertions passed" >&2
exit 0
