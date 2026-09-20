#!/bin/bash
#
# bash-result-shunt-selftest.sh — assertions for bash-result-shunt.sh
#.
#
# Feeds the hook synthetic PreToolUse JSON on stdin, same
# `.tool_name`/`.tool_input.command`/`.session_id` shape read-shunt.sh's own
# selftest already exercises and corroborated live for this hook family.
#
# Per this project's testing-philosophy.md self-verification-independence
# rule ("a check that has only ever passed has not actually been tested"):
# this selftest was proven discriminating during authoring, not just
# exercised. The mutant that DOES discriminate, and is the one to reproduce
# (the case-arm body, not a `return 1` line, is what actually sets the
# capped flag): in `is_uncapped_git_log`, neutralise the
# capping-flag case arm's ACTION, i.e. change
#   --oneline | --max-count | --max-count=* | -n | -n[0-9]* | -[0-9]*)
#     _iug_capped=0
#     ;;
# to end with `:` instead of `_iug_capped=0`, so an ALREADY-capped `git log`
# is still reported as uncapped. Run against that mutant, group 4's "capped
# git log ... is not gated" and group 7's digit-flag-variant assertions fail
# red (rc mismatches: expected 0, got 2 — 6 failures observed); run against
# the real, unmutated script, the same assertions pass green.
# BASH_SHUNT_SCRIPT lets any mutant be pointed at without editing this file
# (build it under your own scratchpad, never under this repo tree, and
# discard it afterward):
#   cp bash-result-shunt.sh "$SCRATCH/mutant.sh" && <apply the edit above>
#   BASH_SHUNT_SCRIPT="$SCRATCH/mutant.sh" ./bash-result-shunt-selftest.sh   # expect FAIL (6 red)
#   ./bash-result-shunt-selftest.sh                                         # expect PASS
#
# Exit 0 if every assertion passes, 1 on the first failure summary printed.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

SCRIPT="${BASH_SHUNT_SCRIPT:-$HERE/bash-result-shunt.sh}"

[ -x "$SCRIPT" ] || { echo "bash-result-shunt-selftest.sh: $SCRIPT not found or not executable" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "bash-result-shunt-selftest.sh: jq required" >&2; exit 1; }

SCRATCH="${CLAUDE_SCRATCHPAD:-${TMPDIR:-/tmp}/bash-result-shunt-selftest.$$}"
WORKDIR="$SCRATCH/bash-result-shunt-selftest.$$"
mkdir -p "$WORKDIR"
# shellcheck disable=SC2329 # invoked indirectly via the EXIT trap below
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

STATE_ROOT="$WORKDIR/state"
mkdir -p "$STATE_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

run_hook() {
  # $1 = tool_name, $2 = command, $3 = session_id
  _tool="$1"; _cmd="$2"; _session="$3"
  _payload="$(jq -n --arg tn "$_tool" --arg sid "$_session" --arg cmd "$_cmd" \
    '{tool_name: $tn, session_id: $sid, tool_input: {command: $cmd}}')"
  echo "$_payload" | env BASH_SHUNT_STATE_ROOT="$STATE_ROOT" \
    "$SCRIPT" 2>"$WORKDIR/.last_stderr"
  echo "RC=$?"
}

last_stderr() { cat "$WORKDIR/.last_stderr" 2>/dev/null; }

assert_rc() {
  _desc="$1"; _expect="$2"; _out="$3"
  _rc="$(printf '%s\n' "$_out" | tail -n1 | sed -n 's/^RC=//p')"
  if [ "$_rc" = "$_expect" ]; then
    pass "$_desc (rc=$_rc)"
  else
    fail "$_desc (expected rc=$_expect, got rc=${_rc:-<none>})"
  fi
}

OUT="$(printf '{"tool_name": "Bash", "tool_in' | env BASH_SHUNT_STATE_ROOT="$STATE_ROOT" "$SCRIPT" 2>"$WORKDIR/.last_stderr"; echo "RC=$?")"
assert_rc "truncated JSON fails open" "0" "$OUT"

OUT="$(printf '' | env BASH_SHUNT_STATE_ROOT="$STATE_ROOT" "$SCRIPT" 2>"$WORKDIR/.last_stderr"; echo "RC=$?")"
assert_rc "empty stdin fails open" "0" "$OUT"

OUT="$(run_hook Read "" "sess-nonbash")"
assert_rc "non-Bash tool_name is left alone" "0" "$OUT"

OUT="$(run_hook Bash "ls -la" "sess-plain")"
assert_rc "plain unrelated Bash command is left alone" "0" "$OUT"

OUT="$(run_hook Bash "git log" "sess-gitlog")"
assert_rc "bare 'git log' is gated" "2" "$OUT"
case "$(last_stderr)" in
  *"git log --oneline"*) pass "'git log' guidance names a capping flag" ;;
  *) fail "'git log' guidance missing: $(last_stderr)" ;;
