---
title: "issues.py lint --source jira reports a cross-project blocked_by as 'does not exist'"
heading_raw: "issues.py lint --source jira reports a cross-project blocked_by as 'does not exist' — LOW"
severity: LOW
status: open
qualifiers: []
note: "the one-JQL fetch is project-scoped; a Blocks link into another project looks like a dangling id"
tickets: []
slug: issues-py-lint-source-jira-reports-a-cross-project-blocked-by-e-g-nwm-68-blocked-by-lab-227-as-does-not-exist
---

Found 2026-09-14. issues.py's Jira source fetches one project (project = KEY AND status not in ...), then derives blocked_by from issuelinks. A Blocks link whose inward issue lives in another project is not in the fetched set, so lint errors 'blocked_by <key> does not exist' and the ticket is treated as unstartable-with-error rather than blocked. Fix: when a blocked_by key has a different project prefix, resolve it with one extra GET /issue/KEY?fields=status (or the slim status nested in the issuelinks payload, which is already there) and treat it as an external blocker: startable iff its statusCategory is Done. Until fixed, the error is cosmetic; waves still exclude the ticket because the link is present.
