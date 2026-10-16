---
date: 2026-10-09
slug: selftests-gains-an-ubuntu-latest-leg-beside-macos
title: "selftests gains an ubuntu-latest leg beside macOS"
migrated: true
---

# selftests gains an ubuntu-latest leg beside macOS

## Decision

The `selftests` CI job is now a matrix: `macos-latest` stays the target and keeps the bare check name `selftests` that `protect_main-2` requires; `ubuntu-latest` reports as `selftests (linux)` and is not required. This narrows the 2026-09-18 macOS-only decision rather than reversing it: bash 3.2 is still what scripts are written to, but the orchestration hosts mike-desktop-l and precision-vm run Ubuntu, and a macOS-only job let five selftests and one real guard false negative sit red there unnoticed — BSD `stat -f`, a `cd ""` bash 5 refuses, and `guard-fs-writes.sh` resolving a shim through `/usr/bin/rm -> gnurm` to a name it did not guard.

## Why

unrecorded

## Cost

unrecorded
