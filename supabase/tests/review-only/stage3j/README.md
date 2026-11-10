# Stage 3J coordination authority evidence review

Minimum preparation follow-up: [two-actor acceptance package](two_actor/README.md)
now fixes and isolate-tests the delayed harness. It reuses existing RPCs and
requires two sessions, not ten; no live execution occurred. The initial review
below and its frozen source hashes preserve the pre-fix findings. Read the
follow-up results for the corrected harness and current execution prerequisites.

Review date: 23 October 2026. **CONDITIONAL GO for focused acceptance preparation;
current-version coordination acceptance is not yet complete.** No new production
SQL defect was established by this review. There are specific evidence,
authentication-fixture and test-harness gaps to close before live acceptance.

Stage 3I remains **PASS for supervised automatic direct-claim recovery**.
Permanent unattended recovery remains **NOT APPROVED**. Job 3 remains inactive.
This review does not prepare or authorize another activation cycle.

## Deliverables and evidence standard

- [Requirements-to-test matrix](EVIDENCE_MATRIX.md): PASS, FAIL, MISSING and OUTDATED,
  explicitly qualified by source, isolated execution or real DEV execution.
- [Shortest acceptance plan](ACCEPTANCE_PLAN.md): reuse, prerequisites and exact
  missing scenarios; no permission to execute state-changing tests.
- [Geographic handoff](GEOGRAPHIC_HANDOFF.md): proposed shared boundary cases for
  the teammate to review; no message sent and no algorithm change requested.
- [Live evidence](live_evidence.json) and [function catalog](function_catalog.json):
  sanitized SELECT-only snapshots, deployed definitions/security and constraints.
- [Checksums](SHA256SUMS.txt): package identity, not a timed execution approval.
- [Input hashes](SOURCE_SHA256.json): preserved SQL, tests and benchmark provenance.

PASS applies only to the described evidence scope. A source check, UI gate or
unique index is not a substitute for authenticated concurrent RPC execution.
MISSING means acceptance evidence was not located, not that implementation is
absent. OUTDATED preserves a valid historical result whose version/workflow does
not establish current acceptance. FAIL is reserved here for a concrete mismatch
or test defect, not an unexecuted test.

## Current DEV evidence

At 13:40:27.411443 UTC (21:40:27.411443 MYT), MCP reported
`supabase_read_only_user`, `transaction_read_only=on`. Job 3 was inactive with
17 succeeded retained runs, zero failed and zero unfinished. Its last run ended
13:00:00.089637 UTC. Jobs 1/2 each had 60 succeeded runs in the preceding hour.
No relevant coordination locks or other active client transactions were returned.
No overdue ACTIVE claim/lease pair, nonterminal claim or OPEN/MANUAL_REVIEW case
was returned. These are observations at a snapshot, not future guarantees.

The Stage 3I final SELECT verifier again returned every flag true: RELEASED claim
and lease, EXPIRED_SAFE_RELEASE, STALE task, AVAILABLE donation/listing, listing
version 3, eligibility generation 2, exactly the expected new audits, completed
real generation-2 refresh and unchanged outside business snapshot. The retained
fixture is evidence and must not be reused for mutation tests.

Recovery body MD5 is `5ff6d8719db9681aae6f444b89dfbaee`, calculated from
`replace(prosrc,E'\r\n',E'\n')`, not from whitespace-normalized function DDL.
Owner postgres; SECURITY DEFINER; search_path pg_catalog/public/extensions/pg_temp;
EXECUTE only postgres/service_role. The 85 other public functions retain closure
aggregate MD5 `6991083a881075cdf0e75d0c266396f0` (definition, owner and ACL).

The entire deployed bodies of claim_listing(uuid,uuid), start_pickup(uuid),
complete_pickup(uuid,boolean) and cancel_claim(uuid,uuid) equal both the persisted
lifecycle migration and the captured isolated-test RPC source after CRLF-to-LF
conversion only. The original V3 dump differs and is a historical base, not a
standalone current deployment artifact. See the captured definitions for exact
signature, search_path and grants; start/complete retain their broader EXECUTE
ACLs and enforce holder authorization inside their bodies. No grants changed.

