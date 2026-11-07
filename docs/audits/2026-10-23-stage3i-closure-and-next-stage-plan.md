# Stage 3I closure and next-stage plan

Stage 3I Phase 2 is **PASS for supervised automatic safe recovery of one genuinely
expired direct-pickup claim**. Permanent unattended recovery is **NOT YET APPROVED**.
Job 3 stays inactive. Jobs 1/2 remain active. No activation, cleanup, recovery call,
fixture change, migration or application change is authorized or performed here.

The detailed [closure results](../../supabase/tests/review-only/stage3i/closure/RESULTS.md),
[SELECT-only evidence](../../supabase/tests/review-only/stage3i/closure/evidence.json)
and saved queries contain exact IDs, snapshots, audits and scheduler history.

## Closure evidence and operational qualification

The final SELECT verification at 2026-10-23 13:18:01.544040 UTC returned every
acceptance flag true. Claim/lease RELEASED with EXPIRED_SAFE_RELEASE; task STALE;
donation/listing AVAILABLE; version 3/generation 2; exact two new audit events;
real generation-2 refresh COMPLETED; outside 13-table snapshot unchanged.
Phase 1 comparison preserves all other target fields, original four audit rows,
item/photo metadata, lease timestamps and generation-1 refresh.

Job 3 has 17 retained succeeded runs: 12 prior canary runs plus five at
12:56/12:57/12:58/12:59/13:00 UTC. Recovery occurred within the first run, 5180,
at 12:56:00.467156 UTC. Four later executions caused no duplicate observed effects.
Immediate pause after the first observed outcome is not independently demonstrated;
the actual activation/observation/pause receipts were not supplied, so five-minute
compliance is not certified from cron history. The functional result is PASS;
this is not an operational pause-control acceptance result.

No unfinished run, active client transaction, relevant coordination lock or
remaining nonterminal claim was returned at the 13:12:37 UTC health snapshot.
Jobs 1/2 each have 60 succeeded runs in the preceding hour. Recovery body MD5
5ff6d8719db9681aae6f444b89dfbaee, exact security metadata and 85 other public-function
definition/owner/ACL aggregate MD5 6991083a881075cdf0e75d0c266396f0 are unchanged.

## Requirements actually reviewed

Read the local files below without editing Word/PDF originals:

| Source | Identity and relevant requirement |
|---|---|
| Downloads/第6组_Lim Qian Yu与Low Susan_GeoLock Hub.pdf | 26-page FYP supervision/review report; SHA-256 7b0d2b3a86239f85cbb1f76bd03b08c295cfa9132a04bd8a600c762258c9bb61. Pages 6-8, 20 and 26 require atomic claims, 2/10/50-client evidence, leases, recovery and stale-holder rejection; pages 11-18 and 24-25 require constrained ranking, aggregation, independently validated routing and reproducible comparisons. The underlying thesis ZIP referenced by that PDF was not reviewed. |
| Downloads/GeoLock_Hub_Coordination_Authority_Contract_Revised_v2.docx | SHA-256 7db53593fae3aafcd437235432776ad2a70e6eaee13f8227c42c0fc1c65ffa28. Invariants 1-13 separate database authority, eligibility, custody, uniqueness and idempotency. Sections 7-10 require DB-time 360-minute leases, renewal disabled, safe release/reconciliation, stale-holder rejection, atomic audits and failure acceptance. |
| Downloads/Latest GeoLock_Hub_Coordination_Authority_Contract.docx | SHA-256 4f73eb18bee9bbdef46df1ab3b11179f574fef29c869e9df7119dd02d9c88351. Despite its filename, this contains older VALIDATED/DELIVERED state examples. Do not treat its name as evidence that its enum definitions supersede deployed policy. |
| Downloads/GeoLock_Hub_Stages_1_to_8_Checklist (1).docx | SHA-256 1f84b1439693e62a4b9857ce1c8fa3e3c93fcc5cf4d96dcb9de32c2bd348d02c. Content is explicitly a 19 October status snapshot, not current runtime sign-off. FYP stages are 1 lifecycle, 2 atomic claims, 3 leases, 4 geographic eligibility, 5 deterministic hub baselines, 6 constrained AI, 7 aggregation and 8 routing/validation. |
| README.md, MF.md, frontend README and October audits | Useful architecture/history; several status paragraphs predate the current application and deployments. They must not be read as current proof that a worker, Flutter UI, road eligibility or profile editing is missing. |

