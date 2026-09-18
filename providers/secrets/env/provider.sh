#!/bin/bash
#
# providers/secrets/env/provider.sh — secrets provider backed by environment
# variables, so a stranger with no 1Password access can still run this repo's
# selftests and a first session.
#
# verb: read REF
#
# REF (a dotted lowercase name) maps to `NW_` + REF with `.` -> `_`, upper-
# cased: `jira.token` -> `NW_JIRA_TOKEN`.
#
# Never prints the secret value anywhere but stdout: not to stderr, not in
# an error message, not logged.
#
# Usage: provider.sh read REF

# shellcheck disable=SC1091  # sourced at a path computed from $0, not visible to shellcheck's static resolution
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$DIR/../../lib" && pwd)"
. "$LIB_DIR/kit.sh"

[ "$#" -ge 1 ] || die "usage: provider.sh read REF"
verb="$1"
shift
[ "$verb" = "read" ] || die "unknown verb: $verb (secrets provider only supports: read)"
[ "$#" -eq 1 ] || die "usage: provider.sh read REF"
ref="$1"

case "$ref" in
    *[!a-z0-9_.-]* | "") die "malformed secret reference: $ref (expected lowercase [a-z0-9_.-])" ;;
esac

var="NW_$(printf '%s' "$ref" | tr '[:lower:].' '[:upper:]_')"

val=""
eval "val=\${$var:-}"
[ -n "$val" ] || die "environment variable not set: $var (for secret ref: $ref)"

printf '%s\n' "$val"