Live indexes enforce one nonterminal ACTIVE/RECONCILIATION_REQUIRED claim per
listing, one lease per claim, request UUID uniqueness and unique active batch
membership. Donation lifecycle and photo checks are deferred to commit. Config
is v2.0, 360-minute claims, 20,000 m eligibility radius, 10 kg direct threshold,
3-5 donations and at most 30 kg per batch. No renewal implementation is proposed.

At 13:42:23.299862 UTC, there were two active NGO profiles, only one with
non-null verified-location and road-node evidence, and five AVAILABLE listings.
These are not ten authenticated eligible sessions or five approved disposable
fixtures. The current harness requires ten distinct JWT subjects and fresh,
road-eligible dedicated listings. It cannot run unchanged with today's evidence.

## Reconciliation of the 2/10/50 results

| Existing evidence | What the saved results establish | Current acceptance disposition |
|---|---|---|
| docs/audits/legacy-claim-geofence/geofence/g16_results/g16_summary.csv and g16_requests.csv | Nine rounds: 3 each at 2/10/50 simultaneous request threads; all saved PASS/db_ok true; 186 requests total, 9 SUCCESS and 177 CONFLICT | Historical authenticated HTTP contention evidence. Two NGO identities reused across threads, not 50 distinct NGOs. Project/source fingerprint is not bound in the results. OUTDATED for current V3 plus lifecycle/async changes |
| docs/audits/legacy-claim-geofence/geofence/geofenced_concurrency_summary.csv and requests CSV | Nine rounds at 2/5/10, 51 requests, one winner per round, all saved PASS | Calls test_claim_listing_geofenced with explicit actor rather than current authenticated claim RPC. OUTDATED; no 50-client cohort |
| docs/audits/legacy-claim-geofence/atomic_claim/concurrency_summary.csv and requests CSV | Nine rounds at 2/5/10, 51 requests, one winner per round, maximum actual DB workers matches 2/5/10 | Calls test_claim_listing; older test path, not current auth/eligibility/lifecycle. OUTDATED; no 50-client cohort |
| baseline implementation/result claim summaries and source README | Frozen comparative simulation; 50 trials at each of 2/5/10 workers | Reusable baseline evidence within that simulation. Fifty trials is not fifty clients; cannot establish native PostgreSQL safety |
| supabase/tests/claim_concurrency_test.py | Guarded current RPC runner, COUNTS=(2,10), correct p_listing/p_request | Prepared code, not a saved successful current run; MISSING current 2/10/50 acceptance |

The G16 runner sends p_listing_id/p_request_id (line 80), whereas the deployed RPC
requires p_listing/p_request. Its fixture uses test_create_donation with synthetic
road node and availability arguments (lines 44-68), and expects
AUTHENTICATED_CLAIM_ATTEMPT (line 110); current event is CLAIM_ATTEMPT. Therefore
it must not be rerun or adapted by simply pointing its environment at DEV.
The legacy scripts were inspected as text/AST only; none was imported/executed
and no historical project was accessed.

The FYP review PDF requests 2/10/50 **clients** (page 20); the checklist separately
calls 50 simultaneous **NGOs** a stretch. Record both request concurrency and
distinct NGO subjects. Reusing two subjects is legitimate request-load evidence
but cannot be relabelled as 50-NGO contention. Resolve that experiment label with
the supervisor before provisioning 50 accounts. Do not manufacture credentials.

## Confirmed gaps and constraints

1. The delayed-lock harness has a concrete release-order defect. In
   claim_concurrency_test.py lines 392-420, ThreadPoolExecutor exits (waits for
   blocked workers) before the outer finally releases the listing lock. The
   worker HTTP timeout can expire first. Correct and isolate-test this test-only
   lifetime before any live delayed-race run. No test code was changed here.
2. That harness does not verify member donation lifecycle or eligibility queue
   generation, and its result lacks a full source/build/run manifest. Extend only
   its assertions/output and 50-client coverage after separate approval; reuse
   the existing safety gate, real authentication and request/audit verification.
