---
seq: 8
date: 2026-09-19
level: 3
slug: 2026-09-19-nwm-123-was-undispatchable-because-its-contract-lived-in-prose-not-in-fields
title: "NWM-123 was undispatchable because its contract lived in prose, not in fields"
---

A ticket whose `verify:` and `executor:` are written as prose in the body
while the structured fields are empty is permanently undispatchable and
looks fine: `issues.py` reads the fields, `issues.py lint` reports the
project clean because an empty field is not a lint error, and the only
tool-side net (no executor means never startable) prevents a bad dispatch
while staying silent about the stranded ticket. NWM-123, captured from a
conversation reported across from homelab's LAB-241, sat in exactly that
state until both were lifted into their fields.

The rule that follows: a ticket captured from a conversation carries its
contract as fields, not sentences, and a verify clause asserts stderr as
well as exit codes and includes a case the fix could not pass by refusing
everything — the failure mode a guard fix is most likely to have.
