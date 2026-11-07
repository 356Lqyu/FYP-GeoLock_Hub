# E2 coordinated shared-helper correction — LOCAL PASS

5 November 2026 (Asia/Kuala_Lumpur). **LOCAL PASS for the requested corrected E2 correctness/robustness scope. Ready for a separate DEV deployment review, not deployed or production verified.** No DEV/production access or writes, deployment, Flutter edit, routing-worker source change, E4 rerun, frozen-input change or GitHub push occurred.

## Resumed checkpoint and outcome

Work resumed from the existing caller review, original deadlock reproduction and 28-check focused pass. The complete investigation and original benchmark were not restarted. The original reproduction is retained in `e2-shared-lock-review/original-reproduction/`: unchanged original claim/helper sources produced the expected 40P01 rollback and exactly one committed owner under the forced FK interleaving.

Custody testing had **not passed** at the checkpoint. Three attempts were blocked by strict fixture source/metadata guards; another failed before any test during route-fixture authorization. The read-only inspection process was interrupted, leaving a stale PostgreSQL PID file with no running server. Its exact task-owned fixture was recovered for read-only inspection and stopped; `resumed-inspection-stop.json` records successful shutdown. No interrupted run was counted as a pass or deleted.

The final fixture fixes were limited to setup: match the primary fixture's explicit authenticated claim-function grant while retaining its existing PUBLIC grant and body authorization; normalize doubled blank lines only after comparing every nonblank source line exactly; and review the operational async-eligibility trigger set rather than removing triggers or bypassing security checks. The assertion that the ACL issue was necessarily an unintended PUBLIC grant was corrected: the reviewed primary catalog also retains PUBLIC execution. The SQL candidate preserves that existing ACL; authorization remains in the unchanged function body.

All final focused checks passed, followed by a new complete 275-scenario benchmark. Original E2/E4 measurements and the failed claim-only candidate remain historical evidence.

## Exact coordinated correction

Only these two function-body lines change:

```diff
 public.claim_listing(uuid,uuid)
-  select * into v_l from public.listings where listing_id=p_listing for update;
+  select * into v_l from public.listings where listing_id=p_listing for no key update;

 public.geolock_lock_listing_donations(uuid,text[])
-  select * into v_l from public.listings where listing_id=p_listing for update;
+  select * into v_l from public.listings where listing_id=p_listing for no key update;
```

The complete diffs are `e2-shared-lock-review/claim_listing.diff` and `geolock_lock_listing_donations.diff`. No other FOR UPDATE acquisition changes. All donation/batch/inventory locks, caller lock prefixes, unique/FK constraints, triggers, authorization/road eligibility, leases, transitions, custody/evidence rules, audits, failure receipts and request UUID/digest/replay semantics remain unchanged. No automatic retry was added; measured benchmark retry count is zero.

| Function | Original normalized body MD5 | Corrected normalized body MD5 | Owner / security / search path |
|---|---|---|---|
| claim_listing(uuid,uuid) | 2c1f60c876797c61b44b3cb43591bab8 | c8d324772b12c843fba231e7ea733914 | postgres; SECURITY DEFINER; pg_catalog, public, extensions, pg_temp |
| geolock_lock_listing_donations(uuid,text[]) | 90816e7c6db3606dc8b6451a899d8036 | e97a3fd80673a827465f3eaa79b65903 | postgres; SECURITY INVOKER; pg_catalog, public, pg_temp |

Claim ACL remains `{=X/postgres,postgres=X/postgres,authenticated=X/postgres}`; helper ACL remains `{postgres=X/postgres}`. Recovery source remains `05fe46d8b76085f71c87fcc5f6520775`, owner postgres, SECURITY DEFINER, postgres/service_role execution. Function OIDs and complete pg_proc metadata excluding prosrc are checked unchanged during patching. Corrected claim/helper/recovery source/owner/ACL metadata is recorded before and after the full run and matches.

The forward and rollback SQL are outside the deployable migrations directory:

- `docs/investigations/e2-shared-lock-review/proposed_migration.sql`
- `docs/investigations/e2-shared-lock-review/rollback_patch.sql`

SHA256:

| Artifact | SHA256 |
|---|---|
| Final coordinated forward SQL | d3b466db926b389155edc499d9cc53106f81ac6cd6addc1033e01b1531e4ce70 |
| Final coordinated rollback SQL | 521f128b12ab7ce99ad9bdc8f8113d3ee67c8409cb214bdca759110c9d744ffd |

The full run retains the exact applied bytes in `applied_candidate.sql`. The old `e2-claim-lock-correction/proposed_migration.sql` stays **FAILED / DO NOT DEPLOY** and was not reused as the final correction.

## Caller and lock-order safety review

