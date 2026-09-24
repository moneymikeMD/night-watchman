---
seq: 12
date: 2026-09-19
level: 3
slug: 2026-09-19-the-extraction-bar-has-two-triggers-not-one-and-the-ticket-contract-leaves-for-work-order
title: "the extraction bar has two triggers, not one, and the ticket contract leaves for `work-order`"
---

`docs/ethos.md`'s extraction default — a measured second consumer is the
bar for extracting a shared core — was written for de-duplication, and
de-duplication is the only signal it can see. Applied to the ticket-contract
layer it gave the wrong answer: switchtender has no `issues.py` and no
ticket tooling at all, so by the letter of the rule the extraction was
speculative. The owner supplied the fact that reverses it: every repo he
works in already assumes a tracker space, tickets, and a sprint wrapping
bounded work, and none of them owns that assumption. That is the inverse of
duplication and it costs more, because nothing drifts visibly — the thing
simply is not there, and no diff shows an absence.

**The rule.** Either trigger is enough on its own: a measured fork, or a
universal assumption no repo owns. Absent both, an extraction is
speculative work.

**The decision set**, settled in five rounds of grilling on 2026-09-19
(memory-graph `96a41a7a-3044-428c-aa0e-66644fd3aa2f`, filed as the WO
project in Jira):

1. Extract now, and rewrite the ethos default that said otherwise.
2. The deliverable is a specification — schema and protocol. `issues.py` is
   the reference implementation, not the product.
3. The name is `work-order`.
4. Its own public repository, MIT throughout.
5. The sprint mechanism is an optional documented extension, not core.
6. It ships spec, reference implementation, runnable conformance validator
   and fixtures. The validator is the teeth.
7. One repository, Claude Code plugin included. No package registry until
   an outsider asks for one.
8. The core is tracker-agnostic, with normative bindings: a file binding
   and a Jira binding. The six Jira custom fields become the Jira binding.
9. The Jira binding is a separately versioned package in the same
   repository, and it owns provisioning, because "provision me a conforming
   Space" is what makes a standard adoptable rather than admirable.
10. The spec versions independently of both packages — three version lines
    from one repository, so "conforms to work-order spec 1.0" stays stable
    while the implementations churn.
11. Conformance is MUST/SHOULD levels plus named profiles: minimal, full,
    unattended. The profiles map onto the layer split.
12. night-watchman depends on `work-order` and deletes its copies. No
    vendored fork. It keeps layer 2 only: dispatch, waves, session-start,
    the land-branch lifecycle, closing-state handoff, wave-trail.
13. `work-order` defines the profile names, including `unattended`, under a
    hard test: `unattended` must be writable purely as what a ticket needs
    to start cold with no human. If it cannot be written without naming
    night-watchman behaviour, it does not belong in the spec.
14. `to-issues` splits in two. The seam is a documented structured decision
    list: night-watchman mines the conversation and emits it, `work-order`
    consumes it and emits conforming tickets. Testable from both sides.
15. No retroactive conformance. New and touched tickets conform; existing
    LAB, NWM and CMB tickets are grandfathered under the touched-ticket and
    active-sprint lint scoping.
16. All three repositories convert in one wave.

The reframing behind this is three layers: a ticket is a contract an agent
can execute (tracker-agnostic, the reusable idea, `work-order`); a session
runs unattended (the differentiator, what night-watchman is); the provider
and plugin system (the extension mechanism).

**The boundary rule does not apply to `work-order`, deliberately.**
homelab's LAB-275 sorts shared tooling by one test: does a machine apply it,
or does a repo call it? Machine-applied goes to the private dotfiles repo;
repo-consumed goes to the public `ai-toolkit`. Read literally, a spec plus a
reference implementation that repos consume would land in `ai-toolkit`. It
does not: that rule sorts internal shared plumbing for this owner's own
repositories, and `work-order` is a public product aimed at strangers — a
different audience, a different cadence, its own independently versioned
spec, and a conformance validator outsiders run against implementations
that are not ours. Folding it into `ai-toolkit` would tie a product's
release line to a plumbing repository's moving `@v1` major tag, which is
exactly what decision 10 exists to prevent. `ai-toolkit` remains the default
for shared tooling; `work-order` is the documented exception, not a
precedent.
