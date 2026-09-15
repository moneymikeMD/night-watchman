#!/bin/bash
#
# Selftest for providers/tracker/jira/{jira-api.sh,provider.sh,lib/*}.
# Nothing here reaches a real network or a real 1Password vault: the
# --dry-run assertions never call curl at all (that is what --dry-run
# means), and every assertion that does exercise the HTTP layer puts a
# stub `curl` on PATH first, so even $NW_JIRA_HOST=127.0.0.1 (used
# throughout, mainly to keep the fixtures below realistic-looking) is
# never actually dialed — the stub, not the host, is what makes this
# network-free.
#
# What is asserted, in order:
#   1  lib/jira-common.sh: require_issue_key accepts PROJECT-123, rejects
#      a bare project, and rejects a key carrying '/' or other
#      non-[A-Za-z0-9_-] characters (the path-traversal shape).
#   2  lib/jira-common.sh: jira_comment_body builds one ADF paragraph per
#      input line and strips trailing newlines.
#   3  --dry-run prints the exact request and exits 0 without ever
#      reaching curl, for every subcommand with a DRY_RUN branch: raw,
#      whoami, projects, fields, statuses, issue, search, comment, write.
#   4  jira-api.sh raw refuses a path containing '..'.
#   5  jira-api.sh write/comment refuse to run with no --yes and no
#      terminal.
#   6  End-to-end happy path through a stubbed curl + the real `env`
#      secrets provider: a 2xx response is redacted before printing, EXCEPT
#      an issue's own `key`/`id` fields (fetch's read path and create's
#      write-readback both survive redaction intact — the CRITICAL fix).
#   7  End-to-end: a non-2xx response dies non-zero and prints the
#      (redacted) error body.
#   8  provider.sh dispatches fetch/transition/comment/create to
#      jira-api.sh with the arguments the contract implies, refuses an
#      unknown verb, and — under NW_DRY_RUN=1 or --dry-run — passes
#      --dry-run through instead of --yes (the HIGH fix).
#
# Usage: providers/tracker/jira/jira-api-selftest.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
JIRA_API="$HERE/jira-api.sh"
PROVIDER_SH="$HERE/provider.sh"
JIRA_COMMON="$HERE/lib/jira-common.sh"

for f in "$JIRA_API" "$PROVIDER_SH"; do
    [ -x "$f" ] || { echo "$f is missing or not executable" >&2; exit 2; }
done
[ -f "$JIRA_COMMON" ] || { echo "$JIRA_COMMON is missing" >&2; exit 2; }

N=0
FAIL=0
ok()  { N=$((N + 1)); echo "ok - $1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else
        bad "$1"
        printf '       expected: %s\n' "$2"
        printf '       actual:   %s\n' "$3"
    fi
}

contains() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) bad "$1"; printf '       wanted substring: %s\n       in: %s\n' "$2" "$3" ;;
    esac
}

not_contains() {
    case "$3" in
        *"$2"*) bad "$1"; printf '       unwanted substring: %s\n       in: %s\n' "$2" "$3" ;;
        *) ok "$1" ;;
    esac
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- 1-2. lib/jira-common.sh --------------------------------------------

