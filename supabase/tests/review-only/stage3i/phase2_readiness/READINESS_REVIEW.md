# Stage 3I Phase 2: target-specific read-only readiness review

CONDITIONAL GO for separately approved SUPERVISED automatic recovery testing.
No technical blocker was found at observation. Execution is NOT approved by this
review; job 3 remains paused. Named/present operator, maintenance window, fresh
preflight/manifest and separate explicit execution approval remain required.
Continuous unattended recovery remains NO-GO.

## Live DEV evidence

Only rcgyuwiidqvrgbxswhqj was inspected, through its read_only=true Supabase MCP;
SELECT-only. No shared project access. Database role supabase_read_only_user,
transaction_read_only=on.

Prepared target-specific preflight first observed 2026-10-23 10:56:28.476844 UTC.
Detailed server-time/security/worker observation: 2026-10-23 11:02:24.537282 UTC
(19:02:24.537282 MYT). Lease expiry 2026-10-23 02:33:13.441725 UTC
(10:33:13.441725 MYT): genuinely overdue by 08:29:11.095557 at that observation.
Final custody/paused-state readback: 2026-10-23 11:04:24.566482 UTC.

| Object | Exact identity | Observed state |
|---|---|---|
| Donation | 3a012ba4-25cc-4054-897e-008e11da3e9e | CLAIMED, DIRECT_PICKUP, 20kg |
| Listing | 95d6cd51-866b-4eec-8a36-36dc24296aec | CLAIMED, DIRECT_DONATION, NULL expiry |
| Claim | 8161392c-e1e1-4723-a954-c80b6b61a8c7 | ACTIVE; no closure reason/time |
| Lease | 11b7d48e-a459-4b47-b1db-b43f98d0d474 | ACTIVE, expired; no closure reason/time |
| Pickup task | 270caa8b-5a6d-481c-b199-c9a47156dda2 | CONFIRMED, 20kg |

Listing version 2; eligibility generation 1. Lease issued_at/deadline unchanged,
with original 360-minute duration. This is the sole nonterminal claim and lease,
and the sole overdue ACTIVE/ACTIVE candidate. No other candidate can interfere
in the observed snapshot; future concurrent writes remain an operational risk.

Zero unresolved OPEN/MANUAL_REVIEW cases globally; no case at all for this target
in its captured audit/Phase 1 evidence. No task route assignment/stop, inventory,
batch membership, hub reservation or hub receipt. No pickup/handover/recovery event
has appeared: the same four SUCCESS creation/photo/claim/transition events remain.
Original claim request 38aba660-edee-4cab-b1eb-ee75692607c4 remains SUCCESS for this
claim/listing/NGO. No physical-custody assertion beyond recorded evidence is made.

## Phase 1 comparison

Complete JSON comparisons PASS for donation, listing, claim, lease, task, audits,
refresh rows, items and photo metadata. Only derived server-time/expired status
changed; no captured persistent fixture field changed. Listing generation-1 job
remains COMPLETED, no error.

The identical populated-manifest 13-table unrelated-business hash remains
070bb28ff5737477d6d91ec9e36feb02, matching Phase 1. This is the correct populated
target scope, not the earlier empty-manifest hash. It is not a whole-database hash;
auth/profile/cache/Storage bytes and some item/photo records outside its scope are
not independently proven immutable by this hash. Target items/photo metadata were
compared separately.

## Recovery function and cron

Entire deployed definition matches approved 20261030 source, allowing only CRLF/LF
and the final pg_get_functiondef statement-semicolon difference. Approved body MD5:
5ff6d8719db9681aae6f444b89dfbaee. Claim OR listing unresolved-case guard present.

Signature p_limit integer DEFAULT 100, integer return; postgres owner;
SECURITY DEFINER=true; search_path=pg_catalog, public, extensions, pg_temp;
ACL {postgres=X/postgres,service_role=X/postgres}. anon/authenticated EXECUTE=false,
service_role=true. Default 100 is unchanged; scheduled invocation remains limit 1.
The 85 unrelated public-function definition/owner/ACL hash remains approved
6991083a881075cdf0e75d0c266396f0. No routing/eligibility/security source drift found.

Job 3 inactive; correct name geolock-expired-claim-recovery; * * * * * schedule;
postgres/current database; original limit-1 command with 5s lock and 50s statement
timeouts. Exactly 12 succeeded historical runs, zero failed/unfinished, max job-3
runid 3137. No new recovery execution, open client transaction or relevant lock.
Jobs 1/2 active; each had 60 succeeded and zero failed/other runs in the observed
last hour, latest successful completions at 11:02 UTC. No unfinished worker run.

## Exact target-specific artifacts

Directory:
C:/Users/User/Downloads/FYP-GeoLock_Hub/supabase/tests/review-only/stage3i/phase2_readiness/

- 01_preflight.sql: SELECT-only target/source/candidate/cron evidence and snapshot.
- 02_supplemental_readiness.sql: SELECT-only detailed security, health, item/photo,
  audit and custody checks used in this review.
- 03_activate.sql: complete guarded BEGIN/COMMIT transaction; only changes job 3
  active flag through cron.alter_job; never directly invokes recovery.
- 04_monitor.sql: read-only target, audits, refresh, new cron runs, blockers/workers.
- 05_verify.sql: read-only exact outcome and pair-scoped audit/refresh checks.
- 06_pause.sql: independent immediate-pause transaction, only job 3.
- SHA256SUMS.txt: exact current SQL hashes.

