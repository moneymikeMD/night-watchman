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
#   - blocks a shim whose NAME matches nothing but which resolves to git or
#     rm, and still allows that shim's in-worktree operations (NWM-123)
#
# Every NWM-123 assertion pins the exit code AND the stderr, so a guard that
# refused everything would fail this file rather than pass it.
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
FAILED_NUMS=""
N=0
pass() { N=$((N + 1)); echo "PASS $N: $1"; }
fail() {
  N=$((N + 1)); echo "FAIL $N: $1" >&2
  FAIL=$((FAIL + 1))
  FAILED_NUMS="${FAILED_NUMS:+$FAILED_NUMS,}$N"
}

assert_exit() {
  desc="$1"; want="$2"; got="$3"
  if [ "$want" = "$got" ]; then
    pass "$desc (oracle: exit code, want $want got $got)"
  else
    fail "$desc (oracle: exit code, want $want got $got)"
  fi
}

# Neither fixture is the real repo worktree nor under the real
# $CLAUDE_SCRATCHPAD: both are minted fresh and torn down on exit, so a run
# of this selftest never touches shared state.

SCRATCH="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
# Canonicalize immediately: macOS mktemp -d returns a path under /var/folders,
# itself a symlink, and the guard always canonicalizes (see its PWD_PHYS).
SCRATCH="$(cd "$SCRATCH" && pwd -P)" || { echo "canonicalizing SCRATCH failed" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT

FAKE_WORKTREE="$SCRATCH/fake-worktree"
FAKE_SCRATCHPAD="$SCRATCH/fake-scratchpad"
NOHOOKS_DIR="$SCRATCH/nohooks"
NOT_WORKTREE_NOT_SCRATCH="$SCRATCH/not-worktree-not-scratch"
mkdir -p "$FAKE_WORKTREE" "$FAKE_SCRATCHPAD" "$NOHOOKS_DIR" "$NOT_WORKTREE_NOT_SCRATCH"

# A scratch git repo is not isolated by default (core.hooksPath, commit.gpgsign,
# gpg.format, user.signingkey all fall through to global config) — pin each one.
# The single commit below is there so `git worktree add` has something to check out.
git -C "$FAKE_WORKTREE" init -q
git -C "$FAKE_WORKTREE" config core.hooksPath "$NOHOOKS_DIR"
git -C "$FAKE_WORKTREE" config commit.gpgsign false
git -C "$FAKE_WORKTREE" config gpg.format ""
git -C "$FAKE_WORKTREE" config user.email "guard-selftest@example.invalid"
git -C "$FAKE_WORKTREE" config user.name "guard-fs-writes-selftest"
: > "$FAKE_WORKTREE/seed.txt"
git -C "$FAKE_WORKTREE" add seed.txt
git -C "$FAKE_WORKTREE" commit -q -m "seed"

# A linked worktree off the same fake repo: its --git-dir lives under the main
# repo's .git/worktrees/<name>, distinct from --git-common-dir.
FAKE_LINKED_WORKTREE="$SCRATCH/fake-linked-worktree"
git -C "$FAKE_WORKTREE" worktree add -q -b guard-selftest-branch "$FAKE_LINKED_WORKTREE" >/dev/null

# A second, UNRELATED repo (no worktree relationship to FAKE_WORKTREE at
# all): WO-023 fix 2 makes every worktree of the SAME repo an allowed root,
# so a test that wants to discriminate "payload .cwd used, not process cwd"
# or "the worktree set is per-repo" needs a tree this genuinely isn't one of.
OTHER_REPO="$SCRATCH/other-repo"
mkdir -p "$OTHER_REPO"
git -C "$OTHER_REPO" init -q
git -C "$OTHER_REPO" config core.hooksPath "$NOHOOKS_DIR"
git -C "$OTHER_REPO" config commit.gpgsign false
git -C "$OTHER_REPO" config gpg.format ""
git -C "$OTHER_REPO" config user.email "guard-selftest@example.invalid"
git -C "$OTHER_REPO" config user.name "guard-fs-writes-selftest"
: > "$OTHER_REPO/seed.txt"
git -C "$OTHER_REPO" add seed.txt
git -C "$OTHER_REPO" commit -q -m "seed"

run_guard() {
  # $1 = cwd to invoke the guard from, $2 = command text. Prints the exit
  # code; the guard's own stderr is discarded.
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

# shellcheck disable=SC2016 # deliberately literal: this is the raw, pre-expansion
# command text the guard receives — $TMPDIR must reach it unexpanded.
CMD_RM_TMPDIR='rm -rf $TMPDIR/tmp.*'
GOT="$(TMPDIR="$SCRATCH/not-worktree-not-scratch-tmp" run_guard "$FAKE_WORKTREE" "$CMD_RM_TMPDIR")"
assert_exit "blocks rm -rf \$TMPDIR/tmp.* (honest-mistake incident command, TMPDIR outside worktree/scratchpad)" 2 "$GOT"

CMD_STASH='git stash push -u'
GOT="$(run_guard "$FAKE_WORKTREE" "$CMD_STASH")"
assert_exit "blocks a command containing 'git stash'" 2 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, same reason as above
CMD_RM_SCRATCH='rm -rf $CLAUDE_SCRATCHPAD/leftover-file'
GOT="$(CLAUDE_SCRATCHPAD="$FAKE_SCRATCHPAD" run_guard "$FAKE_WORKTREE" "$CMD_RM_SCRATCH")"
assert_exit "allows rm -rf of a path under CLAUDE_SCRATCHPAD" 0 "$GOT"

CMD_RM_WORKTREE='rm -rf ./leftover-dir'
GOT="$(unset CLAUDE_SCRATCHPAD; run_guard "$FAKE_WORKTREE" "$CMD_RM_WORKTREE")"
assert_exit "allows rm -rf of a relative path resolving inside the worktree" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "ls -la")"
assert_exit "allows plain 'ls -la'" 0 "$GOT"

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

GOT="$(run_guard "$FAKE_WORKTREE" "git reset --hard")"
assert_exit "blocks 'git reset --hard' run in the MAIN worktree" 2 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git reset --hard")"
assert_exit "allows 'git reset --hard' run in a LINKED worktree (finding 5)" 0 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git stash push -u")"
assert_exit "allows 'git stash' run in a LINKED worktree (finding 5)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "find $SCRATCH/not-worktree-not-scratch -delete")"
assert_exit "blocks 'find <outside> -delete' (finding 2)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "find ./leftover-dir -type f -delete")"
assert_exit "allows 'find <inside-worktree> -delete' (finding 2, no false positive)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "echo $SCRATCH/not-worktree-not-scratch | xargs rm -rf")"
assert_exit "blocks 'echo <outside> | xargs rm -rf' (finding 2: xargs' real targets are stdin-sourced and unverifiable, so xargs rm/mv is blocked unconditionally)" 2 "$GOT"

# shellcheck disable=SC2016 # literal, pre-expansion command text under test
CMD_TILDE_ESCAPE='rm -rf ~/../../../private/tmp/some-outside-target'
GOT="$(run_guard_payload /private/tmp "$(jq -cn --arg cmd "$CMD_TILDE_ESCAPE" '{tool_input:{command:$cmd}}')")"
assert_exit "blocks a ~/../.. escape run from a bare system root (finding 3)" 2 "$GOT"

HEREDOC_CMD="$(printf "cat <<'EOF'\nsome doc text mentions 1 > /etc/passwd as prose, not a real redirect\nEOF\n")"
GOT="$(run_guard "$FAKE_WORKTREE" "$HEREDOC_CMD")"
assert_exit "allows a heredoc whose body merely mentions a redirect-looking string (finding 4)" 0 "$GOT"

# Both targets are ABSOLUTE and OTHER_REPO shares no worktree relationship
# with FAKE_WORKTREE: a sibling worktree of the SAME repo would not
# discriminate here, since WO-023 fix 2 now allows those on its own,
# regardless of which cwd (payload or process) resolved the worktree set.

PAYLOAD_CWD_INSIDE="$(jq -cn --arg cwd "$FAKE_WORKTREE" --arg tgt "$FAKE_WORKTREE/leftover-dir" '{cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:("rm -rf " + $tgt)}}')"
GOT="$(run_guard_payload "$OTHER_REPO" "$PAYLOAD_CWD_INSIDE")"
assert_exit "uses payload .cwd (FAKE_WORKTREE) to allow a target under it, even though the guard's own process cwd is the UNRELATED OTHER_REPO (finding 6)" 0 "$GOT"

PAYLOAD_CWD_OUTSIDE="$(jq -cn --arg cwd "$OTHER_REPO" --arg tgt "$FAKE_WORKTREE/leftover-dir" '{cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:("rm -rf " + $tgt)}}')"
GOT="$(run_guard_payload "$FAKE_WORKTREE" "$PAYLOAD_CWD_OUTSIDE")"
assert_exit "uses payload .cwd (OTHER_REPO) to block a target under the UNRELATED FAKE_WORKTREE, even though the guard's own process cwd IS FAKE_WORKTREE (finding 6)" 2 "$GOT"

PAYLOAD_CWD_SIBLING="$(jq -cn --arg cwd "$FAKE_LINKED_WORKTREE" --arg tgt "$FAKE_WORKTREE/leftover-dir" '{cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:("rm -rf " + $tgt)}}')"
GOT="$(run_guard_payload "$FAKE_WORKTREE" "$PAYLOAD_CWD_SIBLING")"
assert_exit "WO-023 fix 2: payload .cwd in the LINKED worktree allows a target in the SAME repo's main worktree, even via the payload-.cwd path (was a false positive)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "echo hi 2>/dev/null")"
assert_exit "allows 'echo hi 2>/dev/null' (device allowlist)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "some-cmd >/dev/null 2>&1")"
assert_exit "allows '>/dev/null 2>&1' (device allowlist)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "echo hi > /dev/disk0")"
assert_exit "still blocks '> /dev/disk0' (device allowlist must be explicit, not a /dev/* glob)" 2 "$GOT"

run_guard_stderr() {
  # $1 = cwd, $2 = command text. Prints ONLY the guard's stderr: `2>&1` first
  # duplicates fd2 onto the capture target, THEN `>/dev/null` replaces fd1 —
  # deliberate order, not the SC2069 mistake.
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

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT="$(run_guard "$FAKE_WORKTREE" 'x=$(op read foo 2>/dev/null)')"
assert_exit "allows 'x=\$(op read foo 2>/dev/null)' — trailing ')' stripped from the extracted target (finding A)" 0 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT="$(run_guard "$FAKE_WORKTREE" '[ "$(op read foo 2>/dev/null)" = admin ] && echo Y')"
assert_exit "allows the same inside a [ ... ] test with a trailing )\" (finding A)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "for c in 'echo hi 2>/dev/null'; do echo \$c; done")"
assert_exit "allows the same with a stray trailing ' from an unterminated-looking split (finding A)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "x=\$(op read foo 2>$NOT_WORKTREE_NOT_SCRATCH/leak)")"
assert_exit "still blocks a genuinely outside redirect target even with trailing punctuation nearby (finding A safety check)" 2 "$GOT"

CMD_SAME_CMD_VAR="P=$FAKE_WORKTREE/x.tsv; for i in 1 2; do printf '%s\n' \$i; done > \"\$P\""
GOT="$(run_guard "$FAKE_WORKTREE" "$CMD_SAME_CMD_VAR")"
assert_exit "resolves a same-command 'P=...; ... > \"\$P\"' assignment to inside the worktree (finding B)" 0 "$GOT"

CMD_SAME_CMD_VAR_EMBEDDED="L=$FAKE_SCRATCHPAD; ./x.sh > \$L/land.log 2>&1"
GOT="$(CLAUDE_SCRATCHPAD="$FAKE_SCRATCHPAD" run_guard "$FAKE_WORKTREE" "$CMD_SAME_CMD_VAR_EMBEDDED")"
assert_exit "resolves a same-command variable EMBEDDED in a larger target ('\$L/land.log') (finding B addendum)" 0 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT_ERR="$(run_guard_stderr "$FAKE_WORKTREE" 'echo hi > "$Q"')"
assert_contains "an unresolvable variable target's message says so, not the raw text (finding B)" "$GOT_ERR" "unresolvable variable"

GOT="$(run_guard "$FAKE_WORKTREE" "git stash list")"
assert_exit "allows 'git stash list' (read-only, finding C)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git stash show")"
assert_exit "allows 'git stash show' (read-only, finding C)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git stash pop")"
assert_exit "still blocks 'git stash pop' (finding C regression check)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git stash push")"
assert_exit "still blocks 'git stash push' (finding C regression check)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "some-tool prompt-agent ticket-1 \"blocks '> \$VAR' redirects and rm -rf /tmp/x in prose\"")"
assert_exit "allows a dangerous-looking shape inside a quoted prompt-string argument (finding D)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'git commit -m "will run git stash next, see ticket notes"')"
assert_exit "allows 'git stash' mentioned in prose inside a commit message string (finding D)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'bash -c "git stash"')"
assert_exit "still blocks bash -c \"git stash\" — a real re-execution context, not prose (finding D)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'git commit -m "run git restore somefile after this"')"
assert_exit "NWM-180: allows 'git restore' mentioned in prose inside a commit message string" 0 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" 'git commit -m "will run git switch -f other later"')"
assert_exit "NWM-180: allows 'git switch -f' mentioned in prose inside a commit message string" 0 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" 'git commit -m "will run git checkout -f somefile later"')"
assert_exit "NWM-180: allows 'git checkout -f' mentioned in prose inside a commit message string" 0 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" 'git commit -m "will run git checkout . later"')"
assert_exit "NWM-180: allows 'git checkout .' mentioned in prose inside a commit message string" 0 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" 'bash -c "git restore somefile"')"
assert_exit "NWM-180: still blocks bash -c \"git restore somefile\" — a real re-execution context, not prose" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "find $NOT_WORKTREE_NOT_SCRATCH -exec rm -rf {} +")"
assert_exit "blocks 'find <outside> -exec rm -rf {} +' (finding 1)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "find ./leftover-dir -exec rm -rf {} +")"
assert_exit "allows 'find <inside-worktree> -exec rm -rf {} +' (finding 1, no false positive)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "find $NOT_WORKTREE_NOT_SCRATCH -execdir touch {} +")"
assert_exit "blocks 'find <outside> -execdir touch {} +' (finding 1, -execdir too — touch avoids the rm-specific duplicate-detection path so this isolates the find/-execdir leading-path check itself)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'find ./leftover-dir -exec rm -rf {} \;')"
assert_exit 'allows find ./leftover-dir -exec rm -rf {} \; (escaped-semicolon terminator, discovered false positive)' 0 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
CMD_VAR_INTO_BASH_C='CMD="git stash"; bash -c "$CMD"'
GOT="$(run_guard "$FAKE_WORKTREE" "$CMD_VAR_INTO_BASH_C")"
assert_exit "blocks CMD=\"git stash\"; bash -c \"\$CMD\" (finding 2)" 2 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
CMD_VAR_INTO_BASH_C_BENIGN='CMD="echo hi"; bash -c "$CMD"'
GOT="$(run_guard "$FAKE_WORKTREE" "$CMD_VAR_INTO_BASH_C_BENIGN")"
assert_exit "allows CMD=\"echo hi\"; bash -c \"\$CMD\" (finding 2, no false positive)" 0 "$GOT"

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

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
CMD_RESOLVED_MSG="P=$NOT_WORKTREE_NOT_SCRATCH; echo hi > \"\$P/x\""
GOT_ERR="$(run_guard_stderr "$FAKE_WORKTREE" "$CMD_RESOLVED_MSG")"
assert_contains "an outside, resolvable target's message names the resolved path (finding 4)" "$GOT_ERR" "resolves to: $NOT_WORKTREE_NOT_SCRATCH/x"

