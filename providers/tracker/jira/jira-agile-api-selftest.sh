#!/bin/bash
#
# Selftest for jira-agile-api.sh. Runs entirely against a stub `curl` in a
# mktemp -d directory prepended to PATH — never a real Jira site, never a
# real credential, never a real board. JIRA_HOST is pointed at 127.0.0.1 as
# belt and braces on top of the stub.
#
# Fixtures under fixtures/ are real bodies captured live against a real
# Jira Cloud site (a throwaway scratch project, created and deleted, never
# touching a real board) — see each fixture's header comment for the exact
# command. The two synthetic bodies below (WEIRD_STATE_JSON,
# ERROR_CREDSHAPE_JSON) are inline in this file, not under fixtures/, and
# are labelled as synthetic: they test a defensive branch (a sprint state
# Jira has never actually returned) and the redaction machinery itself,
# neither of which a real capture can supply.
#
# What this file proves:
#   1. --dry-run reaches no network (no request, no credential read)
#   2. `write` refuses without --yes and without a terminal
#   3. sprint-close's state-check branch: a 404 (sprint not found) and an
#      unexpected state both exit non-zero with the right message
#   4. a 4xx error body passes through redaction (error_body/redact_json)
#   5. sprint-add-issue's argument handling
#   6. sprint-update builds a partial body from only the flags given, and
#      refuses with none
#   7. sprint-delete's state-check branch: refuses on active/closed/unknown,
#      proceeds on future, and skips the pre-flight GET under --dry-run
#
# Usage: ./jira-agile-api-selftest.sh

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/jira-agile-api.sh"
FIXDIR="$HERE/fixtures"

FAIL=0

check() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) echo "ok   - $desc" ;;
        *) echo "FAIL - $desc (missing: $needle)"; FAIL=1 ;;
    esac
}
check_not() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL - $desc (unexpectedly present: $needle)"; FAIL=1 ;;
        *) echo "ok   - $desc" ;;
    esac
}
assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "ok   - $desc"
    else
        echo "FAIL - $desc (want: $want, got: $got)"
        FAIL=1
    fi
}
assert_nonzero() {
    local desc="$1" rc="$2"
    if [ "$rc" != "0" ]; then
        echo "ok   - $desc (rc=$rc)"
    else
        echo "FAIL - $desc (exited 0)"
        FAIL=1
    fi
}
# assert_nonempty / assert_empty — a "no request was issued" assertion is
# meaningless unless paired with a case proving a request CAN reach the
# same stub.
assert_nonempty() {
    local desc="$1" f="$2"
    if [ -s "$f" ]; then
        echo "ok   - $desc"
    else
        echo "FAIL - $desc (empty — the stub was never reached, this test proves nothing)"
        FAIL=1
    fi
}
assert_empty() {
    local desc="$1" f="$2"
    if [ -s "$f" ]; then
        echo "FAIL - $desc"
        sed 's/^/  unexpected request: /' "$f" >&2
        FAIL=1
    else
        echo "ok   - $desc"
    fi
}

