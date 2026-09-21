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
#   - the same warm/negative pair for an origin advertising Last-Modified
#     and no ETag, so the If-Modified-Since branch decides an assertion
#   - a WebFetch response that is not page content — an error code, a
#     redirect notice from a URL that really does redirect, or a body too
#     short to be a reading — is never stored, since with no TTL such an
#     entry would be served forever under a "the content below is current"
#     banner
#   - a hand-planted entry for a credentialed URL is never SERVED, proved
#     against a control that shows the same planted shape is servable
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
# failing has only been exercised, not tested. Point
# WEBFETCH_CACHE_PRE_SH / WEBFETCH_CACHE_POST_SH at the broken copy to run
# that demonstration without editing the real hooks.
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
READING="The page lists 4.2.1 as the current stable release, dated 2026-08-02. The previous release, 4.2.0, is marked superseded, and the 4.3 series is documented as a preview that is not recommended for production use."
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
# post_payload_obj URL RESULT CODE — the object-shaped tool_response Claude
# Code sends, carrying the HTTP status WebFetch itself saw.
post_payload_obj() {
  jq -nc --arg u "$1" --arg p "$PROMPT" --arg r "$2" --argjson c "$3" \
    '{session_id:"sess-selftest", tool_name:"WebFetch", tool_input:{url:$u, prompt:$p}, tool_response:{result:$r, code:$c}}'
}

run_pre() {
  local payload="$1" cache="${2:-$CACHE}"
  NW_WEBFETCH_CACHE_DIR="$cache" NW_WEBFETCH_CURL="$STUB" \
    STUB_ETAG="${STUB_ETAG_OVERRIDE-$ETAG}" STUB_LAST_MODIFIED="${STUB_LMOD_OVERRIDE-$LMOD}" \
    STUB_FAIL="${STUB_FAIL_OVERRIDE-}" STUB_HEAD_STATUS="${STUB_HEAD_STATUS_OVERRIDE-200}" \
    STUB_REDIRECT_TO="${STUB_REDIRECT_OVERRIDE-}" STUB_REDIRECT_ETAG="${STUB_REDIRECT_ETAG_OVERRIDE-}" \
    bash "$PRE" <<<"$payload"
}
run_post() {
  local payload="$1" cache="${2:-$CACHE}"
  NW_WEBFETCH_CACHE_DIR="$cache" NW_WEBFETCH_CURL="$STUB" \
    NW_WEBFETCH_MAX_BYTES="${MAX_BYTES_OVERRIDE-262144}" \
    STUB_ETAG="${STUB_ETAG_OVERRIDE-$ETAG}" STUB_LAST_MODIFIED="${STUB_LMOD_OVERRIDE-$LMOD}" \
    STUB_FAIL="${STUB_FAIL_OVERRIDE-}" STUB_HEAD_STATUS="${STUB_HEAD_STATUS_OVERRIDE-200}" \
    STUB_REDIRECT_TO="${STUB_REDIRECT_OVERRIDE-}" STUB_REDIRECT_ETAG="${STUB_REDIRECT_ETAG_OVERRIDE-}" \
    bash "$POST" <<<"$payload"
}

