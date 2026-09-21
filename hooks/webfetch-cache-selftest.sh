#!/bin/bash
#
# Assertions for webfetch-cache-pre.sh and webfetch-cache-post.sh.
#
# Structurally offline: every HTTP call the two hooks make goes through
# NW_WEBFETCH_CURL, pointed at hooks/fixtures/webfetch-cache/stub-curl, and
# every cache write goes to a throwaway directory this script creates and
# destroys. No assertion here can reach a network or the real cache root,
# and the one URL used is on a .invalid host, which cannot resolve.
#
# Asserts:
#   - a cold URL passes straight through (exit 0) and stays uncached until
#     the post hook runs
#   - the post hook stores body, prompt and the observed validators
#   - a warm URL the origin calls unchanged is blocked (exit 2) with the
#     cached reading and the prompt that produced it on stderr
#   - THE NEGATIVE: a hand-edited, wrong stored ETag refetches (exit 0)
#     rather than serving the stale body
#   - a missing cache directory, an unwritable one, a failing HEAD, a
#     non-200 HEAD, an origin with no validators, a credentialed URL, an
#     oversized reading, a URL/key mismatch, a non-WebFetch tool and empty
#     stdin all degrade to a plain fetch, never to a failed tool call
#
# Per this plugin's name-the-oracle rule (see script-reviewer.md): a
# deliberately broken copy of webfetch-cache-pre.sh — the 304 comparison
# changed to `[ "$STATUS" != "304" ]`, or the `allow "cache entry has no
# validators"` guard deleted — is a manual demonstration this selftest FAILs
# on, not something it checks automatically. A selftest never observed
# failing has only been exercised, not tested.
#
# Usage: ./hooks/webfetch-cache-selftest.sh
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

PRE="${WEBFETCH_CACHE_PRE_SH:-$HERE/webfetch-cache-pre.sh}"
POST="${WEBFETCH_CACHE_POST_SH:-$HERE/webfetch-cache-post.sh}"
[ -f "$PRE" ] || { echo "cannot find webfetch-cache-pre.sh at $PRE" >&2; exit 1; }
[ -f "$POST" ] || { echo "cannot find webfetch-cache-post.sh at $POST" >&2; exit 1; }

STUB="$HERE/fixtures/webfetch-cache/stub-curl"
[ -x "$STUB" ] || { echo "stub curl is missing or not executable: $STUB" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "jq is required to run this selftest" >&2; exit 1; }

FAIL=0
N=0
pass() { N=$((N + 1)); echo "PASS $N: $1"; }
fail() { N=$((N + 1)); echo "FAIL $N: $1" >&2; FAIL=1; }

WORK="$HERE/.webfetch-selftest.$$"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'chmod u+w "$WORK/locked" 2>/dev/null; rm -rf "$WORK"' EXIT

URL="https://docs.example.invalid/reference/index.html"
PROMPT="What is the current stable release number on this page?"
READING="The page lists 4.2.1 as the current stable release, dated 2026-08-02."
ETAG='"v1-abc123"'
LMOD="Tue, 02 Sep 2026 10:00:00 GMT"

CACHE="$WORK/cache"
mkdir -p "$CACHE"

pre_payload() {
  jq -nc --arg u "$1" --arg p "$PROMPT" \
    '{session_id:"sess-selftest", tool_name:"WebFetch", tool_input:{url:$u, prompt:$p}}'
}
post_payload() {
  jq -nc --arg u "$1" --arg p "$PROMPT" --arg r "$2" \
    '{session_id:"sess-selftest", tool_name:"WebFetch", tool_input:{url:$u, prompt:$p}, tool_response:$r}'
}

run_pre() {
  local payload="$1" cache="${2:-$CACHE}"
  NW_WEBFETCH_CACHE_DIR="$cache" NW_WEBFETCH_CURL="$STUB" \
    STUB_ETAG="${STUB_ETAG_OVERRIDE-$ETAG}" STUB_LAST_MODIFIED="${STUB_LMOD_OVERRIDE-$LMOD}" \
    STUB_FAIL="${STUB_FAIL_OVERRIDE-}" STUB_HEAD_STATUS="${STUB_HEAD_STATUS_OVERRIDE-200}" \
    bash "$PRE" <<<"$payload"
}
run_post() {
  local payload="$1" cache="${2:-$CACHE}"
  NW_WEBFETCH_CACHE_DIR="$cache" NW_WEBFETCH_CURL="$STUB" \
    NW_WEBFETCH_MAX_BYTES="${MAX_BYTES_OVERRIDE-262144}" \
    STUB_ETAG="${STUB_ETAG_OVERRIDE-$ETAG}" STUB_LAST_MODIFIED="${STUB_LMOD_OVERRIDE-$LMOD}" \
    STUB_FAIL="${STUB_FAIL_OVERRIDE-}" STUB_HEAD_STATUS="${STUB_HEAD_STATUS_OVERRIDE-200}" \
    bash "$POST" <<<"$payload"
}