TMPD=$(mktemp -d) || { echo "FAIL - could not create scratch dir" >&2; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

STUBDIR="$TMPD/bin"
mkdir -p "$STUBDIR"

# --------------------------------------------------------------- fixtures
#
# Real captures (see each file's own header for the exact command that
# produced it).
SPRINT_FUTURE="$FIXDIR/sprint.future.txt"
SPRINT_ACTIVE="$FIXDIR/sprint.active.txt"
SPRINT_CLOSED="$FIXDIR/sprint.closed.txt"
# Each fixture's header comment length varies (some cite one command line,
# some cite two, some carry an "HTTP nnn" status line before the body) — the
# strip point is computed from the actual file rather than a hardcoded line
# count, so a future re-recording with a longer header can't silently start
# the JSON body one line early or late.
strip_fixture_header() {
    # Drops comment lines and a lone "HTTP <code>" status line; a JSON body
    # never matches either pattern, so no state machine is needed.
    awk '/^#/{next} /^HTTP [0-9]+$/{next} {print}' "$1"
}
ERROR_NOT_FOUND="$TMPD/error-not-found.json"
strip_fixture_header "$FIXDIR/get.sprint-not-found.txt" > "$ERROR_NOT_FOUND"
CLOSE_FUTURE_REJECTED="$TMPD/close-future-rejected.json"
strip_fixture_header "$FIXDIR/write.close-future-sprint-rejected.txt" > "$CLOSE_FUTURE_REJECTED"
SPRINT_ACTIVE_BODY="$TMPD/sprint-active-body.json"
strip_fixture_header "$SPRINT_ACTIVE" > "$SPRINT_ACTIVE_BODY"
SPRINT_FUTURE_BODY="$TMPD/sprint-future-body.json"
strip_fixture_header "$SPRINT_FUTURE" > "$SPRINT_FUTURE_BODY"
SPRINT_CLOSED_BODY="$TMPD/sprint-closed-body.json"
strip_fixture_header "$SPRINT_CLOSED" > "$SPRINT_CLOSED_BODY"

# SYNTHETIC — Jira has never been observed returning this; it exercises
# do_sprint_close's defensive `*)` branch, which a real capture cannot
# supply because there is no real state value to trigger it with.
WEIRD_STATE_JSON="$TMPD/sprint-weird-state.json"
cat > "$WEIRD_STATE_JSON" <<'JSON'
{"id":99,"state":"quantum","name":"synthetic-not-a-real-jira-state","originBoardId":10}
JSON

# SYNTHETIC — proves error_body's redact_json pass actually redacts a
# credential-shaped key, independent of whether the real agile API has ever
# been observed sending one (it hasn't, per the header note this selftest
# also covers with ERROR_NOT_FOUND / CLOSE_FUTURE_REJECTED above).
ERROR_CREDSHAPE_JSON="$TMPD/error-credshape.json"
cat > "$ERROR_CREDSHAPE_JSON" <<'JSON'
{"errorMessages":["bad request"],"apiToken":"SENTINEL-SHOULD-BE-REDACTED"}
JSON

# --------------------------------------------------------------- stub curl
cat > "$STUBDIR/curl" <<'CURLEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ARGVLOG"
method=""
outfile=""
url=""
databinary=""
prev=""
for a in "$@"; do
    case "$prev" in
        -X|--request) method="$a" ;;
        -o) outfile="$a" ;;
        --data-binary) databinary="$a" ;;
    esac
    case "$a" in
        http://*|https://*) url="$a" ;;
    esac
    prev="$a"
done
[ -n "$method" ] || method="GET"

config_stdin=$(cat)
case "$config_stdin" in
    *'user = "'*) : ;;
    *)
        echo "STUB CURL: no basic-auth config on stdin" >&2
        exit 1
        ;;
esac

body=""
case "$databinary" in
    @*)
        f="${databinary#@}"
        body=$(cat "$f" 2>/dev/null || true)
        ;;
esac

printf '%s\t%s\t%s\n' "$method" "$url" "$body" >> "$REQLOG"

if [ "${STUB_CURL_EXIT:-0}" != "0" ]; then
    printf '000'
    exit "${STUB_CURL_EXIT}"
fi

cat "$STUB_BODY_FILE" > "$outfile"
printf '%s' "${STUB_HTTP_CODE:-200}"
CURLEOF
chmod +x "$STUBDIR/curl"

# --------------------------------------------------------------- run helper
#
# stdin is /dev/null: [ -t 0 ] must read false, so the no-terminal branch of
# the write guard (the one under test in section 2) is reachable rather than
# blocking on a prompt.
run() {
    local name="$1"; shift
    local rc=0
    LAST_REQLOG="$TMPD/$name.reqlog"; : > "$LAST_REQLOG"
    local outf="$TMPD/$name.out" errf="$TMPD/$name.err"
    (
        export PATH="$STUBDIR:$PATH"
        export REQLOG="$LAST_REQLOG"
        export STUB_HTTP_CODE="${STUB_HTTP_CODE:-200}" \
               STUB_CURL_EXIT="${STUB_CURL_EXIT:-0}" \
               STUB_BODY_FILE="${STUB_BODY_FILE:-$SPRINT_ACTIVE_BODY}"
        export JIRA_HOST=127.0.0.1
        export JIRA_AGILE_USER="fixture@example.com" JIRA_AGILE_TOKEN="STUB-API-KEY-KKKK"
        exec "$SCRIPT" "$@"
    ) > "$outf" 2> "$errf" < /dev/null || rc=$?
    LAST_RC="$rc"
    LAST_OUT=$(cat "$outf")
    LAST_ERR=$(cat "$errf")
}

