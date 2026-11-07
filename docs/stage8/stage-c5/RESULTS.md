# Stage C.5 — limited local attempt results

26 October 2026, Asia/Kuala_Lumpur. **NON-PARITY. Status: STOPPED — ENVIRONMENT BLOCKED.**

The approved first local attempt could not start its fresh PostgreSQL instance. No database connection, business-schema assembly, migration execution, or runtime compatibility test occurred. This is an environment failure, **not evidence that Stage A 003 fails**. Direct DEV deployment remains **NO-GO**. The exact-version parity lane remains **BLOCKED / NOT APPROVED**.

## Execution and immediate stop

Evidence directory: `results/stage-c5/nonparity-attempt-01/` (new, not reused).

Command actually invoked:

```powershell
$c5Runtime = (Get-Content results/stage-b1/runtime-path.txt -Raw).Trim()
./.venv-stage8/Scripts/python.exe -B supabase/tests/stage8_stage_c5_isolated_test.py --run-isolated --runtime $c5Runtime --lane nonparity --output-dir results/stage-c5/nonparity-attempt-01
```

Only three PostgreSQL utility invocations occurred, in order:

1. The retained private `postgres.exe --version` returned `postgres (PostgreSQL) 17.11`, exit 0.
2. `initdb` created a new owned `cluster-data` directory in this attempt and returned exit 0. Its output nevertheless contained `could not create restricted token: error code 87` and `could not re-execute with restricted token: error code 3`, before reporting successful initialization under `CodexSandboxOffline`.
3. `pg_ctl ... start` returned exit 1: `could not create restricted token: error code 87` and `could not start server: error code 3`.

The runner stopped at scenario `runtime-identity`; no retry or execution-context change was made. The invocation lasted approximately 12.56 seconds. PostgreSQL's restricted-token handling failed in this execution context; the exact underlying Windows cause is not established. This was not an automatic approval-review rejection.

**Harness limitation discovered:** startup checked `initdb`'s exit status and continued despite its error text. A future reviewed harness revision should treat those diagnostics as environmental uncertainty and stop immediately, even on exit 0. Do not interpret the initialization success text as a verified usable server. The frozen attempted runner is preserved unchanged for audit.

## Actual versions and isolation evidence

| Item | Actual observation | Claim supported |
|---|---|---|
| PostgreSQL private binary | `--version` returned 17.11 | Binary version only; server version was not queried |
| PostGIS | Intended available-runtime version 3.6.2; no database started | Actual extension load/build/version **NOT VERIFIED** |
| pgRouting | Intended available-runtime version 4.0.1; no database started | Actual extension load/build/overload **NOT VERIFIED** |
| Current/session user and isolation | Planned postgres/postgres, READ COMMITTED | **NOT VERIFIED**; identity query never ran |
| Endpoint ownership | Fresh attempt-owned data directory; planned loopback port 63607; unique cluster marker written in owned config | Configuration intent only; actual listener/address/identity **NOT VERIFIED** |
| External connections | Zero psql invocations, zero submitted SQL files; no psycopg/session connection attempted | No local or remote database connection occurred |
| Cleanup | `pg_ctl` reported startup failure; `cluster-data/postmaster.pid` absent | No successfully started owned server or shutdown operation is claimed |

No existing PostgreSQL instance was contacted. No system service, installed runtime or extension directory was modified. The retained private binaries were read/executed only. The fresh initialized data directory remains as attempt evidence; it must not be reused for a later test. `results.json` contains `cluster_stopped=true` because no cluster was observed started; `cleanup-verification.json` explicitly qualifies this field so it is not mistaken for a tested shutdown.

## Frozen assembly and input evidence

Prepared before startup:

- `assembly-map.json`: all 26 historical migration files, each with SHA-256 and proposed disposition.
- `assembly-order.json`: intended dependency order and baseline pause before unchanged 003.
- `input-manifest.json`: 350 frozen source/protected files, including historical/Stage A/B SQL, captured prerequisite definitions, backend Python and existing B.3 evidence.
- `repository.json`: HEAD and dirty/untracked repository state.
- `scenario-manifest.json`: 38 registered scenarios, below the approved ceiling of 60, with task/concurrency/time bounds.

**Nothing in this assembly map was applied.** The map is a frozen proposed assembly, not a verified reproduction of DEV or a complete migration history. Broad `SNAPSHOT_BASE_OR_SUPERSEDED` entries still require object-by-object coverage substantiation before a later complete baseline acceptance. Do not promote them to verified equivalence on the strength of this attempt.

Proposed order was the B.1-derived snapshot assembly, with explicit current additions:

1. Synthetic Auth/JWT-GUC and Storage catalog adapters; real local spatial extensions. Inert cron catalog only, no scheduler.
2. `geolock-v3-public-schema.sql` (only psql restrict transport directives removed in the planned submission).
3. October 19 claim recovery/reconciliation, retired-delivered cleanup, removed-validated cleanup; October 20 operational road functions.
4. Small synthetic road coverage/nodes/edges and inert cron catalog.
5. October 21 location registration; October 22 onboarding; October 23 async NGO eligibility and details/photos; October 24 async listing eligibility; October 25/26 audit corrections; October 27 persisted lifecycle; October 29/30 expiration/recovery fixes; October 31 final audit/lifecycle source.
6. Exact captured depot function/trigger and original assignment prerequisite, with their local evidence files in the input manifest; exact fleet C.1 v2 source.
7. Stage A 001 then 002 once; pause for baseline checks; original Stage A 003 unchanged only if every prerequisite passes.