GOT="$(run_guard "$FAKE_WORKTREE" 'some-tool agent-start x >/dev/null && sleep 8 && echo ok')"
assert_exit "allows the exact reported case 1: some-tool agent-start x >/dev/null && sleep 8 && echo ok" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'echo x >/dev/null&&echo y')"
assert_exit "allows the exact reported case 2: echo x >/dev/null&&echo y" 0 "$GOT"

# shellcheck disable=SC2016 # deliberately literal, pre-expansion command text under test
GOT="$(run_guard "$FAKE_WORKTREE" 'P="/dev/null "; echo hi > "$P"')"
assert_exit 'allows a same-command variable whose QUOTED value legitimately contains trailing whitespace (the fail-first case for this fix)' 0 "$GOT"

# Fail-first reproduction captured byte-for-byte; see the fixture's own
# PROVENANCE.md entry.

CASE4_FIXTURE="$HERE/fixtures/guard-fs-writes/case4-long-quoted-prompt.recorded.txt"
[ -f "$CASE4_FIXTURE" ] || { echo "cannot find $CASE4_FIXTURE" >&2; exit 1; }
CMD_CASE4="$(cat "$CASE4_FIXTURE")"
GOT="$(run_guard "$FAKE_WORKTREE" "$CMD_CASE4")"
assert_exit "allows the recorded long-quoted-prompt reproduction (long double-quoted prompt with embedded single quotes/--/\\\$, then >/dev/null)" 0 "$GOT"

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

