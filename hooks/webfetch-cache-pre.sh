#!/bin/bash
#
# webfetch-cache-pre.sh — Claude Code PreToolUse hook for WebFetch. If this
# URL has been fetched before, revalidates it against the origin with a
# conditional HEAD; a 304 blocks the fetch and hands the model the cached
# reading instead. Anything other than 304 allows the real fetch through.
#
# Usage: not a CLI. Fed the PreToolUse payload on stdin.
#
# Exit codes:
#   0  allow — WebFetch runs and the model sees a freshly fetched page
#   2  block, with the cached reading on stderr, which Claude Code surfaces
#      to the model as the tool's result rather than as an error
#
# There is NO TTL and the prompt is not part of the cache key. Freshness is
# delegated entirely to the origin's validators, so a cache hit is a fresh
# verification rather than a memory read — which is what makes this
# compatible with the standing rule that anything carrying a version or a
# release cadence must be looked up rather than recalled. A reuse asserts
# only what the origin just asserted: the bytes have not changed.
#
# The cached body is not raw HTML. It is one agent's model-processed reading
# of the page under its own prompt, so the prompt that produced it is stored
# alongside and printed on every hit; the reading may not answer a different
# question. There is deliberately no "ask twice and it passes through"
# escape hatch of the kind read-shunt.sh has — a second WebFetch of the same
# URL in the same session is exactly the case this hook exists to serve.
# The escape hatch is a plain `curl` in Bash, which this hook never matches.
#
# Never serves a credentialed URL from cache: a non-http(s) scheme, userinfo
# before the host, or a query string carrying a token/key/secret/signature/
# password-shaped parameter is passed straight through and never stored. That
# last match is deliberately over-broad — the substrings are looked for
# anywhere in the query string, not only in parameter-name position, so
# ordinary parameters such as author=, session_type= or signature_algorithm=
# also opt a URL out of the cache. The cost of a false positive is one
# refetch; the cost of a false negative is a credential on disk.
#
# The revalidating HEAD does not follow redirects. A URL that has started
# redirecting since the entry was stored answers 3xx, which is not 304, so
# the fetch is allowed rather than revalidated against the target's page.
#
# Fails open (exit 0, the real fetch runs) on every ambiguity: missing jq or
# curl, no cache directory, an unreadable or malformed entry, no stored
# validators, a HEAD that times out or errors, an empty cached body. A
# needless refetch costs tokens; serving a stale or wrong body would be a
# correctness bug.
#
# Overridable for testing (the defaults are what a real session uses):
#   NW_WEBFETCH_CACHE_DIR   cache root
#                           (${XDG_STATE_HOME:-$HOME/.local/state}/night-watchman/webfetch-cache)
#   NW_WEBFETCH_CACHE       set to "off" to disable the hook entirely
#   NW_WEBFETCH_CURL        the curl binary (curl)
#   NW_WEBFETCH_TIMEOUT     seconds allowed for the revalidating HEAD (10)
#
# Dependencies: bash 3.2, jq, curl, and one of shasum/md5/openssl.

set -u

CACHE_DIR="${NW_WEBFETCH_CACHE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/night-watchman/webfetch-cache}"
CURL_BIN="${NW_WEBFETCH_CURL:-curl}"
HEAD_TIMEOUT="${NW_WEBFETCH_TIMEOUT:-10}"

allow() {
  [ "${NW_WEBFETCH_DEBUG:-}" = "1" ] && echo "webfetch-cache-pre.sh: ${1:-allow} — allowing the fetch" >&2
  exit 0
}

[ "${NW_WEBFETCH_CACHE:-}" = "off" ] && allow "NW_WEBFETCH_CACHE=off"

command -v jq >/dev/null 2>&1 || allow "jq not found on PATH"

INPUT="$(cat)"
[ -n "$INPUT" ] || allow "empty stdin"

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
[ "$TOOL_NAME" = "WebFetch" ] || exit 0

URL="$(printf '%s' "$INPUT" | jq -r '.tool_input.url // empty' 2>/dev/null)"
[ -n "$URL" ] || allow "no .tool_input.url in hook payload"

