#!/bin/bash
#
# Assertions for memory-push.sh.
#
# Structurally offline: a fixture `memorygraph` written into a throwaway
# directory is put first on PATH, and MEMORY_BACKEND names a backend no
# real memorygraph has, so neither the fixture nor a stray real CLI can
# reach a store. Like the real 0.14 fork, the fixture prints its connection
# preamble on stdout before every answer. FIXTURE_MODE picks its behaviour:
#
#   json        recall prints fixed JSON with full bodies (no get needed)
#   markdown    recall prints the fork's markdown with ~150-char previews;
#               get prints each full body
#   gethang     markdown recall, every get hangs
#   getpartial  markdown recall, get fails for the second result only
#   getdrift    markdown recall, get output has no Content section
#   hang        every call hangs
#   escape      recall hangs and leaves a setsid'd child holding its stdout
#   error       every call exits 1
#   garbage     every call prints unparsable text
#
# Asserts, for all three events, the raw-case query (at most 400
# characters) and the configured payload (top 3 bodies cut at 1,250
# characters, then titles); the 1.5 s embed cap on recall only; that a hang,
# an error or garbage injects nothing and exits 0 inside the budget; the
# circuit breaker; per-session de-duplication of bodies, titles and
# queries, and its reset on compact; the preview-is-never-a-body guard;
# the Bash-only and is_interrupt filters; the opt-out; and the skip when no
# store is configured.
#
# Usage: ./hooks/memory-push-selftest.sh
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${MEMORY_PUSH_SH:-$HERE/memory-push.sh}"
[ -f "$HOOK" ] || { echo "cannot find memory-push.sh at $HOOK" >&2; exit 1; }

FAIL=0
N=0
pass() { N=$((N + 1)); echo "PASS $N: $1"; }
fail() { N=$((N + 1)); echo "FAIL $N: $1" >&2; FAIL=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$3], got [$2])"; fi; }
at_most() { if [ "$2" -le "$3" ]; then pass "$1 ($2)"; else fail "$1 (got $2, limit $3)"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/memory-push-selftest.XXXXXX")"
trap 'pkill -f "memory-push-selftest-[eh][sa]" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fx"

python3 - "$WORK/fx" <<'PY'
import json, sys
fx = sys.argv[1]
long_body = "word " * 600
mems = [
    ("11111111-1111-1111-1111-111111111111", "Push over port 22 is blocked; use ssh.github.com:443", long_body),
    ("22222222-2222-2222-2222-222222222222", "GitHub SSH stalls **intermittently** from both machines", "Route pushes through git-retry.sh.\nSecond line."),
    ("33333333-3333-3333-3333-333333333333", "Third memory", "Third body."),
    ("44444444-4444-4444-4444-444444444444", "Fourth memory", "Fourth body."),
    ("55555555-5555-5555-5555-555555555555", "Fifth memory", "Fifth body."),
    ("66666666-6666-6666-6666-666666666666", "Sixth memory", "Sixth body."),
    ("77777777-7777-7777-7777-777777777777", "Seventh memory", "Seventh body."),
]
json.dump(mems, open(fx + "/mems.json", "w"))
json.dump([{"id": i, "title": t, "content": c} for i, t, c in mems[:5]], open(fx + "/recall.json", "w"))
json.dump({"results": [{"id": i, "title": t, "content": c} for i, t, c in (mems[0], mems[5], mems[6])]},
          open(fx + "/recall2.json", "w"))
md = ["**Found 5 relevant memories:**", ""]
for n, (i, t, c) in enumerate(mems[:5], 1):
    md += ["**%d. %s** (ID: %s)" % (n, t, i), "Type: solution | Importance: 0.8", "Match: hybrid quality",
           "Content: %s..." % c.replace("\n", " ")[:150], "Tags: fixture", ""]
md += ["", "Next steps:", "- Use 'memorygraph get <id>' to see full details"]
open(fx + "/recall.md", "w").write("\n".join(md) + "\n")
for i, t, c in mems:
    open(fx + "/get-%s.md" % i, "w").write(
        "**Memory: %s**\nType: solution\nImportance: 0.8\nTags: fixture\n\n**Content:**\n%s\n" % (t, c))
PY

# expect BODY_INDEXES TITLE_INDEXES — the payload the hook must inject, e.g. `expect 0,1,2 3,4`.
expect() {
    python3 - "$WORK/fx/mems.json" "$1" "$2" <<'PY'
import json, sys
mems = json.load(open(sys.argv[1]))
pick = lambda s: [mems[int(x)] for x in s.split(",") if x != ""]

def trunc(text, limit=1250):
    text = text.strip()
    if len(text) <= limit:
        return text
    cut = text[:limit]
    space = cut.rfind(" ")
    return (cut[:space] if space > limit // 2 else cut).rstrip() + " [truncated]"

parts = ["Stored memories that may be relevant. The top ones are shown in full or truncated; "
         "`memorygraph get <id>` prints one in full.\n"]
parts += ["## %s [%s]\n%s\n" % (t, i, trunc(c)) for i, t, c in pick(sys.argv[2])]
titles = pick(sys.argv[3])
if titles:
    parts.append("Also possibly relevant (title [id]):\n" + "\n".join("- %s [%s]" % (t, i) for i, t, c in titles))
sys.stdout.write("\n".join(parts).rstrip() + "\n")
PY
}

cat > "$WORK/bin/memorygraph" <<'SH'
#!/bin/bash
{ printf '<%s>' "$@"; printf '\n'; } >> "$FIXTURE_ARGV"
[ "$1" = recall ] && echo "${MEMORY_EMBED_TIMEOUT_MS:-unset}" >> "$FIXTURE_ARGV.embed"
echo "Explicit backend selection: Postgres"
echo "Successfully connected to Postgres at 192.0.2.1:5432/memory"
if [ "$1" = recall ] && [ "${#3}" -gt 1000 ]; then
    echo "Validation error: Query exceeds 1000 characters"
    exit 1
fi
hang() { python3 -c 'import time; time.sleep(37)' memory-push-selftest-hang; }
case "$FIXTURE_MODE:$1" in
    hang:* | gethang:get) hang ;;
    escape:*)
        python3 -c 'import os, time; os.setsid(); time.sleep(41)' memory-push-selftest-escapee &
        hang ;;
    error:*) echo "Error: connection refused" >&2; exit 1 ;;
    garbage:*) echo "Something unexpected happened." ;;
    json:recall) cat "$FIXTURE_DIR/recall.json" ;;
    json2:recall) cat "$FIXTURE_DIR/recall2.json" ;;
    markdown:recall | gethang:recall | getpartial:recall | getdrift:recall) cat "$FIXTURE_DIR/recall.md" ;;
    getpartial:get) [ "$2" = 22222222-2222-2222-2222-222222222222 ] && exit 1; cat "$FIXTURE_DIR/get-$2.md" ;;
    getdrift:get) echo "**Memory: $2**"; echo "Body: moved to a new field" ;;
    markdown:get) cat "$FIXTURE_DIR/get-$2.md" ;;
    *) exit 1 ;;
