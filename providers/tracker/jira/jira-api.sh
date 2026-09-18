#!/bin/bash
#
# jira-api.sh — Jira Cloud REST API (/rest/api/3) client. The default
# implementation backing the `tracker` provider kind's `jira` name (see
# providers/README.md); also the jira-api.sh-shaped wrapper
# scripts/land-branch.sh's jira mode and providers/dispatch/herdr/herdr-ticket-start.sh
# expect at --jira-api PATH / $ISSUES_JIRA_API.
#
#   host        [tracker.jira] host = "..." in .night-watchman/config.toml,
#               or $NW_JIRA_HOST to override (mainly for testing)
#   credentials providers/secrets/read.sh jira.user / jira.token
#
# Usage:
#   jira-api.sh whoami                   # confirm auth works, print the account (no secret)
#   jira-api.sh projects                 # key, id, style, projectTypeKey for every project
#   jira-api.sh fields                   # every custom field: customfield_NNNNN id, name, type
#   jira-api.sh statuses <project-key>   # statuses in that project's workflow, by issue type
#   jira-api.sh issue <KEY>              # one issue: summary, status, type, assignee, reporter
#   jira-api.sh search <PROJECT> [--max N] [--token T]
#                                         # one page of {key, summary} for a project's issues,
#                                         # JSON, via /search/jql — see SEARCH below.
#   jira-api.sh raw GET <path>           # any read-only /rest/api/3/... call, redacted
#   jira-api.sh write <METHOD> <path> [json]   # a mutating call, guarded (see below)
#   jira-api.sh comment <KEY> <text>     # post a comment, one paragraph per input line
#   jira-api.sh comment <KEY> -          #   ('-' reads text from stdin)
#
# Global flags, before the subcommand:
#   --show-secrets   do not redact credential-shaped fields in the output
#   --dry-run        print the exact request that WOULD be issued and exit 0,
#                    on EVERY subcommand. Reaches no network, resolves no
#                    credential.
#   --yes            skip the interactive confirmation for POST/PUT/PATCH
#   --confirm <path> the DELETE confirmation, given non-interactively; must
#                    equal the path argument exactly
#
# WRITES. Every `write`/`comment` prints the method, the full URL and the
# body to stderr before it does anything. Then:
#   POST/PUT/PATCH  need --yes, or a y/N answer on a terminal.
#   DELETE          needs --confirm <path> matching the path exactly, or the
#                   same path typed back on a terminal. --yes does NOT cover
#                   a DELETE.
# With no terminal and no flag the run stops.
#
# A non-2xx response exits non-zero on EVERY path, `raw` included, and
# prints the (redacted) response body to stderr before dying.
#
# `search` prints its response UNREDACTED because the request is pinned to
# `fields=summary` here. Do not widen `fields=` without redacting it.

# shellcheck disable=SC1091  # sourced at paths computed from $0, not visible to shellcheck's static resolution
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$DIR/../../lib" && pwd)"
# shellcheck source=../../lib/kit.sh
. "$LIB_DIR/kit.sh"
# shellcheck source=../../lib/config.sh
. "$LIB_DIR/config.sh"
# shellcheck source=lib/http.sh
. "$DIR/lib/http.sh"
# shellcheck source=lib/jira-common.sh
. "$DIR/lib/jira-common.sh"

SECRETS_READ="$DIR/../../secrets/read.sh"


SHOW_SECRETS=0
DRY_RUN=0
ASSUME_YES=0
CONFIRM_ARG=""
HAVE_CONFIRM=0
while [ $# -gt 0 ]; do
    case "$1" in
        --show-secrets) SHOW_SECRETS=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --yes|-y)       ASSUME_YES=1; shift ;;
        --confirm)
            [ $# -ge 2 ] || die "--confirm needs a value, e.g. --confirm /project/PROJ"
            CONFIRM_ARG="$2"; HAVE_CONFIRM=1; shift 2
            ;;
        *) break ;;
    esac