GOT="$(run_guard "$FAKE_WORKTREE" "memorygraph store --content 'sed a -> /home/mike'")"
assert_exit "allows memorygraph store --content 'sed a -> /home/mike' (prose, not a redirect)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'git commit -m "mv the outside target -> /etc/passwd in prose"')"
assert_exit "allows git commit -m \"...mv ... -> /etc/passwd...\" (prose, not a redirect)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'gh pr create --body "rm -rf /etc mentioned in prose"')"
assert_exit "allows gh pr create --body \"rm -rf /etc mentioned in prose\" (prose, not a command)" 0 "$GOT"

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

# NWM-180: git restore was not in the stash/reset/clean/checkout-- set, so
# the same discard went through under a different verb. Every restore form
# mutates the index or tree; there is no read-only one.

GOT="$(run_guard "$FAKE_WORKTREE" "git restore somefile")"
assert_exit "NWM-180: blocks 'git restore somefile' in the MAIN worktree" 2 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git restore somefile")"
assert_exit "NWM-180: allows 'git restore somefile' in a LINKED worktree" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git restore --source=HEAD -- somefile")"
assert_exit "NWM-180: blocks 'git restore --source=HEAD -- somefile' in the MAIN worktree" 2 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git restore --source=HEAD -- somefile")"
assert_exit "NWM-180: allows 'git restore --source=HEAD -- somefile' in a LINKED worktree" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git restore --staged somefile")"
assert_exit "NWM-180: blocks 'git restore --staged somefile' in the MAIN worktree" 2 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git restore --staged somefile")"
assert_exit "NWM-180: allows 'git restore --staged somefile' in a LINKED worktree" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git restore --worktree --staged .")"
assert_exit "NWM-180: blocks 'git restore --worktree --staged .' in the MAIN worktree" 2 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git restore --worktree --staged .")"
assert_exit "NWM-180: allows 'git restore --worktree --staged .' in a LINKED worktree" 0 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git -C $FAKE_WORKTREE restore somefile")"
assert_exit "NWM-180: blocks 'git -C <main-worktree> restore somefile' even when run from a linked worktree" 2 "$GOT"

