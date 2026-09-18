#!/bin/bash
#
# scripts/lib/wizard.sh — guided human-step library: a stages file sources
# this, then calls stage/say/step/ask/ask_secret to walk the owner through a
# `human_steps` procedure one screen at a time.
#
# NEVER HAND-EDIT THIS LIBRARY FROM A STAGES FILE. Author stages in a
# sibling file (see templates/wizard-stages.sh) that sources this one.
#
# Adapted from mattpocock/skills wizard,
# Copyright (c) 2026 Matt Pocock, MIT License.
#
# Differs from upstream: there is no plaintext `.env` for secrets — a raw
# value never touches ENV_FILE or any other file this library writes.
#
# Usage: source this file after `set -euo pipefail`, then write stages.

# shellcheck disable=SC1091  # sourced at a path computed from $0, not visible to shellcheck's static resolution
_WIZARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_WIZARD_LIB_DIR/kit.sh"

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
    BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
else
    BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""
fi

TOTAL_STAGES=0
_STAGE_INDEX=0
ENV_FILE="${ENV_FILE:-.env}"
WRITTEN_ENV=""    # newline-joined "KEY -> where" lines, non-secret
WRITTEN_SECRET=() # secret KEY names handed to a sink this run (never values)
SKIPPED=()        # things that could not be done (e.g. sink command missing)

_clear() {
    [[ -t 1 ]] || return 0
    if command -v tput >/dev/null 2>&1; then tput clear; else printf '\033[2J\033[3J\033[H'; fi
}

banner() {
    _clear
    printf '\n%s%s  %s%s\n' "$BOLD" "$BLUE" "$1" "$RESET"
    printf '%s  %s stages%s\n\n' "$DIM" "$TOTAL_STAGES" "$RESET"
    pause "Ready to start?"
}

stage() {
    _clear
    _STAGE_INDEX=$((_STAGE_INDEX + 1))
    printf '\n%s%s- Stage %s/%s: %s%s\n' "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}

say()  { printf '  %s\n' "$1"; }
step() { printf '  %s*%s %s\n' "$BLUE" "$RESET" "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '  %s! %s%s\n' "$YELLOW" "$1" "$RESET"; }

open_url() {
    local url="$1"
    printf '  %sopening%s %s\n' "$GREEN" "$RESET" "$url"
    { if   command -v wslview      >/dev/null 2>&1; then wslview "$url"
      elif command -v explorer.exe >/dev/null 2>&1; then explorer.exe "$url"
      elif command -v xdg-open     >/dev/null 2>&1; then xdg-open "$url"
      elif command -v open         >/dev/null 2>&1; then open "$url"
      else warn "couldn't open a browser; visit it manually: $url"; fi
    } >/dev/null 2>&1 || warn "couldn't open a browser, so visit it manually: $url"
}

pause() {
    printf '  %s%s%s ' "$DIM" "${1:-Press Enter to continue}" "$RESET"
    read -r _ || true
}

confirm() {
    local reply=""
    printf '  %s? %s [y/N] ' "$YELLOW" "$1"
    read -r reply || true
    [[ "$reply" =~ ^[Yy] ]]
}

# ask KEY "Prompt" — visible input (non-secret) into $KEY.
ask() {
    local key="$1" prompt="$2" input
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
    read -r input || true
    printf -v "$key" '%s' "$input"
}

# ask_secret KEY "Prompt" SINK_CMD REF — hidden input, piped to SINK_CMD on
# stdin (never argv, never a file, never a variable), then records REF (a
# locator, never the value) via write_env under KEY. A failing SINK_CMD is
# non-fatal: it is recorded in SKIPPED for the closing summary.
ask_secret() {
    local key="$1" prompt="$2" sink="$3" ref="$4" input
    printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET"
    read -rs input || true
    printf '\n'
    if printf '%s' "$input" | eval "$sink" >/dev/null 2>&1; then
        WRITTEN_SECRET+=("$key")
        write_env "$key" "$ref"
        printf '  %ssent%s %s to sink\n' "$GREEN" "$RESET" "$key"
    else
        SKIPPED+=("$key: sink command failed ($sink) — set it manually")
        warn "sink failed for $key; nothing written for it"
    fi
    input=""
}

# write_env KEY VALUE — upserts KEY=VALUE into ENV_FILE. Plain settings
# only, or the REF locator ask_secret passes it — never a raw credential.
write_env() {
    local key="$1" value="$2" tmp
    touch "$ENV_FILE"
    tmp=$(tmpfile) || die "write_env: could not create a tempfile for $ENV_FILE"
    grep -vE "^${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    cp "$tmp" "$ENV_FILE"
    WRITTEN_ENV="$WRITTEN_ENV
$key -> $ENV_FILE"
    printf '  %swrote%s %s -> %s\n' "$GREEN" "$RESET" "$key" "$ENV_FILE"
}

finish() {
    _clear
    printf '\n%s%s  Setup complete%s\n' "$BOLD" "$GREEN" "$RESET"
    [ -n "$WRITTEN_ENV" ] && note "wrote:$WRITTEN_ENV"
    (( ${#WRITTEN_SECRET[@]} )) && note "sent ${#WRITTEN_SECRET[@]} secret(s) to their sink: ${WRITTEN_SECRET[*]}"
    if (( ${#SKIPPED[@]} )); then
        printf '\n'; warn "still to do by hand:"
        local s
        for s in "${SKIPPED[@]}"; do note "  - $s"; done
    fi
    printf '\n'
}
