#!/bin/bash
#
# Selftest for providers/publish/atlassian/{provider.sh,confluence.sh,
# townsquare.sh,lib/atlassian-common.sh}. Structurally offline: a stub
# `curl` is first on PATH for every run that could issue a request, the
# host is 127.0.0.1, credentials come from the `env` secrets provider with
# throwaway values, and the stub answers from fixtures/ (responses recorded
# live, then de-identified — see each file's header).
#
# Usage: providers/publish/atlassian/selftest.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVIDER="$HERE/provider.sh"
CONF="$HERE/confluence.sh"
TSQ="$HERE/townsquare.sh"
FIX="$HERE/fixtures"

for f in "$PROVIDER" "$CONF" "$TSQ"; do
    [ -x "$f" ] || { echo "$f is missing or not executable" >&2; exit 2; }
done

N=0
FAIL=0
ok()  { N=$((N + 1)); echo "ok - $1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else
        bad "$1"; printf '       expected: %s\n       actual:   %s\n' "$2" "$3"
    fi
}
contains() {
    case "$3" in *"$2"*) ok "$1" ;; *) bad "$1"; printf '       wanted: %s\n       in: %s\n' "$2" "$3" ;; esac
}
not_contains() {
    case "$3" in *"$2"*) bad "$1"; printf '       unwanted: %s\n' "$2" ;; *) ok "$1" ;; esac
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

strip() { sed -n '/^---$/,$p' "$1" | tail -n +2; }