# =================================================================
# 0. baseline — the happy path reaches the stub, so every "no request"
#    assertion below is meaningful.
# =================================================================
STUB_BODY_FILE="$SPRINT_ACTIVE_BODY" run base0 sprint 5
assert_eq "0: sprint view exits 0" "0" "$LAST_RC"
assert_nonempty "0: sprint view actually issued a request" "$LAST_REQLOG"
check "0: request goes to 127.0.0.1" "$(cat "$LAST_REQLOG")" "https://127.0.0.1/rest/agile/1.0/sprint/5"
check "0: prints the active state" "$LAST_OUT" "State:     active"

# =================================================================
# 1. --dry-run reaches no network at all: no request, no credential read.
#    Covers both a plain read-style dry-run flag combo (--dry-run write)
#    and sprint-close's own pre-flight GET, which must be skipped entirely
#    under --dry-run (do_sprint_close's `if [ "$DRY_RUN" != "1" ]` guard).
# =================================================================
run dry1 --dry-run write POST /sprint '{"name":"x","originBoardId":10}'
assert_eq "1a: --dry-run write exits 0" "0" "$LAST_RC"
assert_empty "1a: --dry-run write sends no request" "$LAST_REQLOG"
check "1a: --dry-run prints what it would have sent" "$LAST_ERR" "would issue:"

run dry2 --dry-run sprint-close 5
assert_eq "1b: --dry-run sprint-close exits 0" "0" "$LAST_RC"
assert_empty "1b: --dry-run sprint-close never runs the pre-flight state GET" "$LAST_REQLOG"

run dry3 --dry-run sprint-start 5
assert_eq "1c: --dry-run sprint-start exits 0" "0" "$LAST_RC"
assert_empty "1c: --dry-run sprint-start sends no request" "$LAST_REQLOG"

run dry4 --dry-run sprint-update 5 --goal "ship it"
assert_eq "1d: --dry-run sprint-update exits 0" "0" "$LAST_RC"
assert_empty "1d: --dry-run sprint-update sends no request" "$LAST_REQLOG"

run dry5 --dry-run sprint-delete 5
assert_eq "1e: --dry-run sprint-delete exits 0" "0" "$LAST_RC"
assert_empty "1e: --dry-run sprint-delete never runs the pre-flight state GET" "$LAST_REQLOG"

# =================================================================
# 2. write refuses without --yes and without a terminal (run's stdin is
#    /dev/null, so have_terminal is false here).
# =================================================================
run noyes1 write POST /sprint '{"name":"x","originBoardId":10}'
assert_nonzero "2a: write with no --yes and no terminal is refused" "$LAST_RC"
assert_empty "2a: refused write sends no request" "$LAST_REQLOG"
check "2a: refusal names the reason" "$LAST_ERR" "no terminal"

run noyes2 sprint-create 10 "some sprint"
assert_nonzero "2b: sprint-create (a write) is refused the same way" "$LAST_RC"
assert_empty "2b: refused sprint-create sends no request" "$LAST_REQLOG"

STUB_HTTP_CODE=201 run yes1 --yes write POST /sprint '{"name":"x","originBoardId":10}'
assert_eq "2c: --yes clears the same guard (positive control)" "0" "$LAST_RC"
assert_nonempty "2c: --yes actually sends the request" "$LAST_REQLOG"