# `git switch` with a discard/force flag mutates the tree the same way a
# checkout -f does; a plain 'git switch <branch>' or '-c' stays allowed —
# it is how agents change or create branches, and git itself refuses when
# the tree is dirty.

GOT="$(run_guard "$FAKE_WORKTREE" "git switch --discard-changes other")"
assert_exit "NWM-180: blocks 'git switch --discard-changes other' in the MAIN worktree" 2 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git switch --discard-changes other")"
assert_exit "NWM-180: allows 'git switch --discard-changes other' in a LINKED worktree" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git switch -f other")"
assert_exit "NWM-180: blocks 'git switch -f other' in the MAIN worktree" 2 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git switch -f other")"
assert_exit "NWM-180: allows 'git switch -f other' in a LINKED worktree" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git switch -C other")"
assert_exit "NWM-180: blocks 'git switch -C other' in the MAIN worktree" 2 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git switch -C other")"
assert_exit "NWM-180: allows 'git switch -C other' in a LINKED worktree" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git switch other")"
assert_exit "NWM-180: still allows plain 'git switch other' (an ordinary branch switch, git itself refuses if dirty)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git switch -c new")"
assert_exit "NWM-180: still allows 'git switch -c new' (creates a branch, not a force/discard)" 0 "$GOT"

# `git checkout -f`/`--force` and a bare `git checkout .` (never a valid ref
# name — git check-ref-format rejects it) discard the tree without needing
# a `--`; a bare `git checkout <word>` stays allowed, indistinguishable from
# an ordinary branch switch.

GOT="$(run_guard "$FAKE_WORKTREE" "git checkout -f somefile")"
assert_exit "NWM-180: blocks 'git checkout -f somefile' in the MAIN worktree" 2 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git checkout -f somefile")"
assert_exit "NWM-180: allows 'git checkout -f somefile' in a LINKED worktree" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git checkout .")"
assert_exit "NWM-180: blocks 'git checkout .' in the MAIN worktree" 2 "$GOT"

GOT="$(run_guard "$FAKE_LINKED_WORKTREE" "git checkout .")"
assert_exit "NWM-180: allows 'git checkout .' in a LINKED worktree" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git checkout somefile")"
assert_exit "NWM-180: still allows bare 'git checkout somefile' (indistinguishable from a branch switch)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git checkout -b new")"
assert_exit "NWM-180: still allows 'git checkout -b new' (creates a branch, not a force/discard)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "git checkout other-branch")"
assert_exit "NWM-180: still allows 'git checkout other-branch' (an ordinary branch switch)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "mv a $NOT_WORKTREE_NOT_SCRATCH/b")"
assert_exit "ticket verify: local 'mv' outside the tree still blocked" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "echo hi > $NOT_WORKTREE_NOT_SCRATCH/outside")"
assert_exit "ticket verify: local '> /outside' still blocked" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "ssh host 'x' > $NOT_WORKTREE_NOT_SCRATCH/outside")"
assert_exit "ticket verify: local redirect AFTER the ssh (ssh host 'x' > /outside/local) still blocked" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "echo ssh rm -rf $NOT_WORKTREE_NOT_SCRATCH")"
assert_exit "still blocks 'echo ssh rm -rf <outside>' — 'ssh' is not this segment's command word, so it must not open opacity for the real 'rm' that follows (fail-first reproduction)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "find $NOT_WORKTREE_NOT_SCRATCH -name ssh -delete")"
assert_exit "still blocks 'find <outside> -name ssh -delete' — 'ssh' as a -name VALUE must not disable find's own leading-path check" 2 "$GOT"

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

# _ss_opaque's push/pop is deliberately NOT asserted here: any word after a
# nested scan_command_text call in the same segment is already unreachable by
# the outer dispatch loop for an unrelated reason, so no probe could isolate it.

