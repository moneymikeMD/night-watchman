#!/bin/bash
#
# fake-script.sh — a tiny fixture script with a Usage block, used only by
# gen-reference-docs-selftest.sh. Reads a ticket at PROJECT-<numeric id>
# and a {a,b}-style glob, both of which MDX would otherwise choke on.
#
# Usage:
#   fake-script.sh <arg>
#   fake-script.sh --help

set -euo pipefail
echo "fixture only"