esac

OUT="$(run_hook Bash "./scripts/api/jira-api.sh board" "sess-jira")"
assert_rc "bare 'jira-api.sh board' is gated" "2" "$OUT"

OUT="$(run_hook Bash "./scripts/api/jira-api.sh raw /search" "sess-jiraraw")"
assert_rc "bare 'jira-api.sh raw' is gated" "2" "$OUT"

OUT="$(run_hook Bash "python3 /plugins/work-order/1.3.0/reference/issues.py board issues/" "sess-issues-board")"
assert_rc "'issues.py board issues/' (this plugin's real invocation) is never gated" "0" "$OUT"

OUT="$(run_hook Bash "python3 /plugins/work-order/1.3.0/reference/issues.py waves issues/" "sess-issues-waves")"
assert_rc "'issues.py waves issues/' is never gated" "0" "$OUT"

# Group 4 is what the discriminating mutant (see the header) flips to rc=2.

OUT="$(run_hook Bash "git log --oneline -20" "sess-gitlog-capped-1")"
assert_rc "capped 'git log --oneline -20' is not gated" "0" "$OUT"

OUT="$(run_hook Bash "git log -n 20" "sess-gitlog-capped-2")"
assert_rc "capped 'git log -n 20' is not gated" "0" "$OUT"

OUT="$(run_hook Bash "git log -20" "sess-gitlog-capped-3")"
assert_rc "capped 'git log -20' (bare numeric limit) is not gated" "0" "$OUT"

OUT="$(run_hook Bash "./scripts/api/jira-api.sh board --limit 20" "sess-jira-capped")"
assert_rc "capped 'jira-api.sh board --limit 20' is not gated" "0" "$OUT"

OUT="$(run_hook Bash "git log" "sess-escape")"
assert_rc "first uncapped 'git log' in a fresh session is gated" "2" "$OUT"

OUT="$(run_hook Bash "git log" "sess-escape")"
assert_rc "escape hatch: identical command, same session, runs unblocked" "0" "$OUT"

OUT="$(run_hook Bash "git log" "sess-escape-other")"
assert_rc "escape hatch is per-session: new session re-gates" "2" "$OUT"

OUT="$(run_hook Bash "op item get some-credential" "sess-secret-1")"
assert_rc "'op item get' is never gated" "0" "$OUT"

OUT="$(run_hook Bash "git log --grep=token" "sess-secret-2")"
assert_rc "command text containing 'token' is never gated" "0" "$OUT"

OUT="$(run_hook Bash "git log --stat -5" "sess-cap-stat")"
assert_rc "'git log --stat -5' (cap not first flag) is not gated" "0" "$OUT"

OUT="$(run_hook Bash "git log --graph -10" "sess-cap-graph")"
assert_rc "'git log --graph -10' (cap not first flag) is not gated" "0" "$OUT"

OUT="$(run_hook Bash "git log -n50" "sess-cap-n50")"
assert_rc "'git log -n50' (glued -n<N>) is not gated" "0" "$OUT"

OUT="$(run_hook Bash "grep -rn \"git log\" scripts/" "sess-mention-1")"
assert_rc "'git log' inside a quoted grep pattern is not gated" "0" "$OUT"

OUT="$(run_hook Bash "echo \"next step: git log\"" "sess-mention-2")"
assert_rc "'git log' inside an echoed string is not gated" "0" "$OUT"

OUT="$(run_hook Bash "echo \"jira-api.sh raw is noisy\"" "sess-mention-4")"
assert_rc "'jira-api.sh raw' inside an echoed string is not gated" "0" "$OUT"

OUT="$(run_hook Bash "git log; grep -n foo bar" "sess-compound-1")"
assert_rc "uncapped 'git log' followed by an unrelated ';'-separated command is gated" "2" "$OUT"

OUT="$(run_hook Bash "git log --format=%H | grep abc" "sess-compound-2")"
assert_rc "'git log' piped to grep (already filtered) is not gated" "0" "$OUT"

OUT="$(run_hook Bash "git log --name-only --since=2000-01-01" "sess-since")"
assert_rc "'--since' alone does not count as a cap; still gated" "2" "$OUT"

OUT="$(run_hook Bash "git log --all  # note: token budget" "sess-secret-comment")"
assert_rc "'token' inside a trailing comment does not suppress gating" "2" "$OUT"

OUT="$(run_hook Bash "git log -- docker/env/plex.env.tpl" "sess-secret-path")"
assert_rc "a path merely containing '.env' (as '.env.tpl') does not suppress gating" "2" "$OUT"

OUT="$(run_hook Bash "./scripts/api/jira-api.sh raw /myself" "sess-jira-myself")"
assert_rc "'jira-api.sh raw /myself' (single-object read) is not gated" "0" "$OUT"