OUT="$NOT_WORKTREE_NOT_SCRATCH"
GOT="$(run_guard "$FAKE_WORKTREE" "bash -c \"true\" rm -rf $OUT")"
assert_exit "blocks 'bash -c \"true\" rm -rf <outside>' — words after the -c string must still be scanned" 2 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" "sh -c \"x\" mv a $OUT/b")"
assert_exit "blocks 'sh -c \"x\" mv a <outside>/b'" 2 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" "eval true rm -rf $OUT")"
assert_exit "blocks 'eval true rm -rf <outside>'" 2 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" "find . -exec true {} \\; -exec rm -rf $OUT \\;")"
assert_exit "blocks a second find -exec rm -rf <outside> after a first harmless -exec" 2 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" "echo x | xargs bash -c \"true\" rm -rf $OUT")"
assert_exit "blocks 'xargs bash -c \"true\" rm -rf <outside>'" 2 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" "echo \"\$(echo \"\$(true)\")\" rm -rf $OUT")"
assert_exit "blocks nested \$( \$( ) ) inside a double-quoted word followed by rm -rf <outside>" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "find . -exec bash -c \"true\" rm -rf $OUT \\;")"
assert_exit "blocks 'find -exec bash -c \"true\" rm -rf <outside>' — the -exec command's own trailing words" 2 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" "find . -exec sh -c \"x\" mv a $OUT/b \\;")"
assert_exit "blocks 'find -exec sh -c \"x\" mv a <outside>/b'" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "bash -c \"true\" echo hello")"
assert_exit "allows 'bash -c \"true\" echo hello' (harmless trailing command)" 0 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" "sh -c \"x\" ls -la")"
assert_exit "allows 'sh -c \"x\" ls -la'" 0 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" "eval true echo hi")"
assert_exit "allows 'eval true echo hi'" 0 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" "find . -exec true {} \\; -exec echo {} \\;")"
assert_exit "allows two harmless find -exec clauses" 0 "$GOT"
GOT="$(run_guard "$FAKE_WORKTREE" "bash -c \"true\" rm -rf ./inside-dir")"
assert_exit "allows 'bash -c \"true\" rm -rf <inside worktree>' (fix must not widen the policy)" 0 "$GOT"

# Stderr oracle: run_guard discards stderr, so spurious bash runtime errors
# (unbound variable, integer expression expected) were invisible above.

run_guard_stderr() {
  _cwd="$1"
  _cmd="$2"
  _payload="$(jq -cn --arg cmd "$_cmd" '{session_id:"test",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd}}')"
  # shellcheck disable=SC2069 # deliberate: capture stderr only, drop stdout
  (cd "$_cwd" && printf '%s' "$_payload" | "$GUARD" 2>&1 >/dev/null)
}

RUNTIME_ERR_RE='unbound variable|integer expression expected|syntax error|command not found|line [0-9]+:'

ERR="$(run_guard_stderr "$FAKE_WORKTREE" "echo hello")"
if [ -z "$ERR" ]; then
  pass "allowed 'echo hello' writes nothing to stderr (oracle: stderr empty)"
else
  fail "allowed 'echo hello' wrote to stderr: $ERR"
fi

ERR="$(run_guard_stderr "$FAKE_WORKTREE" "bash -c \"true\" echo hello")"
if [ -z "$ERR" ]; then
  pass "allowed nested 'bash -c \"true\" echo hello' writes nothing to stderr (oracle: stderr empty)"
else
  fail "allowed nested command wrote to stderr: $ERR"
fi

ERR="$(run_guard_stderr "$FAKE_WORKTREE" "bash -c \"true\" rm -rf $OUT")"
if [ -n "$ERR" ] && ! printf '%s' "$ERR" | grep -Eq "$RUNTIME_ERR_RE"; then
  pass "blocked nested command stderr is the block message only, no bash runtime errors (oracle: stderr regex)"
else
  fail "blocked nested command stderr empty or carries runtime errors: $ERR"
fi

# NWM-113: redirect-shaped text inside a quoted argument is data. The first
# three are the commands wrongly blocked on 2026-09-14/12 (secrets none).
GOT="$(run_guard "$FAKE_WORKTREE" 'memorygraph store --type general --title "note" --content "the hook blocked >/dev/null inside quoted prose" --tags "night-watchman"')"
assert_exit "allows memorygraph store whose quoted --content mentions a redirect (NWM-113 fixture 1)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'known-issue.sh add --title "arrow" --body "project = NWM -> PROJ, and a->b, are prose not redirects"')"
assert_exit "allows known-issue.sh add whose quoted --body contains an arrow (NWM-113 fixture 2)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'herdr agent prompt w1 "fill in <field> and providers/<kind>/<impl>/provider.sh then report"')"
assert_exit "allows herdr agent prompt whose quoted brief contains angle-bracket placeholders (NWM-113 fixture 3)" 0 "$GOT"

# Counterpart: the same redirect text UNQUOTED still blocks.
GOT="$(run_guard "$FAKE_WORKTREE" 'echo hello > /etc/nwm113-unquoted')"
assert_exit "blocks the same redirect when unquoted (NWM-113 counterpart)" 2 "$GOT"

# WO-023 fix 1 resolves the MEDIUM known issue this used to be pinned
# KNOWN-FAILING for: quoted operators no longer split before tokenising.
# shellcheck disable=SC2016 # literal: raw pre-expansion command text
GOT="$(run_guard "$FAKE_WORKTREE" 'grep -E "foo|>$HOME/x" file.txt')"
assert_exit "allows quoted alternation next to a quoted > (WO-023 fix 1, known issue resolved)" 0 "$GOT"

