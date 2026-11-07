# Claim-conflict UI and E2/E4 evidence review

5 November 2026. **Part A: IMPLEMENTED locally. Part B E2: CONFIRMED reproducible lock mechanism. Part B E4: CONFIRMED admission mismatch.** Existing benchmark readiness remains **PARTIAL** for both experiments. No backend SQL/function, routing algorithm, frozen input or existing result was changed. No DEV connection, migration deployment, hosted worker operation, APK installation or push was performed.

## A. Claim conflict: source findings and local UI changes

`supabase/migrations/20261031_claim_audit_and_failure_capture.sql`, `public.claim_listing(uuid,uuid)`, sets `CLAIM_CONFLICT` when the locked listing exists and `listing_status <> 'AVAILABLE'`. That includes CLAIMED, CLOSED and CANCELLED, and a replay returns the previous request's terminal outcome. It does **not** establish current ownership by another NGO: a listing may have been closed/cancelled, the current caller may own it through another request, or its state may have changed after the recorded rejection. Expiry, missing listing, road eligibility and source readiness have separate reason codes, generally mapped to CONFLICT or INELIGIBLE. No current response field confirms another NGO's ownership. Protected discovery's absence also does not identify an owner.

Before this change, `_NgoListingDetailsPageState` in `frontend/geolock_hub_app/lib/donation_pages.dart` cached a `late final` successful `_details` Future. `_load` derived Available/PUBLISHED from the original discovery row. After a complete rejected response, `_claim` removed the terminal UUID, cleared only `_claimBusy` and showed a snackbar using `roadOutcomeMessage`; the successful Future and old row still enabled the button. Only successful claims invoked `onClaimConfirmed`. Discovery and home preview navigation did not refresh on ordinary return. This explains the simultaneous Available/Eligible display after a definite rejection without implying a database ownership failure.

Implemented:

- Initial details and every explicit availability refresh re-read `discover_eligible_listing_cards`, match the exact listing, then call the existing protected `get_eligible_listing_constituents` and optional image readers. No raw table query, foreign claimant lookup or client eligibility calculation is added.
- A complete definite rejection immediately invalidates displayed eligibility, disables Claim, hides stale authorized detail/image content and starts a read-only recheck. It does not resubmit the claim.
- Unknown conflict explanation: **Donation availability changed** — “This donation is no longer available to claim. Please refresh the donation list.” Progress becomes Checking availability/Unavailable to claim and the availability section follows the same state.
- Failed verification: **Unable to verify availability**, with Claim disabled and Refresh availability / Back to Donations available. Previously successful data cannot enable actions during a pending or failed read.
- Trusted rediscovery plus successful protected detail read can re-enable Claim; there is no permanent local blacklist. The current refreshed row supplies routing readiness. Explicit refresh also rechecks routing capability.
- Both discovery and NGO home previews refresh after detail navigation returns, including rejected claims, app-bar back and Back to Donations. Success still refreshes the underlying views and opens My Claims.
- Technical rejection codes/request IDs remain in debug logging and database receipts; transport diagnostics are sanitized. Ordinary user messages no longer expose the raw conflict code, request UUID or exception detail.

The requested “Donation no longer available / already claimed by another NGO” attribution is intentionally **not displayed for current generic responses**: no existing trusted reader confirms it. Using it for every CLAIM_CONFLICT would be incorrect. A future backend contract that explicitly confirms that explanation can support that message, but adding such a contract is outside this UI-only authorization.

### Request safety and tests

`claim_request.dart` is unchanged. The UUID remains scoped to NGO/listing, persisted and read back before sending. Complete SUCCESS (with claim ID) or CONFLICT/INELIGIBLE (with reason) clears it best-effort, as before. There is no automatic retry. A transport exception, malformed/unconfirmed response or trusted rollback receipt retains the saved UUID for a deliberate retry. A rollback-confirmed ERROR with an audit receipt is different from network uncertainty and from a definite conflict; it does not turn into an availability rejection. Busy state is set before awaiting preferences and prevents rapid taps from sending parallel attempts. An identity change before send still prevents submission. All authorization/lease/ownership transitions remain in PostgreSQL.

