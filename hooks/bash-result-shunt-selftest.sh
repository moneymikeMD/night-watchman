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
# The NWM-136 redaction group was proven discriminating the same way. Every
# count below was re-measured 2026-09-21 against the current fixtures, with
# 104 green unmutated; D's earlier figure of 4 was wrong and never
# reproducible, which is why the whole table was re-run rather than extended:
#   A  the pre-change script (`git show <parent>:hooks/bash-result-shunt.sh`)
#      — 37 red. It has no --redact-stream at all.
#   B  `name_is_secret` neutralised to `return 0` — 7 red, all name-only
#      cases. Written first WITHOUT those cases, this mutant passed clean:
#      every other fixture value also matched by shape or by prefix, so the
#      allowlist was dead code no assertion reached. That is why
#      `NAME=hunter2` exists.
#   C  the pass-through `print scrub_tokens(line)` replaced by `print ""`, a
#      redactor that eats all output — 17 red, caught by the negatives and by
#      the surviving-control argument every assert_absent carries.
#   D  `is_opaque`'s length gate inverted so every value is opaque — 2 red.
#   E  `is_opaque`'s `return (hasd && hasa)` forced to `return 1` — 1 red.
#      Passed clean until the long-single-class negative was added.
#   F  the INT/TERM/EXIT trap deleted from the rewrite — 3 red.
#   G  the blank line before the wrapper's closing brace deleted — 2 red.
#   H  `allow_exit`'s `split_segments` handed raw $CMD again — 1 red.
#   I  the NAME boundary set narrowed back to space/tab only — 2 red.
#   J  the PFXRE fast path in `scrub_tokens` deleted — 0 red, expected: it is
#      a pure optimisation, pinned by byte-identical output over a 4.2MB
#      corpus (4.12s to 0.26s), not by any assertion here.
#
# strip_heredocs() has its own mutant, outside the redaction table: in
# _sh_drain_heredoc_queue, change `if [ "$_sh_found_term" -eq 0 ]; then` to
# `if false; then` — expect the LAB-187b assertion alone red (1 failure).
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

# Heredoc-body cases from here through the hyphenated-delimiter assertion:
# function under test is strip_heredocs() (hooks/bash-result-shunt.sh).

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

# LAB-187 (a): two `<<DELIM` operators on one line, attached to one command
# (`cat <<A1 <<B1`) — strip_heredocs() must recognise the second as an
# operator, not fold it into the first heredoc's "rest of line" text.
TWO_HEREDOCS_ONE_LINE_CMD="$(cat <<'EOF'
cat <<'A1' <<'B1'
harmless
A1
git log
B1
EOF
)"
OUT="$(run_hook Bash "$TWO_HEREDOCS_ONE_LINE_CMD" "sess-two-heredocs-one-line")"
assert_rc "[discriminating, LAB-187a] gated prose inside the SECOND of two heredocs stacked on one line ('cat <<A1 <<B1') is not gated" "0" "$OUT"

TWO_HEREDOCS_THEN_REAL_CMD="$(cat <<'EOF'
cat <<'A1' <<'B1'
harmless
A1
prose
B1
git log
EOF
)"
OUT="$(run_hook Bash "$TWO_HEREDOCS_THEN_REAL_CMD" "sess-two-heredocs-then-real")"
assert_rc "[negative control, LAB-187a] a REAL gated command after two stacked heredocs on one line still gates" "2" "$OUT"

# LAB-187 (b): strip_heredocs() restores an UNTERMINATED heredoc's body
# verbatim (rather than discarding it), so it can still be gated — a
# deliberate false-positive-over-false-negative choice, asserted by name.
UNTERMINATED_HEREDOC_CMD="$(printf 'cat <<EOF\ngit log\nsome body with no closing EOF delimiter')"
OUT="$(run_hook Bash "$UNTERMINATED_HEREDOC_CMD" "sess-unterminated-heredoc")"
assert_rc "[discriminating, LAB-187b] strip_heredocs() restores an unterminated heredoc's body verbatim, so a gated shape inside it still gates" "2" "$OUT"

