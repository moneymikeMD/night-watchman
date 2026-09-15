---
id: PREFIX-000
title: Short imperative phrase — what is true when this is done
created: YYYY-MM-DD
updated: YYYY-MM-DD
executor: agent          # agent | human | mixed
tags: [area, kind]
blocked_by: []           # ids that must reach completed/cancelled first
touches:                 # path globs this ticket owns edits to
  - path/to/thing
appends:                 # shared append-mostly files; collisions only warn
  - docs/changelog.md
verify: |
  command that proves it is done
  # and the result that counts as passing
human_steps:             # only when executor is mixed; delete otherwise
  - What a person must do, specifically
outcome:                 # required in cancelled/; delete otherwise
---

## Problem

What is wrong now, from the point of view of whoever suffers it. Not the
implementation's point of view. Someone reading this cold should understand why
the ticket exists before they read what to do.

## Solution

What will be done. Concrete: name the files, commands, versions, addresses.

## Decisions

The non-obvious choices and why. Especially **why not the obvious approach** —
that is the part that stops the obvious approach being re-proposed in three
months.

State verified facts as verified, and mark assumptions as assumptions. A
confident guess in a ticket is worse than an open question, because it gets
acted on without being checked.

## Out of scope

What this deliberately does not cover, and which ticket covers it instead.
