#!/bin/bash
#
# atlassian-common.sh — what confluence.sh and townsquare.sh share: the
# site host, the credential pair, the error-body printer, and the write
# confirmation. Sourced only; not a CLI.
#
# Source AFTER providers/lib/kit.sh, providers/lib/config.sh and the HTTP
# helper lib (curl_auth_config, redact_json, redact_text, JQ_PRELUDE).
# That helper lib lives at providers/tracker/jira/lib/http.sh: it is the
# only copy in the plugin, and a second copy here would let the redaction
# word list drift between two Atlassian clients hitting the same site.
#
# HOST, highest priority first:
#   $NW_ATLASSIAN_HOST              per-run override (+set: EMPTY refuses)
#   [publish.atlassian] host        this kind's own config
#   [tracker.jira] host             the same site, when the tracker is Jira
#
# CREDENTIALS come from the configured `secrets` provider. The refs default
# to jira.user / jira.token (one Atlassian account serves Jira, Confluence
# and the GraphQL gateway); set [publish.atlassian] user_ref / token_ref to
# use a different pair.
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

ATL_SECRETS_READ="$ATL_PROVIDERS_DIR/secrets/read.sh"
LABKIT_TIMEOUT="${LABKIT_TIMEOUT:-25}"

# atl_resolve_host — sets HOST or dies. Top-level call, never inside $( ).
atl_resolve_host() {
    if [ -n "${NW_ATLASSIAN_HOST+set}" ]; then
        [ -n "$NW_ATLASSIAN_HOST" ] || die "\$NW_ATLASSIAN_HOST is set but EMPTY — unset it to use the configured host, or give it one"
        HOST="$NW_ATLASSIAN_HOST"
    else
        HOST=$(nw_config_get "publish.atlassian.host" "")
        [ -n "$HOST" ] || HOST=$(nw_config_get "tracker.jira.host" "")
        [ -n "$HOST" ] || die "no Atlassian host configured — expected [publish.atlassian] host or [tracker.jira] host in .night-watchman/config.toml, or \$NW_ATLASSIAN_HOST for testing"
    fi
    case "$HOST" in
        *[[:space:]]*|*/*|*@*|*:*) die "Atlassian host does not look like a bare hostname: '${HOST:0:40}'" ;;
    esac
}

ATL_USER=""
ATL_TOKEN=""
ATL_CREDS_LOADED=0
# shellcheck disable=SC2034  # ATL_USER/ATL_TOKEN are read by the sourcing client's api()
atl_load_credentials() {
    local uref tref
    [ "$ATL_CREDS_LOADED" = "1" ] && return 0
    [ -x "$ATL_SECRETS_READ" ] || die "secrets provider dispatcher not found or not executable: $ATL_SECRETS_READ"
    uref=$(nw_config_get "publish.atlassian.user_ref" "jira.user")
    tref=$(nw_config_get "publish.atlassian.token_ref" "jira.token")
    ATL_USER=$("$ATL_SECRETS_READ" "$uref") || die "could not resolve secret ref $uref through the configured secrets provider"
    ATL_TOKEN=$("$ATL_SECRETS_READ" "$tref") || die "could not resolve secret ref $tref through the configured secrets provider"
    ATL_CREDS_LOADED=1
}

# atl_error_body <file> — redacted to stderr, capped. JSON goes through
# redact_json then redact_text; anything else through redact_text alone;
# never an unredacted cat.
ATL_ERROR_BODY_MAX_BYTES=4096
atl_error_body() {
    local in="$1" cur next
    cur=$(tmpfile) || { warn "(response body withheld: no temp file)"; return 0; }
    if jq -e . >/dev/null 2>&1 < "$in" && redact_json < "$in" > "$cur" 2>/dev/null; then
        next=$(tmpfile) || next=""
        if [ -n "$next" ] && redact_text < "$cur" > "$next" 2>/dev/null; then cur="$next"; fi
    elif ! redact_text < "$in" > "$cur" 2>/dev/null; then
        printf '(response body could not be redacted — withheld)' > "$cur"
    fi
    if [ -s "$cur" ]; then
        printf '%s\n' "$(head -c "$ATL_ERROR_BODY_MAX_BYTES" < "$cur")" >&2
    fi
    return 0
}

atl_have_terminal() { [ -t 0 ] && [ -r /dev/tty ]; }

# atl_confirm WHAT — --yes, or a y/N on a terminal; dies otherwise.
atl_confirm() {
    local answer
    [ "${ASSUME_YES:-0}" = "1" ] && return 0
    atl_have_terminal || die "$1 needs confirmation and there is no terminal — pass --yes if you really mean it"
    warn "Issue $1? [y/N]"
    IFS= read -r answer < /dev/tty || die "could not read confirmation"
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) die "not confirmed — nothing was sent" ;;
    esac
}