# LAB-187 (a) widened the operator line's TAIL from "copied verbatim" to
# "scanned by the main state machine", so a second command on that same
# line (after a `;`) is now recognised, quotes and all — pin it.
TAIL_SCANNED_CMD="$(cat <<'EOF'
cat <<'A' ; ssh h <<'B'
harmless
A
git log
B
EOF
)"
OUT="$(run_hook Bash "$TAIL_SCANNED_CMD" "sess-tail-scanned")"
assert_rc "[regression guard, LAB-187a] a second, ';'-joined command on a heredoc operator line's tail is scanned, not copied verbatim — its own executor heredoc still gates" "2" "$OUT"

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

# --- NWM-136: secret redaction in command OUTPUT. Every value below is a
# fixture invention, never a real credential: FIXTURE/FAKE appears inside
# each one so a reader and a secret scanner can both tell at a glance.

FIX_OP_TOKEN='ops_FAKEFIXTUREtokenAAAAAAAAAAAAAAAAAAAAAAAA'
FIX_MEMORY_PW='Kj8mQ2FIXTUREx7LpR4tW9zYc3BdFgH6sA1eU5iO0nM2k'
FIX_OPAQUE='Zq4FIXTUREw8Nb2Hs6Yt1Rv9Lm3Kp7Xj0Cd5Gf8Ah2Bn'

redact() { printf '%s\n' "$1" | "$SCRIPT" --redact-stream; }

# An absence assertion over empty output is vacuous: a redactor that deleted
# everything would satisfy it. $4 is a control string that MUST survive.
assert_absent() {
  _desc="$1"; _needle="$2"; _hay="$3"; _control="$4"
  case "$_hay" in
    *"$_needle"*) fail "$_desc (value still present in: $_hay)"; return ;;
  esac
  case "$_hay" in
    *"$_control"*) pass "$_desc" ;;
    *) fail "$_desc (vacuous: surviving control '$_control' absent from: $_hay)" ;;
  esac
}

assert_contains() {
  _desc="$1"; _needle="$2"; _hay="$3"
  case "$_hay" in
    *"$_needle"*) pass "$_desc" ;;
    *) fail "$_desc (expected '$_needle' in: $_hay)" ;;
  esac
}

assert_identical() {
  _desc="$1"; _line="$2"
  _got="$(redact "$_line")"
  if [ "$_got" = "$_line" ]; then
    pass "$_desc"
  else
    fail "$_desc (line was rewritten to: $_got)"
  fi
}

# The three environment-dumping shapes the ticket names, each run for real
# rather than hand-typed, so a change in their output format is caught.

ENV_OUT="$(env OP_SERVICE_ACCOUNT_TOKEN="$FIX_OP_TOKEN" env | grep '^OP_SERVICE_ACCOUNT_TOKEN=' | "$SCRIPT" --redact-stream)"
assert_absent "[NWM-136] real 'env' output: token value is gone" "$FIX_OP_TOKEN" "$ENV_OUT" "OP_SERVICE_ACCOUNT_TOKEN="
assert_contains "[NWM-136] real 'env' output: marker names the variable" "[redacted: OP_SERVICE_ACCOUNT_TOKEN]" "$ENV_OUT"

PRINTENV_OUT="$(env OP_SERVICE_ACCOUNT_TOKEN="$FIX_OP_TOKEN" printenv OP_SERVICE_ACCOUNT_TOKEN | sed 's/^/OP_SERVICE_ACCOUNT_TOKEN=/' | "$SCRIPT" --redact-stream)"
assert_absent "[NWM-136] real 'printenv' output: token value is gone" "$FIX_OP_TOKEN" "$PRINTENV_OUT" "OP_SERVICE_ACCOUNT_TOKEN="