# =================================================================
# 3. sprint-close's state-check branch: a 404 (sprint not found) and each
#    terminal/defensive state give a non-zero exit and the right message.
#    Also exercises the die-inside-pipe reliance on `set -o pipefail` (see
#    the call site's comment in jira-agile-api.sh): a non-2xx from the
#    pre-flight GET must still make sprint-close exit non-zero even though
#    it sits inside `api ... | jq` inside a command substitution.
# =================================================================
STUB_HTTP_CODE=404 STUB_BODY_FILE="$ERROR_NOT_FOUND" run close404 sprint-close 999999999
assert_nonzero "3a: sprint-close on a 404 (sprint not found) exits non-zero" "$LAST_RC"
assert_nonempty "3a: the pre-flight GET actually ran" "$LAST_REQLOG"
check "3a: message names the failure, not a silent no-op" "$LAST_ERR" "could not read current state"

STUB_HTTP_CODE=200 STUB_BODY_FILE="$SPRINT_FUTURE_BODY" run closefuture sprint-close 5
assert_nonzero "3b: sprint-close on a 'future' sprint refuses (not force-start)" "$LAST_RC"
check "3b: message says to run sprint-start first" "$LAST_ERR" "run sprint-start"
check_not "3b: refusal never itself issues the close POST" "$(cat "$LAST_REQLOG")" "POST"

STUB_HTTP_CODE=200 STUB_BODY_FILE="$SPRINT_CLOSED_BODY" run closeclosed sprint-close 5
assert_nonzero "3c: sprint-close on an already-closed sprint refuses" "$LAST_RC"
check "3c: message says already closed" "$LAST_ERR" "already closed"

STUB_HTTP_CODE=200 STUB_BODY_FILE="$WEIRD_STATE_JSON" run closeweird sprint-close 99
assert_nonzero "3d: sprint-close on an unrecognised state refuses (synthetic — no real state does this)" "$LAST_RC"
check "3d: message names the unexpected state" "$LAST_ERR" "unexpected state 'quantum'"

STUB_HTTP_CODE=400 STUB_BODY_FILE="$CLOSE_FUTURE_REJECTED" run closefuturedirect --yes write POST /sprint/6 '{"state":"closed"}'
assert_nonzero "3e: Jira's own rejection of a direct future->closed write exits non-zero" "$LAST_RC"
check "3e: the real Jira error body is what's shown" "$LAST_ERR" "You must specify a start date"

# =================================================================
# 4. a 4xx error body is redacted before printing. ERROR_CREDSHAPE_JSON is
#    synthetic (see its definition above); the two real captures
#    (ERROR_NOT_FOUND, CLOSE_FUTURE_REJECTED) prove the shapes actually
#    seen live carry nothing redactable — this case proves the redaction
#    path still fires when something redactable IS present.
# =================================================================
STUB_HTTP_CODE=400 STUB_BODY_FILE="$ERROR_CREDSHAPE_JSON" run credshape raw GET /sprint/1
assert_nonzero "4a: the credential-shaped error body still exits non-zero" "$LAST_RC"
check_not "4a: the credential-shaped field is redacted out of the error output" "$LAST_ERR" "SENTINEL-SHOULD-BE-REDACTED"

STUB_HTTP_CODE=404 STUB_BODY_FILE="$ERROR_NOT_FOUND" run realerr raw GET /sprint/999999999
assert_nonzero "4b: the real captured 404 body still exits non-zero" "$LAST_RC"
check "4b: the real error message passes through" "$LAST_ERR" "We could not find the sprint"

# =================================================================
# 5. sprint-add-issue's argument handling — needs at least one issue key,
#    and batches every key given into one request rather than looping.
# =================================================================
run addissue0 sprint-add-issue 7
assert_nonzero "5a: sprint-add-issue with no issue keys is refused" "$LAST_RC"
check "5a: message names what's missing" "$LAST_ERR" "needs a sprint id and at least one issue key"
assert_empty "5a: refused sprint-add-issue sends no request" "$LAST_REQLOG"