OUT=$(bash -c '
    . "'"$JIRA_COMMON"'"
    require_issue_key "PROJ-123" && echo ok
')
eq "require_issue_key accepts PROJECT-123" "ok" "$OUT"

OUT=$(bash -c '
    . "'"$JIRA_COMMON"'"
    require_issue_key "PROJ" || echo "$JIRA_KEY_ERR"
')
contains "require_issue_key rejects a bare project" "not a Jira key" "$OUT"

OUT=$(bash -c '
    . "'"$JIRA_COMMON"'"
    require_issue_key "PROJ-1/../x" || echo "$JIRA_KEY_ERR"
')
contains "require_issue_key rejects a key carrying '/'" "not letters, digits" "$OUT"

OUT=$(bash -c '
    . "'"$JIRA_COMMON"'"
    jira_comment_body "line one

line three"
' | jq -c '.body.content')
eq "jira_comment_body: one paragraph per line, blank line included" \
    '[{"type":"paragraph","content":[{"type":"text","text":"line one"}]},{"type":"paragraph","content":[]},{"type":"paragraph","content":[{"type":"text","text":"line three"}]}]' \
    "$OUT"

# ---- 3. --dry-run resolves no credential, on every subcommand that has a
#         DRY_RUN branch -----------------------------------------------------

mkdir -p "$WORK/bin"
unset NW_CONFIG NW_ROOT NW_TRACKER NW_SECRETS NW_DISPATCH NW_MEMORY

OUT=$(NW_JIRA_HOST=127.0.0.1 "$JIRA_API" --dry-run raw GET /myself 2>&1); RC=$?
eq "--dry-run raw exits 0" "0" "$RC"
contains "--dry-run raw prints the exact request" "would issue: GET https://127.0.0.1/rest/api/3/myself" "$OUT"

OUT=$(NW_JIRA_HOST=127.0.0.1 "$JIRA_API" --dry-run whoami 2>&1); RC=$?
eq "--dry-run whoami exits 0" "0" "$RC"
contains "--dry-run whoami prints the exact request" "would issue: GET https://127.0.0.1/rest/api/3/myself" "$OUT"

OUT=$(NW_JIRA_HOST=127.0.0.1 "$JIRA_API" --dry-run projects 2>&1); RC=$?
eq "--dry-run projects exits 0" "0" "$RC"
contains "--dry-run projects prints the exact request" "would issue: GET https://127.0.0.1/rest/api/3/project/search?maxResults=200" "$OUT"

OUT=$(NW_JIRA_HOST=127.0.0.1 "$JIRA_API" --dry-run fields 2>&1); RC=$?
eq "--dry-run fields exits 0" "0" "$RC"
contains "--dry-run fields prints the exact request" "would issue: GET https://127.0.0.1/rest/api/3/field" "$OUT"

OUT=$(NW_JIRA_HOST=127.0.0.1 "$JIRA_API" --dry-run statuses PROJ 2>&1); RC=$?
eq "--dry-run statuses exits 0" "0" "$RC"
contains "--dry-run statuses prints the exact request" "would issue: GET https://127.0.0.1/rest/api/3/project/PROJ/statuses" "$OUT"

OUT=$(NW_JIRA_HOST=127.0.0.1 "$JIRA_API" --dry-run issue PROJ-1 2>&1); RC=$?
eq "--dry-run issue exits 0" "0" "$RC"
contains "--dry-run issue prints the exact request" "would issue: GET https://127.0.0.1/rest/api/3/issue/PROJ-1" "$OUT"

OUT=$(NW_JIRA_HOST=127.0.0.1 "$JIRA_API" --dry-run search PROJ 2>&1); RC=$?
eq "--dry-run search exits 0" "0" "$RC"
contains "--dry-run search prints the exact request" "would issue: GET https://127.0.0.1/rest/api/3/search/jql" "$OUT"

OUT=$(NW_JIRA_HOST=127.0.0.1 "$JIRA_API" --dry-run comment PROJ-1 "a note" 2>&1); RC=$?
eq "--dry-run comment exits 0" "0" "$RC"
contains "--dry-run comment prints the exact request" "would issue: POST https://127.0.0.1/rest/api/3/issue/PROJ-1/comment" "$OUT"
contains "--dry-run comment says nothing was sent" "nothing was sent, no credential was resolved" "$OUT"

OUT=$(NW_JIRA_HOST=127.0.0.1 "$JIRA_API" --dry-run write POST /field '{"name":"x"}' 2>&1); RC=$?
eq "--dry-run write exits 0" "0" "$RC"
contains "--dry-run write prints the exact request" "would issue: POST https://127.0.0.1/rest/api/3/field" "$OUT"
contains "--dry-run write says nothing was sent" "nothing was sent, no credential was resolved" "$OUT"

# ---- 4. path validation --------------------------------------------------

ERR=$( ( NW_JIRA_HOST=127.0.0.1 "$JIRA_API" raw GET '/issue/../project' ) 2>&1 ); RC=$?
eq "raw refuses a path containing '..'" "1" "$RC"
contains "raw refuses a path containing '..' by name" "contain no '..'" "$ERR"

# ---- 5. write guard, no terminal -----------------------------------------

ERR=$( ( NW_JIRA_HOST=127.0.0.1 "$JIRA_API" write POST /field '{}' </dev/null ) 2>&1 ); RC=$?
eq "write with no --yes and no terminal refuses" "1" "$RC"
contains "write's refusal names the missing confirmation" "needs confirmation and there is no terminal" "$ERR"

# ---- 6-7. end-to-end through a stubbed curl + the real env provider ------

cat > "$WORK/bin/curl" <<'CURLEOF'
#!/bin/bash
# Stand-in for curl. Reads and discards --config - (the auth config on
# stdin), finds the -o output path and writes $STUB_BODY there, and prints
# $STUB_CODE in place of curl's own -w '%{http_code}' expansion.
cat >/dev/null
out=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-o" ]; then out="$a"; fi
    prev="$a"
done
[ -n "$out" ] || { echo "stub curl: no -o path found in: $*" >&2; exit 2; }
printf '%s' "$STUB_BODY" > "$out"
printf '%s' "$STUB_CODE"
CURLEOF
chmod +x "$WORK/bin/curl"

run_e2e() {
    ( export PATH="$WORK/bin:$PATH"
      export NW_JIRA_HOST=127.0.0.1
      export NW_SECRETS=env
      export NW_JIRA_USER=testuser NW_JIRA_TOKEN=testtoken
      unset NW_CONFIG NW_ROOT NW_TRACKER
      "$@" )
}

OUT=$(STUB_CODE="200" STUB_BODY='{"displayName":"Test User","apiToken":"shhh"}' \
    run_e2e "$JIRA_API" raw GET /myself)
eq "e2e 2xx: the real field survives" "Test User" "$(printf '%s' "$OUT" | jq -r .displayName)"
eq "e2e 2xx: a credential-shaped field is redacted" "<redacted>" "$(printf '%s' "$OUT" | jq -r .apiToken)"

ERR=$(STUB_CODE="400" STUB_BODY='{"errorMessages":["field X is required"]}' \
    run_e2e "$JIRA_API" raw GET /myself 2>&1 </dev/null); RC=$?
eq "e2e non-2xx: dies non-zero" "1" "$RC"
contains "e2e non-2xx: prints HTTP code and method/path" "HTTP 400 GET /myself" "$ERR"
contains "e2e non-2xx: prints the (redacted, here unchanged) error body" "field X is required" "$ERR"

# `issue` accepts a bare numeric issue id, not only a PROJECT-123
# key — Jira's own issueIdOrKey path segment takes either shape, and a
# create-readback (provider.sh create) only ever has the numeric id.
OUT=$(STUB_CODE="200" STUB_BODY='{"key":"PROJ-9","fields":{"summary":"numeric id fetch"}}' \
    run_e2e "$JIRA_API" issue 10504)
contains "e2e issue: a numeric issue id resolves" "numeric id fetch" "$OUT"

ERR=$( ( run_e2e "$JIRA_API" --dry-run issue 'notakey' ) 2>&1 ); RC=$?
eq "issue: a non-numeric, non-key string is still refused" "1" "$RC"
contains "issue: refusal names it as not a Jira key" "not a Jira key" "$ERR"

# error_body's non-JSON fallback must redact too — a raw `cat` here
# would leak a credential-shaped value straight from an HTML/plain-text
# error page (e.g. a proxy's 502 in front of Jira that happens to echo an
# Authorization header back).
ERR=$(STUB_CODE="502" STUB_BODY=$'<html><body>Authorization: Basic SENTINEL-502-LEAK</body></html>' \
    run_e2e "$JIRA_API" raw GET /myself 2>&1 </dev/null); RC=$?
eq "e2e non-2xx, non-JSON body: dies non-zero" "1" "$RC"
contains "e2e non-2xx, non-JSON body: names it HTTP 502" "HTTP 502" "$ERR"
not_contains "e2e non-2xx, non-JSON body: the credential-shaped value is redacted" "SENTINEL-502-LEAK" "$ERR"
contains "e2e non-2xx, non-JSON body: redaction marker present" "<redacted>" "$ERR"

# review round: redact_text must fail CLOSED rather than try to
# find a value's real end with a delimiter class — any such class is
# incomplete and lets the value's TAIL past the false stop print in clear.
# Three adversarial shapes, each asserting the WHOLE sentinel (prefix AND
# tail) is absent, not just the prefix a truncating pattern would still
# catch:

# (a) an escaped quote inside a value, in a body that is JSON-*shaped* but
# fails jq's strict parse (trailing garbage after the top-level value — a
# truncated/garbled proxy response is exactly this shape) and so falls to
# redact_text, not redact_json. The old `[^"]*` value-stop pattern stopped
# at the escaped quote's own `"`, leaking everything after it.
ERR=$(STUB_CODE="400" STUB_BODY=$'{"apiToken":"SENTINEL-ESCQUOTE\\"TAIL"} trailing garbage' \
    run_e2e "$JIRA_API" raw GET /myself 2>&1 </dev/null); RC=$?
eq "e2e non-2xx, escaped-quote value: dies non-zero" "1" "$RC"
not_contains "e2e non-2xx, escaped-quote value: sentinel prefix absent" "SENTINEL-ESCQUOTE" "$ERR"
not_contains "e2e non-2xx, escaped-quote value: sentinel tail past the escaped quote is absent" "TAIL" "$ERR"
contains "e2e non-2xx, escaped-quote value: redaction marker present" "<redacted>" "$ERR"

# (b) a comma inside a plain key=value's value — the old `[^,;]`-excluding
# class stopped at the comma, leaking the tail.
ERR=$(STUB_CODE="400" STUB_BODY='token=SENTINEL-COMMA,TAIL' \
    run_e2e "$JIRA_API" raw GET /myself 2>&1 </dev/null); RC=$?
eq "e2e non-2xx, comma in value: dies non-zero" "1" "$RC"
not_contains "e2e non-2xx, comma in value: sentinel prefix absent" "SENTINEL-COMMA" "$ERR"
not_contains "e2e non-2xx, comma in value: sentinel tail past the comma is absent" "TAIL" "$ERR"
contains "e2e non-2xx, comma in value: redaction marker present" "<redacted>" "$ERR"

# (c) a semicolon inside a Cookie header's value — Cookie/Authorization
# headers routinely contain ';', which the old pattern also excluded from
# the value class.
ERR=$(STUB_CODE="400" STUB_BODY='Cookie: session=SENTINEL-SEMI;TAIL; path=/' \
    run_e2e "$JIRA_API" raw GET /myself 2>&1 </dev/null); RC=$?
eq "e2e non-2xx, semicolon in Cookie value: dies non-zero" "1" "$RC"
not_contains "e2e non-2xx, semicolon in Cookie value: sentinel prefix absent" "SENTINEL-SEMI" "$ERR"
not_contains "e2e non-2xx, semicolon in Cookie value: sentinel tail past the semicolon is absent" "TAIL" "$ERR"
contains "e2e non-2xx, semicolon in Cookie value: redaction marker present" "<redacted>" "$ERR"

# The CRITICAL regression this guards against: a bare Jira issue `key`
# field must survive redact_json, on both the read path (fetch -> raw GET)
# and the write path (create -> write POST's readback), or a caller like
# provider.sh fetch/create gets "<redacted>" back where it needed the real
# key (memorygraph, 2026-09-11, the jira-import.sh KEY READBACK gotcha).
OUT=$(STUB_CODE="200" STUB_BODY='{"key":"PROJ-1","id":"10042","fields":{"summary":"hi"}}' \
    run_e2e "$JIRA_API" raw GET /issue/PROJ-1)
eq "e2e fetch: the issue's own 'key' field is NOT redacted" "PROJ-1" "$(printf '%s' "$OUT" | jq -r .key)"
eq "e2e fetch: the issue's own 'id' field is NOT redacted" "10042" "$(printf '%s' "$OUT" | jq -r .id)"

OUT=$(STUB_CODE="201" STUB_BODY='{"key":"PROJ-2","id":"10099"}' \
    run_e2e "$JIRA_API" --yes write POST /issue '{"fields":{}}' </dev/null)
eq "e2e create readback: the new issue's 'key' field is NOT redacted" "PROJ-2" "$(printf '%s' "$OUT" | jq -r .key)"

# ---- 8. provider.sh dispatch ----------------------------------------------

mkdir -p "$WORK/dispatch"
cat > "$WORK/dispatch/jira-api.sh" <<'STUBEOF'
#!/bin/bash
printf '%s\n' "$*"
STUBEOF
chmod +x "$WORK/dispatch/jira-api.sh"
cp "$PROVIDER_SH" "$WORK/dispatch/provider.sh"
chmod +x "$WORK/dispatch/provider.sh"

OUT=$("$WORK/dispatch/provider.sh" fetch PROJ-1)
eq "provider.sh fetch dispatches raw GET /issue/KEY" "raw GET /issue/PROJ-1" "$OUT"

OUT=$("$WORK/dispatch/provider.sh" transition PROJ-1 31)
eq "provider.sh transition dispatches a transitions POST with the id" \
    '--yes write POST /issue/PROJ-1/transitions {"transition":{"id":"31"}}' "$OUT"

OUT=$("$WORK/dispatch/provider.sh" comment PROJ-1 "hello")
eq "provider.sh comment dispatches --yes comment KEY TEXT" "--yes comment PROJ-1 hello" "$OUT"

OUT=$("$WORK/dispatch/provider.sh" create PROJ Task "a new ticket")
eq "provider.sh create dispatches a create POST" \
    '--yes write POST /issue {"fields":{"project":{"key":"PROJ"},"issuetype":{"name":"Task"},"summary":"a new ticket"}}' "$OUT"

ERR=$("$PROVIDER_SH" bogus 2>&1); RC=$?
eq "provider.sh refuses an unknown verb" "1" "$RC"
contains "provider.sh names the legal verb set" "fetch, transition, comment, create" "$ERR"

# HIGH: NW_DRY_RUN=1 (and --dry-run) must reach jira-api.sh as --dry-run,
# never --yes — a live write must not slip through under either spelling.
OUT=$(NW_DRY_RUN=1 "$WORK/dispatch/provider.sh" comment PROJ-1 "hello")
eq "NW_DRY_RUN=1: provider.sh comment passes --dry-run, not --yes" "--dry-run comment PROJ-1 hello" "$OUT"

OUT=$("$WORK/dispatch/provider.sh" --dry-run transition PROJ-1 31)
eq "--dry-run flag: provider.sh transition passes --dry-run, not --yes" \
    '--dry-run write POST /issue/PROJ-1/transitions {"transition":{"id":"31"}}' "$OUT"

OUT=$(NW_DRY_RUN=1 "$WORK/dispatch/provider.sh" create PROJ Task "a new ticket")
eq "NW_DRY_RUN=1: provider.sh create passes --dry-run, not --yes" \
    '--dry-run write POST /issue {"fields":{"project":{"key":"PROJ"},"issuetype":{"name":"Task"},"summary":"a new ticket"}}' "$OUT"

echo
echo "$N assertion(s), $((N - FAIL)) passed" >&2
if [ "$FAIL" -ne 0 ]; then
    echo "providers/tracker/jira/jira-api-selftest.sh: FAILED" >&2
    exit 1
fi
echo "providers/tracker/jira/jira-api-selftest.sh: all assertions passed" >&2
exit 0