key_of() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }
KEY="$(key_of "$URL")"

# --- 1. cold URL passes straight through --------------------------------
run_pre "$(pre_payload "$URL")" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ]; then pass "cold URL: pre-hook exits 0 (allow)"; else fail "cold URL: expected exit 0, got $STATUS"; fi
if [ -z "$(ls -A "$CACHE" 2>/dev/null)" ]; then
  pass "cold URL: pre-hook wrote nothing to the cache"
else
  fail "cold URL: pre-hook left files in the cache ($(ls -A "$CACHE"))"
fi

# --- 2. post hook stores the entry ---------------------------------------
run_post "$(post_payload "$URL" "$READING")" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ]; then pass "post-hook exits 0"; else fail "post-hook expected exit 0, got $STATUS"; fi
if [ -f "$CACHE/$KEY.body" ] && [ -f "$CACHE/$KEY.meta" ] && [ -f "$CACHE/$KEY.prompt" ]; then
  pass "post-hook wrote body, meta and prompt"
else
  fail "post-hook did not write all three files (have: $(ls -A "$CACHE" 2>&1))"
fi
if [ "$(cat "$CACHE/$KEY.body" 2>/dev/null)" = "$READING" ]; then
  pass "post-hook stored the reading verbatim"
else
  fail "post-hook body mismatch (got: $(cat "$CACHE/$KEY.body" 2>&1))"
fi
if [ "$(cat "$CACHE/$KEY.prompt" 2>/dev/null)" = "$PROMPT" ]; then
  pass "post-hook stored the originating prompt"
else
  fail "post-hook prompt mismatch (got: $(cat "$CACHE/$KEY.prompt" 2>&1))"
fi
if grep -qF "etag	$ETAG" "$CACHE/$KEY.meta" 2>/dev/null; then
  pass "post-hook stored the ETag the origin advertised"
else
  fail "post-hook did not store the ETag (meta: $(cat "$CACHE/$KEY.meta" 2>&1))"
fi
if grep -qF "last_modified	$LMOD" "$CACHE/$KEY.meta" 2>/dev/null; then
  pass "post-hook stored Last-Modified"
else
  fail "post-hook did not store Last-Modified (meta: $(cat "$CACHE/$KEY.meta" 2>&1))"
fi
if grep -q 'stored_at	[0-9]\{4\}-' "$CACHE/$KEY.meta" 2>/dev/null; then
  pass "post-hook stored a stored_at timestamp"
else
  fail "post-hook did not store stored_at"
fi

# --- 3. warm URL, origin says unchanged: served from cache ---------------
ERR="$WORK/warm.err"
run_pre "$(pre_payload "$URL")" >/dev/null 2>"$ERR"
STATUS=$?
if [ "$STATUS" -eq 2 ]; then pass "warm URL: pre-hook exits 2 (block, serve cache)"; else fail "warm URL: expected exit 2, got $STATUS"; fi
if grep -qF "$READING" "$ERR"; then
  pass "warm URL: the cached reading reached the model on stderr"
else
  fail "warm URL: cached reading absent from stderr"
fi
if grep -qF "$PROMPT" "$ERR"; then
  pass "warm URL: the prompt that produced the reading is shown alongside"
else
  fail "warm URL: originating prompt absent from stderr"
fi
if grep -q '304 Not Modified' "$ERR"; then
  pass "warm URL: the hook reports the 304 revalidation"
else
  fail "warm URL: no 304 report on stderr"
fi

# --- 4. THE NEGATIVE: a wrong stored ETag must refetch -------------------
cp "$CACHE/$KEY.meta" "$WORK/meta.good"
sed 's/^etag	.*/etag	"v0-WRONG"/' "$WORK/meta.good" > "$CACHE/$KEY.meta"
if grep -qF 'etag	"v0-WRONG"' "$CACHE/$KEY.meta"; then
  pass "negative setup: stored ETag hand-edited to a wrong value"