# WO-023 fix 1: scan_command_text's segment splitter is now quote-aware, so a
# quoted ; && || | earlier in the same quoted word than a quoted > no longer
# tears the word apart and reads the > as a real redirect (the ticket's own
# reproduction shapes).
GOT="$(run_guard "$FAKE_WORKTREE" 'echo "alpha beta > /etc/passwd gamma"')"
assert_exit "allows a quoted > with no operator before it (WO-023 fix 1 baseline)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'echo "alpha; beta > /etc/passwd gamma"')"
assert_exit "allows a quoted ';' before a quoted '>' (WO-023 fix 1, was a false positive)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'echo "alpha | beta > /etc/passwd gamma"')"
assert_exit "allows a quoted '|' before a quoted '>' (WO-023 fix 1, was a false positive)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'echo "alpha && beta > /etc/passwd gamma"')"
assert_exit "allows a quoted '&&' before a quoted '>' (WO-023 fix 1, was a false positive)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'echo "alpha || beta > /etc/passwd gamma"')"
assert_exit "allows a quoted '||' before a quoted '>' (WO-023 fix 1, was a false positive)" 0 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" 'echo "alpha; beta gamma"')"
assert_exit "allows a quoted ';' with no redirect at all (WO-023 fix 1 sanity, no split harm)" 0 "$GOT"

# True-positive counterparts: the same operators UNQUOTED are real shell
# syntax, and a genuinely outside redirect after them must still block.
GOT="$(run_guard "$FAKE_WORKTREE" "echo hi; echo bye > $NOT_WORKTREE_NOT_SCRATCH/x")"
assert_exit "still blocks an UNQUOTED ';' before a real outside redirect (WO-023 fix 1 regression)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "echo hi | echo bye > $NOT_WORKTREE_NOT_SCRATCH/x")"
assert_exit "still blocks an UNQUOTED '|' before a real outside redirect (WO-023 fix 1 regression)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "echo hi && echo bye > $NOT_WORKTREE_NOT_SCRATCH/x")"
assert_exit "still blocks an UNQUOTED '&&' before a real outside redirect (WO-023 fix 1 regression)" 2 "$GOT"

GOT="$(run_guard "$FAKE_WORKTREE" "echo hi > $NOT_WORKTREE_NOT_SCRATCH/x")"
assert_exit "still blocks a bare outside redirect with no operator at all (WO-023 fix 1 regression, ticket's own true-positive case)" 2 "$GOT"

# NWM-123: the guard must match the binary a word RESOLVES to, not the name it
# was typed under. Every assertion below pins the exit code AND the stderr, so
# a guard that simply refused everything would fail this section rather than
# pass it.

assert_block() {
  # $1 = description, $2 = cwd, $3 = command text, $4 = extended regex the
  # guard's stderr must match. Both oracles must hold.
  _ab_desc="$1"; _ab_cwd="$2"; _ab_cmd="$3"; _ab_re="$4"
  _ab_rc="$(run_guard "$_ab_cwd" "$_ab_cmd")"
  _ab_err="$(run_guard_stderr "$_ab_cwd" "$_ab_cmd")"
  if [ "$_ab_rc" != 2 ]; then
    fail "$_ab_desc (oracle: exit code, want 2 got $_ab_rc)"
  elif ! printf '%s' "$_ab_err" | grep -Eq "$_ab_re"; then
    fail "$_ab_desc (oracle: stderr, want /$_ab_re/ got: $_ab_err)"
  elif printf '%s' "$_ab_err" | grep -Eq "$RUNTIME_ERR_RE"; then
    fail "$_ab_desc (oracle: stderr carries a runtime error: $_ab_err)"
  else
    pass "$_ab_desc (oracles: exit code 2 AND stderr /$_ab_re/)"
  fi
}

assert_allow() {
  # $1 = description, $2 = cwd, $3 = command text. Exit 0 AND silent stderr —
  # the stderr oracle is what stops a refuse-everything guard passing here.
  _aa_desc="$1"; _aa_cwd="$2"; _aa_cmd="$3"
  _aa_rc="$(run_guard "$_aa_cwd" "$_aa_cmd")"
  _aa_err="$(run_guard_stderr "$_aa_cwd" "$_aa_cmd")"
  if [ "$_aa_rc" != 0 ]; then
    fail "$_aa_desc (oracle: exit code, want 0 got $_aa_rc; stderr: $_aa_err)"
  elif [ -n "$_aa_err" ]; then
    fail "$_aa_desc (oracle: stderr must be empty, got: $_aa_err)"
  else
    pass "$_aa_desc (oracles: exit code 0 AND empty stderr)"
  fi
}

GIT_ABS="$(command -v git 2>/dev/null)"
RM_ABS="$(command -v rm 2>/dev/null)"
SHIM_DIR="$SCRATCH/shims"
mkdir -p "$SHIM_DIR"
# Shims under a name that matches none of the guard's typed-name patterns:
# only resolving them through the filesystem reveals what they run.
if [ -n "$GIT_ABS" ]; then ln -sf "$GIT_ABS" "$SHIM_DIR/g"; fi
if [ -n "$RM_ABS" ]; then ln -sf "$RM_ABS" "$SHIM_DIR/zap"; fi

GIT_MAIN_DIAG='git (stash|reset|clean|checkout) targets the main worktree'
RM_DIAG='rm -r target outside worktree and scratchpad'

# Ticket verify clause 1: a worktree-isolated agent works in its own tree
# unimpeded. A bare status carries no operand for the guard to object to.
assert_allow "allows a bare 'git status' in the agent's OWN linked worktree (NWM-123 verify 1)" \
  "$FAKE_LINKED_WORKTREE" "git status"
assert_allow "allows 'git add -A && git commit' in the agent's OWN linked worktree (NWM-123 verify 1)" \
  "$FAKE_LINKED_WORKTREE" "git add -A"

# Ticket verify clause 2: an absolute-path git write aimed OUT of that
# worktree is refused with the same diagnostic the plain command gets.
if [ -n "$GIT_ABS" ]; then
  assert_block "blocks '<abs>/git -C <main worktree> reset --hard' from a linked worktree (NWM-123 verify 2)" \
    "$FAKE_LINKED_WORKTREE" "$GIT_ABS -C $FAKE_WORKTREE reset --hard" "$GIT_MAIN_DIAG"
