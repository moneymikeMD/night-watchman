---
title: "land-branch-selftest.sh needs PyYAML but neither declares nor checks for it"
heading_raw: "land-branch-selftest.sh needs PyYAML but neither declares nor checks for it — LOW"
severity: LOW
status: open
qualifiers: []
note: "passes locally, fails on a clean machine with an unhelpful traceback; found wiring CI"
tickets: []
slug: land-branch-selftest-sh-needs-pyyaml-but-neither-declares-nor-checks-for-it
---

Found 2026-09-18 on the first CI run of the selftest suite. scripts/land-branch-selftest.sh validates a completed ticket's frontmatter by shelling out to `python3 -c "import sys, yaml; ..."`. PyYAML is not in the standard library, so on a machine without it the assertion fails as a raw ModuleNotFoundError traceback rather than as a missing-dependency message:

    FAIL - test1: completed ticket's frontmatter is not valid YAML: ModuleNotFoundError: No module named 'yaml'

It passes on the developer machine only because PyYAML happens to be installed there. Every other selftest in the repo is dependency-free by design (see docs/testing-philosophy.md), so this one is the outlier.

Worked around in CI by installing PyYAML before the suite runs. The underlying gap is unfixed: anyone who clones this repo and runs the selftests without PyYAML gets a traceback that does not name the real problem. The fix is either to check for the module up front and fail with a message naming it, to skip those two assertions with a stated reason when it is absent, or to parse the frontmatter without PyYAML — the file is a few known keys, not arbitrary YAML.
