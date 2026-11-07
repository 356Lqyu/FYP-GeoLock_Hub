# Simplified reconciliation — final DEV deployment preflight

**Decision: NO-GO.** Read-only DEV inspection on 2026-11-04; catalog fingerprint snapshot at 14:22:09 UTC (22:22:09 MYT). This report supplements the existing local implementation report; it does not reopen implementation or authorize deployment.

Candidate: `supabase/migrations/20261104130000_unstarted_released_route_cancellation.sql`.

SHA256: `d80877ef1a0fc2a570ee87f5df0a664dba1ee580a30814614a0e9e9964663ab1`.

Only this report and its companion `SIMPLIFIED_RECONCILIATION_DEV_PREFLIGHT_EVIDENCE.json` were added during preflight. No application/migration source was changed. Existing unrelated work was preserved. All DEV SQL inspection used explicit READ ONLY transactions ending ROLLBACK; transaction_read_only was verified on. No mutation RPC, Food Can lookup/resolution, production access, backup capture/restore, worker activation, deployment or push occurred. The 125 Flutter and 37 PostgreSQL tests were not repeated.

## Findings and gates

| Check | Result |
|---|---|
| Intended DEV project | PASS: connector URL is `https://rcgyuwiidqvrgbxswhqj.supabase.co`, matching the local DEV configuration |
| Version 20261104130000 unapplied | Package absent; historical version cannot be certified from a ledger because `supabase_migrations.schema_migrations` does not exist |
| Required deployed baseline | Primary fingerprints match; relevant dependencies, constraints, ownership and enabled guards present |
| Reader rename/callers | Same public name/signature retained; no registered OID dependents or other stored function bodies calling that name found; privacy gate fails below |
| SQL body patches | Current anchors match; fail-safe drift coverage is incomplete |
| Matching Flutter | Source/test evidence ready; existing APK predates final changes and must not be used |
| Backup/recovery | Historical procedures exist; no verified recoverable capture of the current baseline established |

### 1. Deployment history must be reconciled

The app migration ledger relation is absent. Auth, Storage and Realtime migration tables are not an application migration ledger. New package columns, the current-round view, renamed pre-coordination reader and new public RPCs are absent; no package-name collisions were found. The original three core fingerprints still match. These observations establish that the package is not currently installed, but do not prove that version 20261104130000 was never applied and subsequently reverted.

Before GO, obtain the manual deployment history/receipts and agree the approved version-recording procedure. Do not create or repair a ledger as part of this inspection, or blindly replay the migrations directory. If this version was previously published, use a reviewed forward migration rather than rewriting its history.

### 2. Route reader privacy remains unresolved

The deployed `get_my_authorized_route_pre_deferral(uuid)` retains an NGO route-owner check, and anon cannot execute it. However, authenticated can execute it, and it returns historical direct-donation `pickup_address` and location/road-node fields without an active valid-claim location filter. The current route reader inherits this payload. The candidate wrapper calls the renamed reader and appends lifecycle flags; it does not redact those stop fields.

Consequently, revoking access to `get_my_authorized_route_pre_coordination` alone does not close the underlying authenticated endpoint or historical-location disclosure to the former route owner. Flutter redaction cannot enforce API privacy. This is not evidence of access by arbitrary foreign NGOs; it is the specific released-claim location-retention issue already identified in the pending reader work.

Reconcile the independent `20261104_released_claim_history_readers.sql` proposal, or a reviewed equivalent backend privacy change, with the actual DEV baseline before GO. Review the full reader chain and grants, not only the new wrapper. Such a change may alter a fingerprint required by this candidate; update the canonical dependency/order and assertions through review rather than bypassing them. Verify revoked-claim locations are unavailable through every directly executable reader while authorized active stops retain their required contract.

### 3. Some patches can silently survive source drift

All inspected anchors match the actual deployed source today. The collection permit patch at candidate lines 124–125 has one occurrence of each intended anchor, but neither replacement asserts the count or pins the source fingerprint. A changed definition can make either replacement silently do nothing while the transaction commits. This could leave collection checks using evidence from previous rounds.

The reader projection loop at lines 455–458 likewise uses unguarded replacement and selects whatever matching functions exist. Current `get_my_donation_claim_reconciliation` has two evidence-table references; `get_my_claim_cards_v2` and `get_my_reconciliation_cases` have zero direct references. Zero can be legitimate when readers delegate, but the migration does not assert the expected reader set/source contracts. Add reviewed count/fingerprint/dependency checks appropriate to that exact baseline before GO; do not require arbitrary positive counts for delegating readers.

The donation-release, task-release, remaining-route binding/origin, collected-close and deferred-commit patches assert their anchor counts. The mixed-close replacements lack individual count assertions but are protected by the initial whole-body fingerprint. Current mixed-close counts are 1 depot check, 1 MIXED_OUTCOME literal, 2 final_pickup_count keys and 1 depot_return_confirmed key. A mismatch in a guarded block raises an exception and the single transaction rolls back. This does not compensate for the unguarded collection and reader patches.

### 4. Recovery readiness is not established