fi
assert_block "blocks the plain-named 'git -C <main worktree> reset --hard' with that same diagnostic (NWM-123 verify 2)" \
  "$FAKE_LINKED_WORKTREE" "git -C $FAKE_WORKTREE reset --hard" "$GIT_MAIN_DIAG"

# The gap the typed-name patterns left: a shim whose own NAME matches nothing.
if [ -n "$GIT_ABS" ]; then
  assert_block "blocks a shim named 'g' that resolves to git, stashing the main worktree (NWM-123)" \
    "$FAKE_LINKED_WORKTREE" "$SHIM_DIR/g -C $FAKE_WORKTREE stash push -u" "$GIT_MAIN_DIAG"
  assert_allow "allows that same shim running 'g status' inside the agent's own worktree (NWM-123, resolution must not widen the policy)" \
    "$FAKE_LINKED_WORKTREE" "$SHIM_DIR/g status"
fi

if [ -n "$RM_ABS" ]; then
  assert_block "blocks a shim named 'zap' that resolves to rm, removing a path outside the worktree (NWM-123)" \
    "$FAKE_WORKTREE" "$SHIM_DIR/zap -rf $NOT_WORKTREE_NOT_SCRATCH/victim" "$RM_DIAG"
  assert_allow "allows that same shim removing a path INSIDE the worktree (NWM-123, resolution must not widen the policy)" \
    "$FAKE_WORKTREE" "$SHIM_DIR/zap -rf $FAKE_WORKTREE/leftover"
fi

# A non-command word that happens to name an executable must stay an argument.
assert_allow "allows 'echo git status' — a head-name word in argument position is not a command head (NWM-123)" \
  "$FAKE_LINKED_WORKTREE" "echo git status"

# NWM-123 review round: on-disk resolution must run ONLY in command position.
# With the shim dir on PATH, a bare `g` or `zap` in ARGUMENT position names
# nothing the command is going to run, and blocking it would grow exactly the
# false-positive surface this ticket exists to shrink.
if [ -n "$GIT_ABS" ]; then
  PATH="$SHIM_DIR:$PATH" assert_allow "allows 'echo hello g stash' — git-shaped shim resolvable on PATH but in argument position (NWM-123 review)" \
    "$FAKE_WORKTREE" "echo hello g stash"
  assert_allow "allows 'echo hello <shimdir>/g stash' — git-shaped shim by absolute path in argument position (NWM-123 review)" \
    "$FAKE_WORKTREE" "echo hello $SHIM_DIR/g stash"
  PATH="$SHIM_DIR:$PATH" assert_block "still blocks a bare 'g stash' — same shim, COMMAND position (NWM-123 review, the gate must not undo the fix)" \
    "$FAKE_WORKTREE" "g stash" "$GIT_MAIN_DIAG"
  PATH="$SHIM_DIR:$PATH" assert_block "still blocks 'env g stash' — shim behind a transparent prefix is still the command word (NWM-123 review)" \
    "$FAKE_WORKTREE" "env g stash" "$GIT_MAIN_DIAG"
  PATH="$SHIM_DIR:$PATH" assert_block "still blocks 'bash -c \"g stash\"' — the nested script has its own command word (NWM-123 review)" \
    "$FAKE_WORKTREE" 'bash -c "g stash"' "$GIT_MAIN_DIAG"
fi

if [ -n "$RM_ABS" ]; then
  PATH="$SHIM_DIR:$PATH" assert_allow "allows 'echo describing zap -rf <outside>' — rm-shaped shim resolvable on PATH but in argument position (NWM-123 review)" \
    "$FAKE_WORKTREE" "echo describing zap -rf $NOT_WORKTREE_NOT_SCRATCH/x"
  PATH="$SHIM_DIR:$PATH" assert_block "still blocks a bare 'zap -rf <outside>' — same shim, COMMAND position (NWM-123 review)" \
    "$FAKE_WORKTREE" "zap -rf $NOT_WORKTREE_NOT_SCRATCH/x" "$RM_DIAG"
  PATH="$SHIM_DIR:$PATH" assert_block "still blocks 'xargs zap' — the xargs TARGET is a command position too (NWM-123 review)" \
    "$FAKE_WORKTREE" "xargs zap" "xargs invokes rm on stdin-sourced arguments"
fi

# WO-023 fix 2: WORKTREE is now the whole worktree SET of the repo at cwd
# (`git worktree list`), not just the one member cwd itself sits in, so a
# write into a sibling worktree of the SAME repo is recognised as the
# agent's own tree regardless of which member cwd drifted to.

assert_allow "allows appending into the LINKED worktree when cwd is the repo's MAIN worktree (WO-023 fix 2, was a false positive)" \
  "$FAKE_WORKTREE" "echo x >> $FAKE_LINKED_WORKTREE/wo023.log"

assert_allow "allows appending into the MAIN worktree when cwd is a LINKED worktree of the same repo (WO-023 fix 2, was a false positive)" \
  "$FAKE_LINKED_WORKTREE" "echo x >> $FAKE_WORKTREE/wo023.log"

# True-positive counterparts: a genuinely outside target, and an unrelated
# repo's worktree, must still block — the fix widens to "this repo's
# worktree set", never to "everything reachable from cwd".

assert_block "still blocks appending outside both worktrees from the MAIN worktree (WO-023 fix 2 regression)" \
  "$FAKE_WORKTREE" "echo x >> $NOT_WORKTREE_NOT_SCRATCH/wo023.log" "target outside worktree and scratchpad"

assert_block "still blocks appending outside both worktrees from a LINKED worktree (WO-023 fix 2 regression)" \
  "$FAKE_LINKED_WORKTREE" "echo x >> $NOT_WORKTREE_NOT_SCRATCH/wo023.log" "target outside worktree and scratchpad"

