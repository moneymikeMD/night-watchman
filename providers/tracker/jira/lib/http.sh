#!/bin/bash
#
# http.sh — the curl/jq helpers providers/lib/kit.sh does not carry:
# credentials on curl's stdin config (never argv), and redaction for any
# JSON this layer prints on a caller's behalf.
#
# Source AFTER providers/lib/kit.sh — warn/die are used below but not
# defined here.
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`, no
# `readarray`/`mapfile`).


# curl_auth_config <user> <pass> — emit a curl config carrying HTTP Basic
# auth. Feed to `curl --config -` on stdin; never on curl's argv, which any
# same-uid process can read via `ps`/`/proc`.
curl_auth_config() { printf 'user = "%s:%s"\n' "$1" "$2"; }

# WORDS match a whole word after norm(); FRAGMENTS match inside one.
# The bare words "key"/"id" are excluded on purpose: blanking a Jira issue's
# own key broke provider.sh fetch/create's readback.
KIT_SECRET_WORDS="pass passwd password passphrase secret client_secret token access_token refresh_token api_key apikey private_key credential credentials authorization bearer session cookie"
KIT_SECRET_FRAGMENTS="password passwd passphrase secret token credential apikey"

# redact_json — read JSON on stdin, print it on stdout with any
# credential-shaped field's value replaced by "<redacted>". Recurses into
# objects/arrays; leaves an explicit null or empty string alone.
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

# redact_text — stdin to stdout, each credential-shaped key's value replaced
# by "<redacted>"; the fallback for a body redact_json cannot handle. Fails
# CLOSED to end of line: any delimiter class is incomplete and leaks the tail.
redact_text() {
    local alt
    alt=$(printf '%s %s' "$KIT_SECRET_WORDS" "$KIT_SECRET_FRAGMENTS" \
        | tr ' ' '\n' | sort -u | tr '\n' '|')
    alt="${alt%|}"
    sed -E "s/([A-Za-z0-9_\"']*(${alt})[A-Za-z0-9_\"']*[[:space:]]*[:=][[:space:]]*).*/\\1<redacted>/I"
}

# JQ_PRELUDE — shared filters. Every rendered field should go through
# blank(): an empty one collapses a `column -t` layout and shifts every
# later value under the wrong header.
# shellcheck disable=SC2034  # used by sourcing scripts inside jq programs
JQ_PRELUDE='def clean: if (. // "") == "" then null else . end;
            def blank(v): (v | clean) // "-";'

# table <tab-separated-header> — read TSV rows on stdin, render aligned.
table() {
    { printf '%s\n' "$1"; cat; } | column -t -s"$(printf '\t')"
}
