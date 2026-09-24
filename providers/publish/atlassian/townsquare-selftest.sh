#!/bin/bash
#
# Selftest for providers/publish/atlassian/townsquare.sh and the Atlas half
# of provider.sh (post-headline). Structurally offline: a stub `curl` is
# first on PATH for every run that could issue a request, the host is
# 127.0.0.1, credentials come from the `env` secrets provider with
# throwaway values, and the stub answers from fixtures/townsquare/
# (responses recorded live, then de-identified — see each file's header).
# The harness is lib/test-harness.sh, shared with confluence-selftest.sh.
#
# Usage: providers/publish/atlassian/townsquare-selftest.sh

set -uo pipefail

# shellcheck source=lib/test-harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/test-harness.sh"

strip "$FIX/townsquare/update.success.json"   > "$WORK/update.ok.json"
strip "$FIX/townsquare/update.invalid-adf.json" > "$WORK/update.adf.json"
strip "$FIX/townsquare/update.error.invalid-ari.json" > "$WORK/update.ari.json"
strip "$FIX/townsquare/learning.success.json"  > "$WORK/learning.ok.json"
strip "$FIX/townsquare/learning.invalid-adf.json" > "$WORK/learning.adf.json"
strip "$FIX/townsquare/risk.success.json"      > "$WORK/risk.ok.json"
strip "$FIX/townsquare/decision.success.json"  > "$WORK/decision.ok.json"
strip "$FIX/townsquare/about.success.json"     > "$WORK/about.ok.json"
strip "$FIX/townsquare/about.invalid-adf.json" > "$WORK/about.adf.json"
check_fixtures

dry "$PROVIDER" post-headline default "Shipped publishing" "https://127.0.0.1/wiki/x/AB"
eq "dry post-headline exits 0" "0" "$RC"
eq "dry post-headline issues no request" "0" "$(reqs)"
contains "dry post-headline targets the default feed" "project/default-feed" "$ERR"

for sub in whoami projects; do
    dry "$TSQ" "$sub"
    eq "dry townsquare.sh $sub exits 0 with no request" "0:0" "$RC:$(reqs)"
done
for sub in about learning decision risk; do
    dry "$TSQ" "$sub" --dry-run
    eq "dry townsquare.sh $sub --dry-run exits 0 with no request" "0:0" "$RC:$(reqs)"
    contains "dry townsquare.sh $sub --dry-run says what it would do" "would issue" "$ERR"
done

HTXT="$WORK/highlight.txt"
printf 'Short headline\nLonger body line.\n' > "$HTXT"
dry "$TSQ" learning "ari:cloud:townsquare:c0:project/x" - < "$HTXT"
eq "dry learning exits 0 with no request" "0:0" "$RC:$(reqs)"
HVARS=$(printf '%s\n' "$ERR" | sed -n 's/^would issue variables: //p')
eq "dry learning's summary is the stdin's first line" "Short headline" "$(printf '%s' "$HVARS" | jq -r .summary)"
contains "dry learning's description ADF-encodes the whole text" "Longer body line." \
    "$(printf '%s' "$HVARS" | jq -r '.description | fromjson | .content[1].content[0].text')"

ABTXT="$WORK/about.txt"
printf '## what\nWe ship faster.\n## measurement\nCycle time.\n' > "$ABTXT"
dry "$TSQ" about "ari:cloud:townsquare:c0:project/x" - < "$ABTXT"
eq "dry about exits 0 with no request" "0:0" "$RC:$(reqs)"
ABDVARS=$(printf '%s\n' "$ERR" | sed -n 's/^would issue variables: //p')
contains "dry about's what section is ADF-encoded" "We ship faster." \
    "$(printf '%s' "$ABDVARS" | jq -r '.what | fromjson | .content[0].content[0].text')"
not_contains "dry about omits the why key entirely (server leaves it alone)" '"why"' "$ABDVARS"

URL="https://127.0.0.1/wiki/x/ABCD"
run env STUB_ROUTES="POST|/gateway/api/graphql|$WORK/update.ok.json|200" \
    "$PROVIDER" post-headline PROJ-12 "Shipped publishing" "$URL"
eq "post-headline (epic key) exits 0" "0" "$RC"
contains "post-headline prints the posted line" "posted on ari:cloud:townsquare:c0:project/epic-feed" "$OUT"
VARS=$(cut -f3 "$WORK/req" | jq -c .variables)
eq "post-headline posts to the mapped epic feed with the configured status" "ari:cloud:townsquare:c0:project/epic-feed:on_track" \
   "$(printf '%s' "$VARS" | jq -r '"\(.pid):\(.status)"')"