assert_block "still blocks a write into an UNRELATED repo's worktree from this repo's main worktree (WO-023 fix 2, the set is per-repo, not global)" \
  "$FAKE_WORKTREE" "echo x >> $OTHER_REPO/wo023.log" "target outside worktree and scratchpad"

assert_block "still blocks appending into a sibling worktree when cwd is NOT a git repo at all (WO-023 fix 2, the no-repo fallback is unchanged, not widened)" \
  "$NOT_WORKTREE_NOT_SCRATCH" "echo x >> $FAKE_LINKED_WORKTREE/wo023.log" "target outside worktree and scratchpad"

# NWM-122 re-entrancy oracle. The three mutually recursive scanners keep their
# per-call state in bash `local`, whose DYNAMIC scope is the whole reason
# re-entry is safe. These assertions are the only thing checking that, and they
# fail against the pre-NWM-122 shape, which no behavioural assertion here does.

scanner_scope_audit() {
  awk '
    BEGIN {
      np = 3
      pfx[1] = "_ss_";  own[1] = "scan_segment"
      pfx[2] = "_sct_"; own[2] = "scan_command_text"
      pfx[3] = "_sdp_"; own[3] = "scan_dollar_parens_in_word"
      nh = 2
      helper[1] = "tokenize_quoted";         howner[1] = "scan_segment"
      helper[2] = "split_unquoted_segments"; howner[2] = "scan_command_text"
      fn = ""
    }
    {
      line = $0
      t = line
      sub(/^[[:space:]]+/, "", t)
      if (substr(t, 1, 1) == "#") next
      if (match(line, /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/)) {
        fn = substr(line, 1, index(line, "(") - 1)
        next
      }
      if (line == "}") { fn = ""; next }
      if (match(t, /^local[[:space:]]/)) {
        n = split(substr(t, 6), parts, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
          nm = parts[i]
          sub(/=.*$/, "", nm)
          if (nm ~ /^_(ss|sct|sdp)_/) declared[nm] = fn
        }
        next
      }
      rest = line
      while (match(rest, /(^|[^A-Za-z0-9_$])_(ss|sct|sdp)_[A-Za-z0-9_]*\+?=/)) {
        tok = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        sub(/^[^A-Za-z0-9_]/, "", tok)
        sub(/\+?=$/, "", tok)
        seen[tok] = 1
        if (fn == "") top[tok] = NR
      }
      if (match(t, /^for[[:space:]]+_(ss|sct|sdp)_[A-Za-z0-9_]+[[:space:]]/)) {
        nm = substr(t, RSTART, RLENGTH)
        sub(/^for[[:space:]]+/, "", nm)
        sub(/[[:space:]]+$/, "", nm)
        seen[nm] = 1
        if (fn == "") top[nm] = NR
      }
      for (i = 1; i <= nh; i++)
        if (line ~ ("(^|[^A-Za-z0-9_])" helper[i] "([^A-Za-z0-9_(]|$)"))
          calls[i] = calls[i] " " (fn == "" ? "<file-scope>" : fn)
    }
    END {
      nseen = 0
      for (nm in seen) {
        want = ""
        for (i = 1; i <= np; i++) if (index(nm, pfx[i]) == 1) want = own[i]
        if (want == "") continue
        nseen++
        if (!(nm in declared)) print "UNDECLARED " nm " (want: local in " want ")"
        else if (declared[nm] != want) print "WRONG-OWNER " nm " (local in " declared[nm] ", want " want ")"
        if (nm in top) print "FILE-SCOPE " nm " (assigned outside any function, line " top[nm] ")"
      }
      if (nseen < 40) print "ORACLE-BLIND matched only " nseen " scanner variables; the audit has stopped seeing them"
      for (i = 1; i <= nh; i++) {
        c = calls[i]
        sub(/^[[:space:]]+/, "", c)
        if (c == "") { print "NO-CALLER " helper[i] " (expected a call from " howner[i] ")"; continue }
        n = split(c, cs, /[[:space:]]+/)
        for (j = 1; j <= n; j++)
          if (cs[j] != howner[i]) print "OUT-OF-EXTENT " helper[i] " called from " cs[j] " (it writes a local of " howner[i] ")"
      }
    }
  ' "$1"
}

SCOPE_AUDIT="$(scanner_scope_audit "$GUARD")"
GUARD_NAME="$(basename "$GUARD")"

assert_scope() {
  desc="$1"; pattern="$2"
  hits="$(printf '%s\n' "$SCOPE_AUDIT" | grep -E "$pattern" | tr '\n' ';')" || true
  if [ -z "$hits" ]; then
    pass "$desc (oracle: static scope audit of $GUARD_NAME, 0 violations)"
  else
    fail "$desc (oracle: static scope audit of $GUARD_NAME, violations: $hits)"
  fi
}

assert_scope "every _ss_/_sct_/_sdp_ scanner variable is declared 'local' in its owning scanner (NWM-122: bash 'local' replaced the hand-maintained _*_FRAME_VARS lists, and an undeclared one is a silent re-entrancy hole of the class NWM-118 was opened to fix)" \
  '^(UNDECLARED|WRONG-OWNER|ORACLE-BLIND)'

assert_scope "no scanner variable is assigned at file scope (NWM-122: a file-scope assignment survives the scanner's return and is what the 'local' declarations replace)" \
  '^FILE-SCOPE'

assert_scope "tokenize_quoted and split_unquoted_segments are called only from the scanner whose 'local' they write (NWM-122: writing another frame's variable is correct only inside that function's dynamic extent)" \
  '^(OUT-OF-EXTENT|NO-CALLER)'

echo
echo "$N assertion(s), $((N - FAIL)) passed, $FAIL failed" >&2
if [ "$FAIL" -ne 0 ]; then
  echo "failing assertion(s): $FAILED_NUMS" >&2
  echo "guard-fs-writes-selftest.sh: FAILED" >&2
  exit 1
fi
echo "guard-fs-writes-selftest.sh: all assertions passed" >&2
exit 0
