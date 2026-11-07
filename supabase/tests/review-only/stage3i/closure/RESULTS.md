# Stage 3I Phase 2 closure

**Functional result: PASS. Supervised automatic expired-claim recovery is VERIFIED
for this dedicated direct-pickup fixture. Permanent unattended recovery is NOT YET
APPROVED. Job 3 remains inactive.**

The human DEV Test Operator executed the permission-compatible activation and
pause. Codex performed only SELECT inspection and local documentation updates.
No fixture, audit, grant, function, migration or cron configuration was changed
by this closure task. No new activation package or stateful test was prepared.

DEV only: rcgyuwiidqvrgbxswhqj. The shared project was not accessed. MCP query
identity is supabase_read_only_user with transaction_read_only=on.

## Evidence and exact scope

- Final unchanged verification SELECT: 2026-10-23 13:18:01.544040 UTC
  (21:18:01.544040 MYT), all_checks_pass=true.
- Scheduler/source/health/lock snapshot: 13:12:37.676653 UTC (21:12:37.676653 MYT).
- [Machine-readable evidence](evidence.json), with donor address/coordinates,
  signed URLs and credentials omitted.
- [Closure diagnostics](01_post_test_audit.sql) and [unchanged final verification](02_verify.sql)
  are SELECT-only. The latter is byte-identical to the approved execution package's
  05_verify.sql. The SHA-256 manifest covers this evidence bundle.
- [Phase 1 baseline](../phase1_claim_baseline.json) and
  [Phase 1 report](../phase1_fixture_report.md) remain unchanged.
- Executed activation source: ../phase2_permission_compatible_execution_approved_20261023/03_activate.sql,
  SHA-256 4B80E7D9493E099B088E33077AFE3CC0B2E0B1F334F7BDD6E9E1B921DC77C824.
  It is spent; do not rerun this one-use activation.

| Object | Exact identifier |
|---|---|
| Donation | 3a012ba4-25cc-4054-897e-008e11da3e9e |
| Listing | 95d6cd51-866b-4eec-8a36-36dc24296aec |
| Claim | 8161392c-e1e1-4723-a954-c80b6b61a8c7 |
| Lease | 11b7d48e-a459-4b47-b1db-b43f98d0d474 |
| Pickup task | 270caa8b-5a6d-481c-b199-c9a47156dda2 |

## Independently observed acceptance results

| Check | Result / evidence |
|---|---|
| Claim | RELEASED; EXPIRED_SAFE_RELEASE; closed_at 12:56:00.084318 UTC |
| Lease | RELEASED; EXPIRED_SAFE_RELEASE; closed_at 12:56:00.080786 UTC |
| Natural lease policy | Original issued_at and expires_at unchanged; expiry 02:33:13.441725 UTC; original 360-minute duration retained |
| Pickup task | STALE; other fields including load, owner, creation and road-node snapshot unchanged |
| Donation | AVAILABLE / DIRECT_PICKUP / 20 kg |
| Listing | AVAILABLE / DIRECT_DONATION; version 3; eligibility generation 2; NULL listing expiry retained |
| Recovery audit | Exactly one SYSTEM/SUCCESS ACTIVE -> RELEASED; exact claim/lease/task/listing/donation IDs and EXPIRED_SAFE_RELEASE |
| Donation audit | Exactly one additional SYSTEM/SUCCESS CLAIMED -> AVAILABLE for this claim/lease |
| Async eligibility | Real job_id 11, generation 2, COMPLETED at 12:57:09.075953 UTC; attempt 1; no error; expected node/snapshot match |
| Prior generation | Generation-1 refresh job unchanged |
| Original history | All four original creation/photo/claim audit rows retained byte-for-byte as JSON values |
| Items/photos | Original one 20 kg item and primary-image metadata unchanged against Phase 1 |
| Custody/reconciliation | No applicable case, assignment or route stop; no unresolved cases globally |
| Unrelated business records | Matching populated-target 13-table hash 070bb28ff5737477d6d91ec9e36feb02 |
| Remaining active backlog | Zero overdue ACTIVE/ACTIVE pairs; zero ACTIVE/RECONCILIATION_REQUIRED claims |
| Recovery source/security | Approved body MD5 5ff6d8719db9681aae6f444b89dfbaee; owner postgres; SECURITY DEFINER; default 100; integer result; protected search_path; exact postgres/service_role EXECUTE ACL |
| Other public functions | 85 definition/owner/ACL aggregate MD5 6991083a881075cdf0e75d0c266396f0, unchanged |
| Job 3 | Inactive; exactly one recovery schedule; approved limit-1 command and one-use marker retained |
| Unfinished operations | No unfinished jobs 1/2/3 run, other active client transaction or relevant non-AccessShare coordination-table lock returned at health snapshot |
| Jobs 1/2 | Active; each has 60 succeeded runs in preceding hour, no failed status returned; latest completions 13:12:00.149332 / 13:12:00.145998 UTC |
| Verification flags | lifecycle_ok, recovery_audit_ok, donation_audit_ok, refresh_completed, custody_clear, unrelated_unchanged, recovery_paused, scheduler_success, scheduler_no_errors and all_checks_pass are all true |