**78 focused Flutter tests passed**, including **13 new widget tests** and 65 existing tests covering request persistence, claim history/cards/lease behavior, road messages and dashboard navigation. The new cases cover success, simulated competing NGO outcomes, pending-conflict stale state, disabled/unavailable state, trusted reavailability/new deliberate UUID, failed verification, timeout/same UUID, rapid taps, rollback receipts, initial absence/failure, back navigation and actual discovery reloading. The competing-UI test supplies trusted RPC outcomes; real atomic ownership evidence comes from PostgreSQL, not a widget simulation.

Static analysis of both changed library files and the new test: **No issues found**. Logs: `e2-e4-review-evidence/flutter-tests.log`, `flutter-analysis.log`.

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub\frontend\geolock_hub_app'
flutter test --no-pub test/claim_conflict_ui_test.dart test/claim_request_test.dart test/claim_history_ui_test.dart test/claim_card_test.dart test/road_routing_test.dart test/dashboard_test.dart
flutter analyze --no-pub lib/donation_pages.dart lib/dashboard_pages.dart test/claim_conflict_ui_test.dart
```

No two-device APK retest was performed; installation remains separately authorized work. The UI cannot resolve the backend's deadlocks or guarantee availability between refresh and a claim; the claim RPC remains authoritative.

## B. E2 deadlock investigation

Original run: `experiments/e2_atomic_claiming/results/e2-20261105-v33-actual-01/`. `database_errors.csv` contains **691 rows, all SQLSTATE 40P01, all rollback_confirmed=true**. No other SQLSTATE is recorded. This does not classify every possible unobserved production error.

| Workers | Contention trials | Success | Clean conflict | Deadlock ERROR | Median / p95 request ms |
|---|---:|---:|---:|---:|---:|
| 2 | 50 | 50 | 2 | 48 | 1055.950 / 1109.310 |
| 5 | 50 | 50 | 2 | 198 | 3049.150 / 4103.485 |
| 10 | 50 | 50 | 5 | 445 | 5096.750 / 9142.620 |

All 150 contention trials committed exactly one claim and zero duplicate ownership. Expired leases: 100/100 recovered/reclaimed, no lease-case errors. Active leases: 0/25 incorrectly released. These establish ownership safety and tested recovery, while the 691 errors establish a separate failure in request robustness. Latency includes those errors.

### Actual lock order and reproducible cause

The claim body executed in the benchmark and diagnostic has normalized source MD5 `2c1f60c876797c61b44b3cb43591bab8`. Source is retained in `e2-e4-review-evidence/claim-source.json`. Relevant sequence:

1. Authenticate, lock the active NGO profile `FOR SHARE`; acquire transaction advisory lock on actor + request UUID.
2. Inside the claim exception subtransaction, insert the request row. Immediate FK `claim_requests_listing_id_fkey` checks `listings(listing_id)`, taking a key-share row lock on the parent. The NGO FK also checks its profile. Different NGOs/request UUIDs are not serialized by the per-request advisory lock.
3. Lock that request `FOR UPDATE`, check digest/replay, read configuration, then lock the **same listing `FOR UPDATE`**.
4. Only after that lock succeeds: check listing/time/road/source readiness; `geolock_lock_listing_donations` locks the source donation set in order; insert claim, then lease; update listing status/version; insert pickup task; transition donation state and append donation audit; complete request and append claim-attempt audit.
5. An exception rolls back the inner claim subtransaction; the outer path writes an immutable failure receipt with SQLSTATE and returns a rollback-confirmed ERROR. Audit-persistence failure itself propagates as an unconfirmed error.

Two transactions can both finish step 2, each holding key-share on the same listing. Each then needs a listing lock incompatible with the other's key-share. PostgreSQL detects the cycle and selects a deadlock victim. The error is not an intended claim conflict, and its rollback is not duplicate ownership.

**New isolated evidence:** `experiments/diagnose_claim_deadlock.py` built a fresh full-schema loopback PostgreSQL 17 cluster, verified the exact current claim source hash, and reproduced that statement-boundary interleaving with the real foreign keys. Both requests were pre-inserted in their own transactions before invoking the unchanged RPC. `wait-graph.json` captured mutual blocking: PID 16148 waited on 23500 and PID 23500 waited on 16148, both executing `claim_listing`. `waiting-locks.json` captures transaction waits. The RPC results were one SUCCESS and one rollback-confirmed ERROR; the failure receipt records 40P01 and the database contains exactly one ACTIVE claim. The function hash was unchanged afterward.

This deliberate pre-insert schedule demonstrates the mechanism; the pre-inserts occur outside the function's inner savepoint to control timing. It is **not** a new formal benchmark or a measurement of natural incidence. The original benchmark saved SQLSTATE, not every deadlock's lock graph, so it cannot prove that all 691 historic failures had an identical graph. The reproduced cycle, unchanged source and original driver evidence establish a confirmed cause that explains the observed class of failures without asserting exhaustive diagnosis of every past event.

`foreign-keys.json` and `triggers.json` retain the actual local catalog definitions, including internal `RI_FKey_check_ins` triggers. Listing transition guards, donation validation/photo-at-commit, audit provenance and append-only guards remain installed. Audit inserts reference actors, lease inserts reference claims, and the ordered source-donation helper introduces later locks; those may matter in other inter-operation lock graphs. They are **not necessary for this reproduced early cycle**, which occurs before claim/lease/donation-transition/audit writes. No trigger was disabled or replaced.

The same pre-insert FK arrangement followed by standalone **FOR NO KEY UPDATE** locks completed for both transactions without deadlock. This is a primitive lock-compatibility control, not an altered GeoLock function or an executed fixed-product benchmark. All diagnostic connections/servers were stopped; `cluster-stop.json` confirms shutdown and zero remote connections. Two preliminary diagnostic setup attempts failed on missing local login/fixture actor assumptions and were stopped; they are not test passes. Retained runtimes are `.tmp/e2-deadlock-review-20261105-01`, `-02`, `-03`.

### Baseline, retry behavior and recommendation

The teammate's `baseline implementation/postgresql/README.md`, “The claim fix in 01”, explicitly documents this FK/FOR UPDATE issue. Its supplied V3 schema uses `FOR NO KEY UPDATE`; the protected driver checks this before execution. This still serializes competing status-changing claim operations while remaining compatible with FK key-share checks. It is an existing baseline correction, not a correction secretly applied to GeoLock. Baseline results: zero duplicates, 150/150 exactly-one-winner trials, 700 clean conflicts, zero database errors. Non-atomic baseline: duplicates in 150/150 trials with 603 extra committed claims.

The shared driver opens separate authenticated connections, uses a barrier, then calls the SQL once per actor/request. This increases overlap, deliberately exercising contention. It does not inject pg_sleep into the actual proposed claim or disable its constraints. Transient psycopg deadlock/serialization **exceptions** receive one same-UUID retry. Actual GeoLock catches 40P01 through `EXCEPTION WHEN OTHERS`, records it and returns JSON ERROR; therefore this is a normal SQL result to the driver and that exception retry does not run. There is no special 40P01 retry in the function. Flutter similarly recognizes the rollback receipt and supports a manual same-UUID retry; transport timeouts preserve the request without asserting rollback.

This cycle can occur with real separate NGO requests whenever those statements overlap. The benchmark's 691/850 contention error rate should not be presented as a predicted phone/emulator error rate, because request scheduling, schema/runtime and server load differ. Conversely, one clean device conflict does not disprove a reproducible SQL lock hazard.

**Smallest recommended backend correction, not implemented:** change only the listing acquisition in current `claim_listing` from `FOR UPDATE` to `FOR NO KEY UPDATE`, after confirming listing key columns are not changed in the claim path and checking the current deployed fingerprint. Preserve request advisory locks, request digest/replay, partial unique ownership index, FK constraints, source locks, leases, transition/audit guards and rollback receipts. Review lock order with cancellation/recovery/start/collection as part of the separately approved change. Validate on fresh disposable fixtures at 2/5/10 requests, same/different UUIDs, expiry/recovery and concurrent lifecycle operations before any deployment. Generic automatic retry is not a substitute for removing this lock cycle; a bounded same-UUID transient retry policy would be separate reviewed work. Do not change the baseline or overwrite the old measurements. Future fixed-product results must use a new run/version.

## C. E4 admission mismatch

The exact rule is `backend/routing/contract.py::_admission`: a finite `listing_expires_at <= horizon_end` yields `LISTING_EXPIRES_BEFORE_HORIZON`. SQL parity is in `docs/stage8/stage-a/forward-migrations/20261102_routing_publication.sql::routing_private.admissible`, requiring listing expiry strictly **after cutoff + horizon + dispatch margin**. Lease sufficiency is a separate guard. The benchmark bridge uses 240-minute horizon, zero margin and original cutoff (including seconds). Its `backend/routing/benchmark_v32/adapter.py::Adapter.convert` and saved v3.3 worker inputs preserve original listing expiry.

The exclusion is admission policy, before optimization. It does not mean that CP-SAT failed to find a route. A task could potentially be visited before its expiry while still expiring before a conservative whole-route horizon. Claim-time unexpired ownership is also distinct from permission to include it in a full routing horizon. Removing the check would weaken the currently approved operational contract, even if a less conservative policy could theoretically be designed with per-stop expiry validation.

### Exact excluded tasks

All timestamps below are **+08:00**. Scenario suffixes refer to `SCN-ROUTE_PLANNING-`. Each reason is `LISTING_EXPIRES_BEFORE_HORIZON`; full cutoff, listing ID, timestamps and shortfall minutes are in `e2-e4-review-evidence/e4-excluded-task-times.csv`, derived read-only from the saved worker input for that scenario.

| Scenario | Task | Listing expiry | Horizon end |
|---|---|---|---|
| 0003 | TASK-LST000085 | 2025-01-31 17:00:00 | 2025-01-31 18:00:05 |
| 0004 | TASK-LST000418 | 2025-06-22 17:00:00 | 2025-06-22 17:15:05 |
| 0016 | TASK-LST001080 | 2026-03-20 17:00:00 | 2026-03-20 18:00:05 |
| 0016 | TASK-LST001081 | 2026-03-20 17:00:00 | 2026-03-20 18:00:05 |
| 0023 | TASK-LST001169 | 2026-04-28 18:00:00 | 2026-04-28 18:00:05 |
| 0023 | TASK-LST001170 | 2026-04-28 18:00:00 | 2026-04-28 18:00:05 |
| 0029 | TASK-LST000887 | 2025-12-28 17:00:00 | 2025-12-28 17:15:05 |
| 0031 | TASK-LST001039 | 2026-02-25 17:00:00 | 2026-02-25 17:00:05 |
| 0031 | TASK-LST001041 | 2026-02-25 17:00:00 | 2026-02-25 17:00:05 |
| 0052 | TASK-LST000679 | 2025-09-21 18:00:00 | 2025-09-21 18:00:05 |
| 0058 | TASK-LST000899 | 2026-01-03 17:00:00 | 2026-01-03 17:45:05 |
| 0060 | TASK-LST000505 | 2025-07-17 17:00:00 | 2025-07-17 17:15:05 |
| 0069 | TASK-LST001153 | 2026-04-25 17:00:00 | 2026-04-25 17:00:05 |
| 0079 | TASK-LST000180 | 2025-03-05 17:00:00 | 2025-03-05 18:00:05 |
| 0079 | TASK-LST000183 | 2025-03-05 18:00:00 | 2025-03-05 18:00:05 |
| 0097 | TASK-LST000111 | 2025-02-14 17:00:00 | 2025-02-14 17:15:05 |
| 0097 | TASK-LST000113 | 2025-02-14 17:00:00 | 2025-02-14 17:15:05 |

Several miss by only five seconds. Rounding away cutoff seconds to include them would change the protocol; it was not done.

### Requirements and scientific interpretation

Reviewed originals: `C:\Users\User\Downloads\RSW_LimQianYu_LowSusan_FullText.docx`, §§3.8.2, 3.8.3/Table 3.9, 3.8.5 and Appendix Table A.4; `C:\Users\User\Downloads\第6组_Lim Qian Yu与Low Susan_GeoLock Hub.pdf`, Stage 8 pp14–15 and E4 p19. The report requires valid confirmed tasks and paired common inputs; the supervisor specifies fixed matrices, windows, services, depot/endpoints, capacities and route-duration behavior, with independent validation. Neither explicitly mandates this exact full-horizon listing-expiry predicate or says to remove it. Its explicit product design provenance is `docs/stage8/2026-10-24-phase-a-architecture.md`, admission rules (lines 119–120), which require listing/lease survival beyond the conservative horizon and reject equality. This distinction separates operational design from a thesis/supervisor necessity claim.

The original dataset/method admits **500 tasks across 100 scenarios**: Nearest-Next and FCFS test expiry at the original claim/snapshot stage, not survival of every listing through the full routing horizon. Both original methods reproduced all published non-runtime scenario records. Thus the 17 exclusions are a real protocol mismatch, not corrupt CSVs or an optimizer approximation.

The **483-task common-admission lane is scientifically usable as a labelled supplemental comparison**: all three algorithms receive identical admitted tasks, depot, fleet, matrix, horizon windows, service and limits. It cannot establish performance on the unchanged original 500-task population. Selection can change difficulty and generalizability. Retain both the original-baseline lane and all exclusion evidence. A formal thesis claim based on the changed admitted population needs an explicit protocol amendment/supervisor agreement and appropriate new frozen protocol/version; no fresh approval is inferred here.

Under different legitimate operational conditions, an excluded task could pass if planning begins sufficiently earlier, a separately valid route horizon/margin is shorter while still feasible, or the donor makes a legitimate supported availability change before a new snapshot. Ownership, lease, source readiness, remaining windows and all other guards must also pass. The old saved snapshot does not change retrospectively, and editing these frozen timestamps or merely hiding the exclusion is not legitimate. A new claim alone does not extend donor/listing expiry.

## D. Supervisor-ready explanation with existing measurements

**E2:** “This experiment tests whether concurrent NGOs can commit more than one active owner and whether expired ownership can safely recover. The non-atomic baseline duplicated claims in 150/150 trials. Both protected methods maintained one owner in all 150 trials. GeoLock additionally recovered all 100 expired cases and incorrectly released none of the 25 active cases. However, 691 competing requests returned audited deadlock errors rather than clean conflicts. We reproduced a listing FK lock-upgrade cycle without changing the function. Ownership safety succeeded, while request robustness needs correction, so readiness remains PARTIAL.”

Source: final E2 `comparison.csv`, `lease_comparison.csv`, `database_errors.csv`, `proposed_committed_states.json`; new diagnostic evidence supplements rather than replaces these measurements. Protected baseline: 150 successes/700 clean conflicts/zero errors. GeoLock: 150 successes/9 clean conflicts/691 errors from 850 contention requests.

**E4:** “FCFS attempts pickups by creation order; Nearest-Next greedily chooses a nearby feasible next pickup. Both use the fixed fleet and supplied constraints. Actual GeoLock uses its current deterministic CP-SAT implementation to maximize served task count, then minimize directed road distance. Every saved route is checked independently for valid task/stop use, capacity, timing, duration and matrix constraints. Current admission requires listings to survive the whole planning horizon, excluding 17 tasks admitted by the original baselines. We retain the original 500-task baseline reproduction and report a separate equal-input 483-task lane. The proposed method serves 439 tasks versus 437 for each baseline, with 100/100 feasible scenarios per method and zero recorded capacity/window/duration violations. Distance must be compared on matched served tasks; this remains a supplemental result, so formal readiness is PARTIAL.”

| Supplemental method | Served/admitted | Weighted coverage | Total road km (descriptive) | Travel min | Median / p95 planner ms |
|---|---:|---:|---:|---:|---:|
| Nearest-Next | 437/483 | 90.476% | 3732.22677 | 4445.80953 | 0.2631 / 0.6956 |
| FCFS | 437/483 | 90.476% | 4429.11178 | 5152.83116 | 0.2594 / 0.6790 |
| GeoLock | 439/483 | 90.890% | 3380.07299 | 4070.70276 | 107.1825 / 241.3605 |

On **identical served-task sets**, GeoLock's aggregate distance is 3140.2774 vs Nearest-Next 3457.59928 km (91 pairs, **9.178%** lower), and 2917.75813 vs FCFS 3776.64111 km (79 pairs, **22.742%** lower). On equal counts, there are 98 qualifying pairs per comparison (9.909%/24.006% lower); equal count alone does not guarantee equal task identity. Two coverage-different scenarios per comparison are excluded. Original full-input baselines each served 453/500, with 3849.889 km Nearest-Next and 4575.154 km FCFS. Do not compare either original total directly with the 483-task GeoLock total as distance savings.

Source: `experiments/e4_post_claim_routing/results/e4-20261105-v33-actual-02/comparison.csv`, `paired_distance_summary.csv`, `original_baseline_summary.csv`, `verification.json` and raw plans. The original horizon-window benchmark does not establish separate donor-window or live dispatch feasibility; no significance, causal runtime improvement or new supervisor approval is claimed. CP-SAT is the actual implementation, despite legacy RoutingModel metadata in historical schema/method descriptions.

## E. Deliverables, preservation and next steps

Modified UI files:

1. `frontend/geolock_hub_app/lib/donation_pages.dart` — trusted refresh, consistent unavailable state, claim gating, sanitized outcomes, injection seams and discovery return refresh.
2. `frontend/geolock_hub_app/lib/dashboard_pages.dart` — NGO home preview refresh on return.

Added files:

3. `frontend/geolock_hub_app/test/claim_conflict_ui_test.dart` — 13 widget regressions.
4. `experiments/diagnose_claim_deadlock.py` — isolated real-SQL diagnostic, not a backend change.
5. This report.
6. `docs/investigations/e2-e4-review-evidence/`: `claim-source.json`, `foreign-keys.json`, `triggers.json`, `wait-graph.json`, `waiting-locks.json`, `diagnostic.json`, `cluster-stop.json`, `e4-excluded-task-times.csv`, `original-evidence-integrity.json`, `flutter-tests.log`, `flutter-analysis.log`, `review-validation.json`.

The prior reproducibility SHA256 inventory was verified without regenerating summaries or rerunning formal experiments. Existing E2/E4 result directories and frozen inputs remain unchanged. Private diagnostic setup/runtime files and logs are retained under `.tmp`; they do not enter the old experiment sample counts. SQL application was confined to a new disposable local fixture; no migration file was edited or deployed. Existing unrelated dirty work was retained.

No further approval is needed to review these deliverables. Backend correction, any DEV deployment, protocol changes/formal result replacement, APK installation and hosted worker operations require separate authorization as requested. Recommended next step is approval for a narrowly scoped local backend lock correction and regression validation, followed separately by supervisor agreement on the E4 formal admission protocol. This task stops before either change.
