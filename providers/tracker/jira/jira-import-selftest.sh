#!/bin/bash
#
# Selftest for providers/tracker/jira/jira-import.sh and lib/frontmatter.py.
# Nothing here reaches a real network: --dry-run assertions never call
# curl, and the end-to-end assertions put a stub `curl` on PATH first, so
# even NW_JIRA_HOST=127.0.0.1 is never actually dialed.
#
# Every non-dry-run below passes --manifest into $WORK, not the committed
# fixtures/import-tickets tree: a manifest write must never land in this
# repo's own fixtures.
#
# Usage: providers/tracker/jira/jira-import-selftest.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMPORT_SH="$HERE/jira-import.sh"
FIXTURES="$HERE/fixtures"

[ -x "$IMPORT_SH" ] || { echo "$IMPORT_SH is missing or not executable" >&2; exit 2; }

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

# ---- 1-2. lib/frontmatter.py ----------------------------------------------

OUT=$(python3 "$HERE/lib/frontmatter.py" "$FIXTURES/import-tickets" --schema issues | python3 -c 'import sys, json
for line in sys.stdin:
    print(json.loads(line)["id"])')
eq "frontmatter.py orders issues-schema tickets by numeric id, across stages" \
    "SPK-1
SPK-2
SPK-3" "$OUT"

OUT=$(python3 "$HERE/lib/frontmatter.py" "$FIXTURES/import-dotissues" --schema dotissues | python3 -c 'import sys, json
for line in sys.stdin:
    print(json.loads(line)["id"])')
eq "frontmatter.py reads the flat dotissues layout" "CHR-11" "$OUT"

# ---- 3. --dry-run -----------------------------------------------------------

mkdir -p "$WORK/bin"
unset NW_CONFIG NW_ROOT NW_TRACKER NW_SECRETS NW_DISPATCH NW_MEMORY

OUT=$(NW_JIRA_HOST=127.0.0.1 "$IMPORT_SH" --project SPK --dry-run --progress "$FIXTURES/import-tickets" 2>&1); RC=$?
eq "--dry-run exits 0" "0" "$RC"
contains "--dry-run creates nothing" "nothing was created, no credential was resolved" "$OUT"
contains "--dry-run lists ticket 1 in order" "would create (1/3): SPK-1 -> Add health check endpoint" "$OUT"
contains "--dry-run lists ticket 3 in order" "would create (3/3): SPK-3 -> Load-test the health endpoint" "$OUT"

OUT=$(NW_JIRA_HOST=127.0.0.1 "$IMPORT_SH" --project SPK --dry-run --progress --resume 2 "$FIXTURES/import-tickets" 2>&1); RC=$?
eq "--resume 2 --dry-run exits 0" "0" "$RC"
case "$OUT" in
    *"would create (1/3)"*) bad "--resume 2 skips the first ticket" ;;
    *) ok "--resume 2 skips the first ticket" ;;
esac
contains "--resume 2 still lists ticket 2" "would create (2/3): SPK-2" "$OUT"

# ---- 4-5. end-to-end through a stubbed curl + the real env provider -------

cat > "$WORK/bin/curl" <<'CURLEOF'
#!/bin/bash
cat >/dev/null
out=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-o" ]; then out="$a"; fi
    prev="$a"