# rc=0 means fail_open rejected the session_id BEFORE any mkdir/write; the
# absence of a write is established by code path, not by inspecting /tmp.
OUT="$(run_hook Bash "git log" "../../../../../../tmp/pwned")"
assert_rc "path-traversal session_id fails open instead of escaping STATE_ROOT" "0" "$OUT"
case "$(last_stderr)" in
  *"session_id contains a path separator"*) pass "path-traversal session_id was rejected by the session_id guard specifically" ;;
  *) fail "path-traversal session_id did not hit the session_id guard: $(last_stderr)" ;;
esac

OUT="$(run_hook Bash "./scripts/api/jira-api.sh board | head -60" "sess-redir-1")"
assert_rc "[regression guard] jira-api.sh board piped to head, no redirection, is not gated" "0" "$OUT"

OUT="$(run_hook Bash "./scripts/api/jira-api.sh board 2>&1 | head -60" "sess-redir-2")"
assert_rc "[discriminating] jira-api.sh board with 2>&1 before the pipe is not gated" "0" "$OUT"

OUT="$(run_hook Bash "./scripts/api/jira-api.sh board 2>&1 | awk '/x/' | head -60" "sess-redir-3")"
assert_rc "[discriminating] jira-api.sh board with 2>&1 and a two-stage pipe is not gated" "0" "$OUT"

OUT="$(run_hook Bash "./scripts/api/jira-api.sh board" "sess-redir-4")"
assert_rc "[regression guard] uncapped, unpiped jira-api.sh board is still gated" "2" "$OUT"

OUT="$(run_hook Bash "git log 2>&1 | head -40" "sess-redir-5")"
assert_rc "[discriminating] 'git log' with 2>&1 before the pipe is not gated" "0" "$OUT"

OUT="$(run_hook Bash "./scripts/api/jira-api.sh raw /search 2>&1 | head -40" "sess-redir-6")"
assert_rc "[discriminating] 'jira-api.sh raw /search' with 2>&1 before the pipe is not gated" "0" "$OUT"

OUT="$(run_hook Bash "git log >&2 | grep abc" "sess-redir-7")"
assert_rc "[discriminating] 'git log' with >&2 (fd-dup redirect) before the pipe is not gated" "0" "$OUT"

OUT="$(run_hook Bash "git log <&3 | grep abc" "sess-redir-8")"
assert_rc "[discriminating] 'git log' with <&3 (input fd-dup) before the pipe is not gated" "0" "$OUT"

OUT="$(run_hook Bash "git log 2>/dev/null | head -5" "sess-redir-9")"
assert_rc "[regression guard] 'git log' with a plain 2>/dev/null redirect (no '&') before the pipe is not gated" "0" "$OUT"

OUT="$(run_hook Bash "./scripts/api/jira-api.sh board &> /tmp/out.log" "sess-redir-10")"
assert_rc "[regression guard] '&>' redirect with no pipe still counts as uncapped (redirecting to a file is not filtering)" "2" "$OUT"

OUT="$(run_hook Bash "git log --oneline -20; git log" "sess-mixed-3")"
assert_rc "[discriminating] capped git log stage followed by an uncapped ';'-joined git log stage is gated" "2" "$OUT"

OUT="$(run_hook Bash "./scripts/api/jira-api.sh board --limit 20; ./scripts/api/jira-api.sh board" "sess-mixed-4")"
assert_rc "[discriminating] capped jira-api.sh board stage followed by an uncapped ';'-joined stage is gated" "2" "$OUT"

OUT="$(run_hook Bash "./scripts/api/jira-api.sh board --limit 20 && ./scripts/api/jira-api.sh board" "sess-mixed-4b")"
assert_rc "[discriminating] capped jira-api.sh board stage followed by an uncapped '&&'-joined stage is gated" "2" "$OUT"

OUT="$(run_hook Bash "./scripts/api/jira-api.sh board --limit 20; ./scripts/api/jira-api.sh board --limit 10" "sess-mixed-5")"
assert_rc "[negative control] capped jira-api.sh board stage followed by ANOTHER capped stage is not gated" "0" "$OUT"

GITCOMMIT_HEREDOC_CMD="$(cat <<'EOF'
git commit -F - <<'EOF2'
fix detector

Example failing output:
  ./jira-api.sh board | head -60; python3 -c "print('git log')"
EOF2
EOF
)"
OUT="$(run_hook Bash "$GITCOMMIT_HEREDOC_CMD" "sess-heredoc-commit")"
assert_rc "[discriminating] a gated-shape mention inside a quoted git-commit heredoc body is not gated" "0" "$OUT"