STUB_HTTP_CODE=201 run addissue1 --yes sprint-add-issue 7 PROJ-1 PROJ-2
assert_eq "5b: sprint-add-issue with keys succeeds" "0" "$LAST_RC"
check "5b: both keys land in the single POST body" "$(cat "$LAST_REQLOG")" '"PROJ-1"'
check "5b: both keys land in the single POST body" "$(cat "$LAST_REQLOG")" '"PROJ-2"'
assert_eq "5b: exactly one request was sent for the batch" "1" "$(grep -c '^POST	' "$LAST_REQLOG")"

# =================================================================
# 6. sprint-update: a partial body built only from the flags given, and a
#    refusal when none are given at all.
# =================================================================
run update0 sprint-update 7
assert_nonzero "6a: sprint-update with no flags is refused" "$LAST_RC"
check "6a: message names what's missing" "$LAST_ERR" "needs at least one of --name, --goal, --start, --end"
assert_empty "6a: refused sprint-update sends no request" "$LAST_REQLOG"

STUB_HTTP_CODE=200 run update1 --yes sprint-update 7 --goal "ship it"
assert_eq "6b: sprint-update with --goal alone succeeds" "0" "$LAST_RC"
check "6b: goal lands in the PUT body" "$(cat "$LAST_REQLOG")" '"goal": "ship it"'
check_not "6b: name is not sent when --name was not given" "$(cat "$LAST_REQLOG")" '"name"'
assert_eq "6b: request method is PUT" "1" "$(grep -c '^PUT	' "$LAST_REQLOG")"

STUB_HTTP_CODE=200 run update2 --yes sprint-update 7 --name "Renamed" --goal "g" --start 2026-09-13T00:00:00.000Z --end 2026-09-20T00:00:00.000Z
assert_eq "6c: sprint-update with all four flags succeeds" "0" "$LAST_RC"
check "6c: name lands in the body" "$(cat "$LAST_REQLOG")" '"name": "Renamed"'
check "6c: startDate lands in the body" "$(cat "$LAST_REQLOG")" '"startDate": "2026-09-13T00:00:00.000Z"'
check "6c: endDate lands in the body" "$(cat "$LAST_REQLOG")" '"endDate": "2026-09-20T00:00:00.000Z"'

# =================================================================
# 7. sprint-delete's state-check branch — mirrors sprint-close's section 3
#    but the polarity is reversed: 'future' proceeds, active/closed refuse.
# =================================================================
STUB_HTTP_CODE=200 STUB_BODY_FILE="$SPRINT_FUTURE_BODY" run delfuture --yes sprint-delete 5
assert_eq "7a: sprint-delete on a 'future' sprint succeeds" "0" "$LAST_RC"
assert_eq "7a: exactly two requests (state GET, then DELETE)" "2" "$(wc -l < "$LAST_REQLOG" | tr -d ' ')"
assert_eq "7a: the second request is the DELETE" "1" "$(grep -c '^DELETE	' "$LAST_REQLOG")"

STUB_HTTP_CODE=200 STUB_BODY_FILE="$SPRINT_ACTIVE_BODY" run delactive sprint-delete 5
assert_nonzero "7b: sprint-delete on an 'active' sprint refuses" "$LAST_RC"
check "7b: message points at sprint-close instead" "$LAST_ERR" "use sprint-close"
check_not "7b: refusal never itself issues the DELETE" "$(cat "$LAST_REQLOG")" "DELETE"

STUB_HTTP_CODE=200 STUB_BODY_FILE="$SPRINT_CLOSED_BODY" run delclosed sprint-delete 5
assert_nonzero "7c: sprint-delete on an already-closed sprint refuses" "$LAST_RC"
check "7c: message says already closed" "$LAST_ERR" "already 'closed'"

STUB_HTTP_CODE=404 STUB_BODY_FILE="$ERROR_NOT_FOUND" run del404 sprint-delete 999999999
assert_nonzero "7d: sprint-delete on a 404 (sprint not found) exits non-zero" "$LAST_RC"
check "7d: message names the failure" "$LAST_ERR" "could not read current state"

echo
if [ "$FAIL" = "0" ]; then
    echo "jira-agile-api-selftest: all checks passed"
    exit 0
fi
echo "jira-agile-api-selftest: FAILURES above" >&2
exit 1