The explicit approved lifecycle migration takes precedence over older state names.
Current direct donations use AVAILABLE -> CLAIMED -> PICKUP_IN_PROGRESS -> COLLECTED;
safe release restores AVAILABLE. Hub safe release restores member donations to
BATCHED, while its listing becomes AVAILABLE. COLLECTED is terminal. SUBMITTED
remains the hub-selection state. VALIDATED/DELIVERED are not donation states.
Expiry is server-derived evidence until protected recovery changes claim/lease
state; do not invent a persisted LEASE_EXPIRED donation enum or re-add creation dates.

The report/contract should be aligned to this approved implementation before
supervisor sign-off. Do not revert working SQL to fit an older document. Automatic
road-node validation establishes technical routing eligibility, not NGO identity
verification. Original Word/PDF sources remain untouched in this closure.

## Current implementation inventory and verification limits

| Area | Existing implementation/evidence | Remaining work; avoid duplication |
|---|---|---|
| Creation/photos/location | Flutter create flow, protected seven-argument creation dependency and photo wrapper; Phase 1 created the real 20 kg photo-backed fixture through the application | Boundary/authorization/failure matrix remains separate evidence; do not rebuild creation or reintroduce availability inputs |
| Persisted lifecycle and audits | Deployed lifecycle helpers, cancellation/audit fixes and actual safe restoration verified here | Broader transitions, rejected-attempt durability and unknown-commit behavior still need appropriate evidence |
| NGO expiry-aware UI | claim_card.dart, claim_cards_controller.dart; MyClaimsPage, NgoHomePage and claim details call v2, use server flags, disable expired/stale actions and refresh safely | Source is implemented and prior manual testing was reported; do not reimplement tabs/classifier/timers. No fresh build/screenshot proof is claimed for this closure |
| Auth/profile/onboarding | Auth role routing; main.dart NGO onboarding/refresh gate; RoleProfilePage update_my_profile and set_ngo_operating_location; hub register/update UI exists | Test current backend authority and active-task restrictions before claiming full acceptance; do not infer these features are absent from stale README prose |
| Hub operations | Reservation/receipt/inventory/batch screens and protected RPC integrations exist | Real whole-batch/custody acceptance remains outside this single-direct-fixture proof; preserve teammate interfaces |
| Atomic claims | Current DEV-allowlisted claim_concurrency_test.py, fault-injection runner, isolated captured-RPC race tests; historical experiments include 2/10/50-client result CSVs | Validate project/version/fixture/auth provenance before accepting old results for current migrations. Current guarded runner has COUNTS=(2,10). Reuse it; add 50 only if required current-version evidence is not already available |
| Geographic eligibility | Trusted directed-road functionality, async NGO/listing workers and genuine fixture eligibility already exist | FYP Stage 4 needs inside/exact/outside 500 m and 20 km, directed asymmetry/disconnection, fail-closed and stale-generation evidence; this is validation work, not permission to rewrite routing |
| Hub/routing benchmarks | nearest/random hub, non-atomic/protected-without-recovery, direct pickup, nearest-next and FCFS source/results exist | Inspect manifests and reuse frozen cases/results. In-memory simulations are not live PostgreSQL transaction evidence; do not rebuild existing baselines or claim AI value without comparison |
| Donor timeline | Recorded audit mapping plus generated current/pending rows exists in status_timeline.dart and donation_pages.dart | Legacy READY_FOR_PICKUP and DONATION_STATUS_BACKFILL remain visible, potentially repeating the current state. A small future Flutter-only display refinement is justified; retain raw history. No change made now |

Historical experiment files reviewed include experiments/geofence/g16_results/g16_summary.csv
and geofenced_concurrency_summary.csv. They are existing evidence to reconcile,
not permission to execute legacy scripts or assume their project/schema matches
current DEV. No experiment runner or Flutter workflow was executed by this task.
The baseline README explicitly describes the coordination baselines as simulations.

## Mandatory gates before unattended recovery