3. Same-request replay and payload mismatch have current source evidence and a
   prepared runner, but no current authenticated result artifact was found.
   Post-release replay must return the original historical claim without new
   authority; a replayed SUCCESS is not proof of an ACTIVE lease.
4. Isolated stale-holder and recovery/claim races reuse exact current RPC bodies.
   They use reduced schema, auth GUCs and a road-check double. They do not prove
   real PostgREST/JWT/RLS/storage boundaries or current multi-NGO fairness.
5. Seven required claim-write fault points are prepared but lack a current run.
   Recovery audit-failure rollback is already isolated-tested and should be
   reused. Do not install fault triggers in DEV under this review.
6. Discarding an HTTP 200 response is not an unknown commit outcome. Actual
   committed-response loss plus safe retry remains an acceptance gap.
7. No public operation_failure_events table exists in DEV. Rolled-back business
   audits cannot durably record their own exception. Existing references to a
   trusted failure logger describe a requirement, not an installed component.
   Agree an approved external/operator failure-evidence mechanism before claiming
   durable exception observability. No SQL redesign is justified merely to pass
   a documentation claim.
8. Native whole-hub recovery/custody and normal-write concurrency are outside the
   successful single-direct Stage 3I proof. Real alerting, starvation response,
   operator coverage and pause receipts remain unattended-recovery gates.

## Current terminology addendum

The [closure requirements inventory](../../../../docs/audits/2026-10-23-stage3i-closure-and-next-stage-plan.md)
records SHA-256 identities for the original FYP PDF, Revised_v2 contract,
older Latest contract and 19 October checklist. They were re-read as requirement
sources; originals are not edited. Revised_v2 invariants remain the acceptance
basis, with these explicit implementation alignments:

| Historical wording | Current approved interpretation |
|---|---|
| READY_FOR_PICKUP initial direct donation | AVAILABLE -> CLAIMED -> PICKUP_IN_PROGRESS -> COLLECTED; safe release restores AVAILABLE |
| Hub BATCHED directly to pickup | BATCHED -> CLAIMED -> PICKUP_IN_PROGRESS -> COLLECTED; safe release restores BATCHED |
| Claim ACTIVE -> EXPIRED -> RELEASED must always be persisted | Deadline expiry can leave stored ACTIVE until protected recovery; v2 reports server expiry, safe recovery commits RELEASED directly |
| VALIDATED / DELIVERED donation states | Not persisted; COLLECTED terminal |
| 20 km straight-line eligibility only | Directed NGO-to-listing road distance <=20 km with current snapshot/node/generation checks; straight-line prefilter is not a fallback |
| 500 m geofence | 500 m is maximum road-node snap distance, distinct from 20 km claim eligibility |
| Road/NGO refresh or expiry-aware UI absent | Implemented and source/live verified; technical road readiness does not establish independent organization identity verification |
| Recovery worker acceptance complete | Supervised direct case PASS; unattended and broader integrated acceptance not approved |
| Failure logger / 50-NGO / unknown commit tested | Requirement or historical claim until exact current evidence exists |

Revised_v2 paragraph 23/40/43/60/74/179, older Latest paragraph 19/21, and
checklist paragraphs 18/96/124 need this addendum when used in Chapter 5. Preserve
original state labels in historical audit rows and result files. Do not rewrite
database history or restore obsolete SQL to make old prose appear current.

## Review validation and limits

All **106 offline source-contract tests PASS**, rerun in this review in 0.129 s
using unittest discovery for *contract_test.py. These tests do not call DEV.
Prior isolated results were reviewed, not rerun: Stage 3F final 45-test suite plus
one separately executed read-only post-query test; 17 Stage 3A tests; 23 Stage 3E
tests; Stage 3I package evidence and managed-role fixture tests. These overlap and
must not be added together as independent coverage. Stage 3E's old open-case bug
characterization is historical negative evidence; reuse Stage 3F's patched tests.

No new Flutter build, browser workflow, stateful test, PostgreSQL mutation test,
benchmark run, cron operation or deployment was performed. Source equality and
catalog checks do not establish every untested business/concurrency path.
Existing dirty repository changes predate this review and were preserved.