The exact Phase 1 field comparison found only the intended changed fields:
claim status/reason/closed_at; lease status/reason/closed_at; task status; listing
status/version/generation; donation status/updated_at. All other target fields
were preserved. The outside hash covers the documented 13-table scope, including
the previous controlled recoveries; it is not a claim about every database table
or unrecorded physical custody. No Storage object bytes were read or altered.

## Actual scheduler history and timing caveat

There are **17 retained succeeded job-3 runs**, comprising the earlier 12 no-op
canary runs plus **five** runs in this supervised test. Zero failures or unfinished
runs were returned. Every new run used the approved marked limit-1 command as
postgres; none ran after 13:00 in the inspected history.

| runid | Start UTC / MYT | End UTC | Result |
|---|---|---|---|
| 5180 | 12:56:00.067623 / 20:56:00.067623 | 12:56:00.471205 | succeeded |
| 5183 | 12:57:00.085016 / 20:57:00.085016 | 12:57:00.096267 | succeeded |
| 5186 | 12:58:00.142550 / 20:58:00.142550 | 12:58:00.151371 | succeeded |
| 5189 | 12:59:00.125530 / 20:59:00.125530 | 12:59:00.132357 | succeeded |
| 5192 | 13:00:00.081383 / 21:00:00.081383 | 13:00:00.089637 | succeeded |

The donation audit bff5e136-7d47-4fe8-9480-fb4dc5480b86 occurred at
12:56:00.462465 UTC. Recovery event b770ed5f-c564-4d79-8cfd-b8e526ef9ae6 occurred
at 12:56:00.467156 UTC, within run 5180. The recovered rows and event timing
correlate the successful automatic recovery to that first run. The four later
runs produced no duplicate recovery events or observed extra business effects.

The cron return_message is "1 row", which is result-set cardinality, NOT the
integer count returned by recover_expired_claims. Do not report five recovered
claims, or assert exact numeric return values for later invocations from that text.

**Operational qualification:** four runs started after committed recovery.
Immediate pause after the first observed outcome is not independently demonstrated.
The actual activation receipt, first-outcome observation and pause-COMMIT timestamp
were not supplied to this closure, and cron.job has no pause timestamp. Five-minute
window compliance cannot be independently certified from run history alone. This
does not invalidate the functional recovery PASS, but it is NOT an operational
pause-control sign-off. Record the five executions rather than describing one tick.

## What this closes and what it does not

Verified: normal Flutter-created dedicated fixture, natural lease expiration,
real pg_cron invocation of the approved protected function, real direct lifecycle
restoration/auditing, real async eligibility completion, and safe paused final
state. This closes the direct real-scheduler gap left by Stage 3H's empty-backlog
canary and the local mock-scheduler tests. The native permission-compatible
activation succeeded for this particular supervised use; previous unsupported-lock
activation variants remain invalid.

Not established: unattended readiness, all hub/batch paths, sustained throughput,
hostile/concurrent production traffic, every authorization/storage policy, or
fault/timeout alert response. Live stale-holder RPC rejection after this recovery
was NOT attempted during closure. The client classifier maps RELEASED to History
and disables its lease-dependent actions; no new app screenshot/build-level
verification is claimed in this read-only task.

The audit software_version remains the existing emitter label
geolock-stage1-2026-10-19, with configuration_version v2.0. Preserve that history;
use captured source/migration hashes to identify the actual approved recovery
implementation rather than treating the generic label as an exact patch build ID.

## Closure disposition

- Supervised automatic expired-claim recovery: **VERIFIED / PASS**, scoped as above.
- Permanent unattended recovery: **NOT YET APPROVED**; keep job 3 inactive.
- Eligibility workers 1/2: keep their existing active configuration.
- Fixture/audit history: retain unchanged. It is AVAILABLE and must not be casually
  reclaimed; any donor cancellation/retirement needs separate approval and the
  existing protected workflow. No cleanup is authorized by this closure.
- Next work and unattended acceptance gates:
  [Stage 3I closure and next-stage plan](../../../../../docs/audits/2026-10-23-stage3i-closure-and-next-stage-plan.md).

Only documentation and SELECT-only evidence artifacts changed. Existing activation
SQL, application code, deployed migration sources and teammate-owned code remain
unchanged. All 106 offline source contracts PASS; git diff --check PASS; local
documentation links, evidence flags, scheduler counts and document whitespace
checks PASS. No Flutter runtime test or isolated mutation suite was rerun for
this documentation-only closure. No stateful tests or new activation cycle ran.
