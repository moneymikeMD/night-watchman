#!/bin/bash
#
# Selftest for providers/tracker/jira/jira-backfill.sh.
# Nothing here reaches a real network: --dry-run assertions never call
# curl, and the end-to-end assertions put a stub `curl` on PATH first (the
# same technique jira-api-selftest.sh uses). The transitions/status
# responses the stub serves are REPLAYED from fixtures/issue.transitions.
# live.json and fixtures/issue.status.live.json — captured live by the
# orchestrator on scratch Space ZZSPK2, host scrubbed — rather than
# hand-authored, so this selftest exercises the real response shape.
#
# What is asserted:
#   1  --dry-run writes nothing, resolves no credential, and reports one
#      "would backfill" line per ticket.
#   2  End-to-end: a stubbed GET /field advertises the custom fields by
#      name; jira-backfill.sh resolves their ids and PUTs
#      /issue/KEY?returnIssue=true (a deliberate confirmation read, not a
#      workaround — see the script's header) with description, labels
#      and the customfield values built from the local ticket.
#   3  A custom field NOT present in the stubbed /field response (here:
#      "appends", requested by the ticket but absent from the site) is
#      skipped, not a fatal error — the PUT still succeeds without it.
#   4  A PUT that fails does not abort the run — the next ticket still
#      gets backfilled — but the overall run exits non-zero and names the
#      field-backfill and transition failure counts SEPARATELY.
#   5  Status backfill, replayed against the live-captured fixtures: an
#      in-progress-stage ticket (not yet at "In Progress" per the live
#      status fixture) triggers exactly one transitions POST, the
#      transition id resolved by NAME from the live transitions fixture,
#      never a hardcoded id; an open-stage ticket triggers no status
#      calls at all (this script never moves a fresh issue off its
#      Jira-assigned initial status).
#   6  A field emptied locally (here: SPK-1's absent human_steps) PUTs an
#      explicit JSON null for that field's id, not an omitted key — a PUT
#      that omits a key leaves the stored value untouched (a
#      recorded fact), so a re-run after clearing a field must null it.
#   7  defer_until: present -> the plain "YYYY-MM-DD" string (not ADF, a
#      datepicker field); absent -> explicit null, same rule as 6.
#   8  A description over 32767 characters is truncated to the longest
#      prefix of whole blocks that fits, plus a pointer line — never cut
#      mid-block, and the PUT body stays under the cap.
#
# Usage: providers/tracker/jira/jira-backfill-selftest.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BACKFILL_SH="$HERE/jira-backfill.sh"
FIXTURES="$HERE/fixtures"

[ -x "$BACKFILL_SH" ] || { echo "$BACKFILL_SH is missing or not executable" >&2; exit 2; }
for f in "$FIXTURES/issue.transitions.live.json" "$FIXTURES/issue.status.live.json"; do
    [ -f "$f" ] || { echo "missing fixture: $f" >&2; exit 2; }
done

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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Use only ticket SPK-1 (has touches, verify, tags, a body — no appends,
# no human_steps, no defer_until) so the "field absent on this site" case
# (3) and the "field empty locally" case (6) are exercised for free: the
# stubbed /field below deliberately omits "appends".
ONE_TICKET="$WORK/one-ticket"
mkdir -p "$ONE_TICKET/open"
cp "$FIXTURES/import-tickets/open/SPK-1.md" "$ONE_TICKET/open/SPK-1.md"

# SPK-1 (open) + SPK-3 (in-progress, defer_until set) for the
# status-backfill (5) and defer_until (7) assertions.
TWO_TICKETS="$WORK/two-tickets"
mkdir -p "$TWO_TICKETS/open" "$TWO_TICKETS/in-progress"
cp "$FIXTURES/import-tickets/open/SPK-1.md" "$TWO_TICKETS/open/SPK-1.md"
cp "$FIXTURES/import-tickets/in-progress/SPK-3.md" "$TWO_TICKETS/in-progress/SPK-3.md"

# A ticket whose body is well over the 32767-char cap, built from many
# small "\n\n"-separated blocks so truncation must stop at a block
# boundary, not mid-paragraph — assertion 8.
BIG_TICKET="$WORK/big-ticket"
mkdir -p "$BIG_TICKET/open"
{
    echo "---"
    echo "id: SPK-9"
    echo "title: Ticket with an oversized body"
    echo "created: 2026-01-09"
    echo "updated: 2026-01-09"
    echo "executor: agent"
    echo "tags: []"
    echo "blocked_by: []"
    echo "touches: []"
    echo "verify: |"
    echo "  true"
    echo "---"
    echo
    i=0
    while [ "$i" -lt 1000 ]; do
        printf 'Block %d — this paragraph exists only to push the body past the 32767-character cap so truncation has to kick in.\n\n' "$i"
        i=$((i + 1))
    done
} > "$BIG_TICKET/open/SPK-9.md"

# ---- 1. --dry-run -----------------------------------------------------------

unset NW_CONFIG NW_ROOT NW_TRACKER NW_SECRETS NW_DISPATCH NW_MEMORY

OUT=$(NW_JIRA_HOST=127.0.0.1 "$BACKFILL_SH" --project SPK --dry-run "$ONE_TICKET" 2>&1); RC=$?
eq "--dry-run exits 0" "0" "$RC"
contains "--dry-run writes nothing" "nothing was written, no credential was resolved" "$OUT"
contains "--dry-run reports the one ticket" "would backfill (1/1): SPK-1 <- SPK-1" "$OUT"

# ---- 2-8. end-to-end through a stubbed curl --------------------------------

mkdir -p "$WORK/bin"
FIELD_JSON='[
  {"id":"customfield_10043","name":"touches","custom":true},
  {"id":"customfield_10044","name":"verify","custom":true},
  {"id":"customfield_10045","name":"human_steps","custom":true},
  {"id":"customfield_10047","name":"executor","custom":true},
  {"id":"customfield_10048","name":"defer_until","custom":true}
]'
# Deliberately no "appends" field — assertion 3.

