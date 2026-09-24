---
title: "land-branch-selftest.sh needs PyYAML but neither declares nor checks for it"
heading_raw: "land-branch-selftest.sh needs PyYAML but neither declares nor checks for it — LOW"
severity: LOW
status: open
qualifiers: []
note: "passes where PyYAML happens to be installed; CI installs it"
tickets: []
slug: land-branch-selftest-sh-needs-pyyaml-but-neither-declares-nor-checks-for-it
---

scripts/land-branch-selftest.sh validates a completed ticket's frontmatter
by shelling out to `python3 -c "import sys, yaml; ..."`
(valid_yaml_frontmatter). PyYAML is not in the standard library and the
script neither checks for it nor names it, so on a machine without it the
assertion fails as a raw traceback:

    FAIL - test1: completed ticket's frontmatter is not valid YAML: ModuleNotFoundError: No module named 'yaml'

CI installs PyYAML before the suite runs. Every other selftest is
dependency-free (docs/testing-philosophy.md). Fix options: check for the
module up front and fail naming it; skip the two assertions with a stated
reason when it is absent; parse the few known frontmatter keys without
PyYAML.
