#!/bin/bash
#
# confluence.sh — Confluence Cloud REST client (/wiki/api/v2), the
# system-of-record half of the `publish` kind's `atlassian` implementation
# (see providers/README.md). Ships read, find-child and create only: there
# is no update and no delete, so publishing can never rewrite or remove an
# existing page.
#
# Usage:
#   confluence.sh print-host                  # the resolved, validated site host (no request)
#   confluence.sh whoami                      # the account the credential belongs to
#   confluence.sh page <id>                   # page metadata, redacted
#   confluence.sh children <id>               # child pages (all pages of results), redacted
#   confluence.sh find-child <parent> <title> # prints the id of the child with that
#                                             # EXACT title, or nothing (exit 0)
#   confluence.sh raw GET <path>              # any read-only /wiki/... call, redacted
#   confluence.sh create --space <id> --parent <id> --title <t> -
#                                             # body on stdin: storage-format HTML,
#                                             # or markdown with --markdown
#
# Global flags, before the subcommand:
#   --dry-run      print the exact request that WOULD be issued, exit 0.
#                  Reaches no network and resolves no credential, for
#                  every subcommand. Also on with $NW_DRY_RUN=1.
#   --yes          skip the interactive confirmation for create
#   --markdown     on create: convert a small markdown subset (# headings,
#                  - bullets, **bold**, `code`, ``` fences, [text](url))
#                  to storage format before sending. Tables, nested lists
#                  and images are not supported.
#   --show-secrets do not redact credential-shaped fields in read output
#
# `create` prints one line: `Created page <id>: <title> (<url>)`, where
# <url> is the page's tiny link when the response carries one.
#
# API facts this relies on (recorded live, see fixtures/confluence/*.json):
#   - An INVALID credential gets HTTP 404, the same body a missing page
#     gets, not 401/403. Every 404 message says so.
#   - /wiki/api/v2 has no current-user resource; whoami uses v1
#     /wiki/rest/api/user/current.
#   - Child listings paginate via _links.next (a /wiki/... path with a
#     cursor); `children` and `find-child` follow it.
#
# Exit codes: 0 success, 1 failure (including any non-2xx).
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

# shellcheck disable=SC1091  # sourced at paths computed from $0
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATL_PROVIDERS_DIR="$(cd "$DIR/../.." && pwd)"
# shellcheck source=../../lib/kit.sh
. "$ATL_PROVIDERS_DIR/lib/kit.sh"
# shellcheck source=../../lib/config.sh
. "$ATL_PROVIDERS_DIR/lib/config.sh"
# shellcheck source=../../tracker/jira/lib/http.sh
. "$ATL_PROVIDERS_DIR/tracker/jira/lib/http.sh"
# shellcheck source=lib/atlassian-common.sh
. "$DIR/lib/atlassian-common.sh"

SHOW_SECRETS=0
DRY_RUN=0
[ "${NW_DRY_RUN:-0}" = "1" ] && DRY_RUN=1
ASSUME_YES=0
MARKDOWN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --show-secrets) SHOW_SECRETS=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --yes|-y)       ASSUME_YES=1; shift ;;
        --markdown)     MARKDOWN=1; shift ;;
        *) break ;;
    esac
done

[ $# -ge 1 ] || show_help
case "$1" in -h|--help|help) show_help ;; esac

need curl jq
atl_resolve_host

require_page_id() {
    case "$1" in
        ''|*[!0-9]*) die "id must be numeric, got '$1'" ;;
    esac
}