else
  fail "negative setup: could not rewrite the stored ETag"
fi
ERR2="$WORK/stale.err"
run_pre "$(pre_payload "$URL")" >/dev/null 2>"$ERR2"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "wrong stored ETag: pre-hook refetches (exit 0) instead of serving stale"
else
  fail "wrong stored ETag: expected exit 0 (refetch), got $STATUS"
fi
if ! grep -qF "$READING" "$ERR2"; then
  pass "wrong stored ETag: the stale reading was NOT handed to the model"
else
  fail "wrong stored ETag: stale reading leaked to the model"
fi
cp "$WORK/meta.good" "$CACHE/$KEY.meta"

# --- 5. a URL that has never been fetched passes through -----------------
OTHER="https://docs.example.invalid/reference/other.html"
run_pre "$(pre_payload "$OTHER")" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ]; then pass "never-fetched URL: exit 0 (straight through)"; else fail "never-fetched URL: expected exit 0, got $STATUS"; fi

# --- 6. missing cache directory ------------------------------------------
run_pre "$(pre_payload "$URL")" "$WORK/no-such-dir" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ]; then pass "missing cache dir: pre-hook exits 0"; else fail "missing cache dir: expected exit 0, got $STATUS"; fi
if [ ! -d "$WORK/no-such-dir" ]; then
  pass "missing cache dir: the pre-hook did not create one"
else
  fail "missing cache dir: the pre-hook created $WORK/no-such-dir"
fi

# --- 7. unwritable cache directory ---------------------------------------
mkdir -p "$WORK/locked"
chmod a-w "$WORK/locked"
run_post "$(post_payload "$URL" "$READING")" "$WORK/locked" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ]; then pass "unwritable cache dir: post-hook exits 0"; else fail "unwritable cache dir: expected exit 0, got $STATUS"; fi
if [ -z "$(ls -A "$WORK/locked" 2>/dev/null)" ]; then
  pass "unwritable cache dir: nothing was written"
else
  fail "unwritable cache dir: files appeared ($(ls -A "$WORK/locked"))"
fi
run_pre "$(pre_payload "$URL")" "$WORK/locked" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ]; then pass "unwritable cache dir: pre-hook exits 0"; else fail "unwritable cache dir: pre-hook expected exit 0, got $STATUS"; fi
chmod u+w "$WORK/locked"

# --- 8. a failing HEAD never blocks ---------------------------------------
STUB_FAIL_OVERRIDE=1
run_pre "$(pre_payload "$URL")" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ]; then pass "HEAD failure: pre-hook exits 0"; else fail "HEAD failure: expected exit 0, got $STATUS"; fi
CACHE2="$WORK/cache2"; mkdir -p "$CACHE2"
run_post "$(post_payload "$URL" "$READING")" "$CACHE2" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ] && [ -z "$(ls -A "$CACHE2")" ]; then
  pass "HEAD failure: post-hook exits 0 and stores nothing"
else
  fail "HEAD failure: post-hook exit $STATUS, cache: $(ls -A "$CACHE2")"
fi
unset STUB_FAIL_OVERRIDE

# --- 9. a non-200 HEAD is not cached --------------------------------------
STUB_HEAD_STATUS_OVERRIDE=404
rm -rf "$CACHE2"; mkdir -p "$CACHE2"
run_post "$(post_payload "$URL" "$READING")" "$CACHE2" >/dev/null 2>&1
if [ -z "$(ls -A "$CACHE2")" ]; then
  pass "non-200 HEAD: nothing cached"
else
  fail "non-200 HEAD: an entry was written ($(ls -A "$CACHE2"))"
fi
unset STUB_HEAD_STATUS_OVERRIDE

# --- 10. an origin with no validators is not cached -----------------------
STUB_ETAG_OVERRIDE=""
STUB_LMOD_OVERRIDE=""
rm -rf "$CACHE2"; mkdir -p "$CACHE2"
run_post "$(post_payload "$URL" "$READING")" "$CACHE2" >/dev/null 2>&1
if [ -z "$(ls -A "$CACHE2")" ]; then
  pass "no validators: nothing cached, so nothing can be served without revalidation"
else
  fail "no validators: an entry was written ($(ls -A "$CACHE2"))"
fi
unset STUB_ETAG_OVERRIDE STUB_LMOD_OVERRIDE

# --- 11. credentialed URLs are never cached or served ---------------------
rm -rf "$CACHE2"; mkdir -p "$CACHE2"
for BAD in \
  "https://api.example.invalid/x?access_token=abc123" \
  "https://user:pw@docs.example.invalid/x" \
  "file:///etc/passwd"