`e2-shared-lock-review/CALLER_LOCK_REVIEW.md` documents the complete reviewed 29-function conservative reverse-call closure, all direct/indirect callers, explicit lock order, FK key-share locks, triggers and limitations. Exact actual definitions, metadata and graph edges are retained in `caller-catalog.json`, `caller-graph.json` and the original full function catalog. Overload edges are conservative, not an assertion that every edge is independently executed.

The six direct caller names are claim_listing, six-argument geolock_transition_listing_donations, cancel_claim, recover_expired_claims, routing_private.lock_sources and routing_private.coord_decide. The compatibility transition wrapper and managed pickup/route/reconciliation entry points are included transitively.

Reviewed listing updates do not change listing ID, donation/batch identity or other listing key columns. Status/version updates are key-stable. The claim path previously upgraded from FK key-share to FOR UPDATE twice; correcting both acquisitions eliminates that reproduced upgrade cycle. Cancellation, recovery, legacy pickup, managed route and reconciliation paths retain their earlier stronger listing locks and established prefixes. A weaker helper acquisition does not downgrade an already held stronger lock or reorder donation/inventory locking.

The final guard explicitly recognizes only the minimal listing-transition trigger set or the reviewed operational set including `zz_listing_eligibility_generation` and `trg_listing_road_eligibility`. It validates names, function identities/fingerprints, owner/security state and trigger firing configuration; unknown configurations fail. Operational trigger source comes from `20261024_async_listing_eligibility_refresh.sql`: AVAILABLE→CLAIMED leaves generation/node unchanged, and the after trigger immediately returns. Legitimate reopening retains coverage/road checks, generation/cache/queue behavior and existing stronger caller locks. No extra claim-path upgrade was found. The operational trigger review and its function hashes are retained in `operational-trigger-review.json`.

The SQL guards fingerprint source/owner/ACL/security/search-path metadata of all 29 reviewed functions, require exact replacement counts, check listing key/trigger dependencies and validate the complete resulting bodies/metadata. Source, security-definer and helper-grant drift tests reject changes and roll back safely. New/unqualified/dynamic DEV callers are not automatically discovered by those guards: repeating the caller/trigger catalog comparison is a mandatory deployment preflight.

This review and finite tests do **not** prove that every possible lifecycle schedule is deadlock-free. Other untested graphs, new callers or administrative SQL remain outside the claim. No third business-function change was required or implemented.

## Focused validation

**41 focused SQL checks/tests passed:** 30 primary checks plus 11 existing custody/route-lifecycle tests. An additional launcher check confirmed optimized Python is rejected before creating an output/database.

Primary checks passed in `e2-20261105-v33-shared-focused-05` and were repeated successfully inside the fresh full-run database before formal scenarios:

- Distinct 2/5/10-NGO contention: exactly one success, all losing requests clean conflicts, one active owner.
- Same UUID replay, concurrent same UUID serialization, different UUID behavior and different-payload/foreign-actor request reuse protection.
- Original controlled FK interleaving: actual corrected claim function returns one SUCCESS and one CONFLICT, no deadlock.
- Five cancellation/release-versus-claim races and one recovery/release-versus-claim race.
- Expired recovery and active-lease protection.
- Deliberately injected failure rolls back partial claim/lease/task changes and persists a trusted receipt; manual same-UUID retry succeeds afterward.
- Ordinary authenticated NGO cannot mutate failure receipts; success replay does not duplicate its audit.
- Unauthenticated/inactive NGO and unverified/outside-road eligibility cases reject safely.
- Source drift, security metadata drift, helper execution-grant drift, safe reapplication rejection and guarded rollback/reapply.

The extra ten-account tests use local regression-only NGOs at a verified frozen location. Frozen ten-request benchmark scenarios can repeat fewer actors; their members/request counts were not changed.

All 11 custody tests passed in `results/automatic-routing-local/20261105T023227Z-d8a3b8`:

1. Started matching no-handover release and depot checkpoint.
2. Matching handover collection with vehicle accountability.
3. Mutual joint review, new evidence rounds and preserved receipts.
4. Ownership/version/request-payload checks.
5. Concurrent matching resolution applies once.
6. Recorded collection/incidents block unsafe release.
7. Missing lease/private permit rejection.
8. Depot checkpoint versus next-dispatch race.
9. Expired source window keeps the released listing closed.
10. Custody incident blocks matching no-handover closure.
11. Hub handover completes all immutable members/inventory together.

Their local synthetic validator/graph setup did not change or activate a hosted worker. Final custody receipt: `custody-tests.json`, with zero failures/errors and successful shutdown in the referenced evidence directory.

### Failed/incomplete attempts retained

