#!/bin/bash
#
# Selftest for providers/publish/atlassian/confluence.sh and the
# Confluence half of provider.sh (publish-brief, markdown conversion, the
# verb table). Structurally offline: a stub `curl` is first on PATH for
# every run that could issue a request, the host is 127.0.0.1, credentials
# come from the `env` secrets provider with throwaway values, and the stub
# answers from fixtures/confluence/ (responses recorded live, then
# de-identified — see each file's header). The harness is
# lib/test-harness.sh, shared with townsquare-selftest.sh.
#
# Usage: providers/publish/atlassian/confluence-selftest.sh

set -uo pipefail

# shellcheck source=lib/test-harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/test-harness.sh"

strip "$FIX/confluence/children.get.json"      > "$WORK/children.empty.json"
strip "$FIX/confluence/create.success.json"    > "$WORK/create.json"
strip "$FIX/confluence/error.404-notfound.json" > "$WORK/404.json"
strip "$FIX/confluence/whoami.success.json"    > "$WORK/whoami.json"
check_fixtures
# Derived from the recorded create response (same page object shape the
# listing returns), never hand-typed.
jq -c '{results: [ {id, status, title, spaceId} ], _links: ._links}' "$WORK/create.json" > "$WORK/children.one.json"
CREATED_ID=$(jq -r .id "$WORK/create.json")
CREATED_TITLE=$(jq -r .title "$WORK/create.json")
CREATED_TINY=$(jq -r ._links.tinyui "$WORK/create.json")

BRIEF="$WORK/brief.md"
printf '## Recent Wins\n\n- 🚀 shipped **publish**\n' > "$BRIEF"

dry "$PROVIDER" publish-brief "2026-09-14 demo Update" "$BRIEF"
eq "dry publish-brief exits 0" "0" "$RC"
eq "dry publish-brief issues no request" "0" "$(reqs)"
contains "dry publish-brief shows the brief create" '"title":"2026-09-14 demo Update"' "$ERR"
contains "dry publish-brief shows the project page create" '"title":"demo Project Updates"' "$ERR"
not_contains "dry publish-brief reads no credential" "could not resolve secret" "$ERR"

for sub in whoami "page 1" "children 1" "find-child 1 T" "raw GET /wiki/api/v2/pages/1"; do
    # shellcheck disable=SC2086  # deliberate split of the subcommand words
    dry "$CONF" $sub
    eq "dry confluence.sh $sub exits 0 with no request" "0:0" "$RC:$(reqs)"
done

