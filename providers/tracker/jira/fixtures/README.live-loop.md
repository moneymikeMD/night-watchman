# Live-loop fixtures

Captured 2026-09-12 against a real Jira Cloud site through
`providers/lib/provider.sh run tracker create|fetch|comment|transition`
on a throwaway issue that was cancelled immediately after. Emails, account
ids, avatar URLs and the host are scrubbed to placeholders; the shape and
the `key`/`id` fields are exactly what the API returned.

- `issue.create.live.json` — POST /rest/api/3/issue response (key intact)
- `issue.fetch.live.json`  — GET /rest/api/3/issue/KEY response (key intact)

comment and transition returned no body worth keeping (201 / 204).