Earlier setup/test-harness failures are not passes: ambiguous SQL row alias; four actors mistakenly asserted as five; a superuser no-op update incorrectly used to test ordinary-user receipt protection; fixture ACL representation; CRLF blank-line padding; an incomplete route-authorization setup; and the initial overly narrow minimal-fixture trigger-count guard. Exact source snapshots/logs/attempt receipts remain retained. The final candidate did not bypass substantive safety failures, disable constraints/triggers or relax security checks to get a pass. The latest passing suite used explicit reviewed fixture/guard corrections described above.

## Complete new frozen E2 benchmark

Run ID: **e2-20261105-v33-shared-no-key-update-01**.

Directory: `experiments/e2_atomic_claiming/results/e2-20261105-v33-shared-no-key-update-01/`.

All **275/275** scenarios completed: 150 CLAIM_COORDINATION, 100 LEASE_RECOVERY and 25 LEASE_ACTIVE_VERIFICATION. There were zero fixture/execution failures. All 275 saved committed states have exactly one active owner. The run used 975 measured requests: 850 contention and 125 replacement/active-check requests, plus separate prior-holder setup calls outside latency denominators.

| Contention method | Trials | Duplicate trials | Extra committed claims | Successes | Clean conflicts | Database errors |
|---|---:|---:|---:|---:|---:|---:|
| Original non-atomic baseline | 150 | 150 | 603 | 753 | 97 | 0 |
| Existing protected, no recovery | 150 | 0 | 0 | 150 | 700 | 0 |
| Original GeoLock proposed | 150 | 0 | 0 | 150 | 9 | 691 (40P01) |
| **Corrected GeoLock proposed** | **150** | **0** | **0** | **150** | **700** | **0** |

Corrected exactly-one-committed-claim and exactly-one-success-response correctness: **150/150**. Every losing measured contention request is a clean conflict. SQLSTATE 40P01: **zero**; other measured database errors: **zero**. No retries masked a failure.

| Method | Expired-lease replacements | Incorrect active-lease releases | Lease-case errors |
|---|---:|---:|---:|
| Protected without recovery | 0/100 | 0/25 | 0 |
| Original proposed | 100/100 | 0/25 | 0 |
| **Corrected proposed** | **100/100** | **0/25** | **0** |

All 25 active prior holders remained active. All 100 expired prior holders were released and replaced. Non-atomic recovery is not implemented and is not invented as a comparison result.

### Request latency (median / p95 milliseconds)

| Concurrent requests | Non-atomic baseline | Protected baseline | Original proposed | Corrected proposed |
|---|---:|---:|---:|---:|
| 2 | 130.700 / 233.215 | 102.300 / 155.295 | 1055.950 / 1109.310 | **74.750 / 113.765** |
| 5 | 176.050 / 273.810 | 131.400 / 201.695 | 3049.150 / 4103.485 | **103.850 / 141.570** |
| 10 | 236.800 / 398.370 | 163.300 / 258.210 | 5096.750 / 9142.620 | **131.100 / 200.730** |

Across all 850 corrected contention requests, median is **111.500 ms**, p95 **190.465 ms**. Historical latencies include their error responses. Historical baseline/proposed rows are reused unchanged from `e2-20261105-v33-actual-01`, not rerun or pooled. Schema/lifecycle/audit differences, warmup/host load and one execution per scenario prevent a causal or significance claim about speed. The new run repeats focused checks before measurement, which also warms its disposable database.

Negative controls are separated correctly: three intentional audited P0001 failures (key/payload reuse and injected failure) appear in `all_failure_audits.json` with `benchmark_request=false`. They are not 40P01, are not benchmark requests, and are not silently removed from raw evidence. Unauthenticated/inactive and metadata rejection details remain in `regressions.json`. `database_errors.csv` is header-only because no measured benchmark request produced a database failure audit.

## Provenance, preservation and reproducibility

The experiment retains GEOLOCK-BM-v3.3, OSM-DIRECTED-v3.3, seed 20260915, all original scenario IDs/order, request barriers, original driver retry setting, road inputs, READ COMMITTED isolation and 360-minute leases. No frozen rows or timestamps were edited; the original driver's documented relative-age replay is reused. The same prior canonical-byte CRLF transport mirror matches all 15 declared CSV hashes; original LF source files remain unchanged.

Python 3.12.14, psycopg 3.3.6, PostgreSQL 17.11. Exact environment, Git HEAD/dirty-state source hashes and input hashes are in the manifest and existing environment/native checksum files. Actual protected PostgreSQL functions/constraints execute; Auth/Storage/cron and frozen-road eligibility remain documented local adapters. This is not a physical-device, hosted Auth, live road graph or end-to-end production latency test. The older baseline schema remains a methodology limitation. No new supervisor approval, statistical significance or E4 result is inferred.

