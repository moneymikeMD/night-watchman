#!/bin/bash
#
# Assertions for memory-push.sh.
#
# Structurally offline: a fixture `memorygraph` written into a throwaway
# directory is put first on PATH, and MEMORY_BACKEND names a backend no
# real memorygraph has, so neither the fixture nor a stray real CLI can
# reach a store. The fixture's FIXTURE_MODE picks its behaviour:
#
#   json      recall prints fixed JSON with full bodies (no get needed)
#   markdown  recall prints the 0.14 fork's markdown with ~150-char
#             previews; get prints each full body
#   gethang   markdown recall, but every get hangs
#   hang      every call hangs
#   error     every call exits 1
#   garbage   every call prints unparsable text
#
# Asserts, for all three events, that the recall query is the event's
# text in raw case; that additionalContext equals the configured payload
# (top 3 bodies cut at 1,250 characters, then titles 4 and 5); that a
# hang, an error or garbage yields no output and exit 0 inside the time
# budget; repeat suppression; the NW_MEMORY_PUSH=0 opt-out; and the skip
# when no store is configured.
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
trap 'rm -rf "$WORK"' EXIT
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
]
json.dump([{"id": i, "title": t, "content": c} for i, t, c in mems], open(fx + "/recall.json", "w"))
md = ["**Found 5 relevant memories:**", ""]
for n, (i, t, c) in enumerate(mems, 1):
    md += ["**%d. %s** (ID: %s)" % (n, t, i), "Type: solution | Importance: 0.8", "Match: hybrid quality",
           "Content: %s..." % c.replace("\n", " ")[:150], "Tags: fixture", ""]
md += ["", "Next steps:", "- Use 'memorygraph get <id>' to see full details"]
open(fx + "/recall.md", "w").write("\n".join(md) + "\n")
for i, t, c in mems:
    open(fx + "/get-%s.md" % i, "w").write(
        "**Memory: %s**\nType: solution\nImportance: 0.8\nTags: fixture\n\n**Content:**\n%s\n" % (t, c))

def trunc(text, limit=1250):
    text = text.strip()
    if len(text) <= limit:
        return text
    cut = text[:limit]
    space = cut.rfind(" ")
    return (cut[:space] if space > limit // 2 else cut).rstrip() + " [truncated]"

parts = ["Stored memories that may be relevant. The top ones are shown in full or truncated; "
         "`memorygraph get <id>` prints one in full.\n"]
parts += ["## %s [%s]\n%s\n" % (t, i, trunc(c)) for i, t, c in mems[:3]]
parts.append("Also possibly relevant (title [id]):\n" + "\n".join("- %s [%s]" % (t, i) for i, t, c in mems[3:]))
open(fx + "/expected.txt", "w").write("\n".join(parts).rstrip() + "\n")
PY

cat > "$WORK/bin/memorygraph" <<'SH'
#!/bin/bash
{ printf '<%s>' "$@"; printf '\n'; } >> "$FIXTURE_ARGV"
echo "Explicit backend selection: fixture" >&2
if [ "$1" = recall ] && [ "${#3}" -gt 1000 ]; then
    echo "Validation error: Query exceeds 1000 characters"
    exit 1
fi
case "$FIXTURE_MODE:$1" in
    hang:* | gethang:get) sleep 37 ;;
    error:*) echo "Error: connection refused" >&2; exit 1 ;;
    garbage:*) echo "Something unexpected happened." ;;
    json:recall) cat "$FIXTURE_DIR/recall.json" ;;
    markdown:recall | gethang:recall) cat "$FIXTURE_DIR/recall.md" ;;
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

# run_hook MODE JSON [ENV=VALUE...] — runs the hook; sets RC, ELAPSED, CONTEXT, EVENT.
run_hook() {
    local mode="$1" stdin_json="$2"
    shift 2
    : > "$ARGV"
    local start=$SECONDS
    env PATH="$WORK/bin:$PATH" MEMORY_BACKEND=fixture-nonexistent \
        FIXTURE_MODE="$mode" FIXTURE_DIR="$WORK/fx" FIXTURE_ARGV="$ARGV" \
        NW_MEMORY_PUSH_STATE="$WORK/state" NW_MEMORY_PUSH_TIMEOUT=2 "$@" \
        bash "$HOOK" <<<"$stdin_json" > "$OUT" 2>"$WORK/err"
    RC=$?
    ELAPSED=$((SECONDS - start))
    CONTEXT="$(jq -r '.hookSpecificOutput.additionalContext // empty' "$OUT" 2>/dev/null)"
    EVENT="$(jq -r '.hookSpecificOutput.hookEventName // empty' "$OUT" 2>/dev/null)"
}
EXPECTED="$(cat "$WORK/fx/expected.txt")"

run_hook json '{"hook_event_name":"UserPromptSubmit","prompt":"Push FAILS on GitHub port 22","session_id":"s1"}'
check "UserPromptSubmit json: exit 0" "$RC" 0
check "UserPromptSubmit json: hookEventName" "$EVENT" UserPromptSubmit
check "UserPromptSubmit json: recall argv is the raw-case prompt" "$(head -1 "$ARGV")" \
    "<recall><--query><Push FAILS on GitHub port 22><--limit><5><--json>"
check "UserPromptSubmit json: full JSON bodies need no get" "$(wc -l < "$ARGV" | tr -d ' ')" 1
check "UserPromptSubmit json: additionalContext is the configured payload" "$CONTEXT" "$EXPECTED"
BODY1="$(printf '%s\n' "$CONTEXT" | sed -n '4p')"
case "$BODY1" in
    *" [truncated]") pass "body 1 is cut and marked" ;;
    *) fail "body 1 is cut and marked (got ${#BODY1} chars)" ;;