do
  run_post "$(post_payload "$BAD" "$READING")" "$CACHE2" >/dev/null 2>&1
  run_pre "$(pre_payload "$BAD")" "$CACHE2" >/dev/null 2>&1
  STATUS=$?
  if [ "$STATUS" -eq 0 ] && [ -z "$(ls -A "$CACHE2")" ]; then
    pass "credentialed/non-http URL not cached and passed through: $BAD"
  else
    fail "credentialed/non-http URL mishandled ($BAD): pre exit $STATUS, cache $(ls -A "$CACHE2")"
  fi
done

# --- 12. an oversized reading is not cached -------------------------------
rm -rf "$CACHE2"; mkdir -p "$CACHE2"
MAX_BYTES_OVERRIDE=16
run_post "$(post_payload "$URL" "$READING")" "$CACHE2" >/dev/null 2>&1
if [ -z "$(ls -A "$CACHE2")" ]; then
  pass "oversized reading: nothing cached"
else
  fail "oversized reading: an entry was written ($(ls -A "$CACHE2"))"
fi
unset MAX_BYTES_OVERRIDE

# --- 13. an entry whose recorded URL does not match is not served ---------
sed 's|^url	.*|url	https://docs.example.invalid/somewhere/else.html|' "$WORK/meta.good" > "$CACHE/$KEY.meta"
ERR3="$WORK/mismatch.err"
run_pre "$(pre_payload "$URL")" >/dev/null 2>"$ERR3"
STATUS=$?
if [ "$STATUS" -eq 0 ] && ! grep -qF "$READING" "$ERR3"; then
  pass "URL/key mismatch: entry not served, fetch allowed"
else
  fail "URL/key mismatch: pre exit $STATUS, reading leaked: $(grep -cF "$READING" "$ERR3")"
fi
cp "$WORK/meta.good" "$CACHE/$KEY.meta"

# --- 14. an empty cached body is not served -------------------------------
cp "$CACHE/$KEY.body" "$WORK/body.good"
: > "$CACHE/$KEY.body"
run_pre "$(pre_payload "$URL")" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ]; then pass "empty cached body: fetch allowed"; else fail "empty cached body: expected exit 0, got $STATUS"; fi
cp "$WORK/body.good" "$CACHE/$KEY.body"

# --- 15. other tools and empty stdin --------------------------------------
OTHER_TOOL='{"session_id":"s","tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
run_pre "$OTHER_TOOL" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ]; then pass "non-WebFetch tool: pre-hook exits 0"; else fail "non-WebFetch tool: expected exit 0, got $STATUS"; fi
run_post "$OTHER_TOOL" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ]; then pass "non-WebFetch tool: post-hook exits 0"; else fail "non-WebFetch tool: expected exit 0, got $STATUS"; fi

: | NW_WEBFETCH_CACHE_DIR="$CACHE" NW_WEBFETCH_CURL="$STUB" bash "$PRE" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ]; then pass "empty stdin: pre-hook exits 0"; else fail "empty stdin: expected exit 0, got $STATUS"; fi
: | NW_WEBFETCH_CACHE_DIR="$CACHE" NW_WEBFETCH_CURL="$STUB" bash "$POST" >/dev/null 2>&1
STATUS=$?
if [ "$STATUS" -eq 0 ]; then pass "empty stdin: post-hook exits 0"; else fail "empty stdin: post-hook expected exit 0, got $STATUS"; fi

# --- 16. NW_WEBFETCH_CACHE=off disables both hooks ------------------------
ERR4="$WORK/off.err"
NW_WEBFETCH_CACHE=off NW_WEBFETCH_CACHE_DIR="$CACHE" NW_WEBFETCH_CURL="$STUB" \
  STUB_ETAG="$ETAG" STUB_LAST_MODIFIED="$LMOD" bash "$PRE" <<<"$(pre_payload "$URL")" >/dev/null 2>"$ERR4"
STATUS=$?
if [ "$STATUS" -eq 0 ] && ! grep -qF "$READING" "$ERR4"; then
  pass "NW_WEBFETCH_CACHE=off: warm URL is fetched, not served from cache"
else
  fail "NW_WEBFETCH_CACHE=off: pre exit $STATUS, reading leaked"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "all $N assertions passed"
else
  echo "FAILURES above ($N assertions run)" >&2
fi
exit "$FAIL"
