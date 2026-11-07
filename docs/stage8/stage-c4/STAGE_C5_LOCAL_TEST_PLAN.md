# Proposed Stage C.5 — disposable PostgreSQL compatibility testing

Prepared 26 October 2026 (Asia/Kuala_Lumpur). **Planning only; tests NOT RUN.**

**Decision: ready for approval of local preparation and bounded testing, subject to the gates below. Not yet ready for an unconditional version-parity execution. Direct DEV deployment remains NO-GO.** No database was contacted, cluster started, test imported/executed, executable upgrade SQL created, or Stage A/B source changed during this review.

## 1. Repository synchronization and preserved contracts

- Current branch: `lqy`; HEAD `8fea9ee7fac42388d2b2aed3f5ca08baaf120a6d`. A read-only `git ls-remote` confirmed remote `refs/heads/lqy` has the same commit. Remote default branch is `main`, at `65e40b89c68f29fdf7035e856f684b22b03f97dd`. This review is synchronized with the current branch and local working files; it does not claim that `main` has been merged or reviewed. No checkout, pull, reset, or merge was performed over the substantial existing dirty/untracked work.
- Stage C documents, routing backend, and much existing evidence are untracked in this checkout. A commit alone cannot identify the reviewed input set. Before execution, record a content-hash manifest of all assembly inputs and protected evidence; stop on subsequent drift.
- Read C.2 ASSESSMENT, C.3 RESULTS, C.4 UPGRADE_DESIGN, Stage A README, all three reviewed Stage A forward SQL files, B.2/B.3/B.4.3 reports, and relevant existing harnesses. C.3 supersedes the earlier C.2 inventory unknowns: **28 functions, 11 tables, 75 columns, 21 indexes, 35 constraints, eight private application triggers** match the supplied evidence. C.3 is catalog evidence, not migration-history or runtime proof.
- All three Stage A SQL byte hashes match `stage-a/package-manifest.json`: 001 `fbe81acd7811e884536ed5bf125fb6b0b5eb71e6bd314872378e68b2da0ec94f`; 002 `96bc7763a30b7a641d6dc768dda4e255e12d4b9de2a5e52e8979cb0e26d1682f`; 003 `6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea`.
- The 11 entries in `stage-b3/changed-files.json` still match their recorded hashes. Preserve B.3 evidence and the original benchmark guard. No repeated 30-second optimizer investigation belongs in C.5. Candidate runtime telemetry remains inside the operational payload/digest; retries replay the exact saved payload. Planning and independent validation issue no dispatch authority.
- Preserve 360-minute leases, 10 kg direct threshold, 20 km geofence, current donation statuses, audit linkage, transaction-bound permits, independent validation and database publication authority. Start/complete/close/cancel and route reads become authenticated-only as specified by 003; reconciliation retains the documented postgres/authenticated/service_role ACL. Do not equate this ACL with bypassing its internal participant checks.

## 2. Environment findings and required runtime

| Component | Required / proposed | Observed without testing | Consequence |
|---|---|---|---|
| PostgreSQL | 17.11, `postgres` current AND session user; READ COMMITTED | Installed `psql --version` and `postgres --version` both report 17.11 | Core binaries available; startup/permissions not yet verified |
| PostGIS | 3.3.7 for recorded DEV parity | Absent from installed PG17 extension directory; retained private runtime control file says 3.6.2 | Exact parity unavailable in the inspected runtime |
| pgRouting | 3.4.1 for recorded DEV parity; required many-to-many `pgr_dijkstraCost` overload | Absent from installed PG17 extension directory; private control file says 4.0.1 | B.2 compatibility on recorded DEV versions remains unproven |
| Extension schema | Real PostGIS and pgRouting in `extensions`; built-in `plpgsql` | Private DLLs/control files exist | File presence is not successful load/runtime evidence; record actual extension/build versions after approved startup |
| Other extensions | Inventory snapshot/migration requirements before assembly | `pgcrypto` 1.3 control file exists in installed PG17 | Do not assume pgcrypto is needed for core `sha256`/UUID functions; enable only dependencies actually required by the chosen sources. No real pg_cron scheduler |
| Python | Existing `.venv-stage8`, recorded Python 3.12.14 / OR-Tools 9.15.6755; psycopg for concurrent sessions | Config and installed metadata match; psycopg metadata reports 3.3.6 | Default PATH Python is 3.14; use explicit venv executable. Imports/native libraries remain unverified |
| Containers | Not required | Docker not found on PATH | Do not depend on Docker or install a service as a workaround |

