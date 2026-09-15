#!/bin/bash
#
# providers/secrets/read.sh REF — read a secret by reference through the
# `secrets` provider in effect (see providers/README.md). Thin wrapper
# around `providers/lib/provider.sh run secrets read REF`; exists so a
# caller that only cares about secrets does not have to know the general
# provider-dispatch CLI.
#
# REF is a dotted lowercase name (e.g. `jira.token`) that both shipped
# implementations map to their own backing store:
#   env  — REF -> environment variable NW_<REF, dots to underscores, upper>
#   op   — REF -> a 1Password item/field/vault looked up in config under
#          [secrets.op.REF]
#
# Prints the secret value on stdout, and nothing else, ever — no
# implementation here or in secrets/op or secrets/env may echo the value
# to stderr, or log it, or include it in an error message.
#
# Usage: providers/secrets/read.sh REF

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_DIR="$(dirname "$DIR")"

exec "$PROVIDERS_DIR/lib/provider.sh" run secrets read "$@"
