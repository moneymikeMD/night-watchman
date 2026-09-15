#!/bin/bash
#
# provider.sh — atlassian's implementation of the `publish` provider kind
# (verbs: publish-brief, post-headline — see ../../README.md for the
# contract). The system of record is Confluence (confluence.sh); the
# status feed is Atlassian Home Projects (townsquare.sh).
#
# Usage:
#   provider.sh [--dry-run] publish-brief <title> <body.md>
#   provider.sh [--dry-run] post-headline <project-ref> <text> <url>
#
# publish-brief writes <body.md> (markdown) as a page titled <title> under
# this project's "<project_name> Project Updates" page, which is itself a
# child of the configured root page and is created on first run if it is
# missing. Prints the brief's URL on stdout. Safe to run twice: when a page
# with <title> already exists under the project page, its URL is printed
# and nothing is written — a published brief is never overwritten.
#
# post-headline posts "<text> <url>" to a project status feed, the whole
# summary capped at 236 characters (<text> is shortened with "…" when it
# does not fit; <url> is never cut). <project-ref> is one of:
#   default                           [publish.atlassian] project_feed
#   an epic/ticket key (e.g. PROJ-12) [publish.atlassian.feeds] PROJ-12
#   ari:cloud:townsquare:...          used as given
# Prints the confirmation line from townsquare.sh. A rejected post exits
# 1; callers publishing to several feeds are expected to note the failure
# and carry on with the next one (fail soft per feed).
#
# Config (.night-watchman/config.toml):
#   [publish.atlassian]
#   host          = "..."   optional; falls back to [tracker.jira] host
#   space         = "..."   numeric Confluence space id
#   root_page     = "..."   numeric id of the page project pages sit under
#   project_name  = "..."   titles the "<project_name> Project Updates" page
#   project_feed  = "..."   Home Project ARI for `default`
#   status        = "..."   state posted with each headline (default on_track)
#   user_ref      = "..."   secrets ref (default jira.user)
#   token_ref     = "..."   secrets ref (default jira.token)
#   [publish.atlassian.feeds]
#   PROJ-12       = "ari:cloud:townsquare:..."
#
# Writes are LIVE by default (--yes is passed to the clients), so a wrap-up
# can call this unattended. $NW_DRY_RUN=1 or --dry-run before the verb makes
# every verb print the requests it would issue and exit 0 with no network
# and no credential.
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

# shellcheck disable=SC1091  # sourced at paths computed from $0
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$(cd "$DIR/../.." && pwd)"
# shellcheck source=../../lib/kit.sh
. "$PROVIDERS_DIR/lib/kit.sh"
# shellcheck source=../../lib/config.sh
. "$PROVIDERS_DIR/lib/config.sh"

CONFLUENCE="$DIR/confluence.sh"
TOWNSQUARE="$DIR/townsquare.sh"
SUMMARY_CAP=236

DRY_RUN=0
[ "${NW_DRY_RUN:-0}" = "1" ] && DRY_RUN=1
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi
# The clients read NW_DRY_RUN themselves; export it so no call below can
# forget the flag.
if [ "$DRY_RUN" = "1" ]; then export NW_DRY_RUN=1; fi

verb="${1:-}"
[ -n "$verb" ] && shift

# cfg KEY — a required [publish.atlassian] key, or die naming it.
cfg() {
    local v
    v=$(nw_config_get "publish.atlassian.$1" "")
    [ -n "$v" ] || die "missing config: [publish.atlassian] $1 in .night-watchman/config.toml"
    printf '%s\n' "$v"
}