SHA256 verification found **all 471 previously sealed files unchanged**, including original experiment evidence and frozen inputs. Every executed full-run source still matches its manifest. The failed claim-only run and all partial/setup attempts remain retained. All six task-owned E2 clusters (five focused attempts and full run), original reproduction and final custody cluster are stopped; shutdown receipts and absence of active PID files were checked. No interrupted evidence was deleted.

Exact fresh-local-environment commands and prerequisites: `e2-shared-lock-review/REPRODUCE_LOCAL_E2.md`. Current run invocation:

```powershell
.venv-stage8/Scripts/python.exe experiments/e2_atomic_claiming/run_shared.py --output experiments/e2_atomic_claiming/results/e2-20261105-v33-shared-no-key-update-01
```

That ID is now occupied and must not be reused. Use the README's timestamped IDs. The controller starts a new loopback cluster, repeats focused checks and requires the custody pass before formal scenarios. It accepts no remote DSN and refuses output-directory overwrite. Read-only result analysis:

```powershell
.venv-stage8/Scripts/python.exe experiments/e2_atomic_claiming/summarize_corrected.py --run experiments/e2_atomic_claiming/results/e2-20261105-v33-shared-no-key-update-01
```

## Review-only migration, rollback and DEV prerequisites

The coordinated migration is locally validated and ready for **separate review/preflight**. It is outside deployable migrations, has no applied DEV ledger version and is not authorization to deploy. No shared DB backup, restore or deployment occurred.

Before deployment:

1. Obtain separate approval for read-only DEV preflight and verify intended project `rcgyuwiidqvrgbxswhqj`. Capture actual current claim/helper and all direct/indirect caller, FK/index/trigger, owner/ACL/SECURITY DEFINER/search-path metadata. Repeat caller discovery, including unqualified/dynamic references; compare both business and operational-trigger configurations. The local catalog cannot establish current DEV state.
2. Require the original claim/helper body hashes listed above and all candidate guards to match. Any prior partial patch, unrelated function/ACL-order/source/trigger drift or added caller requires review, not guard bypass. Select and confirm an unused forward version compatible with the existing manual deployment receipt/ledger workflow; do not rewrite old history.
3. Have the authorized database owner/operator capture exact function definitions, metadata, dependency schema and the approved current backup baseline. Verify backup completeness and perform/validate an isolated restore before deployment. Use the actual reviewed recovery tooling; no untested restore command is prescribed here.
4. Freeze/review the exact candidate and rollback hashes. Arrange a controlled code transition without concurrent schema changes or long-running claim statements. Apply only after separate deployment approval, with ON_ERROR_STOP and retained exact SQL/output/receipt. No Flutter or worker source rollout/restart is part of this correction.
5. Perform separately approved postchecks for metadata/source preservation and clean contention/idempotency/recovery behavior. Do not start destructive or bulk shared-data benchmarks.

Rollback is code-only and requires its own approval. The review script was exercised locally: it restored both original bodies, then the forward script reapplied both corrected bodies with exact source/privilege preservation. It fails on drift. Restoring original code reintroduces the original deadlock exposure. It must **not** undo committed claims, reset lease times, erase audits or restore an old whole database over legitimate new activity. A validated operator backup/recovery plan remains necessary; passing the local code rollback is not a verified DEV restore procedure.

## Changed files and final artifacts

Added/updated local experiment files: `experiments/e2_atomic_claiming/reproduce_shared_original.py`, `run_shared.py`, `shared_regressions.py`, `shared_custody_tests.py`. The existing `summarize_corrected.py` was executed without changing historical inputs. No production SQL/source, original benchmark runner, Flutter or routing-worker file was edited.

Review package: this report and `docs/investigations/e2-shared-lock-review/`, containing forward/rollback SQL, two exact diffs, caller/source/trigger catalogs and graphs, expected body hashes, operational-trigger review, custody attempt/pass receipts, resumed inspection evidence, final verification, reproduction instructions and preserved earlier guarded-candidate versions. A final file/hash inventory is stored as `ARTIFACT_MANIFEST.json` in that directory.

Full new run outputs include raw cases/requests/committed states, exact applied SQL, source/input/environment manifest, 30-check regression evidence, failure audit separation, completion/shutdown receipts, `corrected_summary.json`, `comparison.csv`, `lease_comparison.csv` and presentation-ready `COMPARISON.md`. Focused attempt directories, the original reproduction and custody evidence directories retain their logs/schema/runtime evidence independently.

**Decision:** LOCAL PASS for the corrected E2 experiment and requested local safety validation. The reproduced listing FK lock-upgrade cycle was absent in the corrected controlled case, measured contention and tested lifecycle races. Separate DEV preflight, verified backup/recovery and explicit deployment approval remain outstanding. Stop here; no DEV deployment is performed.