JIRACOMMENT_HEREDOC_CMD="$(cat <<'EOF'
./scripts/api/jira-api.sh comment  - <<'EOF2'
See gated prose: git log
EOF2
EOF
)"
OUT="$(run_hook Bash "$JIRACOMMENT_HEREDOC_CMD" "sess-heredoc-jira-comment")"
assert_rc "[discriminating] gated prose inside a quoted jira-api.sh comment heredoc body is not gated" "0" "$OUT"

CAT_QUOTED_REDIRECT_CMD="$(cat <<'EOF'
cat <<'EOF2' > /tmp/out.txt
git log
EOF2
EOF
)"
OUT="$(run_hook Bash "$CAT_QUOTED_REDIRECT_CMD" "sess-heredoc-cat-quoted")"
assert_rc "[discriminating] gated prose inside a quoted 'cat <<EOF > file' heredoc body is not gated" "0" "$OUT"

CAT_UNQUOTED_CMD="$(cat <<'EOF'
cat <<EOF2
git log
EOF2
EOF
)"
OUT="$(run_hook Bash "$CAT_UNQUOTED_CMD" "sess-heredoc-cat-unquoted")"
assert_rc "[discriminating] gated prose inside an unquoted 'cat <<EOF' heredoc body is not gated" "0" "$OUT"

GITLOG_HEREDOC_CMD="$(cat <<'EOF'
git commit -F - <<'EOF2'
notes: git log
EOF2
EOF
)"
OUT="$(run_hook Bash "$GITLOG_HEREDOC_CMD" "sess-heredoc-gitlog")"
assert_rc "[discriminating] 'git log' mention inside a heredoc body is not gated" "0" "$OUT"

QUOTED_SEMICOLON_CMD='git commit -m "fix: shunt detector; git log should not trigger"'
OUT="$(run_hook Bash "$QUOTED_SEMICOLON_CMD" "sess-quoted-m-semicolon")"
assert_rc "[regression guard] a gated shape mentioned inside a quoted -m string (with an embedded ';') is not gated" "0" "$OUT"

HEREDOC_THEN_REAL_CMD="$(cat <<'EOF'
cat <<'EOF2'
notes
EOF2
git log
EOF
)"
OUT="$(run_hook Bash "$HEREDOC_THEN_REAL_CMD" "sess-heredoc-then-real")"
assert_rc "[negative control] a REAL gated command immediately after a heredoc terminator still gates" "2" "$OUT"

OUT="$(run_hook Bash "$(cat <<'EOF'
ssh docker-host <<'EOF2'
git log
EOF2
EOF
)" "sess-ssh-heredoc")"
assert_rc "[discriminating, HIGH] 'git log' inside an ssh heredoc body is gated (heredoc body is a command list over ssh, not prose)" "2" "$OUT"

OUT="$(run_hook Bash "$(cat <<'EOF'
bash <<'EOF2'
./scripts/api/jira-api.sh board
EOF2
EOF
)" "sess-bash-heredoc")"
assert_rc "[discriminating, HIGH] gated command inside a bare 'bash <<EOF' heredoc body is gated" "2" "$OUT"

OUT="$(run_hook Bash "$(cat <<'EOF'
sudo sh <<'EOF2'
git log
EOF2
EOF
)" "sess-sudosh-heredoc")"
assert_rc "[discriminating, HIGH] gated command inside a 'sudo sh <<EOF' heredoc body is gated (interpreter word not in first position)" "2" "$OUT"

COMMENT_CMD="$(cat <<'EOF'
# example: cat <<EOF
./scripts/api/jira-api.sh board
EOF
)"
OUT="$(run_hook Bash "$COMMENT_CMD" "sess-comment-fakeheredoc")"
assert_rc "[discriminating, MEDIUM] a real gated command after a '<<EOF' mentioned inside a comment is gated (comment is not a real heredoc operator)" "2" "$OUT"

HYPHEN_DELIM_CMD="$(cat <<'EOF'
cat <<'EOF-1'
note
EOF-1
./scripts/api/jira-api.sh board
EOF
)"
OUT="$(run_hook Bash "$HYPHEN_DELIM_CMD" "sess-hyphen-delim")"
assert_rc "[discriminating, MEDIUM] a real gated command after a heredoc with a hyphenated delimiter ('EOF-1') is gated (delimiter is a shell word, not [A-Za-z0-9_] only)" "2" "$OUT"

REGRESSION_COMMIT_CMD="$(cat <<'EOF'
git commit -F - <<'EOF2'
fix detector

Example failing output:
  ./jira-api.sh board | head -60; git log
EOF2
EOF
)"
OUT="$(run_hook Bash "$REGRESSION_COMMIT_CMD" "sess-regression-commit-prose")"
assert_rc "[regression guard] gated prose inside a git-commit heredoc body is still not gated after the rework" "0" "$OUT"

echo ""
echo "bash-result-shunt-selftest.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