case "$verb" in
    publish-brief)
        [ $# -eq 2 ] || die "usage: provider.sh [--dry-run] publish-brief <title> <body.md>"
        TITLE="$1"; BODY="$2"
        [ -n "$TITLE" ] || die "publish-brief: title is empty"
        [ -f "$BODY" ] && [ -r "$BODY" ] || die "publish-brief: body file not readable: $BODY"
        [ -s "$BODY" ] || die "publish-brief: body file is empty: $BODY"
        SPACE=$(cfg space) || exit 1
        ROOT=$(cfg root_page) || exit 1
        PNAME=$(cfg project_name) || exit 1
        PTITLE="$PNAME Project Updates"

        if [ "$DRY_RUN" = "1" ]; then
            "$CONFLUENCE" find-child "$ROOT" "$PTITLE"
            printf 'Wave briefs for %s, newest first.\n' "$PNAME" \
                | "$CONFLUENCE" --markdown create --space "$SPACE" --parent "$ROOT" --title "$PTITLE" -
            warn "(dry run: the brief's parent id is only known after the lookup above; shown as $ROOT)"
            "$CONFLUENCE" find-child "$ROOT" "$TITLE"
            "$CONFLUENCE" --markdown create --space "$SPACE" --parent "$ROOT" --title "$TITLE" - < "$BODY"
            exit 0
        fi

        PID=$("$CONFLUENCE" find-child "$ROOT" "$PTITLE") || die "could not look up '$PTITLE' under page $ROOT"
        if [ -z "$PID" ]; then
            LINE=$(printf 'Wave briefs for %s, newest first.\n' "$PNAME" \
                | "$CONFLUENCE" --yes --markdown create --space "$SPACE" --parent "$ROOT" --title "$PTITLE" -) \
                || die "could not create '$PTITLE' under page $ROOT"
            PID=$(printf '%s\n' "$LINE" | sed -nE 's/^Created page ([0-9]+): .*/\1/p')
            [ -n "$PID" ] || die "created '$PTITLE' but could not read its id from: $LINE"
            warn "created $PTITLE (page $PID)"
        fi

        EXISTING=$("$CONFLUENCE" find-child "$PID" "$TITLE") || die "could not look up '$TITLE' under page $PID"
        if [ -n "$EXISTING" ]; then
            SITE=$("$CONFLUENCE" print-host) || die "could not resolve the Confluence host"
            warn "'$TITLE' already exists under $PTITLE (page $EXISTING) — not overwriting"
            printf 'https://%s/wiki/pages/viewpage.action?pageId=%s\n' "$SITE" "$EXISTING"
            exit 0
        fi
        LINE=$("$CONFLUENCE" --yes --markdown create --space "$SPACE" --parent "$PID" --title "$TITLE" - < "$BODY") \
            || die "could not create '$TITLE' under page $PID"
        URL=$(printf '%s\n' "$LINE" | sed -nE 's/^Created page [0-9]+: .* \((https:[^ ]+)\)$/\1/p')
        [ -n "$URL" ] || die "created '$TITLE' but could not read its URL from: $LINE"
        printf '%s\n' "$URL"
        ;;
    post-headline)
        [ $# -eq 3 ] || die "usage: provider.sh [--dry-run] post-headline <project-ref> <text> <url>"
        REF="$1"; TEXT="$2"; URL="$3"
        [ -n "$TEXT" ] || die "post-headline: text is empty"
        case "$URL" in
            https://*) ;;
            *) die "post-headline: url must start with https:// — got '${URL:0:60}'" ;;
        esac
        case "$REF" in
            ari:cloud:townsquare:*) FEED="$REF" ;;
            default) FEED=$(cfg project_feed) || exit 1 ;;
            *[!A-Za-z0-9_-]*|"") die "post-headline: project-ref must be 'default', a key like PROJ-12, or a Home Project ARI — got '${REF:0:60}'" ;;
            *)
                FEED=$(nw_config_get "publish.atlassian.feeds.$REF" "")
                [ -n "$FEED" ] || die "post-headline: no status feed mapped for '$REF' — add it under [publish.atlassian.feeds]"
                ;;
        esac
        STATUS=$(nw_config_get publish.atlassian.status "on_track")
        SUMMARY=$(jq -rn --arg t "$TEXT" --arg u "$URL" --argjson cap "$SUMMARY_CAP" '
            ($cap - ($u | length) - 1) as $room
            | if $room < 2 then error("url alone is too long for the \($cap)-character summary cap")
              elif ($t | length) <= $room then "\($t) \($u)"
              else "\($t[0:($room - 1)])… \($u)" end') \
            || die "post-headline: could not fit the headline and url into $SUMMARY_CAP characters"
        if [ "$DRY_RUN" = "1" ]; then
            printf '%s' "$SUMMARY" | "$TOWNSQUARE" update "$FEED" "$STATUS" -
            exit 0
        fi
        printf '%s' "$SUMMARY" | "$TOWNSQUARE" --yes update "$FEED" "$STATUS" -
        ;;
    "")
        echo "Error: usage: provider.sh [--dry-run] VERB [ARG...] (verbs: publish-brief, post-headline)" >&2
        exit 1
        ;;
    *)
        echo "Error: unknown publish verb: $verb (contract: publish-brief, post-headline)" >&2
        exit 1
        ;;
esac