# markdown conversion, asserted on the dry-run request body
MD="$WORK/md.md"
cat > "$MD" <<'EOF'
# Title
Para with **bold**, `code` and [a link](https://x.test/p).

- one & two
```
if a < b && c: ]]> x
```
EOF
dry "$CONF" --markdown create --space 1 --parent 2 --title T - < "$MD"
BODY=$(printf '%s\n' "$ERR" | sed -n 's/^would issue body: //p' | jq -r .body.value)
contains "md: heading" "<h1>Title</h1>" "$BODY"
contains "md: bold, code span and link" '<p>Para with <strong>bold</strong>, <code>code</code> and <a href="https://x.test/p">a link</a>.</p>' "$BODY"
contains "md: bullet is escaped" "<li>one &amp; two</li>" "$BODY"
contains "md: fenced code is verbatim, ]]> split" "if a < b && c: ]]]]><![CDATA[> x" "$BODY"

QMD="$WORK/md-quote.md"
printf '%s\n' '[x](https://h/?q="1")' > "$QMD"
dry "$CONF" --markdown create --space 1 --parent 2 --title T - < "$QMD"
QBODY=$(printf '%s\n' "$ERR" | sed -n 's/^would issue body: //p' | jq -r .body.value)
contains "md: link URL with a double quote stays inside the attribute" 'href="https://h/?q=&quot;1&quot;"' "$QBODY"

run env STUB_ROUTES="GET|/pages/9001/children|$WORK/children.empty.json|200;POST|/wiki/api/v2/pages|$WORK/create.json!|200;GET|/pages/$CREATED_ID/children|$WORK/children.empty.json|200;POST|/wiki/api/v2/pages|$WORK/create.json|200" \
    "$PROVIDER" publish-brief "2026-09-14 demo Update" "$BRIEF"
eq "publish-brief (new project page) exits 0" "0" "$RC"
eq "publish-brief prints the brief's tiny link" "https://127.0.0.1/wiki$CREATED_TINY" "$OUT"
eq "publish-brief issued lookup, create, lookup, create" "4" "$(reqs)"
REQ2=$(sed -n 2p "$WORK/req" | cut -f3)
REQ4=$(sed -n 4p "$WORK/req" | cut -f3)
eq "the project page is created under the root page" "9001:demo Project Updates" "$(printf '%s' "$REQ2" | jq -r '"\(.parentId):\(.title)"')"
eq "the brief is created under the new project page" "$CREATED_ID:2026-09-14 demo Update" "$(printf '%s' "$REQ4" | jq -r '"\(.parentId):\(.title)"')"
contains "the brief body is storage format" "<h2>Recent Wins</h2>" "$(printf '%s' "$REQ4" | jq -r .body.value)"

PROJ_LIST="$WORK/children.proj.json"
jq -c --arg t "demo Project Updates" '.results[0].title = $t | .results[0].id = "777"' "$WORK/children.one.json" > "$PROJ_LIST"
BRIEF_LIST="$WORK/children.brief.json"
jq -c --arg t "$CREATED_TITLE" '.results[0].id = "888"' "$WORK/children.one.json" > "$BRIEF_LIST"
run env STUB_ROUTES="GET|/pages/9001/children|$PROJ_LIST|200;GET|/pages/777/children|$BRIEF_LIST|200" \
    "$PROVIDER" publish-brief "$CREATED_TITLE" "$BRIEF"
eq "publish-brief (brief exists) exits 0" "0" "$RC"
eq "publish-brief (brief exists) issues only the two lookups" "GET GET" "$(cut -f1 "$WORK/req" | tr '\n' ' ' | sed 's/ $//')"
eq "publish-brief (brief exists) prints the existing page's URL" "https://127.0.0.1/wiki/pages/viewpage.action?pageId=888" "$OUT"
contains "publish-brief says it did not overwrite" "not overwriting" "$ERR"

PAGE1="$WORK/children.page1.json"
jq -c '.results = [] | ._links.next = "/wiki/api/v2/pages/5/children?cursor=abc"' "$WORK/children.one.json" > "$PAGE1"
run env STUB_ROUTES="GET|cursor=abc|$WORK/children.one.json|200;GET|/pages/5/children|$PAGE1|200" \
    "$CONF" find-child 5 "$CREATED_TITLE"
eq "find-child follows _links.next to the second page" "0:$CREATED_ID" "$RC:$OUT"
eq "find-child issued two requests" "2" "$(reqs)"

run env STUB_ROUTES="GET|/wiki/rest/api/user/current|$WORK/404.json|404" "$CONF" whoami
eq "a Confluence 404 exits 1" "1" "$RC"
contains "the 404 warns a bad credential looks the same" "INVALID credential" "$ERR"
run env STUB_ROUTES="GET|/wiki/rest/api/user/current|$WORK/whoami.json|200" "$CONF" whoami
eq "whoami prints the account" "Account:    Fixture Account" "$(printf '%s\n' "$OUT" | head -1)"
not_contains "the token never reaches curl's argv" "STUB-TOKEN-XYZ" "$(cat "$WORK/argv")"
contains "the token reaches curl on stdin" "stub-user:STUB-TOKEN-XYZ" "$(cat "$WORK/stdin")"

run env STUB_ROUTES="" "$CONF" print-host
eq "print-host prints the resolved host with no request" "0:127.0.0.1:0" "$RC:$OUT:$(reqs)"
run env NW_ATLASSIAN_HOST= STUB_ROUTES="" "$CONF" print-host
eq "print-host refuses a set-but-empty host override" "1" "$RC"
run env NW_ATLASSIAN_HOST=evil.test/x STUB_ROUTES="" "$CONF" print-host
eq "print-host refuses a host that is not a bare hostname" "1" "$RC"

run env STUB_ROUTES="" "$PROVIDER" update-page x
eq "an unknown verb exits 1" "1" "$RC"
contains "the refusal names the contract" "publish-brief, post-headline" "$ERR"

finish "providers/publish/atlassian/confluence-selftest.sh"
