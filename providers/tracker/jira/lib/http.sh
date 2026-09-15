#!/bin/bash
#
# http.sh — the curl/jq helpers a real HTTP API client needs that
# providers/lib/kit.sh (die/warn/need/show_help/known_command/tmpfile)
# deliberately does not carry: a credential goes on curl's stdin config,
# never argv (rule: secrets never enter argv), and any JSON this layer
# prints on a caller's behalf is redacted first (rule: a `raw`/`write`
# passthrough is not an excuse to print an unfiltered response).
#
# Source AFTER providers/lib/kit.sh — warn/die are used below but not
# defined here.
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`, no
# `readarray`/`mapfile`).

# --------------------------------------------------------------- curl config

# curl_auth_config <user> <pass> — emit a curl config carrying HTTP Basic
# auth. Feed to `curl --config -` on stdin so the credential never enters
# curl's argv, where any same-uid process could read it via `ps`/`/proc`.
curl_auth_config() { printf 'user = "%s:%s"\n' "$1" "$2"; }

# --------------------------------------------------------------- redaction
#
# KIT_SECRET_WORDS / KIT_SECRET_FRAGMENTS — the key-name shapes redact_json
# treats as credential-bearing. WORDS match as a whole underscore-delimited
# word after normalising the key name (camelCase and punctuation both
# folded to underscores); FRAGMENTS match anywhere inside a single word,
# for the handful of morphemes (password, token, secret, ...) that appear
# in English essentially nowhere except as part of a credential, so
# unbounded matching costs nothing (a key like `apiTokenValue` still needs
# to be caught even though `token` isn't the whole word — and, because
# norm() splits camelCase/snake_case into underscore-delimited words before
# testing, a field ending in Token/Secret/Password (`refreshToken`,
# `adminPassword`) is already caught by the same anchored WORDS match, with
# no separate "ends with" rule needed).
#
# Deliberately EXCLUDES the bare words "key" and "id": a Jira issue's own
# `key` field (e.g. "PROJ-1") and numeric `id` are not credentials, and
# blanking them broke exactly the callers that need them back whole —
# `provider.sh fetch`/`create`'s readback, and the same KEY READBACK
# problem recorded against jira-import.sh (memorygraph, 2026-09-11).
# Compound credential names that happen to contain "key" as one half
# (`api_key`, `private_key`) are still caught — they are listed here as
# whole words, not via a bare "key" fragment.
KIT_SECRET_WORDS="pass passwd password passphrase secret client_secret token access_token refresh_token api_key apikey private_key credential credentials authorization bearer session cookie"
KIT_SECRET_FRAGMENTS="password passwd passphrase secret token credential apikey"

# redact_json — read JSON on stdin, print it on stdout with any
# credential-shaped field's value replaced by "<redacted>". Recurses into
# objects/arrays; leaves an explicit null or empty string alone (blanking
# them loses the only information they carry, and neither is a live
# credential). A bare Jira issue `key` or `id` field is never redacted —
# see KIT_SECRET_WORDS above.
redact_json() {
    if ! command -v jq >/dev/null 2>&1; then
        warn "redact_json: jq not found — refusing to print unredacted API output"
        return 1
    fi
    local regex
    regex="_($(printf '%s' "$KIT_SECRET_WORDS" | tr ' ' '|'))_"
    regex="$regex|($(printf '%s' "$KIT_SECRET_FRAGMENTS" | tr ' ' '|'))"
    jq --arg re "$regex" '
      def norm:
        gsub("(?<a>[A-Za-z0-9])(?<b>[A-Z][a-z])"; "\(.a)_\(.b)")
        | gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a)_\(.b)")
        | ascii_downcase
        | gsub("[^a-z0-9]+"; "_");
      def secretish: "_" + norm + "_" | test($re);
      def redactable: type != "null" and (type != "string" or length > 0);
      def scrub:
        if type == "object" then
          with_entries(if (.key | secretish) and (.value | redactable)
                       then .value = "<redacted>"
                       else .value |= scrub
                       end)
        elif type == "array" then map(scrub)
        else . end;
      scrub
    '
}

# redact_text — read arbitrary text on stdin, print it on stdout with any
# credential-shaped key's value replaced by "<redacted>". Fallback for a
# body that is not valid JSON (an HTML error page from a proxy in front of
# Jira) or that redact_json itself could not process — redact_json handles
# the JSON case with real value boundaries; this does not even try to find
# a value's closing delimiter in unstructured text, because a delimiter
# class can never be complete (a JSON string value can carry an escaped
# quote — `abc\"def` — past a `[^"]*` stop; a plain key=value can carry a
# comma or semicolon in the value itself — a `Cookie:`/`Authorization:`
# header routinely does — past a `[^,;]*` stop). Both are real leaks, not
# hypothetical: either one lets a value's TAIL past the false stop print in
# clear. So this fails CLOSED instead: once a credential-shaped key and its
# `:`/`=` separator are seen, EVERYTHING from there to end of line is
# replaced, with no attempt to stop at the value's real end. This can never
# leave a tail exposed, at the cost of over-redacting neighbouring text on
# the same line — the same trade `error_body`'s doc comment already accepts
# ("over-redacting costs nothing; under-redacting leaks a credential").
#
# Case-insensitive via sed's `I` flag on the substitute command — a
# GNU/BSD sed extension, not POSIX, but honoured by both stock macOS sed
# and GNU sed, the two `sed`s this codebase runs under. Does not
# camelCase-normalise the key name the way redact_json's own `secretish`
# does (so `apiToken` still matches only because it contains the bare word
# `token`, not because of normalisation) — accepted: this is a text
# fallback erring toward whole-line over-redaction, not a byte-for-byte
# mirror of redact_json's word-boundary logic.
redact_text() {
    local alt
    alt=$(printf '%s %s' "$KIT_SECRET_WORDS" "$KIT_SECRET_FRAGMENTS" \
        | tr ' ' '\n' | sort -u | tr '\n' '|')
    alt="${alt%|}"
    sed -E "s/([A-Za-z0-9_\"']*(${alt})[A-Za-z0-9_\"']*[[:space:]]*[:=][[:space:]]*).*/\\1<redacted>/I"
}

# --------------------------------------------------------------- output
#
# JQ_PRELUDE — shared filters.
#   clean    : turn "" and null into null, so `//` fallbacks actually fire
#   blank(v) : v, or "-" when absent or empty
# An empty field silently collapses a `column -t` layout and shifts every
# later value under the wrong header, so every rendered field should go
# through blank().
# shellcheck disable=SC2034  # used by sourcing scripts inside jq programs
JQ_PRELUDE='def clean: if (. // "") == "" then null else . end;
            def blank(v): (v | clean) // "-";'

# table <tab-separated-header> — read TSV rows on stdin, render aligned.
table() {
    { printf '%s\n' "$1"; cat; } | column -t -s"$(printf '\t')"
}
