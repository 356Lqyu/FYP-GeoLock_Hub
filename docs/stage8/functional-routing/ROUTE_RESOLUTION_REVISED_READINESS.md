# Revised route resolution release preparation — 31 October 2026

**HOLD for deployment/activation. LOCAL preparation only.** No DEV connection,
backup, writer/cron pause, deployment, identity setup or business write occurred.
Migration unchanged: 20261106_route_interruption_resolution.sql, SHA-256
`a9fe7713fe2ffd65816743b52abd43695d63d1ecbb45fd216983c4a952eca557`.
Local correction evidence: results/v2-resolution-local-correction-20261031/;
10 focused + 74 SQL + 5 API/security bridge tests passed. Hosted parity not proven.

## Gate 1: ONE native read-only preflight — next approval

Use Run-RouteResolutionPreflight.ps1 -ExecuteReadOnly -ConnectionApprovalRef
'REVISED-RESOLUTION-PREFLIGHT-20261031' only after explicit approval. Default or
-ValidateOnly never connects. It pins both SQL and migration hashes and checks the
exact existing geolock_dev_owner_export profile, approved CA, verify-full and
native PostgreSQL 17.11. One hidden password prompt, no fallback or retry.
Evidence: results/route-resolution-dev-preflight-revised/<UTC>-<suffix>/.

The explicit REPEATABLE READ READ ONLY capture ends ROLLBACK. No business RPCs:
four baseline guards; signature conflicts/absence; full function metadata and
scoped dependency definitions; case-insensitive TimeZone settings; constraints,
triggers, ACLs/effective grants, role memberships and installer ownership facts;
extensions/known ledger and manual-history uncertainty; exact known job3 command
equality, batch1/lock5s/statement50s only if matched; bounded cron history; V2
claims/cases/statements/windows/source identities and assignments; completed V3
closed binding, source states, audits, receipt and snapshot/candidate/validation
bindings; graph/policy manifest and reserved audit-key counts. No road graph scan.
Unexpected state/hash/grant/role/trigger drift, partial installation, unknown cron
command or missing preservation evidence means HOLD, not an automatic repair.
Owner-export capability facts do not authorize using that profile for installation.
Supabase ledger entries do not prove manually applied application migration history.

## Gate 2: current recovery capture — separate approval

The 29 October archive predates completed V3 and cannot be the sole current
recovery point. Reuse backup_pre003.ps1 -PreRouteResolution, never default PRE003
or -PreFreeze. Its LOCAL helper/baseline now pin the revised release checksum;
the original 143 deployed-function fingerprints and source timestamp remain
unchanged historical evidence. Compare them with Gate 1; drift requires review,
not blindly repinning the baseline. The helper additionally requires V3 COMPLETED,
closed binding, exactly three completed items, zero assignments, correct candidate/
snapshot, one successful owner closure audit and one authorization receipt; V2
must remain open IN_PROGRESS with three assignments and matching vehicle version.

After backup approval, operator command from repository root:

```powershell
& '.\docs\stage8\stage-a\deployment-preparation\backup_pre003.ps1' -PreRouteResolution
```

No export was run. Future capture uses only approved owner-export profile and PG17
native hidden prompts. New private Git-ignored timestamped directory under
backups/stage-a003/pre-route-resolution/; no previous files overwritten. Unfiltered
custom-format pg_dump plus pg_dumpall --roles-only --no-role-passwords. All app,
routing, road, policy, auth/storage metadata, audit and receipt data are included
to the account's verified scope. Source permission/RLS/identity failures stop it.

Require export exit0, nonempty files, TOC schema/data coverage, complete payload
decoding to NUL, schema extraction, sizes/SHA-256, all 143 function bodies and nine
routing-table metadata comparisons. Archive contains all public audit/claim/task
rows; current V2/V3 guards and routing metadata comparisons are scoped evidence,
not a proof of exact full-row equivalence. Save manifest and independent review.
Optional later LOCAL verification (no export): same script -PreRouteResolution
-VerifyArchiveDirectory '<actual directory>'. It does not prove restorability.

## Restore/recovery and maintenance decisions

- A separately approved restore-only test must use a new isolated loopback PG17
  target, independently checked host/port/database and no DEV service/profile.
  Require compatible extension packages/versions, inert scheduler/network effects,
  reviewed role/ownership dependencies and no external service credentials.
  Never replay Supabase-managed global roles indiscriminately. Check every restore
  error, constraints, data/PK/content evidence where available, functions, ACLs,
  audits/receipts and V2/V3 invariants. Exact source/archive row equivalence needs a
  snapshot-consistent source baseline. No restore is approved by this plan.
- If restore validation is deferred, obtain this release's explicit DEV-only risk
  acceptance. Passwords, provider-managed runtime/configuration, extension binaries,
  Storage object bytes, Edge Functions, Auth/OAuth/signing settings and external
  secrets/services require separate recovery. A logical archive is not full
  Supabase service recovery. Retain previous archives unchanged.
