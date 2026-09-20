---
seq: 12
date: 2026-09-19
level: 3
slug: 2026-09-19-the-extraction-bar-has-two-triggers-not-one-and-the-ticket-contract-leaves-for-work-order
title: "the extraction bar has two triggers, not one, and the ticket contract leaves for `work-order`"
---

`docs/ethos.md`'s extraction default read "a measured second consumer is the
bar for extracting a shared core": one real fork of the same code, not an
anticipated one, or the extraction is speculative work. Applied to the
ticket-contract layer on 2026-09-19 it gave the wrong answer. Per the ethos
file's own rule the row is fixed in place; no exception is bolted onto it.

**Why the original misfired.** It was written for de-duplication — two copies
of the same code drifting apart — and de-duplication is the only signal it can
see. switchtender has no `issues.py` and no ticket tooling at all, so by the
letter of the rule the extraction was speculative and should have waited. The
owner supplied the fact that reverses it: every repo he works in already
assumes a tracker space, tickets, and a sprint wrapping bounded work, and none
of them owns that assumption. Working a switchtender ticket from inside the
night-watchman checkout follows the protocol by accident, not by design. That
is the inverse of duplication and it costs more, because nothing drifts
visibly — the thing simply is not there, and no diff shows an absence. A rule
that answers a whole class of cases wrongly is worse than no rule, because it
carries authority.

**The corrected rule.** Either trigger is enough on its own: a measured fork,
or a universal assumption no repo owns. NWM-127's evidence (`land-branch.sh`
against homelab's 1402-line fork) is untouched and still carries the first
trigger; the `work-order` extraction is the second trigger's evidence beside
it. Absent both, an extraction is still speculative work.

**The decision set.** Five rounds of grilling on 2026-09-19 settled 16
decisions, recorded in memory-graph as `96a41a7a-3044-428c-aa0e-66644fd3aa2f`
and filed as the WO ticket set under `~/code/issues/`. Repeated here because
memory-graph fails closed off the LAN:

1. Extract now, and rewrite the ethos default that said otherwise.
2. The deliverable is a specification — schema and protocol. `issues.py` is
   the reference implementation, not the product.
3. The name is `work-order`.
4. Its own public repository, MIT throughout.
5. The sprint mechanism is an optional documented extension, not core.
6. It ships spec, reference implementation, runnable conformance validator and
   fixtures. The validator is the teeth.
7. One repository, Claude Code plugin included. No package registry until an
   outsider asks for one.
8. The core is tracker-agnostic, with normative bindings: a file binding and a
   Jira binding. The six Jira custom fields become the Jira binding.
9. The Jira binding is a separately versioned package in the same repository,
   and it owns provisioning, because "provision me a conforming Space" is what
   makes a standard adoptable rather than admirable.
10. The spec versions independently of both packages — three version lines from
    one repository, so "conforms to work-order spec 1.0" stays stable while the
    implementations churn.
11. Conformance is MUST/SHOULD levels plus named profiles: minimal, full,
    unattended. The profiles map onto the layer split.
12. night-watchman depends on `work-order` and deletes its copies. No vendored
    fork. It keeps layer 2 only: dispatch, waves, session-start, the
    land-branch lifecycle, closing-state handoff, wave-trail.
13. `work-order` defines the profile names, including `unattended`, under a
    hard test: `unattended` must be writable purely as what a ticket needs to
    start cold with no human. If it cannot be written without naming
    night-watchman behaviour, it does not belong in the spec.
14. `to-issues` splits in two. The seam is a documented structured decision
    list: night-watchman mines the conversation and emits it, `work-order`
    consumes it and emits conforming tickets. Testable from both sides.
15. No retroactive conformance. New and touched tickets conform; existing LAB,
    NWM and CMB tickets are grandfathered under the touched-ticket and
    active-sprint lint scoping decided 2026-09-18.
16. All three repositories convert in one wave.

The reframing that produced this is three layers: a ticket is a contract an
agent can execute (tracker-agnostic, the reusable idea, becomes `work-order`);
a session runs unattended (the differentiator, becomes what night-watchman
actually is); the provider and plugin system (the extension mechanism).

UNVERIFIED and load-bearing for decision 12: that `plugin.json` supports a
`dependencies` field with semver constraints, that installing a plugin
auto-installs its dependencies, and that one repository can publish several
independently versioned plugins through one `marketplace.json`. This is
agent-reported and is spiked before the design leans on it. If it is false the
fallback is vendoring, which changes decision 12's mechanism only.

**The boundary rule does not apply to `work-order`, deliberately.** homelab's
LAB-275 (2026-09-18) sorts shared tooling by one test: does a machine apply it,
or does a repo call it? Machine-applied goes to the private dotfiles repo;
repo-consumed goes to the public `ai-toolkit`. Read literally, a spec plus a
reference implementation that repos consume is repo-consumed, and `work-order`
would land in `ai-toolkit`.

It does not, and this is recorded so nobody re-litigates it on the next read of
LAB-275. That rule sorts internal shared plumbing by where it is applied from,
and its audience is this owner's own repositories. `work-order` is a public
product aimed at strangers: a different audience, a different cadence, its own
independently versioned spec, and a conformance validator outsiders run against
implementations that are not ours. Folding it into `ai-toolkit` would tie a
product's release line to a plumbing repository's moving `@v1` major tag, which
is exactly what decision 10 exists to prevent. LAB-275 is unchanged for
everything it was written for — `comment-lint.py`, the composite action, the
five migrating scripts — and `ai-toolkit` remains the default for shared
tooling. `work-order` is the documented exception, not a precedent for moving
plumbing out of `ai-toolkit`.

Still open, left unguessed: whether `work-order` gets its own tracker space.
Every other active repo has one.