| Gate | Required acceptance evidence |
|---|---|
| Operational ownership | Named primary/backup, coverage/response expectation, approved pause/escalation access and change-control ownership. Do not rely on one person keeping SQL Editor open indefinitely |
| Durable monitoring and alerts | Persist run failures/missed ticks, oldest overdue age, repeated candidate failures/no progress, nonterminal/reconciliation backlog, unexpected schedule/source/ACL drift, lifecycle/audit mismatch, and eligibility job failures/latency. Monitoring must run independently of the recovery worker |
| Alert policy and drill | Agree thresholds and delivery/dedup/escalation rules; test missed run, SQL error, stuck work and notification failure. Suggested starting policies are alert on first worker error and investigate repeated no-progress; exact thresholds are not approved by this document |
| Structured result evidence | Preserve jobid/runid, candidate/claim/lease IDs, actual processed/outcome counts, duration, failure SQLSTATE/reason and source/config fingerprint. pg_cron message "1 row" is insufficient. Failed transactions cannot durably retain their own rolled-back business audit; design a trusted out-of-transaction failure record or external incident journal |
| Bounded failure handling | Preserve 5s/50s timeouts and current limit 1 until workload evidence supports change. Existing SQL errors roll back the invocation. With larger batches one error can roll back other candidates. Do not add catch-and-continue, silently skip bad claims or expand privileges without a separately reviewed concrete design |
| Starvation handling | Track whether the same oldest eligible claim repeatedly fails. SKIP LOCKED only skips claim-row contention; later locks can still time out. Alert and use an approved investigation/reconciliation path instead of deleting evidence or increasing batch size |
| Real branch/concurrency coverage | Representative hub batch atomicity/large-batch timing, route/pickup/uncertain-custody fences, unresolved cases, expired listing crossing, recovery vs pickup/cancel, stale holder and reassignment. Existing isolated evidence helps but is not all live integration proof |
| Progress under normal writes | The pilot's quiescent maintenance window does not prove continuous recovery alongside ordinary application writes. Demonstrate consistent authority plus bounded waits/deadlocks under realistic concurrency before removing that test restriction |
| Stop, restart and receipt evidence | Confirm pause prevents new scheduling, inspect in-flight work, preserve actual activation/first-outcome/pause timestamps, and define safe restart without restoring old ACTIVE claims. Pausing is not cancellation or rollback of a committed release |
| Security and retention | Keep recovery trusted-only, EXECUTE/search_path/source baselines intact, use supported cron API under managed permissions, retain audits/logs with a privacy policy, and never put service credentials in Flutter or reports |

These are approval gates, not implementations delivered here. Existing SELECT
monitoring is a starting point, not an installed alerting service. Any alert
integration, failure journal, worker change or future scheduling requires its
own reviewed implementation and authorization. This plan does not start another
activation preparation cycle. Permanent unattended recovery remains NOT YET APPROVED.

## Recommended next stage

**Stage 3J: Current-version Coordination Authority Acceptance and Evidence.**
Use the existing approved backend and Flutter workflows to close remaining FYP
Stage 2/3 proof gaps, while preparing the operational monitoring acceptance plan.
This is a planning recommendation; no stateful execution is authorized here.

1. Freeze a small requirement/evidence matrix linking contract invariants to the
   actual migrations, RPC signatures, function fingerprints, app source/build,
   fixture IDs and test results. Correct stale status wording without rewriting
   deployed SQL or manufacturing missing evidence.
2. Reuse existing isolated tests and the allowlisted DEV concurrency harness.
   Prepare focused acceptance for released old-holder Start/Complete rejection,
   same-request replay without renewed ownership, current eligible 2/10-client
   contention, rollback and uncertain outcomes. Reconcile old 50-client evidence;
   extend the guarded suite only for the unproven gap. Later DEV mutation tests
   need separate approval and dedicated approved fixtures; preserve the Stage 3I
   fixture as evidence, do not reuse or alter it now.
3. Confirm server/UI consistency through read-only refresh: Released in History,
   no active count/pickup authority, correct donor availability. Record app build
   and screenshots for supervisor evidence. A disabled button alone is not proof
   of backend stale-holder rejection.
4. Design durable operator monitoring/alerting and a failure-response drill with
   concrete owners and measurable acceptance criteria. Implement only after its
   scope/permissions are reviewed. Keep job 3 paused; completing this plan does
   not require continuous scheduling or another manual recovery.
5. Then advance the original FYP Stage 4 acceptance with the teammate: deterministic
   500 m/20 km directed-road and cache consistency cases. Preserve their road graph,
   recommendation, aggregation and routing algorithms. Feed accepted results into
   existing Stage 5-8 baselines/independent validators and Chapter 5 comparisons.

The donor timeline cleanup is a bounded follow-up presentation task, not a reason
to delay authority acceptance or rebuild the NGO claims UI. A standalone donor
map, lease renewal, new donation enums, AI ownership decisions and a new routing
implementation are not justified by this closure. AI remains advisory over the
deterministically feasible set; report incremental value only after evaluation.
