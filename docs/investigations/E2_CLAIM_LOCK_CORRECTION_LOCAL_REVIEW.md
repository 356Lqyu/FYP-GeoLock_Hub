# E2 claim-only lock correction: stopped, not deployment-ready

5 November 2026. **Outcome: PARTIAL / NOT PASS. Local validation stopped under the user's explicit wider-change stop condition. Do not deploy this candidate.**

The requested one-line change is safe with respect to the listing columns directly updated by `claim_listing`, but it is insufficient for the complete current call chain. The shared `public.geolock_lock_listing_donations(uuid,text[])` reacquires the listing **FOR UPDATE**, upgrading the lock and recreating a key-share wait cycle. A complete fix needs review beyond the approved claim-only line. No shared helper, unrelated lock, existing migration, claim/recovery semantics or deployed database was changed.

The earlier investigation's one-line recommendation was incomplete: it identified the first listing lock but did not account for the stronger listing lock taken later by the shared helper. Its reproduced original deadlock remains valid; the assumption that changing the first acquisition alone would solve full-path contention is disproved by this new execution.

## What was implemented locally

A guarded forward SQL candidate was created in `docs/investigations/e2-claim-lock-correction/proposed_migration.sql`, outside the deployable migration directory. Proposed version 20261105120000 is only a review identifier, not an applied/published ledger entry. It was applied solely to `e2_proposed` in a fresh private PostgreSQL 17.11 cluster.

Exact business-function diff (also in `claim_listing.diff`):

```diff
-  select * into v_l from public.listings where listing_id=p_listing for update;
+  select * into v_l from public.listings where listing_id=p_listing for no key update;
```

All other function-body bytes are preserved after CRLF normalization. Other `FOR UPDATE` statements are untouched. The original `supabase/migrations/20261031_claim_audit_and_failure_capture.sql`, canonical reconciliation migration, schema snapshot and original benchmark runner remain unchanged.

The SQL patch checked the exact original source hash, a single exact anchor, expected owner/security/search-path metadata, listing key dependencies, the existing listing transition trigger and its source fingerprint. It verified the replacement body and unchanged function OID/owner/ACL/security/search path after `CREATE OR REPLACE`. These checks **passed locally**; they do not establish robustness of the full call chain.

- Original normalized claim body MD5: `2c1f60c876797c61b44b3cb43591bab8`.
- Candidate normalized claim body MD5: `c8d324772b12c843fba231e7ea733914`.
- Actual applied SQL bytes are preserved separately in the new run's `applied_candidate.sql`, SHA256 `f4e5a91a30177f5825f64965f7158152e79e09b79c59e7f9e3fe79daea028718`.
- The review copy now has an explicit FAILED/DO NOT DEPLOY header. That comment-only annotation was added after saving the exact applied bytes.

## Dependency and lock-safety findings

The pinned claim body updates `listing_status` and `listing_version` only; it does not change listing ID, donation ID, batch ID or source type. The reviewed listing indexes include the primary listing ID and source-specific donation/batch uniqueness; the two updated columns are not listing unique/FK keys. `enforce_listing_transition()` validates allowed statuses and returns NEW; it does not rewrite keys. The local patch's dependency guards accepted the actual catalog. This supports using a no-key-update lock for that acquisition but cannot prevent a later explicit lock upgrade.

Relevant call chain:

1. `claim_listing`: insert request; immediate `claim_requests_listing_id_fkey` takes a listing key-share lock.
2. `claim_listing`: candidate takes listing **FOR NO KEY UPDATE**.
3. `claim_listing`: source readiness check calls `geolock_lock_listing_donations`.
4. That shared helper, defined in `supabase/migrations/20261027_persisted_donation_lifecycle.sql`, begins with `select * into v_l from public.listings where listing_id=p_listing for update;` (line 132).
5. The successful transition path later calls the same helper again through `geolock_transition_listing_donations`.