EXPORTP_OUT="$(env OP_SERVICE_ACCOUNT_TOKEN="$FIX_OP_TOKEN" bash -c 'export -p' | grep 'OP_SERVICE_ACCOUNT_TOKEN' | "$SCRIPT" --redact-stream)"
assert_absent "[NWM-136] real 'export -p' output: token value is gone" "$FIX_OP_TOKEN" "$EXPORTP_OUT" "declare -x OP_SERVICE_ACCOUNT_TOKEN="
assert_contains "[NWM-136] 'export -p' marker keeps the declare -x quoting" 'OP_SERVICE_ACCOUNT_TOKEN="[redacted: OP_SERVICE_ACCOUNT_TOKEN]"' "$EXPORTP_OUT"

SET_OUT="$(env OP_SERVICE_ACCOUNT_TOKEN="$FIX_OP_TOKEN" bash -c 'set' | grep '^OP_SERVICE_ACCOUNT_TOKEN=' | "$SCRIPT" --redact-stream)"
assert_absent "[NWM-136] real 'set' output: token value is gone" "$FIX_OP_TOKEN" "$SET_OUT" "OP_SERVICE_ACCOUNT_TOKEN="

# Shape alone, with a NAME that is on no allowlist.

SHAPE_OUT="$(redact "NWM_FIXTURE_BLOB=$FIX_OPAQUE")"
assert_absent "[NWM-136] opaque value under a non-allowlisted NAME is redacted on shape alone" "$FIX_OPAQUE" "$SHAPE_OUT" "NWM_FIXTURE_BLOB="
assert_contains "[NWM-136] shape-only marker names the variable" "[redacted: NWM_FIXTURE_BLOB]" "$SHAPE_OUT"

# Name-only cases: the value is short and ordinary, so ONLY the allowlist can
# catch it. Without these the allowlist is dead code every other fixture
# reaches by shape or by prefix instead.

for NAME_ONLY in MEMORY_FALKORDB_PASSWORD OP_SESSION MY_API_KEY DB_PASSWD SOME_SECRET AWS_CREDENTIAL GH_TOKEN; do
  NAME_ONLY_OUT="$(redact "$NAME_ONLY=hunter2")"
  assert_absent "[NWM-136] name-only: $NAME_ONLY=hunter2 is redacted on the NAME alone" "hunter2" "$NAME_ONLY_OUT" "[redacted: $NAME_ONLY]"
done

PREFIX_OUT="$(redact "NWM_FIXTURE_BLOB=$FIX_OP_TOKEN")"
assert_absent "[NWM-136] credential-prefixed value under a non-allowlisted NAME is redacted" "$FIX_OP_TOKEN" "$PREFIX_OUT" "NWM_FIXTURE_BLOB="

BARE_OUT="$(redact "the value is $FIX_OP_TOKEN right there")"
assert_absent "[NWM-136] a bare credential-prefixed token with no NAME= at all is redacted" "$FIX_OP_TOKEN" "$BARE_OUT" "the value is "

# The exact reproduction that caused this ticket, run end to end through the
# hook: the hook's own updatedInput rewrite is executed, not simulated.

REPRO_PAYLOAD="$(jq -n --arg cmd "env | grep -iE 'memory|op_|herdr'" \
  '{tool_name: "Bash", session_id: "sess-nwm136-repro", tool_input: {command: $cmd}}')"
REPRO_WRAPPED="$(printf '%s' "$REPRO_PAYLOAD" | env BASH_SHUNT_STATE_ROOT="$STATE_ROOT" BASH_SHUNT_REDACT_OUTPUT=1 \
  "$SCRIPT" | jq -r '.hookSpecificOutput.updatedInput.command // empty')"
if [ -z "$REPRO_WRAPPED" ]; then
  fail "[NWM-136] hook emits an updatedInput rewrite when BASH_SHUNT_REDACT_OUTPUT=1"
