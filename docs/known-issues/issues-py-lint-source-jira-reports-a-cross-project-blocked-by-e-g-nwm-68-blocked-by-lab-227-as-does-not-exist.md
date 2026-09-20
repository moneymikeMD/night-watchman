---
title: "issues.py lint --source jira reports a cross-project blocked_by as 'does not exist'"
heading_raw: "issues.py lint --source jira reports a cross-project blocked_by as 'does not exist' — LOW"
severity: LOW
status: resolved
resolved: 2026-09-19
qualifiers: []
note: "fixed in work-order/reference/issues.py (WO-021): a blocker outside the projects the fetch returned is taken on its nested statusCategory — Done resolves, anything else blocks — and lint names it external instead of missing; a same-project dangling id still errors"
tickets: []
slug: issues-py-lint-source-jira-reports-a-cross-project-blocked-by-e-g-nwm-68-blocked-by-lab-227-as-does-not-exist
---

Found 2026-09-14. issues.py's Jira source fetches one project (project = KEY AND status not in ...), then derives blocked_by from issuelinks. A Blocks link whose inward issue lives in another project is not in the fetched set, so lint errors 'blocked_by <key> does not exist' and the ticket is treated as unstartable-with-error rather than blocked. Fix: when a blocked_by key has a different project prefix, resolve it with one extra GET /issue/KEY?fields=status (or the slim status nested in the issuelinks payload, which is already there) and treat it as an external blocker: startable iff its statusCategory is Done. Until fixed, the error is cosmetic; waves still exclude the ticket because the link is present.

Resolved 2026-09-19 by WO-021, in work-order/reference/issues.py — the reference implementation this file moved to under WO-004, not in night-watchman. night-watchman's own byte-identical copy carried the defect until WO-010 deleted it; this repo now runs the fixed reference implementation out of the work-order plugin dependency.

_jira_shadow_for_blocker() now takes the set of project prefixes the fetch
actually returned, rather than trusting JIRA_PROJECT_KEY. A blocker outside that
set can never have been in the fetch whatever its status, so the slim status
nested in the issuelinks payload is taken as-is, with no second call:
statusCategory `done` becomes the completed stage and the dependent is startable;
anything else becomes a `jira-external:<status>` stage, which is in neither
WORKABLE nor DONE, so it blocks the dependent without ever being dispatched
itself. lint names it as an external blocker instead of erroring.

The narrowing matters and is pinned by a selftest check: a SAME-project blocker
that is not Done is still "does not exist", because the JQL excludes only
Completed/Cancelled/Done, so such a key really is dangling.

Not changed, and not a regression: `waves` still files a ticket blocked by a
live external blocker under "cycle or unresolvable dependency". That wording
predates this fix and is byte-identical before and after it.
