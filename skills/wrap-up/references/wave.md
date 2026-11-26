# Wave wrap-up

Loaded from `wrap-up` step 0 when the session dispatched or landed a wave. The "Before the questions" steps run first; the "After the handoff" steps run once `wrap-up` step 3 has
committed the wave note.

## Before the questions

**Audit the trail.** Audit the wave-trail against this session's transcript and end the report with its Attention section — see `wave-trail`. Give each unit a fixed status tag, not free text:
`[landed <sha>]`, `[in flight <branch>]`, `[blocked <on>]`, `[abandoned <why>]`, `[owed-human <step>]`.

**Cost review, if this wave runs one.** If this wave runs the `cost-review` skill (the optional per-wave review in `docs/cost.md`, distinct from the automatic `SessionEnd` ledger row), first record the
`accepted` event for every script whose ticket reached completion this wave — `librarian` or the main thread runs ai-toolkit's `script-analytics.py record --event accepted ...` per script — and
confirm each row landed by re-reading `docs/script-events.jsonl`. Only once that is confirmed, run `cost-review`: an `accepted` event written while its usage report runs lands after
it and is silently missing from that wave's report. Fix the ordering, not the symptom: `cost-review` never polls or retries for a late-arriving event.

## After the handoff

**Publish the brief** once the wave note is written and committed, if a `publish` provider is configured (`provider.sh doctor` shows it `installed` and `[publish.<impl>]` is filled in — in the
committed config, or, for a repo that is published, in the private config `$NW_CONFIG` points at, where site identifiers live alongside the tracker host). The brief is the note's owner-facing
sections — Recent Wins / Things to be aware of / What We Have Comin' Next — as markdown, with the H1 and any `harness:` line stripped (the title is the page title):

```bash
P=${CLAUDE_PLUGIN_ROOT}/providers/lib/provider.sh
URL=$("$P" publish publish-brief "<date> <project> Update" brief.md)
"$P" publish post-headline default "<headline, under 200 chars>" "$URL"
"$P" publish post-headline <EPIC-KEY> "<headline>" "$URL"   # once per epic with a landed ticket, if mapped
```

Rehearse both with `NW_DRY_RUN=1` first on a wave that publishes for the first time. Fail soft, per feed: a rejected `post-headline` (exit 1) gets one line in the wave note naming the feed and the
exact error, and the next feed is still posted. A failed `publish-brief` skips the headlines — there is no URL to point at — and is noted the same way.

**Report to the user** as: verified (moved), verified-partial (what is owed and by whom), started (what each agent left on disk), and the one or two decisions only the user can make. When a
dispatch provider ran the wave, name the dispatch tool and carry the **run record** — one row per agent, plus the collected `ASSUMED:` escalations, `denials` and stalls. See `wave-trail`.

Report the run record, not "how each agent was watched", under an in-process dispatch tool. Nobody watched: there is no pane and no way to intervene mid-run, and a live view is not wanted (offering
one has been declined on principle). The run record is the owner's only channel into that wave, so treat an omission from it as information destroyed rather than detail spared.

The outcome comment's `cost:` line is read from `.night-watchman/last-session-cost.txt`, if present — the plugin's `SessionEnd` hook (`hooks/session-cost.sh`, see `docs/cost.md`) writes it
automatically as the session ends. Write `cost: UNVERIFIED` only when that file is absent (the hook isn't wired up, or hasn't run yet for this session), and say so explicitly rather than omitting
the line.