# is_credentialed_url: true when $1 must never be cached or served from
# cache. Checked before the URL is hashed, so a credentialed URL leaves no
# trace in the cache directory at all.
is_credentialed_url() {
  _icu_url="$1"
  case "$_icu_url" in
    http://*|https://*) : ;;
    *) return 0 ;;
  esac
  _icu_rest="${_icu_url#*://}"
  _icu_authority="${_icu_rest%%/*}"
  case "$_icu_authority" in
    *@*) return 0 ;;
  esac
  case "$_icu_rest" in
    *\?*) _icu_query="$(printf '%s' "${_icu_rest#*\?}" | tr '[:upper:]' '[:lower:]')" ;;
    *) return 1 ;;
  esac
  case "$_icu_query" in
    *token*|*secret*|*apikey*|*api_key*|*password*|*passwd*|*signature*|*sig=*|*auth*|*access_key*|*credential*|*session*) return 0 ;;
  esac
  return 1
}

# key_for_url: a collision-resistant cache key for $1, hashed with shasum,
# then md5, then openssl. Returns 1 if none are on PATH.
key_for_url() {
  _kfu_u="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$_kfu_u" | shasum -a 256 2>/dev/null | awk '{print $1}'
    return 0
  fi
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$_kfu_u" | md5 2>/dev/null
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$_kfu_u" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
    return 0
  fi
  return 1
}

meta_field() {
  awk -F'\t' -v k="$2" '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }' "$1" 2>/dev/null
}

is_credentialed_url "$URL" && allow "credentialed or non-http(s) URL, never cached"

command -v "$CURL_BIN" >/dev/null 2>&1 || allow "$CURL_BIN not found on PATH"
[ -d "$CACHE_DIR" ] || allow "no cache directory at $CACHE_DIR"

KEY="$(key_for_url "$URL")" || allow "no hashing tool (shasum/md5/openssl) on PATH"
[ -n "$KEY" ] || allow "empty cache key derived for the URL"

META="$CACHE_DIR/$KEY.meta"
BODY="$CACHE_DIR/$KEY.body"
PROMPT_FILE="$CACHE_DIR/$KEY.prompt"

[ -r "$META" ] && [ -r "$BODY" ] || allow "no cache entry for this URL"
[ -s "$BODY" ] || allow "cached body is empty"

# A hash collision would serve another page's reading, so the entry's own
# record of its URL is checked rather than trusted from the filename.
CACHED_URL="$(meta_field "$META" url)"
[ "$CACHED_URL" = "$URL" ] || allow "cache entry URL does not match the requested URL"

ETAG="$(meta_field "$META" etag)"
LAST_MODIFIED="$(meta_field "$META" last_modified)"
STORED_AT="$(meta_field "$META" stored_at)"

[ -n "$ETAG" ] || [ -n "$LAST_MODIFIED" ] || allow "cache entry has no validators to revalidate with"

set -- -sS -I -m "$HEAD_TIMEOUT" -o /dev/null -w '%{http_code}'
[ -n "$ETAG" ] && set -- "$@" -H "If-None-Match: $ETAG"
[ -n "$LAST_MODIFIED" ] && set -- "$@" -H "If-Modified-Since: $LAST_MODIFIED"

STATUS="$("$CURL_BIN" "$@" -- "$URL" 2>/dev/null)"
CURL_RC=$?
[ "$CURL_RC" -eq 0 ] || allow "revalidating HEAD failed (curl exit $CURL_RC)"
[ "$STATUS" = "304" ] || allow "origin answered $STATUS, not 304"

CACHED_PROMPT="$(cat "$PROMPT_FILE" 2>/dev/null)"
[ -n "$CACHED_PROMPT" ] || CACHED_PROMPT="(not recorded)"

{
  echo "[webfetch-cache] The origin answered 304 Not Modified to a conditional"
  echo "HEAD, so this page is byte-identical to the copy cached on ${STORED_AT:-an unrecorded date}"
  echo "and the fetch was skipped. This is a revalidation against the origin"
  echo "just now, not a recalled memory: the content below is current."
  echo ""
  echo "URL: $URL"
  [ -n "$ETAG" ] && echo "ETag: $ETAG"
  [ -n "$LAST_MODIFIED" ] && echo "Last-Modified: $LAST_MODIFIED"
  echo ""
  echo "IMPORTANT — the text below is not the page. It is an earlier agent's"
  echo "reading of the page under THIS prompt:"
  echo ""
  echo "    $CACHED_PROMPT"
  echo ""
  echo "If that does not answer your question, the reading below may not"
  echo "either. Fetch the page yourself with a Bash \`curl\`, which this hook"
  echo "does not match."
  echo ""
  echo "--- cached reading ---"
  cat "$BODY"
} >&2

exit 2
