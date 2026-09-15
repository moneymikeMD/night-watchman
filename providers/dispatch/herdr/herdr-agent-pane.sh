#!/bin/bash
#
# herdr-agent-pane.sh — from inside a Herdr pane, split the current pane
# and start a coding agent in the new one.
#
# OPTIONAL LAYER, ported from a production system (see the README's
# "optional layers"; from the 2026-09-13 parity sweep).
# Generic Herdr utility, no lab content: splits the current pane and hands
# the new pane to `herdr agent start`.
#
# Herdr's CLI returns JSON; the new pane's id is read from
# `.result.pane.pane_id` via jq. The agent name must be unique among
# currently-live Herdr agents, or `herdr agent start` will refuse it.
#
# Usage:
#   herdr-agent-pane.sh [--dir DIR] [--name NAME] [--kind KIND] \
#       [--direction right|down] [-- agent-args...]
#   herdr-agent-pane.sh --help
#
# Defaults: --dir "$PWD", --name derived from the basename of DIR, --kind
# claude, --direction right.
#
# bash 3.2 compatible (no associative arrays, no `${var^^}`).

set -euo pipefail

DIR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kit.sh
. "$DIR_SELF/lib/kit.sh"

DIR="$PWD"
NAME=""
KIND="claude"
DIRECTION="right"
AGENT_ARGS=()

while [ $# -gt 0 ]; do
	case "$1" in
	-h | --help) show_help ;;
	--dir)
		[ -n "${2:-}" ] || die "--dir requires a value"
		DIR="$2"
		shift 2
		;;
	--name)
		[ -n "${2:-}" ] || die "--name requires a value"
		NAME="$2"
		shift 2
		;;
	--kind)
		[ -n "${2:-}" ] || die "--kind requires a value"
		KIND="$2"
		shift 2
		;;
	--direction)
		[ -n "${2:-}" ] || die "--direction requires a value"
		DIRECTION="$2"
		shift 2
		;;
	--)
		shift
		AGENT_ARGS=("$@")
		break
		;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

case "$DIRECTION" in
right | down) ;;
*) die "--direction must be right or down, got: $DIRECTION" ;;
esac

[ "${HERDR_ENV:-}" = "1" ] || die "not inside a Herdr pane (HERDR_ENV != 1)"
[ -d "$DIR" ] || die "no such directory: $DIR"
need herdr jq

if [ -z "$NAME" ]; then
	NAME=$(basename "$DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')
fi
[[ "$NAME" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "name must match [a-z][a-z0-9_-]{0,31}: $NAME"

PANE_JSON=$(herdr pane split --current --direction "$DIRECTION" --cwd "$DIR" --no-focus) \
	|| die "herdr pane split failed"
PANE_ID=$(echo "$PANE_JSON" | jq -r '.result.pane.pane_id')
[ -n "$PANE_ID" ] && [ "$PANE_ID" != "null" ] || die "no pane_id in herdr pane split output: $PANE_JSON"

if [ "${#AGENT_ARGS[@]}" -gt 0 ]; then
	herdr agent start "$NAME" --kind "$KIND" --pane "$PANE_ID" -- "${AGENT_ARGS[@]}" \
		|| die "herdr agent start failed"
else
	herdr agent start "$NAME" --kind "$KIND" --pane "$PANE_ID" \
		|| die "herdr agent start failed"
fi

echo "agent $NAME ($KIND) started in pane $PANE_ID, cwd $DIR"
