# fixtures/ — recorded Prime Agent output

Every response file here was captured on 2026-10-25 from a live Prime Agent
0.10.1 binary (`version.txt`), against throwaway sessions `nw-probe-001` to
`nw-probe-004` created for exactly this purpose with
`rlm.create_session(..., model="anthropic/claude-haiku-4-5", thinking="off")`
in a scratch directory, and stopped afterwards. Per this project's fixture
rule ("fixtures are recorded, never authored") and
`docs/testing-philosophy.md`'s fixture-provenance discipline,
`provider-selftest.sh`'s fake `prime-agent` serves these files.

Edits made after capture, and nothing else: home paths read `/Users/adopter`,
the scratch cwd reads `/Users/adopter/code/wt-nw-probe-001`, only the probe
session and two or three unrelated live sessions are kept, and the unrelated
sessions' `firstMessage` is cut to 60 characters. The selftest rewrites the
probe session's `sessionName` and `cwd` to its scenario's ticket and
worktree; the shape is verbatim.

| File | Captured with | Notes |
| --- | --- | --- |
| `sessions-working.json` | `prime-agent sessions --json` | the probe mid-turn: `activity: working`, `lifecycle: live`, `model` an object, `usage` with tokens and cost |
| `sessions-idle.json` | `prime-agent sessions --json` | the same probe after its turn: `activity: idle` |
| `sessions-all-archived.json` | `prime-agent sessions --all --json` | after `prime-agent stop`: the probe is `lifecycle: archived`, its `id` is now the durable `sessionId`, and it has no `model` key. Also holds a live session whose `sessionName` is `null` |
| `sessions-all-reused-name.json` | `prime-agent sessions --all --json` | a stopped session's name reused: one live and one archived `nw-probe-002`. Reference only |
| `stop.json` | `prime-agent stop <agent> --json` | identical for a name, an active id and a durable `sessionId`, while the session is live |
| `stop-not-live.txt` | `prime-agent stop <active id>` on a stopped session | stderr, exit 1. A name or id that is not live gets this |
| `stop-help.txt`, `sessions-help.txt` | `prime-agent help stop`, `prime-agent help sessions` | |
| `create-session-duplicate-name.txt` | `rlm.create_session(name=...)` while a live session of that name exists under the same parent | REPL exception, reference only: names are unique per parent, not globally |
| `create-session-bad-model.txt` | `rlm.create_session(model="anthropic/claude-nonexistent-9")` | REPL exception, reference only: the selector is checked at create time |

`prime-agent list --json` returns the same keys as `sessions --json`; the
provider reads only `sessions`. The ticket frontmatter fixtures are
workflow's, read from `../workflow/fixtures/`.