done

[ $# -ge 1 ] || show_help
case "$1" in -h|--help|help) show_help ;; esac

need curl jq column

# +set, not :- — a harness passing NW_JIRA_HOST="$UNSET_VAR" must be a
# refusal, not a silent fall-through to the configured host.
if [ -n "${NW_JIRA_HOST+set}" ]; then
    [ -n "$NW_JIRA_HOST" ] || die "\$NW_JIRA_HOST is set but EMPTY — unset it to use the configured host, or give it one"
    HOST="$NW_JIRA_HOST"
else
    HOST=$(nw_config_get "tracker.jira.host") \
        || die "no Jira host configured — expected [tracker.jira] host = \"...\" in .night-watchman/config.toml, or \$NW_JIRA_HOST for testing"
fi
case "$HOST" in
    *[[:space:]]*|*/*|*@*|*:*) die "Jira host does not look like a bare hostname: '${HOST:0:40}'" ;;
esac


# valid_path <path> — the /rest/api/3 prefix is a string concatenation, not
# a boundary: `raw GET /../../../../rest/api/2/project/X` normalises on the
# wire to /rest/api/2/... and leaves the version pin behind. Make it one.
valid_path() {
    local p="$1"
    case "$p" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$p" in
        //*) return 1 ;;
        *[[:space:]]*) return 1 ;;
        *..*) return 1 ;;
    esac
    return 0
}

require_path() {
    valid_path "$1" || die "path must start with '/' and contain no '..', '//' or whitespace: '$1'"
}


JIRA_USER=""
JIRA_TOKEN=""
CREDS_LOADED=0
load_credentials() {
    [ "$CREDS_LOADED" = "1" ] && return 0
    [ -x "$SECRETS_READ" ] || die "secrets provider dispatcher not found or not executable: $SECRETS_READ"
    JIRA_USER=$("$SECRETS_READ" jira.user) || die "could not resolve secret ref jira.user through the configured secrets provider"
    JIRA_TOKEN=$("$SECRETS_READ" jira.token) || die "could not resolve secret ref jira.token through the configured secrets provider"
    CREDS_LOADED=1
}

# error_body <file> — print a failed response's body to stderr, redacted.
# Falls back redact_json -> redact_text -> die, never to an unredacted
# `cat`: a non-2xx body can echo a credential-shaped field straight back.
error_body() {
    local in="$1"
    if jq -e . >/dev/null 2>&1 < "$in"; then
        redact_json < "$in" >&2 \
            || redact_text < "$in" >&2 \
            || die "error_body: both redact_json and its redact_text fallback failed — refusing to print the response body unredacted"
    else
        redact_text < "$in" >&2 \
            || die "error_body: redact_text failed — refusing to print the response body unredacted"
    fi
    return 0
}


# api <METHOD> <path> [json-body] — dies on a non-2xx response and on a
# transport failure.
LABKIT_TIMEOUT="${LABKIT_TIMEOUT:-25}"
api() {
    local method="$1" path="$2" body="${3:-}" out code bodyfile rc
    load_credentials
    out=$(tmpfile) || die "could not create temp file"
    rc=0
    if [ -n "$body" ]; then
        bodyfile=$(tmpfile) || die "could not create temp file"
        printf '%s' "$body" > "$bodyfile"
        code=$(curl_auth_config "$JIRA_USER" "$JIRA_TOKEN" \
            | curl -s -m"$LABKIT_TIMEOUT" --config - -X "$method" \
                   -H 'Content-Type: application/json' \
                   --data-binary @"$bodyfile" \
                   -o "$out" -w '%{http_code}' \
                   "https://$HOST/rest/api/3$path") || rc=$?
    else
        code=$(curl_auth_config "$JIRA_USER" "$JIRA_TOKEN" \
            | curl -s -m"$LABKIT_TIMEOUT" --config - -X "$method" \
                   -o "$out" -w '%{http_code}' \
                   "https://$HOST/rest/api/3$path") || rc=$?
    fi
    [ "$rc" -eq 0 ] \
        || die "$method $path: could not reach https://$HOST (curl exit $rc) — check the configured tracker.jira.host, DNS and connectivity"
    case "$code" in
        2??) ;;
        *)
            warn "jira-api: HTTP $code $method $path"
            error_body "$out"
            die "$method $path failed (HTTP $code)"
            ;;
    esac
    cat "$out"
}

# emit <method> <path> [body] — run the request and print it, redacted
# unless --show-secrets.
emit() {
    local method="$1" path="$2" body="${3:-}" out
    if [ "$SHOW_SECRETS" = "1" ]; then
        warn "--show-secrets: credential fields are NOT redacted. Do not paste this."
        api "$method" "$path" "$body"
        return $?
    fi
    out=$(tmpfile) || die "could not create temp file"
    api "$method" "$path" "$body" > "$out"
    redact_json < "$out" || die "redact_json failed — refusing to print unredacted output"
}


view_whoami() {
    api GET /myself | jq -r "$JQ_PRELUDE"'
        "Account:    \(blank(.displayName))",
        "Email:      \(blank(.emailAddress))",
        "Account ID: \(blank(.accountId))",
        "Active:     \(.active)"'
}

# style/projectTypeKey are printed deliberately — a Work Management project
# can masquerade as the software project a script expected.
view_projects() {
    api GET '/project/search?maxResults=200' | jq -r "$JQ_PRELUDE"'.values[]
        | "\(blank(.key))\t\(.id)\t\(blank(.style))\t\(blank(.projectTypeKey))"' \
        | table "KEY	ID	STYLE	TYPE"
}

view_fields() {
    api GET /field | jq -r "$JQ_PRELUDE"'.[] | select(.custom == true)
        | "\(blank(.id))\t\(blank(.name))\t\(blank(.schema.type))"' \
        | sort | table "ID	NAME	TYPE"
}

view_statuses() {
    local key="$1"
    api GET "/project/$key/statuses" | jq -r "$JQ_PRELUDE"'.[]
        | .name as $issuetype
        | .statuses[] | "\(blank($issuetype))\t\(blank(.name))\t\(.id)\t\(blank(.statusCategory.name))"' \
        | table "ISSUE TYPE	STATUS	ID	CATEGORY"
}

# view_search <project-key> [--max N] [--token T] — one page of
# {issues:[{key,fields:{summary}}], nextPageToken}. /rest/api/3/search is
# 410 Gone on Jira Cloud; /search/jql is the replacement.
view_search() {
    local key="$1" max=100 token="" jql qs
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --max)
                [ $# -ge 2 ] || die "search: --max needs a value"
                max="$2"; shift 2
                ;;
            --token)
                [ $# -ge 2 ] || die "search: --token needs a value"
                token="$2"; shift 2
                ;;
            *) die "search: unknown argument '$1'" ;;
        esac
    done
    # Both checks: `case ... [A-Z]*)` validates only the first character,
    # and a crafted key would otherwise rewrite the JQL built below.
    case "$key" in
        [A-Z]*) ;;
        *) die "search: project key must look like a Jira key (e.g. PROJ), got '$key'" ;;
    esac
    case "$(printf '%s' "$key" | tr -d 'A-Z0-9')" in
        "") ;;
        *) die "search: project key must be A-Z0-9 only (starting with a letter), got '$key'" ;;
    esac
    case "$max" in
        ''|*[!0-9]*) die "search: --max must be a positive integer, got '$max'" ;;
    esac
    { [ "$max" -ge 1 ] && [ "$max" -le 100 ]; } \
        || die "search: --max must be between 1 and 100 (Jira's own per-page cap), got '$max'"
    jql=$(jq -rn --arg v "project = $key ORDER BY key ASC" '$v|@uri') \
        || die "search: could not URL-encode the JQL for project '$key'"
    qs="jql=$jql&fields=summary&maxResults=$max"
    if [ -n "$token" ]; then
        qs="$qs&nextPageToken=$(jq -rn --arg v "$token" '$v|@uri')" \
            || die "search: could not URL-encode --token"
    fi
    if [ "$DRY_RUN" = "1" ]; then
        show_request "GET" "/search/jql?$qs" "" "would issue:"
        exit 0
    fi
    api GET "/search/jql?$qs"
}

view_issue() {
    local key="$1"
    # Jira's issueIdOrKey path segment takes a bare numeric id as well as a
    # PROJECT-123 key. Scoped to this read-only GET; `comment` still
    # requires a real key.
    case "$key" in
        ''|*[!0-9]*)
            require_issue_key "$key" || die "$JIRA_KEY_ERR"
            ;;
    esac
    if [ "$DRY_RUN" = "1" ]; then
        show_request "GET" "/issue/$key" "" "would issue:"
        exit 0
    fi
    api GET "/issue/$key" | jq -r "$JQ_PRELUDE"'
        "Key:      \(blank(.key))",
        "Summary:  \(blank(.fields.summary))",
        "Status:   \(blank(.fields.status.name))",
        "Type:     \(blank(.fields.issuetype.name))",
        "Assignee: \(blank(.fields.assignee.displayName))",
        "Reporter: \(blank(.fields.reporter.displayName))",
        "Updated:  \(blank(.fields.updated))"'
}


# show_request <method> <path> <body> <prefix> — echo the exact request
# back, on stderr so `write ... | jq` still gets clean stdout.
show_request() {
    warn "$4 $1 https://$HOST/rest/api/3$2"
    [ -n "$3" ] && warn "$4 body: $3"
    return 0
}

# confirm_write <method> <path> — returns 0 to proceed, dies otherwise.
have_terminal() { [ -t 0 ] && [ -r /dev/tty ]; }
confirm_write() {
    local method="$1" path="$2" answer
    if [ "$method" = "DELETE" ]; then
        # --yes deliberately does NOT cover DELETE: a blanket flag cannot
        # catch a mistyped resource; naming it a second time can.
        if [ "$HAVE_CONFIRM" = "1" ]; then
            [ "$CONFIRM_ARG" = "$path" ] \
                || die "--confirm '$CONFIRM_ARG' does not match the path '$path' — refusing to DELETE"
            return 0
        fi
        have_terminal || die "DELETE needs confirmation and there is no terminal — pass --confirm '$path' if you really mean it"
        warn "About to DELETE the resource above. Type the path back to confirm:"
        IFS= read -r answer < /dev/tty || die "could not read confirmation"
        [ "$answer" = "$path" ] || die "confirmation '$answer' does not match '$path' — nothing was sent"
        return 0
    fi
    [ "$ASSUME_YES" = "1" ] && return 0
    have_terminal || die "$method needs confirmation and there is no terminal — pass --yes if you really mean it"
    warn "Issue this $method? [y/N]"
    IFS= read -r answer < /dev/tty || die "could not read confirmation"
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) die "not confirmed — nothing was sent" ;;
    esac
}


CMD="$1"; shift
case "$CMD" in
    whoami)
        if [ "$DRY_RUN" = "1" ]; then
            show_request "GET" "/myself" "" "would issue:"
            exit 0
        fi
        view_whoami
        ;;
    projects)
        if [ "$DRY_RUN" = "1" ]; then
            show_request "GET" "/project/search?maxResults=200" "" "would issue:"
            exit 0
        fi
        view_projects
        ;;
    fields)
        if [ "$DRY_RUN" = "1" ]; then
            show_request "GET" "/field" "" "would issue:"
            exit 0
        fi
        view_fields
        ;;
    statuses)
        [ $# -ge 1 ] || die "statuses needs a project key, e.g. statuses PROJ"
        if [ "$DRY_RUN" = "1" ]; then
            show_request "GET" "/project/$1/statuses" "" "would issue:"
            exit 0
        fi
        view_statuses "$1"
        ;;
    issue)
        [ $# -ge 1 ] || die "issue needs an issue key, e.g. issue PROJ-1"
        view_issue "$1"
        ;;
    search)
        [ $# -ge 1 ] || die "search needs a project key, e.g. search PROJ [--max N] [--token T]"
        view_search "$@"
        ;;
    raw)
        [ $# -ge 2 ] || die "raw needs a METHOD and a path, e.g. raw GET /myself"
        METHOD="$1"; RAWPATH="$2"
        case "$METHOD" in
            GET|HEAD) ;;
            *) die "raw is read-only and takes GET or HEAD — use 'write $METHOD $RAWPATH' for a mutating call, which is guarded" ;;
        esac
        require_path "$RAWPATH"
        if [ "$DRY_RUN" = "1" ]; then
            show_request "$METHOD" "$RAWPATH" "" "would issue:"
            exit 0
        fi
        emit "$METHOD" "$RAWPATH" ""
        ;;
    comment)
        [ $# -ge 2 ] || die "comment needs an issue key and text, e.g. comment PROJ-1 'note' — or comment PROJ-1 - to read text from stdin"
        CKEY="$1"; shift
        require_issue_key "$CKEY" || die "$JIRA_KEY_ERR"
        if [ "$1" = "-" ]; then
            [ $# -eq 1 ] || die "comment: '-' (read text from stdin) takes no further arguments"
            CTEXT=$(cat) || die "could not read comment text from stdin"
        else
            [ $# -eq 1 ] || die "comment takes exactly one text argument — quote multi-word text, or pass '-' to read from stdin"
            CTEXT="$1"
        fi
        [ -n "$CTEXT" ] || die "comment text is empty — refusing to post an empty comment"
        CBODY=$(jira_comment_body "$CTEXT") || die "could not build the Jira comment body"
        CPATH="/issue/$CKEY/comment"
        require_path "$CPATH"
        if [ "$DRY_RUN" = "1" ]; then
            show_request "POST" "$CPATH" "$CBODY" "would issue:"
            warn "--dry-run: nothing was sent, no credential was resolved."
            exit 0
        fi
        show_request "POST" "$CPATH" "$CBODY" "about to issue:"
        confirm_write "POST" "$CPATH"
        # Not emit(): the response is parsed for one named field (.id), the
        # same trust boundary the view_* helpers draw.
        CRESP_FILE=$(tmpfile) || die "could not create temp file"
        api POST "$CPATH" "$CBODY" > "$CRESP_FILE"
        CID=$(jq -r '.id // empty' < "$CRESP_FILE") \
            || die "could not parse the created comment's id from the response"
        [ -n "$CID" ] || die "POST $CPATH succeeded but the response carried no comment id"
        echo "Comment $CID posted on $CKEY"
        ;;
    write)
        [ $# -ge 2 ] || die "write needs a METHOD and a path, e.g. write POST /field '{...}'"
        METHOD="$1"; RAWPATH="$2"; BODY="${3:-}"
        case "$METHOD" in
            POST|PUT|PATCH|DELETE) ;;
            GET|HEAD) die "write is for mutating methods — use 'raw $METHOD $RAWPATH'" ;;
            *) die "write takes POST, PUT, PATCH or DELETE (got '$METHOD')" ;;
        esac
        require_path "$RAWPATH"
        if [ "$DRY_RUN" = "1" ]; then
            show_request "$METHOD" "$RAWPATH" "$BODY" "would issue:"
            warn "--dry-run: nothing was sent, no credential was resolved."
            exit 0
        fi
        show_request "$METHOD" "$RAWPATH" "$BODY" "about to issue:"
        confirm_write "$METHOD" "$RAWPATH"
        emit "$METHOD" "$RAWPATH" "$BODY"
        ;;
    *) die "unknown command '$CMD' — run with --help" ;;
esac