Inputs/evidence saved alongside the directory as phase2_readiness_manifest.json and
phase2_readiness_evidence.json. Phase 1 files and canonical templates are preserved.

The activation file is REVIEW-ONLY and intentionally held: operator=null,
maintenance_confirmed=false, stop_at=null, approval_ref explicitly says no execution
approval. Its fixed target IDs, accounts, exact deadline and version/generation are
populated. The <=3m baseline freshness and <=5m future human stop-deadline guards
also prevent later use of stale evidence. Do not simply execute or weaken it.

After separate execution approval, refresh SELECT-only evidence, name the present
operator/backup, confirm maintenance, set an approved stop_at <=5m ahead, render a
NEW package from the reviewed canonical generator, review the new hashes and then
execute only within the approved window. These review hashes are not authorization
and will change when approval/operator/timestamps are populated.

## Proposed execution and expected results -- NOT EXECUTED

1. Obtain separate explicit execution/activation approval and verify DEV selection.
   Keep all other claim/recovery actions and privileged coordination writes stopped;
   jobs 1/2 stay enabled. Have the postgres pause script ready in a clean session.
2. Run 01 and 02 again, inspect every condition and save full external snapshots.
   Require exactly this one overdue/nonterminal pair; no new custody/case evidence,
   source/security/history drift, unhealthy eligibility worker or conflicting lock.
3. Render/review/freeze the fresh target package with operator/maintenance/stop
   acknowledgement. The activation guards exact 12 job-3 historical runids and
   approved source/ACL, target/lease/deadline and snapshots. Any drift aborts review.
4. Manually execute the COMPLETE 03_activate.sql transaction as postgres only after
   approval. It sets active=true, retaining limit 1/minute and 5s/50s timeouts.
   Record actual COMMIT time. Do not call recover_expired_claims manually.
5. Inspect 04 every 10-15 seconds around the next tick. At the first observed
   outcome/error, or no later than the approved <=5m deadline, execute COMPLETE
   06_pause.sql. stop_at is a human deadline, NOT an installed auto-stop job.
6. Confirm job 3 inactive, all its in-flight runs terminal, no new failed run and
   jobs 1/2 still healthy. Multiple additional NOOP ticks may occur; inspect every
   run after 3137. '1 row' is not proof of one recovered claim.
7. Let actual worker 2 complete the new eligibility generation. Run 05 and require
   all_checks_pass=true, with saved before/after evidence. Refresh Flutter My Claims
   and require Expired - Recovery Pending -> History / Released, without a client
   recovery RPC. Preserve fixture records; cleanup is outside this approval.

Expected actual function outcome, if safe under its locks:

| Table/evidence | Expected committed result |
|---|---|
| donation_claims | RELEASED; EXPIRED_SAFE_RELEASE; closed_at set |
| claim_leases | RELEASED; EXPIRED_SAFE_RELEASE; closed_at set; expiry unchanged |
| pickup_tasks | STALE; original pickup/task snapshot fields preserved |
| listings | AVAILABLE; listing_version 3; eligibility_generation 2 |
| donations | AVAILABLE; DIRECT_PICKUP; 20kg |
| audit_events | Exactly one new target-pair LEASE_RECOVERY ACTIVE -> RELEASED and one SYSTEM donation CLAIMED -> AVAILABLE, both SUCCESS |
| listing refresh | Generation 2 enqueued by actual trigger, then COMPLETED without error |
| reconciliation/routes/custody | No new case/assignment/stop/custody evidence |
| unrelated business | Same scoped hash and preserved old claim history |

05 was executed as a SELECT-only pre-execution SQL compatibility check. It correctly
returns all_checks_pass=false now: no recovery, new donation audit, generation 2
or new scheduler run has occurred. Those false postconditions are EXPECTED before
execution and are not a readiness failure. Custody, unchanged outside snapshot,
paused state and no new scheduler error flags already pass.

## Stop conditions and risk boundaries

Pause immediately on any worker failure/timeout/deadlock, wrong candidate, source/
ACL/config drift, missing/duplicate audit, partial restore, unexpected reconciliation
or custody/route evidence, snapshot drift, eligibility failure, lost supervision,
no run for >2 scheduled minutes or repeated retained oldest candidate. Do not wait
for repeated rollback before stopping; do not bypass a failing candidate.

An unsafe case handled as RECONCILIATION_REQUIRED is a conservative outcome, but
it fails this happy-path test: pause and investigate without forcing reopen.
Pausing stops future scheduling, not an already running transaction or committed
recovery. Inspect job_pid/pg_stat_activity and wait for quiescence. Targeted backend
cancellation needs separate approval. No generic undo/lease resurrection/cleanup.

SQL errors still roll back the entire invocation; limit 1 reduces blast radius
but does not remove oldest-candidate starvation. A claim can represent many hub
rows; this direct test does not prove hub load safety. Temporal guards do not lock
the future asynchronous candidate set: maintenance and a present operator remain
required. Never claim target isolation from this snapshot alone.

Validation: prepared SELECT scripts executed in read-only DEV; 87/87 offline
contracts rerun PASS. SQL whitespace/checksum checks pass. Existing 46 recovery +
11 prepared-script isolated tests were reviewed as prior evidence, not rerun or
misrepresented as a real scheduler recovery during this read-only stage. No new
recovery/business algorithm or migration was introduced.

No state-changing DEV SQL, cron operation, recovery invocation, fixture modification,
migration deployment or cleanup occurred. Stop here and await explicit approval.
