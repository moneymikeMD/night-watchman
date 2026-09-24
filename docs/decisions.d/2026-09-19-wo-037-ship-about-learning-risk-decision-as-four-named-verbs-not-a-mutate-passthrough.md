---
seq: 18
date: 2026-09-19
level: 3
slug: 2026-09-19-wo-037-ship-about-learning-risk-decision-as-four-named-verbs-not-a-mutate-passthrough
title: "WO-037: ship About/Learning/Risk/Decision as four named verbs, not a `mutate` passthrough"
---

The Home Projects fields that carry the *reasoning* behind a status
(Learning, Decision, Risk, About) have no REST fallback (memory `8238ce2c`),
and this workspace's operating model produces exactly those artifacts
(decision entries, known-issue resolutions, per-wave learnings).
`townsquare.sh` ships them as four named verbs (`about`, `learning`,
`decision`, `risk`), each mirroring `update`'s own read/write discipline,
rather than one free-form `mutate` passthrough: a passthrough would make
every future field free but also make an arbitrary GraphQL mutation against
the live site one typo away. `mutate` stays unshipped.

`learning`/`decision`/`risk` take only `<project-ari> -`, unlike homelab's
`atlassian-graphql.sh` which also takes a separate `<summary>` shell
argument. The short plain-text `summary` these three mutations require is
derived from the first line of stdin, with the whole text ADF-encoded into
`description` — one input channel instead of two, at the cost of the summary
and the body's first line always matching.

Every mutation ships with a fixture recorded from a real call, because a
guessed GraphQL shape is worse than no entry:
`fixtures/townsquare/{learning,risk,decision,about}.*.json` are the LAB-180
spike's verified recordings from
`homelab/scripts/fixtures/atlassian-graphql/` (the throwaway
`ZZPROBE-tabs-fixtures-2026-09-11` project, never the real Homelab
project). Two facts from that spike this implementation depends on:
`description` requires ADF the same as `update`'s `summary` does (a plain
string is rejected, naming the field), while `summary` on
Learning/Risk/Decision is the one exception and is sent as plain text; and
Risk/Decision's created id carries the ARI type segment `learning`
regardless — the server's own inconsistency, not a bug.