else
  pass "[NWM-136] hook emits an updatedInput rewrite when BASH_SHUNT_REDACT_OUTPUT=1"
  printf '%s\n' "$REPRO_WRAPPED" > "$WORKDIR/repro.sh"
  REPRO_OUT="$(env OP_SERVICE_ACCOUNT_TOKEN="$FIX_OP_TOKEN" MEMORY_FALKORDB_PASSWORD="$FIX_MEMORY_PW" \
    NWM136_op_CONTROL=plainvalue bash "$WORKDIR/repro.sh" 2>&1)"
  assert_absent "[NWM-136] the ticket's own 'env | grep -iE' repro shows no OP_SERVICE_ACCOUNT_TOKEN value" "$FIX_OP_TOKEN" "$REPRO_OUT" "NWM136_op_CONTROL=plainvalue"
  assert_absent "[NWM-136] the ticket's own 'env | grep -iE' repro shows no MEMORY_FALKORDB_PASSWORD value" "$FIX_MEMORY_PW" "$REPRO_OUT" "NWM136_op_CONTROL=plainvalue"
  assert_contains "[NWM-136] the repro output still names both redacted variables" "[redacted: OP_SERVICE_ACCOUNT_TOKEN]" "$REPRO_OUT"
fi

# The wrapper must not change what the shell sees: state survives, status is
# replayed. A rewrite that subshells the command would break both.

printf '%s\n' "$(jq -n --arg cmd 'cd /usr; pwd; false' '{tool_name: "Bash", session_id: "sess-nwm136-state", tool_input: {command: $cmd}}' \
  | env BASH_SHUNT_STATE_ROOT="$STATE_ROOT" BASH_SHUNT_REDACT_OUTPUT=1 "$SCRIPT" \
  | jq -r '.hookSpecificOutput.updatedInput.command // empty')" > "$WORKDIR/state.sh"
STATE_OUT="$(bash -c 'cd /; . "$1"; printf "rc=%s pwd=%s\n" "$?" "$PWD"' _ "$WORKDIR/state.sh")"
assert_contains "[NWM-136] the rewrite replays the real exit status" "rc=1" "$STATE_OUT"
assert_contains "[NWM-136] the rewrite leaves 'cd' in effect (no subshell)" "pwd=/usr" "$STATE_OUT"

OUT="$(run_hook Bash "ls -la" "sess-nwm136-default-off")"
assert_rc "[NWM-136] redaction is off by default: no rewrite, plain allow" "0" "$OUT"

# grep/git-grep prefix a match with 'path:N:' or 'N:', which is the shape a
# leak actually arrives in. The NAME boundary must accept ':'.

GREPSHAPE_OUT="$(redact "lab-env.sh:4:MEMORY_FALKORDB_PASSWORD=$FIX_MEMORY_PW")"
assert_absent "[NWM-136] the grep 'path:N:NAME=value' shape is redacted" "$FIX_MEMORY_PW" "$GREPSHAPE_OUT" "lab-env.sh:4:MEMORY_FALKORDB_PASSWORD="
GREPN_OUT="$(redact "4:GH_TOKEN=$FIX_MEMORY_PW")"
assert_absent "[NWM-136] the 'grep -n' 'N:NAME=value' shape is redacted" "$FIX_MEMORY_PW" "$GREPN_OUT" "4:GH_TOKEN="

# The rewrite must not turn a valid command into a syntax error. A trailing
# line continuation swallows the newline before the closing brace.

wrap_cmd() {
  printf '%s\n' "$(jq -n --arg cmd "$1" --arg sid "$2" \
    '{tool_name: "Bash", session_id: $sid, tool_input: {command: $cmd}}' \
    | env BASH_SHUNT_STATE_ROOT="$STATE_ROOT" BASH_SHUNT_REDACT_OUTPUT=1 "$SCRIPT" \
    | jq -r '.hookSpecificOutput.updatedInput.command // empty')"
}

# shellcheck disable=SC1003 # the trailing backslash IS the fixture
wrap_cmd 'echo BSLASH_OK \' sess-nwm136-bslash > "$WORKDIR/bslash.sh"
BSLASH_OUT="$(bash "$WORKDIR/bslash.sh" 2>&1; echo "rc=$?")"
assert_contains "[NWM-136] a command ending in a line continuation still runs once wrapped" "BSLASH_OK" "$BSLASH_OUT"
assert_contains "[NWM-136] a wrapped line-continuation command exits 0, not a parse error" "rc=0" "$BSLASH_OUT"

