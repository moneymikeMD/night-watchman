#!/usr/bin/env bash
# hitl-loop.sh — human-in-the-loop reproduction loop, last resort in the
# diagnosis loop (skills/diagnose-and-pr/references/diagnosis-loop.md).
#
# MIT License
# Copyright (c) 2026 Matt Pocock
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
#
# Adapted from mattpocock/skills diagnosing-bugs, 2026-09-14.
#
# Copy this file, edit the steps below, and run it. The agent runs the
# script; the human follows prompts in their terminal.
#
#   step "<instruction>"       show instruction, wait for Enter
#   capture VAR "<question>"   show question, read the answer into VAR
#
# At the end, captured values print as KEY=VALUE for the agent to parse.
# `capture` is for observations only — never a credential or secret value;
# leave signing in and clicking through auth to a plain `step`.

set -euo pipefail

step() {
  printf '\n>>> %s\n' "$1"
  read -r -p "    [Enter when done] " _ || true
}

capture() {
  local var="$1" question="$2" answer
  printf '\n>>> %s\n' "$question"
  read -r -p "    > " answer
  printf -v "$var" '%s' "$answer"
}

# --- edit below ----------------------------------------------------------

step "Open the app and reproduce the symptom."

capture REPRODUCED "Did the symptom reproduce? (y/n)"

capture OBSERVATION "Paste the exact error/output observed (or 'none'):"

# --- edit above ----------------------------------------------------------

printf '\n--- Captured ---\n'
printf 'REPRODUCED=%s\n' "$REPRODUCED"
printf 'OBSERVATION=%s\n' "$OBSERVATION"