- Propose the user as deployment/recovery operator, but obtain named confirmation,
  recovery location/credential access and an actual MYT maintenance window.
  Approve installer geolock_dev_installer separately. Verify actual login/current
  role postgres, function/table ownership or equivalent rights, database/schema
  creation and role creation (migration creates a safe NOLOGIN resolver group).
  Do not infer installer authority from export access.
- Preferred cutover: separately approve app/background writer pause and job3 pause
  before final backup, wait for existing transactions/job to drain, then capture
  the stable recovery point and install/postflight. No schedule/command change or
  duplicate job. Record and later restore only approved prior active states.
  If writers remain active during backup, explicitly accept the backup-to-cutover
  gap. The custom dump is consistent; catalogs/globals use separate snapshots.
  An idle pg_stat_activity sample does not prove a writer pause is effective.

## Gate 3: installation disabled — separate execution approval

Before approval, review Gate 1, backup/restore-risk evidence, exact installer,
maintenance controls and UNKNOWN manual migration-history disposition. Preserve
new checksum: old approvals/hashes do not authorize revised bytes. Refresh only
time-sensitive cutover facts and baseline guards; never bypass them.

Migration is one transaction with lock_timeout5s and statement_timeout90s.
config.enabled=false, resolver group NOLOGIN, no login/operator mapping or test-run
registry rows. **Not inert:** donation/fleet guards are replaced; ABANDONED enters
the route CHECK; audit-provenance and task-scope triggers become active immediately.
These can reject ordinary writes with incompatible context/data even while the
resolution API gate is false. New private immutable-history triggers protect new
tables. No recovery function/cron/graph/algorithm/lease deadline is changed.

Read-only installation postflight must verify new fingerprints/ACLs, gate=false,
empty mappings/registry, safe role flags, enabled triggers/constraint and unchanged
baseline helpers/graph/policy/cron. Compare V2 holds and all completed V3 data,
binding, receipts and audit evidence. Test owner/source readers with authorized
hosted sessions only after separately approved access; do not create cases to test.
Any pre-COMMIT error rolls back installation. Unknown COMMIT outcome requires
read-only schema/data inspection before any retry. After COMMIT there is no safe
blind DOWN: keep approved pauses and use a reviewed forward correction/recovery.
Do not drop history, undo collection or reactivate released old claims. Resume
writers/cron only after postflight and separate explicit approval.

## Gate 4: operator and acceptance55 — separate decisions

Provision a named dedicated safe native resolver login, restricted group membership
and active mapping only after approved grant/credential review. No NGO JWT in that
native session. This is separate from installation and never a Flutter service key.

Check55 DOES affect V2 synthetic release: AVAILABLE listings become discoverable
to any eligible DEV NGO under the normal 20km rule. Registry labels do not hide
them, limit discoverability or justify false custody. Installation while disabled
can be reviewed independently; activation/finalization remains HOLD until decision.

Required decision: approve exact V2 fixture IDs/source identities, synthetic
semantics and a verified test-only recipient/discovery boundary. Identify all
eligible recipients and how access is controlled. If ordinary visibility to all
eligible DEV NGOs is instead accepted, record an explicit scoped exception and
its evidence; do not relabel check55 PASS/isolation without proof. If neither is
acceptable, retain holds and separately design/test discovery controls. No RLS or
policy alteration is part of this package. Institutional retention is provisional.

## Gates 5–7: activation, evidence, finalization — all separate

5. Explicit workflow enablement and any UI/API delivery approval. Keep the existing
   NGO routing services unchanged. Reader42702 correction is separate and not a
   dependency of native preflight/backup; do not silently bundle another migration.
6. Approve one interruption report, then exact source/NGO statements. Donor A
   bc68e284-58eb-4ba7-91ca-f27bab108b71 owns Test10/test c; donor B
   21d373a7-6551-4469-81d1-280198d4317e owns Test42. NGO
   8e50bc66-7a8d-4791-bc6b-640682daa496 supplies its own statements and vehicle
   accountability. Verify identities and current state again before writes. No
   handover/source possession inferred from task status, fixture names or consent
   to testing. Use UNKNOWN when evidence is unavailable; retain versions/request
   IDs, amend append-only and reconcile uncertain responses read-only.
7. Approve one native restricted finalization only after matching truthful modeled
   no-handover/source-control evidence, current case/manifest/window checks and
   vehicle accountability. Successful atomic outcome: uncollected donations/
   listings AVAILABLE, old claims/leases RELEASED, tasks STALE, cases
   RESOLVED_RELEASED, archived/removed assignments, closed binding and ABANDONED
   route; retire only V2's hold. COLLECTED remains terminal; preserve V3. Any unsafe
   listing/window returns MANUAL_REVIEW with whole-route holds retained. Do not
   fabricate completion or force partial release. Read-only postflight follows.

Next requested approval is Gate1 ONLY. All later commands are procedure references,
not authorization or evidence of execution.