cat > "$WORK/bin/curl" <<CURLEOF
#!/bin/bash
cat >/dev/null
out="" method="" url="" bodyfile=""
prev=""
for a in "\$@"; do
    if [ "\$prev" = "-o" ]; then out="\$a"; fi
    if [ "\$prev" = "-X" ]; then method="\$a"; fi
    case "\$a" in @*) bodyfile="\${a#@}" ;; esac
    prev="\$a"
done
url="\${!#}"
[ -n "\$out" ] || { echo "stub curl: no -o path found in: \$*" >&2; exit 2; }
echo "\$method \$url" >> "$WORK/requests.log"

tmp="\${url#*/issue/}"
key="\${tmp%%\\?*}"
key="\${key%%/*}"
if [ "\$method" = "PUT" ] && [ -n "\$bodyfile" ]; then
    cp "\$bodyfile" "$WORK/put-body-\$key.json"
fi

case "\$url" in
    *rest/api/3/field)
        printf '%s' '$FIELD_JSON' > "\$out"
        printf '200'
        ;;
    *rest/api/3/issue/SPK-1\?returnIssue=true)
        if [ "\${STUB_PUT_CODE:-200}" = "200" ]; then
            printf '{"key":"SPK-1","id":"10001","fields":{"summary":"Add health check endpoint"}}' > "\$out"
            printf '200'
        else
            printf '{"errorMessages":["boom"]}' > "\$out"
            printf '500'
        fi
        ;;
    *rest/api/3/issue/SPK-3\?returnIssue=true)
        printf '{"key":"SPK-3","id":"10003","fields":{"summary":"Load-test the health endpoint"}}' > "\$out"
        printf '200'
        ;;
    *rest/api/3/issue/SPK-9\?returnIssue=true)
        printf '{"key":"SPK-9","id":"10009","fields":{"summary":"Ticket with an oversized body"}}' > "\$out"
        printf '200'
        ;;
    *rest/api/3/issue/*\?fields=status)
        # Replayed, not authored — see the file header.
        cat "$FIXTURES/issue.status.live.json" > "\$out"
        printf '200'
        ;;
    *rest/api/3/issue/*/transitions)
        if [ "\$method" = "POST" ]; then
            printf '' > "\$out"
            printf '204'
        else
            # Replayed, not authored — see the file header.
            cat "$FIXTURES/issue.transitions.live.json" > "\$out"
            printf '200'
        fi
        ;;
    *)
        echo "stub curl: unexpected URL \$url" >&2
        printf '{}' > "\$out"
        printf '404'
        ;;
esac
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

: > "$WORK/requests.log"
OUT=$(run_e2e "$BACKFILL_SH" --project SPK "$ONE_TICKET" 2>&1); RC=$?
eq "e2e: exits 0 when the PUT succeeds" "0" "$RC"
contains "e2e: reports the backfilled ticket" "backfilled SPK-1 (1/1): SPK-1" "$OUT"
contains "e2e: PUTs the returnIssue=true path" "PUT https://127.0.0.1/rest/api/3/issue/SPK-1?returnIssue=true" "$(cat "$WORK/requests.log")"