Existing preparation material includes `docs/stage8/stage-a/deployment-preparation/BACKUP_AND_RECOVERY.md`, `FINAL_DEPLOYMENT_CHECKPOINT.md`, `EXECUTION_APPROVAL.md`, `BACKUP_OPERATOR_STEPS.md` and the stage-specific PowerShell capture/verification scripts. PostgreSQL 17 psql/pg_dump/pg_restore are installed. The installer service profile exists, contains `geolock_dev_installer`, targets username `postgres.rcgyuwiidqvrgbxswhqj`/database postgres and requests TLS verify-full. Credentials were not emitted. These checks are not a live connection or certificate-validity test of that profile.

Available verification metadata includes historical October captures labelled VERIFIED LOGICAL EXPORT / RESTORABILITY NOT VERIFIED. The November 1 capture attempts are labelled INCOMPLETE or FAILED / NOT A VERIFIED BACKUP. No verified current pre-coordination capture or successful restore receipt was established. Existing backup modes have stage-specific baseline/absence checks, including an older reader fingerprint; they cannot be assumed ready unchanged for this S7 baseline.

Before GO, name the recovery operator, adapt/review the capture baseline, and obtain a current consistent schema/data capture plus required role/membership information without passwords, checksums and protected storage. Verify a compatible isolated restore or the provider recovery procedure, with a recorded recovery point and write-gap/maintenance plan. Confirm hosted backup/PITR availability separately; SQL catalog inspection does not establish entitlement. Do not pause workers or capture/restore DEV under this preflight authorization.

DEV has PostGIS 3.3.7/pgRouting 3.4.1; disposable tests used 3.6.2/4.0.1. Those test clusters are not evidence of restore parity. A transaction failure before COMMIT is recoverable by rollback. After COMMIT, there is no approved automatic down migration: new evidence rounds/receipts cannot safely be collapsed, and restoring an old snapshot loses intervening writes. The recovery plan must address that explicitly.

## Baseline, ownership, grants and dependencies

Normalized fingerprints are MD5 of prosrc with carriage returns removed; these are source comparisons, not general security attestations. Full inspected metadata is in the companion JSON.

| Function | Deployed fingerprint | Assessment |
|---|---|---|
| cancel_my_unstarted_route(uuid) | `25d5d50b727abd9cf94fd0b9c479e612` | Candidate's exact baseline |
| close_my_resolved_route(uuid,boolean,uuid) | `1de1767851ac4a68e68e3c17f8e5d421` | Candidate's exact baseline |
| get_my_authorized_route(uuid) | `167e9843e6e026df8844f441af77fded` | Candidate's exact baseline |
| close_my_collected_route(uuid,boolean) | `5f83aea95b8c8971ea3bfcbcb8b3c18a` | Closure anchor matches |
| enforce_donation_transition() | `50f7c982be9c6cce75174e09f73649ae` | Release anchor matches |
| geolock_assert_donation_lifecycle(uuid) | `3e7df59a90533e0708c51767889d930e` | Deferred invariant anchor matches |
| permit_reconciled_collection(uuid) | `c5bbed4368a64f83ed837d6195b02050` | Both unguarded anchors currently match |
| task_guard() | `4012fed7dad4a6f7767d39bed3de70e6` | Guarded anchor matches |
| check_remaining(uuid,uuid,timestamptz) | `fefd041705ec87001a10135923ac7acc` | Both guarded anchors match |

Inspected functions and private schemas are owned by postgres. Required lifecycle lock/transition helpers, reconciliation lock/participant/finish helpers, route lock/digest/observe helpers, fleet depot check and actor-scoped receipt/save helpers exist at the expected signatures. Cases have the expected statuses and unique claim constraint; evidence has request PK, case FK and the old one-response-per-case/actor uniqueness; resolution requests have actor/request uniqueness. New round/review columns are absent as expected.

Relevant triggers are enabled (`tgenabled=O`): pickup-task `routing_task_authority`, pickup-route `c1_route_vehicle_guard`, donation transition and deferred lifecycle-at-commit, protected deferred stop/event transitions, immutable mixed closure/cancelled-stop histories and immutable receipts. Donation lifecycle validation remains DEFERRABLE INITIALLY DEFERRED. No evidence-immutability trigger from this undeployed package is expected yet.

Private routing/resolution/fleet schemas grant access only to postgres; no inspected private-table mutation privileges were available to anon/authenticated. Current core route APIs grant postgres/authenticated, not anon. Some existing reconciliation APIs also grant service_role; CREATE OR REPLACE compatibility adapters preserve existing grants. Candidate permission blocks revoke PUBLIC/anon/service_role on newly introduced public endpoints, grant authenticated, revoke client execution on new private helpers, and revoke the renamed internal route reader. Default public function privileges include client roles, making those explicit final revokes essential.

The donation transition trigger function currently runs SECURITY INVOKER with public,pg_temp search_path and broad existing EXECUTE grants. The candidate recreates it SECURITY DEFINER with pg_catalog,pg_temp and qualified relation references. This is an explicit privilege-mode change, not a preserved invoker setting; its existing trigger/lifecycle checks remain relevant to review. Other security-definer entry points use pinned search paths. Owner postgres is BYPASSRLS, so participant/owner validation and private grants are material safeguards.