One caller can hold NO KEY UPDATE while another holds FK key-share and waits for that caller's lock. The first caller's helper then requests FOR UPDATE, which conflicts with the other FK key-share. Changing only the first acquisition leaves this cycle possible. Actual stopped-database function definitions/hashes are saved in `stopped_function_evidence.json`; no live DEV definition is assumed.

The protected baseline does not have this current lifecycle-helper call chain and already uses FOR NO KEY UPDATE. Its clean historical result therefore cannot validate this candidate in the full GeoLock schema. The previous standalone compatible-lock control likewise did not exercise the later helper upgrade.

**Wider correction candidate requiring approval:** review all callers of the shared helper, and determine whether its listing acquisition can also use FOR NO KEY UPDATE while retaining its donation/batch/inventory locks and all custody guards. This would change a second function with cancellation, recovery and reconciliation callers; it has **not** been implemented or declared safe. An alternative lock-order redesign would be a larger change. Neither additional helper changes nor a retry policy was silently introduced.

## New run and actual partial results

New run: `experiments/e2_atomic_claiming/results/e2-20261105-v33-no-key-update-01/`.

The proposed-only controller reused the preserved original fixture and scenario driver with the same frozen GEOLOCK-BM-v3.3 cases, road matrix, actor ordering, barriers, READ COMMITTED isolation, lease settings and retry behavior. Original baseline results were reused, not rerun or overwritten. The original Auth/Storage/frozen-road adapters and full-schema qualifications remain applicable.

The run was stopped as soon as the continued errors and wider helper dependency were identified. **65 of 275 planned scenario records were saved**, all contention: 50 two-request cases and 15 five-request cases. The remaining 35 five-request, all 50 ten-request, 100 expired-lease and 25 active-lease cases were not completed/saved. Do not describe this as a completed corrected benchmark or extrapolate its counts to 150 contention trials.

| Candidate workers | Saved trials | Requests | Successes | Clean conflicts | ERROR responses | Duplicate trials | Exactly-one-owner trials | Median request ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 | 50 | 100 | 50 | 0 | 50 | 0 | 50 | 1056.35 |
| 5 | 15 | 75 | 15 | 0 | 60 | 0 | 15 | 3060.00 |

These are the **175 raw requests associated with saved complete scenario rows**, not a full rerun. Request latencies include rollback errors. `proposed_requests.json` and `proposed_results_per_scenario.csv` are authoritative.

The disposable database contained **114 audited errors, all 40P01**, including four additional errors from an in-flight unsaved scenario. The 110 ERROR responses in saved complete cases and 114 database audit rows have different scopes; they must not be silently treated as the same denominator. `database_errors.csv` preserves every collected audit. `stopped_committed_states.json` captures committed active claim counts after the controller stopped.

Historical comparisons are retained unchanged:

| Method / evidence scope | Contention trials | Duplicate trials | Successes | Clean conflicts | Database errors | Expired recovery | Incorrect active releases |
|---|---:|---:|---:|---:|---:|---:|---:|
| Original non-atomic, full old run | 150 | 150 | 753 | 97 | 0 | Not implemented | Not applicable |
| Protected without recovery, full old run | 150 | 0 | 150 | 700 | 0 | 0/100 | 0/25 |
| Original proposed, full old run | 150 | 0 | 150 | 9 | 691 | 100/100 | 0/25 |
| Claim-only candidate, **partial saved cases** | **65** | 0 | 65 | 0 | 110 responses | **Not rerun** | **Not rerun** |

No equal-sample improvement or significance claim is justified. Original median/p95 latencies and all full-sample comparisons remain in `e2-20261105-v33-actual-01/comparison.csv`. Historical successes are not evidence that this candidate passed an unexecuted recovery, authorization or concurrency regression.

## Validation status and shutdown

