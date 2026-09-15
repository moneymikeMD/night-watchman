#!/bin/bash
#
# providers/secrets/op/provider.sh — secrets provider backed by 1Password,
# via the `op` CLI. This is the built-in default for the `secrets` kind
# (see providers/README.md).
#
# verb: read REF
#
# REF (a dotted lowercase name, e.g. `jira.token`) resolves to an item and
# field through the committed config, never through argv or the reference
# itself — the op:// URI is built here, so a ref never doubles as the
# 1Password coordinate an operator has to keep in sync by hand:
#
#   [secrets.op.jira.token]
#   item  = "..."            # required
#   field = "..."            # required
#   vault = "..."            # optional; falls back to [secrets.op].vault,
#                            # then the built-in default "Private"
#
# NOTE: an item name containing parentheses breaks `op read` — this is a
# limitation of `op` itself, not this provider; keep item names free of
# them.
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
. "$LIB_DIR/config.sh"

[ "$#" -ge 1 ] || die "usage: provider.sh read REF"
verb="$1"
shift
[ "$verb" = "read" ] || die "unknown verb: $verb (secrets provider only supports: read)"
[ "$#" -eq 1 ] || die "usage: provider.sh read REF"
ref="$1"

case "$ref" in
    *[!a-z0-9_.-]* | "") die "malformed secret reference: $ref (expected lowercase [a-z0-9_.-])" ;;
esac

need op

item=$(nw_config_get "secrets.op.$ref.item") \
    || die "no 1Password item configured for secret ref: $ref (expected [secrets.op.$ref] item = \"...\" in config)"
field=$(nw_config_get "secrets.op.$ref.field") \
    || die "no 1Password field configured for secret ref: $ref (expected [secrets.op.$ref] field = \"...\" in config)"
vault=$(nw_config_get "secrets.op.$ref.vault" "$(nw_config_get "secrets.op.vault" "Private")")

op read "op://$vault/$item/$field"