The existing private runtime path is recorded in `results/stage-b1/runtime-path.txt`; its postgres binary and PostGIS/pgRouting libraries still exist. Reuse only its binaries, with a **new owned data directory**; never reconnect to any retained data directory/server. Do not modify the installed PostgreSQL service or its extension directory.

Two explicit lanes:

1. **Parity lane:** PostgreSQL 17.11 / PostGIS 3.3.7 / pgRouting 3.4.1, with compatible binaries and dependencies. Availability of this combination is not established. Resolve package provenance/compatibility before attempting assembly; do not infer ABI compatibility from version labels. No downloads or installs are proposed for this planning turn.
2. **Available-runtime lane:** PostgreSQL 17.11 with 3.6.2 / 4.0.1, after binary version verification. This can produce limited local compatibility evidence if separately approved. Label it NON-PARITY throughout. Passing it cannot close the parity lane or authorize DEV deployment. If exact builds cannot be obtained, stop the parity lane as BLOCKED; never silently substitute versions.

## 3. Preparation and baseline assembly after approval

A new C.5-specific test runner is needed. Do not invoke the Stage B runner as the C.5 entrypoint: its setup applies 001/002/003 immediately, installs road/eligibility doubles, and rejects whole-batch fixtures. The B.1/B.2 harness provides real spatial assembly but does not compose the Stage A cutover. Reuse reviewed transport/fixture ideas, preserving the original runners and sources.

Before starting any cluster, the new runner must reject external DSNs/service files; scrub inherited PG*, SUPABASE*, GEOLOCK* and DATABASE_URL connection settings; use an absent password file and explicit loopback/random port/database/user on every connection. Use only owned initdb/pg_ctl/psql binaries and owned fresh directories. Local trust authentication is confined to the disposable loopback instance. Set a run-specific identity marker and verify server address, port and data-directory identity before any migration. Bind no external address. No Supabase tools, dashboard, backup restoration or worker services.

Assembly manifest, with byte hashes and purpose for every source:

1. Minimal synthetic `auth.users`, JWT-GUC `auth.uid`/`auth.role`, Storage metadata, Supabase principal roles, and inert cron catalog adapters. These are declared adapters, not real Auth/Storage/scheduler acceptance.
2. `geolock-v3-public-schema.sql`, then the historical dependency chain through 20261031. Begin from B.1's explicit snapshot-plus-migration order (claim recovery, retired/validated status cleanup, operational roads, onboarding/async eligibility, audit fixes, persisted lifecycle, expiration/recovery fixes, final audit source). Reconcile it with Stage B's full business assembly. Specifically account for 20261028, the October 23 details/photos migration, and any other file omitted because its objects are already in the snapshot or superseded. Do not blindly replay every historical migration over a later snapshot. Freeze a per-file applied/already-covered/superseded/not-required map before runtime assembly; unresolved dependencies block the run.
3. Restore the exact captured original assignment prerequisite from `integration/dev-preparation-evidence.json`, as the Stage B assembly does, with provenance/hash. It is a reviewed local prerequisite fixture, not a new DEV export. Keep real October 20 spatial/road functions; no replacement stubs for B.2 or spatial claims.
4. Exact fleet C.1 v2 source `phase-c1/proposed_migration_v2.sql`, required depot trigger/dependencies and matching installation seal. Resolve any fixture/source mismatch before Stage A; never fabricate the seal to pass a guard.
5. Exact Stage A 001, then 002, **once**. Stop here for baseline catalog/state capture. Worker roles are cluster-global: use separate fresh clusters for independent lanes or otherwise explicitly account for their lifetime; fresh databases alone do not remove role collisions.
6. Require 28 phase-aware function contracts, all 11 tables/75 columns/21 indexes/35 constraints/eight private triggers, RLS, worker grants, public dependencies, memberships and 003 absence to match. Compare portable definitions rather than generated OIDs/TOAST names. Also verify graph-freeze/task/public triggers and public/column-level privileges.
7. Apply **the original reviewed 003 file unchanged** to a copy of that eligible local baseline. No compatibility wrapper, source-pin override, replacement body, idempotent skip or executable upgrade artifact is part of C.5. If it rejects, retain the first failure and stop that scenario. A SQL correction requires a later review.