# fixtures (recorded responses, bodies only)
strip "$FIX/confluence/children.get.json"      > "$WORK/children.empty.json"
strip "$FIX/confluence/create.success.json"    > "$WORK/create.json"
strip "$FIX/confluence/error.404-notfound.json" > "$WORK/404.json"
strip "$FIX/confluence/whoami.success.json"    > "$WORK/whoami.json"
strip "$FIX/townsquare/update.success.json"    > "$WORK/update.ok.json"
strip "$FIX/townsquare/update.invalid-adf.json" > "$WORK/update.adf.json"
strip "$FIX/townsquare/update.error.invalid-ari.json" > "$WORK/update.ari.json"
strip "$FIX/townsquare/learning.success.json"  > "$WORK/learning.ok.json"
strip "$FIX/townsquare/learning.invalid-adf.json" > "$WORK/learning.adf.json"
strip "$FIX/townsquare/risk.success.json"      > "$WORK/risk.ok.json"
strip "$FIX/townsquare/decision.success.json"  > "$WORK/decision.ok.json"
strip "$FIX/townsquare/about.success.json"     > "$WORK/about.ok.json"
strip "$FIX/townsquare/about.invalid-adf.json" > "$WORK/about.adf.json"
for f in "$WORK"/*.json; do
    jq -e . >/dev/null 2>&1 < "$f" || { echo "fixture is not valid JSON: $f" >&2; exit 2; }
done
# Derived from the recorded create response (same page object shape the
# listing returns), never hand-typed.
jq -c '{results: [ {id, status, title, spaceId} ], _links: ._links}' "$WORK/create.json" > "$WORK/children.one.json"
CREATED_ID=$(jq -r .id "$WORK/create.json")
CREATED_TITLE=$(jq -r .title "$WORK/create.json")
CREATED_TINY=$(jq -r ._links.tinyui "$WORK/create.json")

# Stub curl. Logs argv and stdin; routes on "METHOD PATH-SUBSTRING" through
# $STUB_ROUTES ("METHOD|substring|file|code;..."), first match wins. Suffix a
# route's file with '!' to consume it once, so a path can answer twice.
cat > "$WORK/bin/curl" <<'CURLEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_ARGV"
cat >> "$STUB_STDIN"
method=GET out="" url="" data="" prev=""
for a in "$@"; do
    case "$prev" in
        -X) method="$a" ;;
        -o) out="$a" ;;
        --data-binary) data="$a" ;;
    esac
    case "$a" in https://*) url="$a" ;; esac
    prev="$a"
done
body=""
case "$data" in @*) body=$(cat "${data#@}") ;; esac
printf '%s\t%s\t%s\n' "$method" "$url" "$body" >> "$STUB_REQ"
used="$STUB_REQ.used"; touch "$used"
i=0
old="$IFS"; IFS=';'
for r in $STUB_ROUTES; do
    i=$((i + 1))
    IFS="$old"
    m="${r%%|*}"; rest="${r#*|}"; sub="${rest%%|*}"; rest="${rest#*|}"; file="${rest%%|*}"; code="${rest#*|}"
    once=0
    case "$file" in *'!') once=1; file="${file%!}" ;; esac
    if [ "$m" = "$method" ] && case "$url" in *"$sub"*) true ;; *) false ;; esac; then
        if [ "$once" = "1" ] && grep -qx "$i" "$used"; then IFS=';'; continue; fi
        [ "$once" = "1" ] && echo "$i" >> "$used"
        cat "$file" > "$out"
        printf '%s' "$code"
        exit 0
    fi
    IFS=';'
done
IFS="$old"
echo "stub curl: no route for $method $url" >&2
exit 7
CURLEOF
chmod +x "$WORK/bin/curl"

CFG="$WORK/config.toml"
cat > "$CFG" <<'EOF'
[providers]
secrets = "env"
publish = "atlassian"

[publish.atlassian]
host = "unused.invalid"
space = "4242"
root_page = "9001"
project_name = "demo"
project_feed = "ari:cloud:townsquare:c0:project/default-feed"

[publish.atlassian.feeds]
PROJ-12 = "ari:cloud:townsquare:c0:project/epic-feed"
EOF

# run [VAR=VAL...] CMD... — offline environment; sets OUT, ERR, RC.
run() {
    : > "$WORK/argv"; : > "$WORK/stdin"; : > "$WORK/req"; rm -f "$WORK/req.used"
    OUT=$( env PATH="$WORK/bin:$PATH" NW_CONFIG="$CFG" NW_ATLASSIAN_HOST=127.0.0.1 \
               NW_SECRETS=env NW_JIRA_USER=stub-user NW_JIRA_TOKEN=STUB-TOKEN-XYZ \
               STUB_ARGV="$WORK/argv" STUB_STDIN="$WORK/stdin" STUB_REQ="$WORK/req" \
               "$@" 2>"$WORK/err" )
    RC=$?
    ERR=$(cat "$WORK/err")
}
reqs() { wc -l < "$WORK/req" | tr -d ' '; }

BRIEF="$WORK/brief.md"
printf '## Recent Wins\n\n- 🚀 shipped **publish**\n' > "$BRIEF"

# NW_SECRETS=op with no op on PATH: a dry run that tried to read a credential
# would fail, so passing proves the secrets provider was skipped.
dry() {
    : > "$WORK/req"
    OUT=$( env PATH="$WORK/bin:$PATH" NW_CONFIG="$CFG" NW_ATLASSIAN_HOST=127.0.0.1 \
               NW_SECRETS=op NW_DRY_RUN=1 STUB_ARGV="$WORK/argv" STUB_STDIN="$WORK/stdin" \
               STUB_REQ="$WORK/req" STUB_ROUTES="" "$@" 2>"$WORK/err" )
    RC=$?
    ERR=$(cat "$WORK/err")
}
dry "$PROVIDER" publish-brief "2026-09-14 demo Update" "$BRIEF"
eq "dry publish-brief exits 0" "0" "$RC"
eq "dry publish-brief issues no request" "0" "$(reqs)"
contains "dry publish-brief shows the brief create" '"title":"2026-09-14 demo Update"' "$ERR"
contains "dry publish-brief shows the project page create" '"title":"demo Project Updates"' "$ERR"
not_contains "dry publish-brief reads no credential" "could not resolve secret" "$ERR"

dry "$PROVIDER" post-headline default "Shipped publishing" "https://127.0.0.1/wiki/x/AB"
eq "dry post-headline exits 0" "0" "$RC"
eq "dry post-headline issues no request" "0" "$(reqs)"
contains "dry post-headline targets the default feed" "project/default-feed" "$ERR"

for sub in whoami "page 1" "children 1" "find-child 1 T" "raw GET /wiki/api/v2/pages/1"; do
    # shellcheck disable=SC2086  # deliberate split of the subcommand words
    dry "$CONF" $sub
    eq "dry confluence.sh $sub exits 0 with no request" "0:0" "$RC:$(reqs)"
done
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

echo
echo "$N assertion(s), $((N - FAIL)) passed" >&2
if [ "$FAIL" -ne 0 ]; then
    echo "providers/publish/atlassian/selftest.sh: FAILED" >&2
    exit 1
fi
echo "providers/publish/atlassian/selftest.sh: all assertions passed" >&2
exit 0