done
[ -n "$out" ] || { echo "stub curl: no -o path found in: $*" >&2; exit 2; }
n=$(cat "$STUB_COUNTER_FILE" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$STUB_COUNTER_FILE"
if [ "$n" -le "$STUB_FAIL_AFTER" ] || [ "$STUB_FAIL_AFTER" = "0" ]; then
    printf '{"id":"100%s","key":"SPK-%s"}' "$n" "$n" > "$out"
    printf '%s' "201"
else
    printf '{"errorMessages":["boom"]}' > "$out"
    printf '%s' "500"
fi
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

STUB_COUNTER_FILE="$WORK/counter"; echo 0 > "$STUB_COUNTER_FILE"
MANIFEST_1="$WORK/manifest-1.json"
OUT=$(STUB_COUNTER_FILE="$STUB_COUNTER_FILE" STUB_FAIL_AFTER=0 \
    run_e2e "$IMPORT_SH" --project SPK --progress --manifest "$MANIFEST_1" "$FIXTURES/import-tickets" 2>&1); RC=$?
eq "e2e: exits 0 when every create succeeds" "0" "$RC"
contains "e2e: prints the first created key" "created SPK-1 (1/3): SPK-1" "$OUT"
contains "e2e: prints the third created key" "created SPK-3 (3/3): SPK-3" "$OUT"

# ---- 6. manifest --------------------------------------------------------

eq "manifest: written with the ordered ids used" \
    '["SPK-1","SPK-2","SPK-3"]' "$(jq -c . "$MANIFEST_1")"

# Happy path: --resume against the same directory and manifest.
OUT=$(STUB_COUNTER_FILE="$STUB_COUNTER_FILE" STUB_FAIL_AFTER=0 \
    run_e2e "$IMPORT_SH" --project SPK --progress --resume 3 --manifest "$MANIFEST_1" "$FIXTURES/import-tickets" 2>&1); RC=$?
eq "manifest: --resume against an unchanged directory succeeds" "0" "$RC"

# Unhappy path: the directory changed between the manifest's run and this
# --resume, so it must refuse before creating anything.
CHANGED_DIR="$WORK/changed-tickets"
mkdir -p "$CHANGED_DIR/open" "$CHANGED_DIR/in-progress"
cp "$FIXTURES/import-tickets/open/SPK-1.md" "$CHANGED_DIR/open/SPK-1.md"
sed -e 's/id: SPK-2/id: SPK-92/' "$FIXTURES/import-tickets/open/SPK-2.md" > "$CHANGED_DIR/open/SPK-92.md"
cp "$FIXTURES/import-tickets/in-progress/SPK-3.md" "$CHANGED_DIR/in-progress/SPK-3.md"

STUB_COUNTER_FILE="$WORK/counter-changed"; echo 0 > "$STUB_COUNTER_FILE"
ERR=$(STUB_COUNTER_FILE="$STUB_COUNTER_FILE" STUB_FAIL_AFTER=0 \
    run_e2e "$IMPORT_SH" --project SPK --resume 3 --manifest "$MANIFEST_1" "$CHANGED_DIR" 2>&1 </dev/null); RC=$?
eq "manifest: --resume against a changed directory refuses" "1" "$RC"
contains "manifest: names the position that no longer matches" "position 2 was 'SPK-2'" "$ERR"
# Renaming SPK-2 to SPK-92 reshuffles rather than substitutes: by numeric
# id it now sorts after SPK-3, so position 2 becomes SPK-3.
contains "manifest: names the new id found there instead" "is now 'SPK-3'" "$ERR"

# --resume with no manifest at all refuses too, rather than guessing.
ERR=$(run_e2e "$IMPORT_SH" --project SPK --resume 2 --manifest "$WORK/no-such-manifest.json" "$FIXTURES/import-tickets" 2>&1 </dev/null); RC=$?
eq "manifest: --resume with no manifest file refuses" "1" "$RC"
contains "manifest: says why" "no manifest at" "$ERR"

STUB_COUNTER_FILE="$WORK/counter2"; echo 0 > "$STUB_COUNTER_FILE"
OUT=$(STUB_COUNTER_FILE="$STUB_COUNTER_FILE" STUB_FAIL_AFTER=1 \
    run_e2e "$IMPORT_SH" --project SPK --progress --manifest "$WORK/manifest-2.json" "$FIXTURES/import-tickets" 2>&1); RC=$?
eq "e2e: a failed create stops the run non-zero" "1" "$RC"
contains "e2e: the first ticket was created before the failure" "created SPK-1 (1/3)" "$OUT"
case "$OUT" in
    *"created SPK-3"*) bad "e2e: no ticket after the failure was created" ;;
    *) ok "e2e: no ticket after the failure was created" ;;