October 28 is explicitly classified outside this Stage A authority baseline: it adds the claim-card v2 reader and a paused recovery scheduler, requires a real pg_cron extension, and was not replaced with a fake extension catalog entry. Therefore claim-card-v2/scheduler coverage is missing; no full public-schema parity claim is made. The exact reviewed file remains protected and unmodified.

| Frozen artifact | SHA-256 |
|---|---|
| Attempted C.5 harness | `264374be4deeb2ccfe12c7da77dfdd33b022ccf8f5ef13a4382bdc4b4c3b5236` |
| Input manifest | `ade3fccbc9ef55580128ad0f0b7a6e45c4ddd2f9defe0aa4461791c07663763e` |
| Assembly map | `6a5ab43ba5a7e7228397141b67a0f62863029af4cc9da7608c33692246857a33` |
| Assembly order | `a94623b6cb25e01eeacbe17b8b15a84da5c9eed4e2439a05dd27d6211e24f16d` |
| Original Stage A 001 | `fbe81acd7811e884536ed5bf125fb6b0b5eb71e6bd314872378e68b2da0ec94f` |
| Original Stage A 002 | `96bc7763a30b7a641d6dc768dda4e255e12d4b9de2a5e52e8979cb0e26d1682f` |
| Original Stage A 003 | `6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea` |

The full per-source hashes, including B.2 and B.4.3 Candidate 2, are in `input-manifest.json`. Final integrity verification found **350/350 unchanged, zero mismatches**. The Stage A manifest pins and saved-original B.3 benchmark guard were checked before startup. No previous evidence was overwritten or regenerated.

## Scenario accounting

These are the actual scenario counters in `results.json`, not inferred test passes:

| Status | Count |
|---|---:|
| PASS | 0 |
| FAIL | 1 |
| BLOCKED | 0 |
| NOT RUN | 37 |
| Total registered | 38 |

The sole FAIL is `runtime-identity`, which failed at server startup before identity/version queries. **Lane readiness is ENVIRONMENT BLOCKED**; that readiness classification is separate from the unchanged raw scenario counters. The unapproved exact-version lane is separately BLOCKED and has no executed scenarios.

| Required outcome | Result |
|---|---|
| Baseline assembly and 28-function/11-table/21-index/35-constraint verification | NOT RUN |
| Unchanged Stage A 003 | **NOT RUN**; `unchanged_003_success=false` does not mean an attempted migration failed |
| Negative guard cases / atomic rollback | NOT RUN |
| Writer locks, legacy capture and volume/collision cases | NOT RUN |
| Route/pickup authority and two-party reconciliation | NOT RUN |
| Effective security/RLS/ACL tests | NOT RUN |
| Whole-batch scenarios | NOT RUN |
| 003 → B.2 → B.4.3 Candidate 2; reverse-order rejection | NOT RUN |

No SQL compatibility issue or source-guard gap was established because no SQL ran. There is no runtime PASS, rollback PASS, concurrency PASS or security PASS to report.

## Implementation and missing coverage

The new runner implements input freezing, explicit local endpoint construction, fresh-instance startup, real-spatial assembly, an initial baseline catalog/metadata/privilege checker, unchanged 003 submission, selected negative rollback checks and a security postflight. None of its database branches were exercised. It must not be described as a completed or validated full C.5 harness.

The scenario manifest registers broader workflow, existing-record, volume, race, legacy, whole-batch and correction-order coverage, but those families do not yet have complete executable implementations in this initial runner. It contains an explicit coverage stop after its initial implemented cases. Preparation was interrupted by the required first-failure stop; **registration is not implementation or coverage**. Before any separately approved resumption, finish/review those fixture handlers, strengthen portable table/constraint/ACL/return-type comparisons beyond initial structural counts/source provenance, substantiate the assembly coverage map and address the startup diagnostic handling. Preserve this attempt and its frozen runner hash; use a distinct evidence attempt for any future work.

## Remaining deployment blockers and decision

1. Resolve/review the Windows local-startup restriction before another attempt. No retry or broader execution was performed here.
2. Verify actual server identity, PostgreSQL and extension versions, READ COMMITTED and compatible spatial overloads in a fresh owned instance. Every permitted newer-runtime result remains NON-PARITY.
3. Complete the harness/assembly/fixture preparation above, then obtain the missing baseline, unchanged-003, rollback/concurrency/security and whole-batch/correction-order evidence. Do not replace missing coverage with historical Stage B results.
4. Exact PostgreSQL 17.11 / PostGIS 3.3.7 / pgRouting 3.4.1 parity remains BLOCKED unless separately approved. A newer-runtime PASS would not establish that parity.
5. Application migration history remains UNKNOWN. Prior C.3 catalog/count observations remain historical; future DEV object/privilege/session/cutover/lock/backup preflight and review are not cleared.
6. No DEV upgrade artifact, forward-repair/rollback package, operational execution plan or deployment is approved by this attempt. Real Auth/Storage/cron/worker/UI integration and Chapter 5 experiments remain outside its evidence.

**Stop point:** environment failure recorded; evidence retained; no database connection, migration, worker activation, executable DEV upgrade package or deployment. Stage C.5 remains incomplete and blocked. Await further approval before resuming or creating any upgrade package.