- Executed: fresh full-schema bootstrap, exact forward patch/pre/post guards, 65 saved frozen contention cases, source/failure-audit capture and private server shutdown.
- **Failed:** clean losing-request conflict handling / elimination of 40P01.
- Observed in saved cases: single committed ownership preserved, zero duplicate trials.
- **Not executed:** the additional corrected regression suite, controlled-interleaving confirmation, ten-request candidate cases, same/different UUID tests, candidate lease tests, cancellation/release races, audit-fault tests and negative authorization/eligibility controls. The code for these checks is a draft, not a test result.
- `STOPPED.json` explicitly records `formal_full_run_complete=false`, `additional_regression_suite_executed=false`, `e2_readiness=PARTIAL_NOT_PASS` and the reason for stopping. No successful completion receipt was fabricated.
- The owned controller was interrupted. `cluster-stop.json` confirms its exact marked data directory is stopped (`pg_ctl status` exit 3), zero remote connections. Runtime data and logs remain retained; no existing database was opened for writing.
- SHA256 comparison against all **471** previously sealed files found no differences. Evidence: `original_evidence_integrity.json`. Original E2/E4 results, original runner, baseline algorithms and frozen input bytes remain unchanged. No E4 rerun was performed.

## Deployment and recovery review

**NO-GO for this candidate.** No deployment command is recommended while it remains incomplete. The separate rollback SQL is an **unexecuted review draft**, not validated recovery tooling. No DEV rollback is needed because no DEV write occurred.

The candidate changes function code only; there is no new table/state, data rewrite, lease extension or history cleanup. A later approved code rollback must not delete/revert legitimate claims, reset leases, erase audits or restore a full database over newly committed business activity. Restoring the original function would restore its original deadlock exposure. Drift checks must prevent restoring over a different function revision.

Before any future DEV deployment:

1. Obtain approval for the wider helper/caller review and local correction; complete fresh controlled-interleaving, 2/5/10 contention, idempotency, lease, cancellation/recovery, audit and negative authorization/eligibility checks. Then execute a **new** complete proposed-method benchmark with a new run ID.
2. Review and freeze a complete forward migration, its exact SHA256 and expected before/after function/trigger fingerprints. Verify actual DEV project `rcgyuwiidqvrgbxswhqj`, dependencies, owner/ACLs and migration/receipt history read-only; do not assume today's local catalog proves deployed state.
3. Have an authorized database owner/operator capture current function definitions, ownership/ACLs, relevant schema/constraint/trigger definitions and the approved backup baseline. Verify the backup and restore it into an isolated environment; validate recovery against that baseline. Neither backup nor restore was executed here.
4. Agree on an unused forward version and the established manual receipt/ledger procedure without rewriting old history; retain exact applied SQL, hashes, execution output and postchecks.
5. Obtain separate explicit deployment approval and schedule a controlled post-deployment validation. No worker change or APK installation is required merely to prepare the SQL review.

## Files added for this attempt

- `docs/investigations/E2_CLAIM_LOCK_CORRECTION_LOCAL_REVIEW.md` — this report.
- `docs/investigations/e2-claim-lock-correction/proposed_migration.sql` — failed, guarded claim-only review candidate; explicitly DO NOT DEPLOY.
- `docs/investigations/e2-claim-lock-correction/claim_listing.diff` — exact one-line business-function diff.
- `docs/investigations/e2-claim-lock-correction/rollback_patch.sql` — unexecuted guarded rollback draft.
- `docs/investigations/e2-claim-lock-correction/original_evidence_integrity.json` — original 471-file seal check.
- `docs/investigations/e2-claim-lock-correction/attempt_integrity.json` — new-attempt file hashes and stopped/source/syntax verification.
- `experiments/e2_atomic_claiming/run_corrected.py` — new proposed-only controller derived from the unchanged original runner.
- `experiments/e2_atomic_claiming/corrected_regressions.py` — drafted additional checks; not reached/executed.
- `experiments/e2_atomic_claiming/summarize_corrected.py` — drafted full-run comparison; not executed because this run is incomplete.
- New run directory above — input/source manifest, 65 saved scenario records and requests, committed state snapshots, failure audits, applied candidate bytes, actual function definitions, STOPPED/shutdown receipts, retained runtime/schema evidence. `.tmp/e2-corrected-01.log` retains progress output.

Stop point: further implementation requires authorization for the shared-helper scope. The failed candidate and partial run are evidence, not deployable deliverables or a corrected E2 PASS.