esac
SH
chmod +x "$WORK/bin/memorygraph"

REPO="$WORK/fixture-checkout"
git init -q -b feat-x "$REPO" 2>/dev/null || { git init -q "$REPO" && git -C "$REPO" checkout -q -b feat-x; }
git -C "$REPO" remote add origin "git@github.com:example/Fixture-Repo.git"
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

ARGV="$WORK/argv.log"
OUT="$WORK/out.json"
KEEP_BREAKER=0

# run_hook MODE JSON [ENV=VALUE...] — runs the hook; sets RC, ELAPSED, CONTEXT, EVENT.
# The breaker is cleared first unless KEEP_BREAKER=1.
run_hook() {
    local mode="$1" stdin_json="$2"
    shift 2
    : > "$ARGV"
    : > "$ARGV.embed"
    [ "$KEEP_BREAKER" = 1 ] || rm -f "$WORK/state/breaker"
    local start=$SECONDS
    env PATH="$WORK/bin:$PATH" MEMORY_BACKEND=fixture-nonexistent MEMORY_EMBED_TIMEOUT_MS=5000 \
        FIXTURE_MODE="$mode" FIXTURE_DIR="$WORK/fx" FIXTURE_ARGV="$ARGV" \
        NW_MEMORY_PUSH_STATE="$WORK/state" NW_MEMORY_PUSH_TIMEOUT=2 "$@" \
        bash "$HOOK" <<<"$stdin_json" > "$OUT" 2>"$WORK/err"
    RC=$?
    ELAPSED=$((SECONDS - start))
    CONTEXT="$(jq -r '.hookSpecificOutput.additionalContext // empty' "$OUT" 2>/dev/null)"
    EVENT="$(jq -r '.hookSpecificOutput.hookEventName // empty' "$OUT" 2>/dev/null)"
}
prompt() { jq -cn --arg p "$1" --arg s "$2" '{hook_event_name:"UserPromptSubmit",prompt:$p,session_id:$s}'; }
FULL="$(expect 0,1,2 3,4)"

run_hook json "$(prompt "Push FAILS on GitHub port 22" s1)"
check "UserPromptSubmit json: exit 0" "$RC" 0
check "UserPromptSubmit json: no stderr" "$(cat "$WORK/err")" ""
check "UserPromptSubmit json: hookEventName" "$EVENT" UserPromptSubmit
check "UserPromptSubmit json: recall argv is the raw-case prompt" "$(head -1 "$ARGV")" \
    "<recall><--query><Push FAILS on GitHub port 22><--limit><5><--json>"
