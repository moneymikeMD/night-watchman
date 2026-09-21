#!/bin/bash
#
# webfetch-cache-post.sh — Claude Code PostToolUse hook for WebFetch. Stores
# the reading WebFetch just produced together with the ETag and Last-Modified
# the origin is advertising right now, so webfetch-cache-pre.sh can
# revalidate it on the next request for the same URL.
#
# Usage: not a CLI. Fed the PostToolUse payload on stdin.
#
# Always exits 0. A PostToolUse hook cannot improve a result that has already
# been produced, and a caching failure must never turn a successful WebFetch
# into a failed tool call.
#
# An entry is stored only when the origin advertises at least one validator.
# Without an ETag or a Last-Modified there is nothing to revalidate against,
# and this cache has no TTL to fall back on, so the entry would be unusable —
# see webfetch-cache-pre.sh for why that is deliberate.
#
# Claude Code does not hand a hook the tool's response headers, so the
# validators come from a separate HEAD this hook issues itself. That HEAD can
# in principle observe a newer page than WebFetch read a moment earlier; the
# cost of that race is one stale entry which the next revalidation will not
# catch. Cheap insurance against it is that the write is skipped whenever the
# HEAD is not a clean 200.
#
# Overridable for testing — same variables as webfetch-cache-pre.sh, plus:
#   NW_WEBFETCH_MAX_BYTES   largest reading stored, in bytes (262144)
#
# Dependencies: bash 3.2, jq, curl, and one of shasum/md5/openssl.

set -u

CACHE_DIR="${NW_WEBFETCH_CACHE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/night-watchman/webfetch-cache}"
CURL_BIN="${NW_WEBFETCH_CURL:-curl}"
HEAD_TIMEOUT="${NW_WEBFETCH_TIMEOUT:-10}"
MAX_BYTES="${NW_WEBFETCH_MAX_BYTES:-262144}"

skip() {
  [ "${NW_WEBFETCH_DEBUG:-}" = "1" ] && echo "webfetch-cache-post.sh: ${1:-skip} — not caching" >&2
  exit 0
}

[ "${NW_WEBFETCH_CACHE:-}" = "off" ] && skip "NW_WEBFETCH_CACHE=off"

command -v jq >/dev/null 2>&1 || skip "jq not found on PATH"

INPUT="$(cat)"
[ -n "$INPUT" ] || skip "empty stdin"

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
[ "$TOOL_NAME" = "WebFetch" ] || exit 0

URL="$(printf '%s' "$INPUT" | jq -r '.tool_input.url // empty' 2>/dev/null)"
[ -n "$URL" ] || skip "no .tool_input.url in hook payload"

PROMPT="$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null)"

BODY_TEXT="$(printf '%s' "$INPUT" | jq -r '
  (.tool_response // empty) as $r
  | if ($r | type) == "string" then $r
    elif ($r | type) == "object" then ($r.result // $r.output // $r.text // ($r | tostring))
    else ""
    end' 2>/dev/null)"
[ -n "$BODY_TEXT" ] || skip "no usable .tool_response in hook payload"

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

# header_value: last occurrence of header $2 in the header block on stdin,
# so a redirect chain yields the final response's validator, not the 301's.
header_value() {
  awk -v want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
    { line = $0; sub(/\r$/, "", line)
      split(line, kv, ":")
      name = tolower(kv[1])
      if (name == want) {
        sub(/^[^:]*:[ \t]*/, "", line)
        found = line
      }
    }
    END { if (found != "") print found }'
}

is_credentialed_url "$URL" && skip "credentialed or non-http(s) URL, never cached"

BODY_BYTES="$(printf '%s' "$BODY_TEXT" | wc -c | tr -d ' ')"
[ "${BODY_BYTES:-0}" -le "$MAX_BYTES" ] || skip "reading is $BODY_BYTES bytes, over the $MAX_BYTES cap"

command -v "$CURL_BIN" >/dev/null 2>&1 || skip "$CURL_BIN not found on PATH"

KEY="$(key_for_url "$URL")" || skip "no hashing tool (shasum/md5/openssl) on PATH"
[ -n "$KEY" ] || skip "empty cache key derived for the URL"

HEADERS="$("$CURL_BIN" -sS -L -I -m "$HEAD_TIMEOUT" -- "$URL" 2>/dev/null)" || skip "validator HEAD failed"
[ -n "$HEADERS" ] || skip "validator HEAD returned no headers"

STATUS_LINE="$(printf '%s\n' "$HEADERS" | awk '/^HTTP\// { code = $2; gsub(/\r/, "", code); last = code } END { print last }')"
[ "$STATUS_LINE" = "200" ] || skip "validator HEAD answered $STATUS_LINE, not 200"

ETAG="$(printf '%s\n' "$HEADERS" | header_value etag)"
LAST_MODIFIED="$(printf '%s\n' "$HEADERS" | header_value last-modified)"
[ -n "$ETAG" ] || [ -n "$LAST_MODIFIED" ] || skip "origin advertises no ETag or Last-Modified"

mkdir -p "$CACHE_DIR" 2>/dev/null || skip "could not create cache directory $CACHE_DIR"
[ -w "$CACHE_DIR" ] || skip "cache directory $CACHE_DIR is not writable"

TMP="$CACHE_DIR/.$KEY.$$"
printf '%s' "$BODY_TEXT" > "$TMP.body" 2>/dev/null || { rm -f "$TMP".*; skip "could not write cached body"; }
printf '%s' "$PROMPT" > "$TMP.prompt" 2>/dev/null || { rm -f "$TMP".*; skip "could not write cached prompt"; }
{
  printf 'url\t%s\n' "$URL"
  [ -n "$ETAG" ] && printf 'etag\t%s\n' "$ETAG"
  [ -n "$LAST_MODIFIED" ] && printf 'last_modified\t%s\n' "$LAST_MODIFIED"
  printf 'stored_at\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'bytes\t%s\n' "$BODY_BYTES"
} > "$TMP.meta" 2>/dev/null || { rm -f "$TMP".*; skip "could not write cache metadata"; }

# Body and prompt land before the metadata the pre-hook gates on, so a crash
# mid-write leaves no entry the pre-hook will serve.
mv -f "$TMP.body" "$CACHE_DIR/$KEY.body" 2>/dev/null || { rm -f "$TMP".*; skip "could not install cached body"; }
mv -f "$TMP.prompt" "$CACHE_DIR/$KEY.prompt" 2>/dev/null
mv -f "$TMP.meta" "$CACHE_DIR/$KEY.meta" 2>/dev/null || { rm -f "$TMP".*; skip "could not install cache metadata"; }
rm -f "$TMP".* 2>/dev/null

exit 0