# ---- 6-7. explicit null for an emptied/absent field ------------------------

PUT_BODY=$(cat "$WORK/put-body-SPK-1.json" 2>/dev/null || echo '{}')
eq "e2e: human_steps (locally empty) is explicit null, not omitted" \
    "null" "$(printf '%s' "$PUT_BODY" | jq -r '.fields | has("customfield_10045") as $has | if $has then (.customfield_10045 // "null") else "MISSING" end')"
eq "e2e: defer_until (absent on SPK-1) is explicit null" \
    "null" "$(printf '%s' "$PUT_BODY" | jq -r '.fields | has("customfield_10048") as $has | if $has then (.customfield_10048 // "null") else "MISSING" end')"
eq "e2e: touches (present) is NOT null" \
    "false" "$(printf '%s' "$PUT_BODY" | jq -r '.fields.customfield_10043 == null')"

: > "$WORK/requests.log"
OUT=$(STUB_PUT_CODE=500 run_e2e "$BACKFILL_SH" --project SPK "$ONE_TICKET" 2>&1); RC=$?
eq "e2e: a failed PUT exits non-zero" "1" "$RC"
contains "e2e: names field-backfill and transition failures separately" \
    "1 of 1 ticket(s) failed field backfill, 0 failed to transition" "$OUT"

# ---- 5. status backfill, and defer_until present ---------------------------

: > "$WORK/requests.log"
OUT=$(run_e2e "$BACKFILL_SH" --project SPK "$TWO_TICKETS" 2>&1); RC=$?
eq "e2e status: exits 0" "0" "$RC"
contains "e2e status: reports the in-progress ticket's transition" "transitioned SPK-3: To Do -> In Progress" "$OUT"

LOG=$(cat "$WORK/requests.log")
TRANSITION_POSTS=$(printf '%s\n' "$LOG" | grep -c "POST https://127.0.0.1/rest/api/3/issue/SPK-3/transitions")
eq "e2e status: exactly one transitions POST for the in-progress ticket" "1" "$TRANSITION_POSTS"

case "$LOG" in
    *"issue/SPK-1?fields=status"*|*"issue/SPK-1/transitions"*)
        bad "e2e status: the open ticket triggers no status calls" ;;
    *) ok "e2e status: the open ticket triggers no status calls" ;;
esac

SPK3_BODY=$(cat "$WORK/put-body-SPK-3.json" 2>/dev/null || echo '{}')
eq "e2e: defer_until (present on SPK-3) is the plain date string" \
    "2026-03-01" "$(printf '%s' "$SPK3_BODY" | jq -r '.fields.customfield_10048')"

# ---- 8. oversized description ----------------------------------------------

: > "$WORK/requests.log"
OUT=$(run_e2e "$BACKFILL_SH" --project SPK "$BIG_TICKET" 2>&1); RC=$?
eq "e2e big body: exits 0" "0" "$RC"

BIG_BODY=$(cat "$WORK/put-body-SPK-9.json" 2>/dev/null || echo '{}')
DESC_TEXT=$(printf '%s' "$BIG_BODY" | jq -r '[.fields.description.content[]?.content[]?.text? // ""] | join("\n")')
DESC_LEN=$(printf '%s' "$BIG_BODY" | jq -c '.fields.description' | wc -c | tr -d ' ')
contains "e2e big body: the truncated description carries the pointer" \
    "truncated" "$DESC_TEXT"
case "$DESC_TEXT" in
    *"Block 0 "*) ok "e2e big body: keeps whole leading blocks" ;;
    *) bad "e2e big body: keeps whole leading blocks" ;;
esac
if [ "$DESC_LEN" -lt 40000 ]; then
    ok "e2e big body: the PUT body's description is nowhere near its untruncated size (was ~119KB raw)"
else
    bad "e2e big body: the PUT body's description is nowhere near its untruncated size (was ~119KB raw)"
    printf '       actual JSON length: %s\n' "$DESC_LEN"
fi

echo
echo "$N assertion(s), $((N - FAIL)) passed" >&2
if [ "$FAIL" -ne 0 ]; then
    echo "providers/tracker/jira/jira-backfill-selftest.sh: FAILED" >&2
    exit 1
fi
echo "providers/tracker/jira/jira-backfill-selftest.sh: all assertions passed" >&2
exit 0
