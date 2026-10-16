---
date: 2026-09-21
slug: night-watchman-resolves-ai-toolkit-s-known-issue-sh-through-scripts-ai-toolkit-root-sh-and-drops-its-copy-nwm-128
title: "night-watchman resolves ai-toolkit's known-issue.sh through scripts/ai-toolkit-root.sh and drops its copy (NWM-128)"
---

# night-watchman resolves ai-toolkit's known-issue.sh through scripts/ai-toolkit-root.sh and drops its copy (NWM-128)

## Decision

night-watchman deletes its known-issue.sh copy and routes all call sites through ${CLAUDE_PLUGIN_ROOT}/scripts/ai-toolkit-root.sh, which checks $AI_TOOLKIT_ROOT then a sibling checkout and omits any plugin-list step (2026-09-21). CI clones ai-toolkit's default branch; no composite action was published.

## Why

ai-toolkit's scripts/ surface cannot serve a CI consumer by absolute path, and ai-toolkit is not a plugin so there is no installPath; cut-over was measured loss-free.

## Cost

An adopting repo now needs an ai-toolkit checkout or $AI_TOOLKIT_ROOT; before moving any script out of the plugin, grep ${CLAUDE_PLUGIN_ROOT}/scripts/<name> as well as CI usage.
