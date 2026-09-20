---
seq: 18
date: 2026-09-19
level: 3
slug: 2026-09-19-wo-037-ship-about-learning-risk-decision-as-four-named-verbs-not-a-mutate-passthrough
title: "WO-037: ship About/Learning/Risk/Decision as four named verbs, not a `mutate` passthrough"
---

`townsquare.sh` shipped `whoami`/`projects`/`update` only, by its own header's
admission — the fields that carry the *reasoning* behind a status (Learning,
Decision, Risk, About) had no verb, though Home Projects has no REST fallback
for them (memory `8238ce2c`). That left the most informative half of the
capability unbuilt on purpose, for a workspace whose whole operating model
produces exactly those artifacts (`docs/decisions.md` entries, known-issue
resolutions, per-wave learnings) with no route to the project feed a human
reads.

Four named verbs (`about`, `learning`, `decision`, `risk`), each mirroring
`update`'s own read/write discipline, rather than one free-form `mutate`
passthrough: a passthrough would make every future field free but also make
an arbitrary GraphQL mutation against the live site one typo away — the
shipped script's discipline is the thing worth preserving. `mutate` stays
unshipped.

`learning`/`decision`/`risk` take only `<project-ari> -`, unlike homelab's
`atlassian-graphql.sh` (LAB-180) which also takes a separate `<summary>`
shell argument. The short plain-text `summary` these three mutations require
is instead derived from the first line of stdin, with the whole text
ADF-encoded into `description` — one input channel instead of two, at the
cost of the summary and the body's first line always matching.

Every mutation ships with a fixture recorded from a real call, per the
existing rule that a guessed GraphQL shape is worse than no entry: rather
than spike these live again, `fixtures/townsquare/{learning,risk,decision,
about}.*.json` reuse the LAB-180 spike's already-verified recordings from
`homelab/scripts/fixtures/atlassian-graphql/` (same throwaway
`ZZPROBE-tabs-fixtures-2026-09-11` project, never the real Homelab project),
the same sourcing `update`'s own fixtures used. That spike also confirmed,
live, two facts this implementation depends on: `description` requires ADF
the same as `update`'s `summary` does (a plain string is rejected, naming the
field), while `summary` on Learning/Risk/Decision is the one exception and is
sent as plain text; and Risk/Decision's created id carries the ARI type
segment `learning` regardless — the server's own inconsistency, not a bug.