eq "the summary is ADF carrying headline and url" "Shipped publishing $URL" \
   "$(printf '%s' "$VARS" | jq -r '.summary | fromjson | .content[0].content[0].text')"

LONG=$(printf 'x%.0s' $(seq 1 400))
run env STUB_ROUTES="POST|/gateway/api/graphql|$WORK/update.ok.json|200" \
    "$PROVIDER" post-headline default "$LONG" "$URL"
TEXT=$(cut -f3 "$WORK/req" | jq -r '.variables.summary | fromjson | .content[0].content[0].text')
eq "a long headline is capped at 236 characters" "236" "$(printf '%s' "$TEXT" | jq -Rr length)"
contains "the capped summary keeps the url whole" "… $URL" "$TEXT"

run env STUB_ROUTES="" "$PROVIDER" post-headline NOPE-1 "t" "$URL"
eq "an unmapped key is refused before any request" "1:0" "$RC:$(reqs)"
contains "the refusal names the feeds table" "[publish.atlassian.feeds]" "$ERR"
run env STUB_ROUTES="" "$TSQ" --yes update PROJ-12 on_track - <<< "t"
eq "a short key where an ARI belongs is refused before any request" "1:0" "$RC:$(reqs)"
run env STUB_ROUTES="" "$PROVIDER" post-headline default "t" "http://insecure.test/x"
eq "a non-https url is refused" "1:0" "$RC:$(reqs)"

run env STUB_ROUTES="POST|/gateway/api/graphql|$WORK/update.adf.json|200" \
    "$PROVIDER" post-headline default "t" "$URL"
eq "success:false exits 1" "1" "$RC"
contains "success:false surfaces the server message" "Invalid ADF" "$ERR"
run env STUB_ROUTES="POST|/gateway/api/graphql|$WORK/update.ari.json|200" \
    "$PROVIDER" post-headline default "t" "$URL"
eq "a top-level GraphQL error exits 1" "1" "$RC"
contains "the GraphQL error body is shown" "InvalidARI" "$ERR"

HARI="ari:cloud:townsquare:c0:project/x"
run env STUB_ROUTES="POST|/gateway/api/graphql|$WORK/learning.ok.json|200" \
    "$TSQ" --yes learning "$HARI" - <<< $'Fixture learning\nBody text'
eq "learning (live-fixture) exits 0" "0" "$RC"
contains "learning prints the created id and project" "created on $HARI" "$OUT"
LVARS=$(cut -f3 "$WORK/req" | jq -c .variables)
eq "learning's summary is sent plain, not ADF-wrapped" "Fixture learning" "$(printf '%s' "$LVARS" | jq -r .summary)"

run env STUB_ROUTES="POST|/gateway/api/graphql|$WORK/learning.adf.json|200" \
    "$TSQ" --yes learning "$HARI" - <<< "plain text"
eq "learning success:false exits 1" "1" "$RC"
contains "learning surfaces the server's Invalid ADF message" "Invalid ADF" "$ERR"

run env STUB_ROUTES="POST|/gateway/api/graphql|$WORK/risk.ok.json|200" \
    "$TSQ" --yes risk "$HARI" - <<< "Fixture risk"
eq "risk (live-fixture) exits 0" "0" "$RC"
contains "risk prints the created id and project" "created on $HARI" "$OUT"

run env STUB_ROUTES="POST|/gateway/api/graphql|$WORK/decision.ok.json|200" \
    "$TSQ" --yes decision "$HARI" - <<< "Fixture decision"
eq "decision (live-fixture) exits 0" "0" "$RC"
contains "decision prints the created id and project" "created on $HARI" "$OUT"

run env STUB_ROUTES="POST|/gateway/api/graphql|$WORK/about.ok.json|200" \
    "$TSQ" --yes about "$HARI" - <<< $'## what\nFixture what\n'
eq "about (live-fixture) exits 0" "0" "$RC"
contains "about prints the updated project" "updated on $HARI" "$OUT"

run env STUB_ROUTES="POST|/gateway/api/graphql|$WORK/about.adf.json|200" \
    "$TSQ" --yes about "$HARI" - <<< $'## what\nplain text\n'
eq "about success:false exits 1" "1" "$RC"
contains "about surfaces the server's Invalid ADF message" "Invalid ADF" "$ERR"

run env STUB_ROUTES="" "$TSQ" --yes learning PROJ-12 - <<< "t"
eq "a short key where an ARI belongs is refused before any request (learning)" "1:0" "$RC:$(reqs)"
run env STUB_ROUTES="" "$TSQ" --yes about PROJ-12 - <<< $'## what\nx\n'
eq "a short key where an ARI belongs is refused before any request (about)" "1:0" "$RC:$(reqs)"

finish "providers/publish/atlassian/townsquare-selftest.sh"