check "recall runs with the 1.5 s embed cap, not the caller's 5000" "$(cat "$ARGV.embed")" 1500
check "UserPromptSubmit json: full JSON bodies need no get" "$(wc -l < "$ARGV" | tr -d ' ')" 1
check "UserPromptSubmit json: JSON after the stdout preamble is the configured payload" "$CONTEXT" "$FULL"
BODY1="$(printf '%s\n' "$CONTEXT" | sed -n '4p')"
case "$BODY1" in
    *" [truncated]") pass "body 1 is cut and marked" ;;
    *) fail "body 1 is cut and marked (got ${#BODY1} chars)" ;;
esac
at_most "body 1 is within 1,250 characters plus the marker" "${#BODY1}" 1262

run_hook json "$(prompt "Push FAILS on GitHub port 22" s1)"
check "repeat query in the same session: no recall" "$(cat "$ARGV")" ""
run_hook json2 "$(prompt "a different question" s1)"
check "second query in the session: only memories not yet injected" "$CONTEXT" "$(expect 5,6 "")"
run_hook json "$(prompt "a third question" s1)"
check "nothing new in the session: no output" "$(cat "$OUT")" ""
check "nothing new in the session: recall still ran" "$(grep -c '^<recall>' "$ARGV")" 1
run_hook json "$(prompt "Push FAILS on GitHub port 22" s2)"
check "same query in another session: pushed in full" "$CONTEXT" "$FULL"

ss() { printf '{"hook_event_name":"SessionStart","source":"%s","cwd":"%s","session_id":"%s"}' "$1" "$REPO" "$2"; }
run_hook json "$(ss startup s3)"
check "SessionStart json: recall argv is repo name and branch" "$(head -1 "$ARGV")" \
    "<recall><--query><Fixture-Repo feat-x><--limit><5><--json>"
check "SessionStart json: hookEventName" "$EVENT" SessionStart
check "SessionStart json: configured payload" "$CONTEXT" "$FULL"
run_hook json "$(ss resume s3)"
check "SessionStart resume: nothing re-injected" "$(cat "$OUT")" ""
run_hook json "$(ss compact s3)"
check "SessionStart compact: record reset, pushed in full again" "$CONTEXT" "$FULL"
run_hook json "$(ss clear s3)"
check "SessionStart clear: record reset, pushed in full again" "$CONTEXT" "$FULL"

failure() {
    jq -cn --arg e "$1" --arg t "$2" --argjson i "$3" --arg s "$4" \
        '{hook_event_name:"PostToolUseFailure",tool_name:$t,is_interrupt:$i,error:$e,session_id:$s}'
}
run_hook json "$(failure "fatal: Could not read from remote repository." Bash false s4)"
check "PostToolUseFailure json: recall argv is the error text" "$(head -1 "$ARGV")" \
    "<recall><--query><fatal: Could not read from remote repository.><--limit><5><--json>"
check "PostToolUseFailure json: hookEventName" "$EVENT" PostToolUseFailure
check "PostToolUseFailure json: configured payload" "$CONTEXT" "$FULL"
run_hook json "$(failure "fatal: interrupted" Bash true s5)"
check "PostToolUseFailure with is_interrupt: no recall" "$(cat "$ARGV")" ""
run_hook json "$(failure "File does not exist." Read false s5)"
check "PostToolUseFailure from a non-Bash tool: no recall" "$(cat "$ARGV")" ""

LONG="$(python3 -c 'print("Start of a long prompt " + "x" * 3000 + " end")')"
run_hook json "$(prompt "$LONG" s6)"
check "long prompt: pushed" "$CONTEXT" "$FULL"
check "long prompt: query is the prompt's first 400 characters" \
    "$(python3 -c 'import sys; q = open(sys.argv[1]).read().split("><")[2]; print(len(q), q[:22])' "$ARGV")" \
    "400 Start of a long prompt"
LONG_ERR="$(python3 -c 'print("Exit code 128\n" + "noise line\n" * 300 + "fatal: the real failure")')"
run_hook json "$(failure "$LONG_ERR" Bash false s7)"
check "long error: pushed" "$CONTEXT" "$FULL"
check "long error: query is the error's last 400 characters" \
    "$(python3 -c 'import sys; q = open(sys.argv[1]).read().split("><")[2]; print(len(q) <= 400, q.endswith("fatal: the real failure"))' "$ARGV")" \
    "True True"

