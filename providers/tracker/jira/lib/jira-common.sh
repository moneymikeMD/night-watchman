#!/bin/bash
# shellcheck disable=SC2034  # JIRA_KEY_ERR is read by sourcing scripts (jira-api.sh), never in this file
#
# jira-common.sh — the two Jira helpers shared between jira-api.sh and (via
# scripts/land-branch.sh's own copy) the rest of this plugin's jira-mode
# tooling. Ported from the source project's scripts/lib/jira-common.sh, de-identified.
#
# Source it, do not execute it:
#     . "$(cd "$(dirname "$0")" && pwd)/lib/jira-common.sh"
#
# Targets bash 3.2 (macOS /bin/bash): no associative arrays, no ${var^^}, no
# readarray.
#
# Rule: a fallible helper here returns non-zero and prints NOTHING on
# failure — the caller decides how to die. jira-api.sh has its own die();
# each caller reads $JIRA_KEY_ERR immediately:
#     require_issue_key "$key" || die "$JIRA_KEY_ERR"

# require_issue_key <key> — validates PROJECT-123 shape: letters, digits,
# underscore and dash only, then a run of letters, a dash, then digits only.
#
# jira-api.sh's `comment` and `issue` (view_issue) subcommands interpolate
# $key straight into an /issue/$key/... path, and require_path's own checks
# allow '/' and '?' — so an unvalidated key like 'PROJ-1/../../project/PROJ'
# or 'PROJ-1?x=y' would reach a different endpoint than the one
# show_request prints. This closes that.
JIRA_KEY_ERR=""
require_issue_key() {
    local key="$1"
    JIRA_KEY_ERR=""
    case "$key" in
        *[!A-Za-z0-9_-]*)
            JIRA_KEY_ERR="issue key '$key' contains characters that are not letters, digits, '_' or '-'"
            return 1
            ;;
    esac
    case "$key" in
        [A-Za-z]*-[0-9]*) ;;
        *)
            JIRA_KEY_ERR="issue key '$key' is not a Jira key (PROJECT-123)"
            return 1
            ;;
    esac
    case "${key#*-}" in
        *[!0-9]*)
            JIRA_KEY_ERR="issue key '$key' is not a Jira key — the part after the first dash must be digits only"
            return 1
            ;;
    esac
    return 0
}

# jira_comment_body <text> — the ADF document Jira Cloud's v3 comment
# endpoint requires. One paragraph per input line; a blank line becomes an
# empty paragraph, which is how a blank line reads as a paragraph break in
# the rendered comment. Text is JSON-encoded by jq, never interpolated.
# Prints the body; returns jq's status (rule: nothing printed on failure).
#
# Strips ALL trailing newlines from $1 before splitting into paragraphs,
# rather than trusting every caller to have already done so — a
# trailing-newline value assigned straight from argv (no `$( )` to strip
# it) would otherwise produce an extra empty paragraph.
jira_comment_body() {
    jq -cn --arg t "$1" '{
        body: {
            type: "doc", version: 1,
            content: ($t | gsub("\r"; "") | sub("\n+$"; "") | split("\n") | map(
                if . == "" then {type: "paragraph", content: []}
                else {type: "paragraph", content: [{type: "text", text: .}]} end
            ))
        }
    }'
}