Synthetic data only: two NGOs, donor, independent participant/outsider identities; eligible direct donation/listing/claim/active lease/task created through the protected business path; vehicle/depot/capacity/window policy; small directed road graph with approved-local-only coverage, return arcs and unreachable/inactive nodes; graph/matrix/snapshot/candidate/independent attestation; empty and nonempty routing records; captured legacy tasks; unresolved two-party cases; and a small whole hub batch with linked inventory/donations. Populate the graph before freezing it. Use local fake image metadata, explicit clock-relative lease/window anchors, and bounded fixture IDs. No personal data, DEV rows, backup files, or formal experiment datasets.

## 4. Bounded scenario matrix and success criteria

One run per approved version lane; **maximum 60 named scenarios, three repetitions only for the three cutover race schedules, maximum 100 synthetic tasks, two vehicles and ten concurrent sessions**. Initial volume probes use 0/1/10/100 dispatched tasks, not production-scale benchmarking. Per scenario allow 180 seconds total; retain the original 003 five-second lock and 90-second statement timeouts. Stop the lane at 60 minutes, reporting NOT RUN cases explicitly. No automatic retries of failing scenarios. These are engineering bounds, not throughput or Chapter 5 evidence.

| Family | Required observations |
|---|---|
| Empty/existing schema | Fresh 001/002 and existing-data baseline both accept unchanged 003; retain all immutable artifacts, inactive/history rows and unrelated business data. Never replay 001/002 in the existing-schema branch |
| Negative preconditions | Independently introduce lifecycle body drift, security/search-path drift, coordination drift, wrong installer identity, REPEATABLE READ, private-table DML grant, helper EXECUTE grant, partial-003 collision, and dispatched/legacy PK overlap. Identify exact SQLSTATE/message/statement, and prove complete rollback relative to the deliberately altered starting state |
| Replay/partial installation | Successful 003 cannot be blindly replayed; seeded partial objects must not be silently skipped/normalized. Existing SQL may fail on an object collision rather than a dedicated partial-state guard; report the actual failure, not an invented guard |
| Writer commits first | Coordinate two sessions; old valid start commits before migration acquires its task lock; captured set includes that task exactly once |
| Migration locks first | Observe actual pg_locks/blocking PIDs while unmodified migration runs; old writer waits, then fails under the installed guard. Do not change SQL to add sleeps or weaken triggers. Capture expected dispatched set at lock acquisition, **after draining prior writers**, rather than using a stale pre-lock snapshot |
| Lock timeout | Conflicting task writer held beyond five seconds causes bounded migration failure and full rollback. Synchronize with lock observations, not timing-only assumptions; runner timeout is a separate harness error |
| Legacy | Captured dispatched task completes atomically under valid participant/lease checks. Reject a new legacy start, uncaptured/duplicate completion, expired lease, false handover and foreign actor |
| Managed direct route | Actual protected creation → claim → planning → independent validation → publication → start → collection → explicit depot closure. Validate source/vehicle/route binding, stop order, schedule, capacity, time-window, maximum duration, active lease and transaction-scoped permit consumption |
| Cancellation/recovery | Unstarted cancellation archives stops/releases only its reservations; started/stale routes require reconciliation. Collection retains depot hold until closure. Cover both pickup/recovery orderings and audit/business-write fault rollback |
| Whole batch | Positive whole-batch pickup and reconciliation; reject incomplete/inconsistent inventory or partial batch evidence. If fixtures cannot exercise these real paths, mark coverage BLOCKED and broader C.5 acceptance incomplete; direct-only PASS is explicitly limited |
| Reconciliation | Legacy and managed-route two-party agreement, disagreement/manual review, outsider denial, same-request replay with no fresh permit/audit, changed-payload request misuse, concurrent final submissions, donation/inventory/item bookkeeping and injected write failure |
| Security | Effective EXECUTE/DML/TRUNCATE and column grants, schema access, RLS, owner/security/search-path, memberships for PUBLIC/anon/authenticated/service_role/three workers/test identities. Test non-owner callers; superuser-only success is insufficient. Separate callable RPC boundary from internal actor authorization |
| Correction order | Independent clone: 003 → guarded B.2 → B.4.3 Candidate 2, with catalogs/regressions after each step. Another clone: Candidate 2 → 003 must reject the changed claim body and roll back. Never use rejected Candidate 1 |

Exercise deferred PL/pgSQL paths; CREATE FUNCTION success alone is insufficient. For deliberately corrupted metadata not checked by the existing SQL, record acceptance as a discovered guard gap, not an expected rejection PASS. A non-postgres attempt may fail on privileges before the identity guard; preserve that distinction.

