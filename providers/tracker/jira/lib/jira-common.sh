#!/bin/bash
# shellcheck disable=SC2034  # JIRA_KEY_ERR is read by sourcing scripts (jira-api.sh), never in this file
#
# jira-common.sh — the two Jira helpers shared between jira-api.sh and the
# rest of this plugin's jira-mode tooling.
#
# Source it, do not execute it:
#     . "$(cd "$(dirname "$0")" && pwd)/lib/jira-common.sh"
#
# Targets bash 3.2 (macOS /bin/bash): no associative arrays, no ${var^^}, no
# readarray.
#
# Rule: a fallible helper here returns non-zero and prints NOTHING on
# failure — the caller decides how to die:
#     require_issue_key "$key" || die "$JIRA_KEY_ERR"

# require_issue_key <key> — validate PROJECT-123 shape; returns non-zero and
# sets $JIRA_KEY_ERR. A guard, not a typo check: require_path allows '/' and
# '?', so an unvalidated key reaches an endpoint show_request never printed.
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
# endpoint requires, one paragraph per input line; prints it, returns jq's
# status. Strips trailing newlines, which would add an empty paragraph.
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
