---
date: 2026-09-15
slug: commit-attribution-is-the-owner-s-alone-ai-attribution-trailers-are-opt-in-not-required
title: "Commit attribution is the owner's alone; AI-attribution trailers are opt-in, not required"
migrated: true
---

# Commit attribution is the owner's alone; AI-attribution trailers are opt-in, not required

## Decision

Owner rule: every commit and PR, on every machine, is attributed to Mike
Garrett alone. `scripts/land-branch.sh` writes no `Co-Authored-By` or
`Claude-Session` trailer and has no switch that adds one.

Reasoning: a landing script that refuses to land unless attribution
variables are provisioned blocks landing on any machine that has not set
them, and provisioning them would run counter to the attribution rule
itself. Attribution is a property of the owner, not of the tool that
merges.

## Why

unrecorded

## Cost

unrecorded