Compare normalized catalogs and full sorted synthetic row content before/after every rejected transaction. No partial functions, triggers, grants, permits, audits, or capture inserts may survive relative to that scenario's starting snapshot. After successful installation the only migration-time business-row addition is exact legacy capture; later workflow mutations have separately specified expected transitions and audit events. Never assert only row counts where content or linkage may change.

## 5. Proposed commands and evidence

**Commands below describe the future execution interface; none were run.** The C.5 runner does not yet exist and must be implemented/reviewed after approval. Suggested entrypoint:

```powershell
.\.venv-stage8\Scripts\python.exe -B supabase/tests/stage8_stage_c5_isolated_test.py --run-isolated --runtime <owned-runtime-root> --lane <parity-or-nonparity> --output-dir results/stage-c5/<new-attempt>
```

Require those explicit flags, new output directory, fixed scenario manifest and version assertions; no external connection argument. Each SQL execution should use the owned UTF-8 SQL-file transport pattern already reviewed in `isolated_psql_sqlfile.py`, with:

```text
<owned-pg-bin>/psql.exe -X --no-password -v ON_ERROR_STOP=1 -h 127.0.0.1 -p <owned-random-port> -U postgres -d <owned-test-db> -f <owned-input.sql>
```

Preserve 003's explicit BEGIN/COMMIT without an outer transaction. For wrong-role cases select the dedicated fixture role; for isolation cases set the session default before the unchanged file begins. Use persistent psycopg sessions for controlled concurrency, with the same explicit endpoint/identity restrictions. No package builder invocation that regenerates Stage A files.

Evidence goes only to a new `results/stage-c5/<attempt>/`; write a later results report under a new `docs/stage8/stage-c5/` after execution. Retain:

- repository/dirty-state and input/fixture/protected-file SHA-256 manifests; per-file assembly coverage map and execution order;
- actual server/client/Python/OR-Tools/extension versions, build details, extension schemas/overloads, locale/timezone, connection identity and parity classification;
- raw SQL files and byte hashes, command arguments without secrets, stdout/stderr, SQLSTATE/context, durations, failure/first-attempt records and per-case assertions;
- before/after catalog/ACL snapshots and sorted synthetic row/invariant snapshots, expected/actual legacy task sets;
- race timelines, pg_locks/pg_stat_activity/blocking-PID observations and server logs;
- named PASS/FAIL/BLOCKED/NOT RUN outcomes, regression coverage, adapter limitations and explicit zero remote connections;
- final cleanup record showing only the owned cluster was stopped and its postmaster.pid is absent; protect server logs before disposal. Cleanup failure prevents a clean completion claim;
- final protected-source/evidence hash comparison, including B.3 benchmark guard, candidates/authority inputs and previous evidence. Do not overwrite earlier attempts.

Existing Stage B/B.2/B.4 tests are references for assertions, not substitutes for this composition. Any separately approved historical runner rerun must use a fresh output directory and retain its declared doubles; it cannot be relabelled as C.5 parity evidence.

## 6. Readiness and stop gates

**Plan/contract review: READY.** C.4's approach is consistent with Stage A/B when executed with unchanged sources, real spatial dependencies, preserved ACLs/authority/reproducibility, and the correction order above. C.3's zero cutover counts remain point-in-time evidence only.

**Execution: AWAITING USER APPROVAL plus preparation.** Outstanding local work is the C.5 harness, frozen snapshot-to-migration coverage map, combined real-spatial/fleet/routing fixture assembly, whole-batch fixture support and runtime startup verification. Exact DEV extension versions are unavailable in the inspected installations, so full parity testing is currently BLOCKED. The retained newer private runtime is a conditional NON-PARITY option, not an automatic fallback. No runtime success is claimed from file inspection.

Stop on source/manifest drift, baseline mismatch, unowned endpoint, unexpected partial installation, compilation/runtime failure, guard gap, timeout, missing required coverage, evidence loss or cleanup failure. Preserve evidence and report; do not repair sources, adopt new expected hashes, normalize records or create upgrade SQL to obtain PASS.

Even a complete local PASS only supports a later separately reviewed in-place upgrade artifact and deployment-parity review. Application migration history remains UNKNOWN, future DEV counts/session/lock feasibility remain unverified, and real Supabase Auth/Storage/cron/UI/worker deployment and Chapter 5 runs remain outside C.5. Stop here pending separate approval.