esac
contains "e2e: names the position to resume from" "re-run with --resume 2" "$OUT"

# ---- 8. a wrapper's stderr preamble must not corrupt the parsed response --
#
# Pinned at the tracker-provider seam itself, independent of jira-api.sh:
# a stand-in `create` that prints a preamble to stderr before its JSON.

FAKEROOT="$WORK/fakeroot"
mkdir -p "$FAKEROOT/providers/lib" "$FAKEROOT/providers/tracker/jira" "$FAKEROOT/providers/tracker/fake"
cp "$HERE/../../lib/kit.sh" "$HERE/../../lib/config.sh" "$HERE/../../lib/provider.sh" "$FAKEROOT/providers/lib/"
chmod +x "$FAKEROOT/providers/lib/provider.sh"
cp "$IMPORT_SH" "$FAKEROOT/providers/tracker/jira/jira-import.sh"
chmod +x "$FAKEROOT/providers/tracker/jira/jira-import.sh"
cp -r "$HERE/lib" "$FAKEROOT/providers/tracker/jira/lib"

cat > "$FAKEROOT/providers/tracker/fake/provider.sh" <<'FAKEEOF'
#!/bin/bash
# Behaves like jira-api.sh's write path: a preamble on stderr, THEN the
# created issue's JSON on stdout.
verb="$1"; shift
case "$verb" in
    create)
        echo "about to issue: POST https://fake.example/rest/api/3/issue" >&2
        echo "about to issue body: {\"fields\":{}}" >&2
        printf '{"id":"1001","key":"FAKE-1"}\n'
        ;;
    *)
        echo "fake provider: unsupported verb $verb" >&2
        exit 1
        ;;
esac
FAKEEOF
chmod +x "$FAKEROOT/providers/tracker/fake/provider.sh"

FAKE_TICKETS="$WORK/fake-tickets"
mkdir -p "$FAKE_TICKETS/open"
cp "$FIXTURES/import-tickets/open/SPK-1.md" "$FAKE_TICKETS/open/SPK-1.md"

OUT=$( ( export NW_TRACKER=fake
         unset NW_CONFIG NW_ROOT NW_JIRA_HOST NW_JIRA_USER NW_JIRA_TOKEN NW_SECRETS NW_DISPATCH NW_MEMORY
         "$FAKEROOT/providers/tracker/jira/jira-import.sh" --project SPK --progress \
             --manifest "$WORK/fake-manifest.json" "$FAKE_TICKETS" 2>&1 ) ); RC=$?
eq "wrapper-preamble: exits 0 despite the stub's stderr preamble" "0" "$RC"
contains "wrapper-preamble: parses the key past the preamble noise" "created FAKE-1 (1/1)" "$OUT"

# ---- 7. CRLF ----------------------------------------------------------

CRLF_DIR="$WORK/crlf-tickets/open"
mkdir -p "$CRLF_DIR"
python3 -c '
content = """---
id: CRL-1
title: CRLF ticket
created: 2026-01-01
updated: 2026-01-01
executor: agent
tags: []
blocked_by: []
touches: []
verify: |
  true
---

body text
"""
open("'"$CRLF_DIR"'/CRL-1.md", "wb").write(content.replace("\n", "\r\n").encode())
'
OUT=$(python3 "$HERE/lib/frontmatter.py" "$WORK/crlf-tickets" --schema issues | jq -r '.id, .title')
eq "frontmatter.py reads a CRLF ticket file" \
    "CRL-1
CRLF ticket" "$OUT"

echo
echo "$N assertion(s), $((N - FAIL)) passed" >&2
if [ "$FAIL" -ne 0 ]; then
    echo "providers/tracker/jira/jira-import-selftest.sh: FAILED" >&2
    exit 1
fi
echo "providers/tracker/jira/jira-import-selftest.sh: all assertions passed" >&2
exit 0