run_hook markdown "$(prompt "markdown path" s8)"
check "markdown: configured payload from full get bodies" "$CONTEXT" "$FULL"
check "markdown: get called for exactly the top 3" "$(grep '^<get>' "$ARGV" | sort | tr -d '\n')" \
    "<get><11111111-1111-1111-1111-111111111111><get><22222222-2222-2222-2222-222222222222><get><33333333-3333-3333-3333-333333333333>"

run_hook getpartial "$(prompt "one get fails" s9)"
check "getpartial: the failed body drops to the titles, never a preview" "$CONTEXT" "$(expect 0,2 1,3,4)"
run_hook markdown "$(prompt "later question" s9)"
check "getpartial then later: a memory listed as a title is not injected again" "$(cat "$OUT")" ""
run_hook getdrift "$(prompt "get output drifted" s10)"
check "getdrift: no full body means no injection" "$(cat "$OUT")" ""
run_hook gethang "$(prompt "get hangs" s11)"
check "gethang: exit 0" "$RC" 0
check "gethang: no injection" "$(cat "$OUT")" ""
at_most "gethang: seconds taken with a 2 s budget" "$ELAPSED" 4
KEEP_BREAKER=1
run_hook json "$(prompt "after a push that ran out of budget" s11)"
check "breaker open after gets ran out of budget: no recall" "$(cat "$ARGV")" ""
KEEP_BREAKER=0

for mode in hang error garbage escape; do
    run_hook "$mode" "$(prompt "$mode case" s12)"
    check "$mode: exit 0" "$RC" 0
    check "$mode: no injection" "$(cat "$OUT")" ""
    check "$mode: no stderr" "$(cat "$WORK/err")" ""
    at_most "$mode: seconds taken with a 2 s budget" "$ELAPSED" 4
done
pkill -f 'memory-push-selftest-[e]scapee' >/dev/null 2>&1
run_hook hang "$(ss startup s13)"
check "hang on SessionStart: no injection" "$(cat "$OUT")" ""
at_most "hang on SessionStart: seconds taken with a 2 s budget" "$ELAPSED" 4
run_hook hang "$(failure "fatal: x" Bash false s13)"
check "hang on PostToolUseFailure: no injection" "$(cat "$OUT")" ""
at_most "hang on PostToolUseFailure: seconds taken with a 2 s budget" "$ELAPSED" 4
if pgrep -f 'memory-push-selftest-[h]ang' >/dev/null 2>&1; then
    fail "a timed-out memorygraph is killed, not orphaned"
else
    pass "a timed-out memorygraph is killed, not orphaned"
fi

run_hook hang "$(prompt "the store is black-holed" s14)"
KEEP_BREAKER=1
run_hook json "$(prompt "next prompt" s14)"
check "breaker open after a timeout: no recall" "$(cat "$ARGV")" ""
check "breaker open after a timeout: no output" "$(cat "$OUT")" ""
at_most "breaker open: seconds taken" "$ELAPSED" 1
run_hook json "$(prompt "next prompt" s14)" NW_MEMORY_PUSH_BREAKER=0
check "breaker window over: pushed again" "$CONTEXT" "$FULL"
run_hook error "$(prompt "store refuses" s15)" NW_MEMORY_PUSH_BREAKER=0
run_hook json "$(prompt "after an error" s15)"
check "breaker open after an error: no recall" "$(cat "$ARGV")" ""
KEEP_BREAKER=0
run_hook json "$(prompt "the store is black-holed" s14)"
check "a timed-out query is not recorded as answered: re-run" "$(grep -c '^<recall>' "$ARGV")" 1

run_hook json "$(prompt "opted out" s16)" NW_MEMORY_PUSH=0
check "NW_MEMORY_PUSH=0: no output" "$(cat "$OUT")" ""
check "NW_MEMORY_PUSH=0: no recall" "$(cat "$ARGV")" ""

run_hook json "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"no store\",\"cwd\":\"$WORK/fx\"}" MEMORY_BACKEND=
check "no MEMORY_BACKEND and no ./.memorygraph: no recall" "$(cat "$ARGV")" ""
mkdir -p "$WORK/fx/.memorygraph"
run_hook json "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"local store\",\"cwd\":\"$WORK/fx\"}" MEMORY_BACKEND=
check "no MEMORY_BACKEND but a ./.memorygraph store: pushed" "$CONTEXT" "$FULL"

run_hook json '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
check "other event: no output" "$(cat "$OUT")" ""
run_hook json '{"hook_event_name":"UserPromptSubmit","prompt":"   "}'
check "blank prompt: no recall" "$(cat "$ARGV")" ""
run_hook json 'not json'
check "malformed stdin: exit 0" "$RC" 0
check "malformed stdin: no output" "$(cat "$OUT")" ""

if [ "$FAIL" -eq 0 ]; then
    echo "OK: all $N assertions passed"
    exit 0
fi
echo "FAILED: see FAIL lines above" >&2
exit 1