# allow_exit scans $STRIPPED_CMD, so an '&' in a heredoc BODY is not read as a
# background separator — but a REAL background '&' must still skip the rewrite.

HEREDOC_AMP_WRAPPED="$(wrap_cmd "$(printf 'cat <<XEOF\nA & B\nXEOF\n')" sess-nwm136-hd-amp)"
if [ -n "$HEREDOC_AMP_WRAPPED" ]; then
  pass "[NWM-136] an '&' inside a heredoc body does not disable the rewrite"
else
  fail "[NWM-136] an '&' inside a heredoc body does not disable the rewrite (no updatedInput emitted)"
fi
BG_WRAPPED="$(wrap_cmd 'sleep 0 & echo hi' sess-nwm136-real-bg)"
if [ -z "$BG_WRAPPED" ]; then
  pass "[NWM-136] a real backgrounded statement still skips the rewrite"
else
  fail "[NWM-136] a real backgrounded statement still skips the rewrite (rewrite was emitted)"
fi

# A killed command (the Bash tool's own 120s timeout is the common case) must
# still replay what it already produced, and must not leak its temp files.

KILL_TMP="$WORKDIR/killtmp"
mkdir -p "$KILL_TMP"
wrap_cmd 'echo PRE_KILL_LINE; sleep 3; echo POST_KILL_LINE' sess-nwm136-kill > "$WORKDIR/kill.sh"
( env TMPDIR="$KILL_TMP" bash "$WORKDIR/kill.sh" > "$WORKDIR/kill.out" 2>&1 & echo $! > "$WORKDIR/kill.pid" )
sleep 1
kill -TERM "$(cat "$WORKDIR/kill.pid")" 2>/dev/null
sleep 4
KILL_OUT="$(cat "$WORKDIR/kill.out" 2>/dev/null)"
assert_contains "[NWM-136] output produced before a TERM survives the kill" "PRE_KILL_LINE" "$KILL_OUT"
assert_absent "[NWM-136] a TERM-killed command does not emit its post-kill output" "POST_KILL_LINE" "$KILL_OUT" "PRE_KILL_LINE"
KILL_LEFT="$(find "$KILL_TMP" -name 'nwm-redact.*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$KILL_LEFT" = "0" ]; then
  pass "[NWM-136] a TERM-killed command leaves no nwm-redact temp file behind"
else
  fail "[NWM-136] a TERM-killed command leaves no nwm-redact temp file behind (found $KILL_LEFT)"
fi

# The NEGATIVE half. A redactor that eats ordinary output is the same defect
# as a guard that over-blocks, and this repo has shipped one of those.

assert_identical "[NWM-136 negative] a NAME mentioned with no value is untouched" "OP_SERVICE_ACCOUNT_TOKEN is not set in this shell"
assert_identical "[NWM-136 negative] a NAME inside an ordinary command line is untouched" "grep -c MEMORY_FALKORDB_PASSWORD ~/.zshenv"
assert_identical "[NWM-136 negative] an empty assignment is untouched" "OP_SERVICE_ACCOUNT_TOKEN="
assert_identical "[NWM-136 negative] a short ordinary assignment is untouched" "FOO=bar"
assert_identical "[NWM-136 negative] a long PATH value is untouched" "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
assert_identical "[NWM-136 negative] a long PWD value is untouched" "PWD=/opt/build/code/home_workspace/night-watchman"
assert_identical "[NWM-136 negative] a long single-class value is untouched (is_opaque needs a letter AND a digit)" "NOTES=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_identical "[NWM-136 negative] a Python kwarg is untouched ('(' is deliberately not a NAME boundary)" "    rows.sort(key=lambda r: r[0])"
assert_identical "[NWM-136 negative] a prefixed-but-ordinary env var is untouched" "npm_config_prefix=/opt/homebrew"
assert_identical "[NWM-136 negative] a flag that looks like an assignment is untouched" "git log --max-count=20 --oneline"
assert_identical "[NWM-136 negative] ordinary prose is untouched" "Rotated the token on 2026-09-19; see docs/known-issues for the write-up."

echo ""
echo "bash-result-shunt-selftest.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