esac
at_most "body 1 is within 1,250 characters plus the marker" "${#BODY1}" 1262

run_hook json '{"hook_event_name":"UserPromptSubmit","prompt":"Push FAILS on GitHub port 22","session_id":"s1"}'
check "repeat prompt in the same session: no output" "$(cat "$OUT")" ""
check "repeat prompt in the same session: no recall" "$(cat "$ARGV")" ""
run_hook json '{"hook_event_name":"UserPromptSubmit","prompt":"Push FAILS on GitHub port 22","session_id":"s2"}'
check "same prompt in another session: pushed" "$CONTEXT" "$EXPECTED"

SS="{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$REPO\",\"session_id\":\"s1\"}"
run_hook json "$SS"
check "SessionStart json: recall argv is repo name and branch" "$(head -1 "$ARGV")" \
    "<recall><--query><Fixture-Repo feat-x><--limit><5><--json>"
check "SessionStart json: hookEventName" "$EVENT" SessionStart
check "SessionStart json: additionalContext is the configured payload" "$CONTEXT" "$EXPECTED"
run_hook json "$SS"
check "SessionStart again in the same session: still pushed" "$CONTEXT" "$EXPECTED"

FAILURE='{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","session_id":"s1","error":"fatal: Could not read from remote repository.","tool_input":{"command":"git push"}}'
run_hook json "$FAILURE"
check "PostToolUseFailure json: recall argv is the error text" "$(head -1 "$ARGV")" \
    "<recall><--query><fatal: Could not read from remote repository.><--limit><5><--json>"
check "PostToolUseFailure json: hookEventName" "$EVENT" PostToolUseFailure
check "PostToolUseFailure json: additionalContext is the configured payload" "$CONTEXT" "$EXPECTED"

LONG="$(python3 -c 'print("Start of a long prompt " + "x" * 3000 + " end")')"
run_hook json "$(jq -cn --arg p "$LONG" '{hook_event_name:"UserPromptSubmit",prompt:$p,session_id:"s7"}')"
check "long prompt: pushed despite memorygraph's 1,000-character query cap" "$CONTEXT" "$EXPECTED"
check "long prompt: query is the prompt's first 1,000 characters" \
    "$(head -1 "$ARGV" | cut -c1-40)" "<recall><--query><Start of a long prompt"
LONG_ERR="$(python3 -c 'print("Exit code 128\n" + "noise line\n" * 300 + "fatal: the real failure")')"
run_hook json "$(jq -cn --arg e "$LONG_ERR" '{hook_event_name:"PostToolUseFailure",tool_name:"Bash",error:$e,session_id:"s7"}')"
check "long error: pushed despite memorygraph's 1,000-character query cap" "$CONTEXT" "$EXPECTED"
if grep -q 'fatal: the real failure><--limit>' "$ARGV"; then
    pass "long error: query keeps the error's last line"
else
    fail "long error: query keeps the error's last line (got $(tail -c 80 "$ARGV"))"
fi

run_hook markdown '{"hook_event_name":"UserPromptSubmit","prompt":"markdown path","session_id":"s3"}'
check "markdown: additionalContext is the configured payload from full get bodies" "$CONTEXT" "$EXPECTED"
check "markdown: get called for exactly the top 3" "$(grep -c '^<get>' "$ARGV")" 3
check "markdown: get ids" "$(grep '^<get>' "$ARGV" | sort | tr -d '\n')" \
    "<get><11111111-1111-1111-1111-111111111111><get><22222222-2222-2222-2222-222222222222><get><33333333-3333-3333-3333-333333333333>"

for mode in hang error garbage; do
    run_hook "$mode" "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"$mode case\",\"session_id\":\"s4\"}"
    check "$mode: exit 0" "$RC" 0
    check "$mode: no injection" "$(cat "$OUT")" ""
    at_most "$mode: seconds taken with a 2 s budget" "$ELAPSED" 4
done
hang_case() {
    run_hook hang "$2"
    check "hang on $1: no injection" "$(cat "$OUT")" ""
    at_most "hang on $1: seconds taken with a 2 s budget" "$ELAPSED" 4
}
hang_case SessionStart "$SS"
hang_case PostToolUseFailure "$FAILURE"
if pgrep -f 'sleep 37' >/dev/null 2>&1; then
    fail "a timed-out memorygraph is killed, not orphaned"
else
    pass "a timed-out memorygraph is killed, not orphaned"
fi

run_hook gethang '{"hook_event_name":"UserPromptSubmit","prompt":"get hangs","session_id":"s5"}'
check "gethang: exit 0" "$RC" 0
at_most "gethang: seconds taken with a 2 s budget" "$ELAPSED" 4
case "$CONTEXT" in
    *"## Third memory [33333333-3333-3333-3333-333333333333]"$'\n'"Third body...."*) pass "gethang: falls back to the recall preview" ;;
    *) fail "gethang: falls back to the recall preview (got [$CONTEXT])" ;;
esac

run_hook json '{"hook_event_name":"UserPromptSubmit","prompt":"opted out","session_id":"s6"}' NW_MEMORY_PUSH=0
check "NW_MEMORY_PUSH=0: no output" "$(cat "$OUT")" ""
check "NW_MEMORY_PUSH=0: no recall" "$(cat "$ARGV")" ""

run_hook json "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"no store\",\"cwd\":\"$WORK/fx\"}" MEMORY_BACKEND=
check "no MEMORY_BACKEND and no ./.memorygraph: no recall" "$(cat "$ARGV")" ""
mkdir -p "$WORK/fx/.memorygraph"
run_hook json "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"local store\",\"cwd\":\"$WORK/fx\"}" MEMORY_BACKEND=
check "no MEMORY_BACKEND but a ./.memorygraph store: pushed" "$CONTEXT" "$EXPECTED"

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
