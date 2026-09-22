---
seq: 24
date: 2026-09-22
level: 3
slug: 2026-09-22-script-analytics-py-vendors-its-cost-helpers-instead-of-importing-them-nwm-156
title: "script-analytics.py vendors its cost helpers instead of importing them (NWM-156)"
---

The 85 lines script-analytics.py needed from claude-cost.py and
claude-cost-scan.py are now copies inside it, not `importlib` loads of two
siblings at import time. The file is self-contained and runs from any
directory in any repo, which is what NWM-130 needs and what NWM-129 made
permanent by fixing the two claude-cost files in this repo for good.

A third shared module was rejected because it renames the coupling rather
than removing it, and because `hooks/session-cost.sh` runs for every
installer under `SessionEnd`, so the plugin cannot depend on an ai-toolkit
checkout to satisfy it. Environment-supplied paths were rejected because
they turn a build-time coupling into a runtime dependency on the repo the
script is leaving. The price of vendoring is two copies of three renderers
and four price helpers living in this repo permanently;
`scripts/script-analytics-selftest.sh` carries a drift guard that compares
the two implementations' behaviour so the copies cannot diverge unnoticed,
and that guard leaves with the originals.

`templates/claude-prices.tsv` stopped being one fixed relative path and
became a search: `$CLAUDE_PRICES_TSV`, `../templates/`, beside the script,
then the same two under `$CLAUDE_PROJECT_DIR`, with a validation error
naming every path tried when none exists.

`hooks/script-events-hook.sh` held a hardcoded
`$PROJECT_DIR/scripts/script-analytics.py` and failed open when it was
absent. That was already broken, not merely about to break: `plugin.json`
registers the hook for every installer, but it looked in the CONSUMING
project's `scripts/`, so it had only ever worked in this checkout and in
homelab, which happens to keep its own copy. It now resolves through a
chain and names every path it tried when nothing resolves. The general
lesson, third instance in one week: a migration must count `$PROJECT_DIR`
paths as a consumer surface alongside `${CLAUDE_PLUGIN_ROOT}` ones, and the
`$PROJECT_DIR` kind is worse, because it fails for consumers rather than
installers and a fail-open hook leaves no error behind.

**Provenance.** Decided and landed by an unattended session on 2026-09-22,
under NWM-156. Verified red-then-green and through the full CI set, but not
reviewed by the owner. Superseding it needs a later entry, not an edit here
(NWM-167).
