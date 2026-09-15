#!/bin/bash
#
# templates/wizard-stages.sh — example wizard stages file. Copy this next to
# scripts/lib/wizard.sh (or point WIZARD_LIB at it), then replace the one
# example stage below with the real human_steps for your ticket.
#
# Everything below this header is author-territory: never hand-edit
# scripts/lib/wizard.sh itself, write your steps here instead.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Set before sourcing: wizard.sh defaults ENV_FILE to .env in its own
# ENV_FILE="${ENV_FILE:-.env}" line, and that default wins if not already
# set by the time it runs — writing into the invoker's cwd instead of this
# quarantined example file.
ENV_FILE="${ENV_FILE:-$HERE/wizard-example.env}"

# shellcheck source=../scripts/lib/wizard.sh
. "${WIZARD_LIB:-$HERE/../scripts/lib/wizard.sh}"

# shellcheck disable=SC2034  # read by wizard.sh's banner()/stage(), invisible to a plain (non -x) shellcheck run
TOTAL_STAGES=1

banner "Example provider setup"

stage "Provider: API credentials"
say "Grab a provider API key pair and record where it lives."
open_url "https://example.invalid/dashboard/api-keys"
step "Copy the public/client identifier."
ask PROVIDER_CLIENT_ID "Paste the client id:"
write_env PROVIDER_CLIENT_ID "$PROVIDER_CLIENT_ID"
step "Copy the secret key."
ask_secret PROVIDER_SECRET_KEY "Paste the secret key:" \
    'op item edit "Example Provider" password=-' \
    "op://Private/Example Provider/password"

finish
