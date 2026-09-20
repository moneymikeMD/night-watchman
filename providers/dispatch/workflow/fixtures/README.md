# fixtures/ — recorded ticket frontmatter

This implementation calls no external binary, so there is no external
output to record. `start` reads exactly one outside artifact whose shape it
does not control: a ticket file, whose frontmatter decides whether the
ticket may be dispatched unattended. Those are the fixtures.

Each file below is the frontmatter of a real ticket from this project's
work-order set, copied rather than retyped, with the body trimmed to one
line and home paths de-identified. Per this project's fixture rule
("fixtures are recorded, never authored") and `docs/testing-philosophy.md`'s
fixture-provenance discipline, `provider-selftest.sh` reads these files
instead of writing frontmatter inline.

| File | Recorded from | Notes |
| --- | --- | --- |
| `ticket-executor-agent.md` | `WO-026` (this ticket) | the dispatchable case: `executor: agent` |
| `ticket-executor-mixed.md` | `WO-025` | the refused case. `human` is refused by the same branch and has no separate fixture: every real `executor: human` ticket on hand is a cancelled `WO-C0x`, and that id shape is refused a step earlier by the `PROJ-###` check, so such a fixture would test the wrong refusal |
| `ticket-no-executor.md` | `ticket-executor-agent.md` minus its `executor:` line | the only derived file here, and the derivation is the point: a ticket whose executor cannot be read is exit 2, "could not evaluate", never a silent dispatch. No real ticket omits the field, so there was nothing to record |