require_path() {
    case "$1" in
        /wiki/*) ;;
        *) die "path must start with '/wiki/': '$1'" ;;
    esac
    case "$1" in
        *[[:space:]]*|*..*) die "path must contain no '..' or whitespace: '$1'" ;;
    esac
}

# api METHOD PATH [BODY] — dies on transport failure or non-2xx. Top-level
# only (redirect into a file), never inside $( ).
api() {
    local method="$1" path="$2" body="${3:-}" out code bodyfile rc=0
    atl_load_credentials
    out=$(tmpfile) || die "could not create temp file"
    if [ -n "$body" ]; then
        bodyfile=$(tmpfile) || die "could not create temp file"
        printf '%s' "$body" > "$bodyfile"
        code=$(curl_auth_config "$ATL_USER" "$ATL_TOKEN" \
            | curl -s -m"$LABKIT_TIMEOUT" --config - -X "$method" \
                   -H 'Content-Type: application/json' \
                   --data-binary @"$bodyfile" \
                   -o "$out" -w '%{http_code}' \
                   "https://$HOST$path") || rc=$?
    else
        code=$(curl_auth_config "$ATL_USER" "$ATL_TOKEN" \
            | curl -s -m"$LABKIT_TIMEOUT" --config - -X "$method" \
                   -o "$out" -w '%{http_code}' \
                   "https://$HOST$path") || rc=$?
    fi
    [ "$rc" -eq 0 ] || die "$method $path: could not reach https://$HOST (curl exit $rc)"
    case "$code" in
        2??) ;;
        404)
            warn "confluence: HTTP 404 $method $path"
            atl_error_body "$out"
            die "$method $path failed (HTTP 404) — Confluence Cloud also answers an INVALID credential with 404; check the token before assuming the resource is missing"
            ;;
        *)
            warn "confluence: HTTP $code $method $path"
            atl_error_body "$out"
            die "$method $path failed (HTTP $code)"
            ;;
    esac
    cat "$out"
}

emit_file() {
    if [ "$SHOW_SECRETS" = "1" ]; then
        warn "--show-secrets: credential fields are NOT redacted. Do not paste this."
        cat "$1"
    else
        redact_json < "$1" || die "redact_json failed — refusing to print unredacted output"
    fi
}

would_issue() {
    warn "would issue: $1 https://$HOST$2"
    [ -z "${3:-}" ] || warn "would issue body: $3"
    warn "--dry-run: nothing was sent, no credential was read."
}

# children_all ID OUT — every child page across _links.next, merged into
# one {"results":[...]} document in OUT. Capped at 50 pages of results.
children_all() {
    local id="$1" dest="$2" path page acc n=0
    acc=$(tmpfile) || die "could not create temp file"
    page=$(tmpfile) || die "could not create temp file"
    printf '[]' > "$acc"
    path="/wiki/api/v2/pages/$id/children?limit=250"
    while [ -n "$path" ]; do
        n=$((n + 1))
        [ "$n" -le 50 ] || die "children $id: more than 50 pages of results — refusing to continue"
        require_path "$path"
        api GET "$path" > "$page"
        jq -s '.[0] + (.[1].results // [])' "$acc" "$page" > "$acc.next" && mv "$acc.next" "$acc"
        path=$(jq -r '._links.next // empty' < "$page")
        case "$path" in
            ""|/wiki/*) ;;
            /*) path="/wiki$path" ;;
        esac
    done
    jq '{results: .}' < "$acc" > "$dest"
}

# markdown_to_storage — stdin to storage-format HTML; fenced content verbatim,
# and replace_link escapes a double quote before href="...". BSD awk has no
# gensub/backrefs (hence index()/substr()) and the program holds no quote.
markdown_to_storage() {
    awk '
        function esc(s) {
            gsub(/&/, "\\&amp;", s)
            gsub(/</, "\\&lt;", s)
            gsub(/>/, "\\&gt;", s)
            return s
        }
        function replace_delim(s, delim, otag, ctag,    out, i, j, dl) {
            dl = length(delim)
            out = ""
            while ((i = index(s, delim)) > 0) {
                j = index(substr(s, i + dl), delim)
                if (j == 0) break
                out = out substr(s, 1, i - 1) otag substr(s, i + dl, j - 1) ctag
                s = substr(s, i + 2 * dl + j - 1)
            }
            return out s
        }
        function replace_link(s,    out, i, j, k, m, text, url) {
            out = ""
            while ((i = index(s, "[")) > 0) {
                j = index(substr(s, i + 1), "]")
                if (j == 0) break
                k = i + j
                if (substr(s, k + 1, 1) != "(") { out = out substr(s, 1, i); s = substr(s, i + 1); continue }
                m = index(substr(s, k + 2), ")")
                if (m == 0) break
                text = substr(s, i + 1, j - 1)
                url = substr(s, k + 2, m - 1)
                gsub(/"/, "\\&quot;", url)
                out = out substr(s, 1, i - 1) "<a href=\"" url "\">" text "</a>"
                s = substr(s, k + 2 + m)
            }
            return out s
        }
        function render(s) {
            s = esc(s)
            s = replace_delim(s, "`", "<code>", "</code>")
            s = replace_delim(s, "**", "<strong>", "</strong>")
            s = replace_link(s)
            return s
        }
        function flush_para() { if (para != "") { print "<p>" para "</p>"; para="" } }
        function close_list() { if (in_list) { print "</ul>"; in_list=0 } }
        /^```/ {
            if (in_code) {
                print "]]></ac:plain-text-body></ac:structured-macro>"; in_code=0
            } else {
                flush_para(); close_list()
                print "<ac:structured-macro ac:name=\"code\"><ac:plain-text-body><![CDATA["
                in_code=1
            }
            next
        }
        in_code {
            line = $0
            gsub(/\]\]>/, "]]]]><![CDATA[>", line)
            print line
            next
        }
        /^#{1,6} / {
            flush_para(); close_list()
            n=0; while (substr($0,n+1,1)=="#") n++
            print "<h" n ">" render(substr($0,n+2)) "</h" n ">"
            next
        }
        /^[-*] / {
            flush_para()
            if (!in_list) { print "<ul>"; in_list=1 }
            print "<li>" render(substr($0,3)) "</li>"
            next
        }
        /^[ \t]*$/ { flush_para(); close_list(); next }
        {
            close_list()
            para = (para == "" ? render($0) : para " " render($0))
        }
            END { flush_para(); close_list() }
        '
}

CMD="$1"; shift
case "$CMD" in
    print-host)
        [ $# -eq 0 ] || die "usage: confluence.sh print-host"
        printf '%s\n' "$HOST"
        ;;
    whoami)
        if [ "$DRY_RUN" = "1" ]; then would_issue GET /wiki/rest/api/user/current; exit 0; fi
        OUT=$(tmpfile) || die "could not create temp file"
        api GET /wiki/rest/api/user/current > "$OUT"
        jq -r "$JQ_PRELUDE"'
            "Account:    \(blank(.displayName))",
            "Account ID: \(blank(.accountId))"' < "$OUT"
        ;;
    page)
        [ $# -eq 1 ] || die "usage: confluence.sh page <id>"
        require_page_id "$1"
        if [ "$DRY_RUN" = "1" ]; then would_issue GET "/wiki/api/v2/pages/$1"; exit 0; fi
        OUT=$(tmpfile) || die "could not create temp file"
        api GET "/wiki/api/v2/pages/$1" > "$OUT"
        emit_file "$OUT"
        ;;
    children)
        [ $# -eq 1 ] || die "usage: confluence.sh children <id>"
        require_page_id "$1"
        if [ "$DRY_RUN" = "1" ]; then would_issue GET "/wiki/api/v2/pages/$1/children?limit=250"; exit 0; fi
        OUT=$(tmpfile) || die "could not create temp file"
        children_all "$1" "$OUT"
        emit_file "$OUT"
        ;;
    find-child)
        [ $# -eq 2 ] || die "usage: confluence.sh find-child <parent-id> <title>"
        require_page_id "$1"
        [ -n "$2" ] || die "find-child: title is empty"
        if [ "$DRY_RUN" = "1" ]; then would_issue GET "/wiki/api/v2/pages/$1/children?limit=250"; exit 0; fi
        OUT=$(tmpfile) || die "could not create temp file"
        children_all "$1" "$OUT"
        # Named field extraction, not redact_json: only id and title leave here.
        jq -r --arg t "$2" '[.results[] | select(.title == $t and (.status // "current") == "current") | .id] | .[0] // empty' < "$OUT"
        ;;
    raw)
        [ $# -eq 2 ] || die "usage: confluence.sh raw GET <path>"
        case "$1" in
            GET) ;;
            *) die "raw is read-only and takes GET — writes go through create" ;;
        esac
        require_path "$2"
        if [ "$DRY_RUN" = "1" ]; then would_issue GET "$2"; exit 0; fi
        OUT=$(tmpfile) || die "could not create temp file"
        api GET "$2" > "$OUT"
        emit_file "$OUT"
        ;;
    create)
        CSPACE=""; CPARENT=""; CTITLE=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --space)  [ $# -ge 2 ] || die "create: --space needs a value"; CSPACE="$2"; shift 2 ;;
                --parent) [ $# -ge 2 ] || die "create: --parent needs a value"; CPARENT="$2"; shift 2 ;;
                --title)  [ $# -ge 2 ] || die "create: --title needs a value"; CTITLE="$2"; shift 2 ;;
                -) break ;;
                *) die "create: unknown argument '$1'" ;;
            esac
        done
        [ "${1:-}" = "-" ] || die "create: body is always read from stdin — pass '-' as the last argument"
        [ -n "$CTITLE" ] || die "create: --title is required"
        require_page_id "$CSPACE"
        require_page_id "$CPARENT"
        CBODY_IN=$(cat) || die "could not read the page body from stdin"
        [ -n "$CBODY_IN" ] || die "create: page body is empty — refusing to create an empty page"
        if [ "$MARKDOWN" = "1" ]; then
            CSTORAGE=$(printf '%s\n' "$CBODY_IN" | markdown_to_storage) || die "could not convert markdown to storage format"
        else
            CSTORAGE="$CBODY_IN"
        fi
        CREQ=$(jq -cn --arg s "$CSPACE" --arg p "$CPARENT" --arg t "$CTITLE" --arg b "$CSTORAGE" \
            '{spaceId: $s, status: "current", title: $t, parentId: $p, body: {representation: "storage", value: $b}}') \
            || die "could not build the create request body"
        if [ "$DRY_RUN" = "1" ]; then would_issue POST /wiki/api/v2/pages "$CREQ"; exit 0; fi
        warn "about to issue: POST https://$HOST/wiki/api/v2/pages (title: $CTITLE, parent: $CPARENT)"
        atl_confirm "this POST"
        CRESP=$(tmpfile) || die "could not create temp file"
        api POST /wiki/api/v2/pages "$CREQ" > "$CRESP"
        CID=$(jq -r '.id // empty' < "$CRESP") || die "could not parse the created page's id"
        [ -n "$CID" ] || die "POST /wiki/api/v2/pages succeeded but the response carried no page id"
        CTINY=$(jq -r '._links.tinyui // empty' < "$CRESP") || CTINY=""
        if [ -n "$CTINY" ]; then
            CURL_OUT="https://$HOST/wiki$CTINY"
        else
            CURL_OUT="https://$HOST/wiki/pages/viewpage.action?pageId=$CID"
        fi
        echo "Created page $CID: $CTITLE ($CURL_OUT)"
        ;;
    *) die "unknown command '$CMD' — run with --help" ;;
esac
