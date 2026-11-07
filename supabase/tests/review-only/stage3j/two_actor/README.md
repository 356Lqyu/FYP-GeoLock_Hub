# Two-actor claim acceptance after the claim-audit migration

Local compatibility preparation only. No live experiment was executed.

Use the current [claim harness runbook](../../../claim_concurrency_test.md) for
preflight, manifests, result semantics, commands, fault testing and recovery limits.
The runner defaults to preflight and accepts exactly two authenticated NGOs and two
fresh manifest-approved direct donation/listing pairs. No fixture insertion, recovery
RPC, cron operation or global cleanup is available.

`approved_functions.json` now contains the nine exact current migration definitions
plus the unchanged claim-card reader. It is derived from reviewed local SQL and checked
against disposable-local PostgreSQL catalogs, not claimed as a fresh DEV capture.
ACLs and other-function/recovery-history baselines must be supplied in the reviewed
private manifest and compared during live preflight. Prior whole-function aggregate
and fixed 17-run history assumptions are no longer silently reused.

Copy `dev.env.template` and `fixture_manifest.template.json` outside the repository.
Use the same ordered actor IDs, listing/donation mappings and unique fixture label.
Existing historical fixtures are fenced off. Provision new fixtures later through
protected application workflows. Both NGOs must genuinely discover both listings.

The scenario includes the normal two-way race, sequential and concurrent replay,
structured changed-actor/listing ERROR receipts with deduplicated failure records,
actor-scoped receipt retrieval, nonholder denial, normal cancellation, historical
replay after release and the observed delayed-lock race. Both listings finish
AVAILABLE with RELEASED history; failure/audit history remains intact.

`RESULTS.md` records validation versions. `SOURCE_PROTECTION.json` is historical
preparation evidence and is preserved; it is not the current function-contract file.
`SHA256SUMS.txt` identifies the current local package. No local PASS substitutes for
current approved DEV sessions, fixtures, worker health and a separate live-run decision.