No registered pg_depend consumers of the current authorized-reader OID were found, nor other inspected stored function bodies mentioning that public reader name. Flutter calls the same RPC name and UUID argument; the wrapper retains the legacy JSON and adds fields. Rename preserves the old OID internally while the wrapper gets a new OID; no known catalog consumer is stranded. This cannot enumerate external applications or prepared remote clients. Refresh the PostgREST schema cache and validate the public signature after approved installation. The privacy blocker above prevents an unconditional compatibility/security approval.

## Flutter coordinated rollout

The existing implementation report and final logs record 125 Flutter passes, 22+15 disposable PostgreSQL passes, 6+5 source-contract passes and clean analyze. They were reviewed, not rerun. The canonical file still has the tested SHA256 above. Source includes the new participant panel, versioned joint review, explicit resolve, durable actor-scoped requests, refresh behavior and vehicle checkpoint/no-collection wording. Local DEV project configuration matches the inspected connector.

The existing `frontend/geolock_hub_app/build/app/outputs/flutter-apk/app-debug.apk` is dated 2026-11-04 20:16:37 MYT, before final donation/coordination/route source edits (21:45–22:07 MYT). It is not a matching rollout artifact. Produce and identify a fresh intended DEV build after blockers are addressed; preserve the approved routing endpoint/configuration and do not activate workers. Backend must be visible before the client rollout. Existing clients support only round-one submission/replay; restrict later review rounds/checkpoint-dependent workflows to upgraded clients. Hosted Auth/RLS/PostgREST and owning-participant acceptance checks still require their separately approved rollout scope; never resolve real goods as an installation smoke test.

## Conditional deployment procedure — do not execute now

First clear the reader privacy and patch-drift blockers, reconcile version history, verify current recovery, regenerate the reviewed hash, run only tests relevant to resulting source changes, and repeat the affected preflight comparisons. Obtain explicit deployment approval for that exact artifact. This report does not approve the current candidate or an amended hash.

Required baseline order remains the existing lifecycle/recovery, C1 fleet, protected routing/automatic departure, receipts/legacy compatibility/donor readers, per-stop reconciliation and claim-scoped reconciliation. These are already-deployed dependencies to verify, not files to replay. Reconcile released-history reader privacy work with the fingerprint/dependency order before applying this package. Apply exactly one reviewed canonical file; do not use an indiscriminate `supabase db push`.

The following is the single-file PowerShell execution procedure for the existing installer service, after all gates and approval. Replace the hash value with the newly approved 64-character hash. It deliberately fails until that value is supplied. Run from the project root. No credentials belong in command text or report files.

```powershell
$approvedHash = '<approved-SHA256-after-blockers-are-cleared>'
$migration = (Resolve-Path -LiteralPath 'supabase\migrations\20261104130000_unstarted_released_route_cancellation.sql').Path
if ($approvedHash -notmatch '^[0-9a-fA-F]{64}$') { throw 'Approved hash required' }
if ((Get-FileHash -LiteralPath $migration -Algorithm SHA256).Hash -ine $approvedHash) { throw 'Migration hash mismatch' }
$env:PGSERVICEFILE = (Resolve-Path -LiteralPath 'backups\stage-a003\pg_installer_service.conf').Path
$psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
$log = Join-Path (Get-Location) ('results\coordination-deploy-' + (Get-Date -Format 'yyyyMMddTHHmmss') + '.log')
& $psql -X --password --dbname 'service=geolock_dev_installer' --set ON_ERROR_STOP=1 --file $migration --output $log
if ($LASTEXITCODE -ne 0) { throw 'Installation failed or outcome uncertain: inspect logs and catalogs before any retry' }
& $psql -X --password --dbname 'service=geolock_dev_installer' --set ON_ERROR_STOP=1 --command "NOTIFY pgrst, 'reload schema';"
if ($LASTEXITCODE -ne 0) { throw 'Schema-cache refresh failed: inspect before client rollout' }
```

Pre-validate the service's DEV identity, certificate configuration, postgres session/current role and READ COMMITTED default using a separate explicit read-only session immediately before installation. The migration owns BEGIN/COMMIT and 5-second lock/90-second statement timeouts; do not add --single-transaction, disable guards, or run in a read-only installation session. Its role/isolation guards must succeed unchanged. Record the approved version/history receipt through the separately agreed process; this candidate does not insert an absent Supabase migration ledger row.

Capture file hash, operator, target, UTC start/end, exit status and postflight catalog/grant checks in the approved deployment receipt. A disconnect can make COMMIT outcome uncertain: inspect installed markers and history before retrying. Do not automatically rerun this non-idempotent DDL package. After schema visibility/security checks, roll out the freshly identified Flutter artifact. No Food Can resolution, real-record repair, worker activation or bulk cleanup is part of this procedure.

Stop at this NO-GO report. Implementation corrections, capture/recovery operations and deployment require their applicable authorization; none were performed here.