# plant_entry CACHE URL ETAG LAST_MODIFIED — writes the three files the post
# hook would have written, so the pre hook can be exercised on an entry that
# exists regardless of whether the post hook would agree to create it.
plant_entry() {
  local cache="$1" url="$2" etag="$3" lmod="$4" k
  k="$(key_of "$url")"
  mkdir -p "$cache"
  printf '%s' "$READING" > "$cache/$k.body"
  printf '%s' "$PROMPT" > "$cache/$k.prompt"
  {
    printf 'url\t%s\n' "$url"
    [ -n "$etag" ] && printf 'etag\t%s\n' "$etag"
    [ -n "$lmod" ] && printf 'last_modified\t%s\n' "$lmod"
    printf 'stored_at\t2026-09-01T00:00:00Z\n'
    printf 'bytes\t%s\n' "$(printf '%s' "$READING" | wc -c | tr -d ' ')"
  } > "$cache/$k.meta"
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

# --- 17. a response that is not page content is never stored --------------
# With no TTL, a stored notice is served forever under a banner asserting it
# is current, so these three are the only "fails wrong" path in the design.
NOTICE="REDIRECT DETECTED: the URL redirects to https://docs.example.invalid/reference/v2/index.html. Please fetch that URL instead."
CACHE3="$WORK/cache3"

rm -rf "$CACHE3"; mkdir -p "$CACHE3"
# Over the byte floor and with no redirect, so the response code is the only
# gate that can refuse it.
run_post "$(post_payload_obj "$URL" "This URL cannot be fetched. The origin answered 403 Forbidden, and its robots.txt disallows this path for automated clients, so no page content was retrieved and nothing below reflects what the page actually says right now." 403)" "$CACHE3" >/dev/null 2>&1
if [ -z "$(ls -A "$CACHE3")" ]; then
  pass "error-coded tool_response: nothing cached"
else
  fail "error-coded tool_response: an entry was written ($(ls -A "$CACHE3"))"
fi

rm -rf "$CACHE3"; mkdir -p "$CACHE3"
STUB_REDIRECT_OVERRIDE="https://docs.example.invalid/reference/v2/index.html"
STUB_REDIRECT_ETAG_OVERRIDE='"tgt-v1"'
run_post "$(post_payload_obj "$URL" "$NOTICE    Padding so the byte floor is not what refuses this entry: the redirect is." 200)" "$CACHE3" >/dev/null 2>&1
if [ -z "$(ls -A "$CACHE3")" ]; then
  pass "redirect notice from a redirecting URL: nothing cached under the source URL"
else
  fail "redirect notice cached under the source URL ($(ls -A "$CACHE3")) — the target's validators would revalidate it forever"
fi
unset STUB_REDIRECT_OVERRIDE STUB_REDIRECT_ETAG_OVERRIDE

rm -rf "$CACHE3"; mkdir -p "$CACHE3"
run_post "$(post_payload "$URL" "$NOTICE")" "$CACHE3" >/dev/null 2>&1
if [ -z "$(ls -A "$CACHE3")" ]; then
  pass "notice-length reading: nothing cached"
else
  fail "notice-length reading: an entry was written ($(ls -A "$CACHE3"))"
fi

rm -rf "$CACHE3"; mkdir -p "$CACHE3"
run_post "$(post_payload_obj "$URL" "$READING" 200)" "$CACHE3" >/dev/null 2>&1
CTRL_KEY="$(key_of "$URL")"
if [ -f "$CACHE3/$CTRL_KEY.body" ] && [ "$(cat "$CACHE3/$CTRL_KEY.body")" = "$READING" ]; then
  pass "control: an object-shaped 200 response carrying a real reading IS cached"
else
  fail "control: a good object-shaped response was refused (cache: $(ls -A "$CACHE3"))"
fi

# --- 18. a planted entry for a credentialed URL is never served -----------
# The control is the point: it proves the planted shape is servable, so the
# credentialed assertion below cannot pass just because nothing was there.
CACHE4="$WORK/cache4"
rm -rf "$CACHE4"; mkdir -p "$CACHE4"
plant_entry "$CACHE4" "$URL" "$ETAG" "$LMOD"
ERR5="$WORK/planted.err"
run_pre "$(pre_payload "$URL")" "$CACHE4" >/dev/null 2>"$ERR5"
STATUS=$?
if [ "$STATUS" -eq 2 ] && grep -qF "$READING" "$ERR5"; then
  pass "control: a hand-planted entry for a plain URL IS served (exit 2)"
else
  fail "control: planted entry not served (pre exit $STATUS) — assertion below would be vacuous"
fi

CRED_URL="https://api.example.invalid/x?access_token=abc123"
rm -rf "$CACHE4"; mkdir -p "$CACHE4"
plant_entry "$CACHE4" "$CRED_URL" "$ETAG" "$LMOD"
ERR6="$WORK/cred-served.err"
run_pre "$(pre_payload "$CRED_URL")" "$CACHE4" >/dev/null 2>"$ERR6"
STATUS=$?
if [ "$STATUS" -eq 0 ]; then
  pass "credentialed URL with a valid entry on disk: pre-hook exits 0 (refetch)"
else
  fail "credentialed URL with a valid entry on disk: expected exit 0, got $STATUS"
fi
if ! grep -qF "$READING" "$ERR6"; then
  pass "credentialed URL: the stored reading was NOT handed to the model"
else
  fail "credentialed URL: the stored reading leaked to the model"
fi

# --- 19. Last-Modified-only origins revalidate through If-Modified-Since --
# nginx static hosting and many documentation sites advertise no ETag, so
# this branch, not If-None-Match, is what decides their revalidation.
CACHE5="$WORK/cache5"
rm -rf "$CACHE5"; mkdir -p "$CACHE5"
STUB_ETAG_OVERRIDE=""
run_post "$(post_payload "$URL" "$READING")" "$CACHE5" >/dev/null 2>&1
LKEY="$(key_of "$URL")"
if grep -qF "last_modified	$LMOD" "$CACHE5/$LKEY.meta" 2>/dev/null && ! grep -q '^etag	' "$CACHE5/$LKEY.meta" 2>/dev/null; then
  pass "Last-Modified-only origin: entry stored with Last-Modified and no ETag"
else
  fail "Last-Modified-only origin: unexpected meta ($(cat "$CACHE5/$LKEY.meta" 2>&1))"
fi
ERR7="$WORK/ims.err"
run_pre "$(pre_payload "$URL")" "$CACHE5" >/dev/null 2>"$ERR7"
STATUS=$?
if [ "$STATUS" -eq 2 ] && grep -qF "$READING" "$ERR7"; then
  pass "Last-Modified-only origin: If-Modified-Since revalidation serves the cache (exit 2)"
else
  fail "Last-Modified-only origin: expected exit 2 with the reading, got $STATUS"
fi
sed 's/^last_modified	.*/last_modified	Mon, 01 Jan 2001 00:00:00 GMT/' "$CACHE5/$LKEY.meta" > "$CACHE5/$LKEY.meta.tmp"
mv "$CACHE5/$LKEY.meta.tmp" "$CACHE5/$LKEY.meta"
ERR8="$WORK/ims-stale.err"
run_pre "$(pre_payload "$URL")" "$CACHE5" >/dev/null 2>"$ERR8"
STATUS=$?
if [ "$STATUS" -eq 0 ] && ! grep -qF "$READING" "$ERR8"; then
  pass "wrong stored Last-Modified: pre-hook refetches (exit 0) instead of serving stale"
else
  fail "wrong stored Last-Modified: pre exit $STATUS, reading leaked: $(grep -cF "$READING" "$ERR8")"
fi
unset STUB_ETAG_OVERRIDE

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "all $N assertions passed"
else
  echo "FAILURES above ($N assertions run)" >&2
fi
exit "$FAIL"
