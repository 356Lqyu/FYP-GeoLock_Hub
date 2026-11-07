# From current DEV to functional Flutter post-claim routing

**Current status:** Stage A 003 is **DEPLOYED / POSTFLIGHT PASS** under the scoped [postdeployment assessment](POSTDEPLOYMENT_ASSESSMENT.md). Do not replay the historical deployment steps below. Follow [ROUTING_INITIALIZATION_PROCEDURE.md](ROUTING_INITIALIZATION_PROCEDURE.md) for the next separately approved policy/freeze/activation procedure; no initialization has occurred.

**Current checkpoint:** new pre-003 backup `20261026T123006Z-fb09b6` has been independently checked locally; export integrity/defined coverage PASS, restore validation NOT VERIFIED. [FINAL_DEPLOYMENT_CHECKPOINT.md](FINAL_DEPLOYMENT_CHECKPOINT.md) supersedes earlier missing-backup status and contains the exact unchanged migration, remaining approvals, prepared installer profile and deployment/postflight commands. No initialization or deployment occurred.

**Current backup instructions:** [BACKUP_OPERATOR_STEPS.md](BACKUP_OPERATOR_STEPS.md). The user now reports successful approved owner-export connection verification; run the prepared backup runner locally with hidden prompts. Earlier statements below about no approved export profile describe the prior checkpoint. No archive/restore PASS is inferred from connection success.

Prepared 26 October 2026 (Asia/Kuala_Lumpur). Instructions and read-only evidence only. No 003, role/grant, lifecycle action, initialization, worker activation, fixture, backup export or restore was executed. No separate migration-compatibility TEST environment was created or is required by this sequence.

## Current facts

Read-only DEV refresh at **19:41:44–19:41:47 MYT**, connection `supabase_read_only_user`, READ ONLY on, pinned DEV `rcgyuwiidqvrgbxswhqj`:

* All 11 routing_private tables remain empty.
* Approved active operational road coverage `OSM-OPS-20261018` exists. This is not yet a registered frozen graph, matrix or proof of path reachability/precision/performance.
* Existing LOGINs `geolock_graph_login`, `geolock_planner_login`, `geolock_validator_login` each have direct membership in their corresponding worker role, with SET permitted, inheritance/admin false. Their usable credentials, isolation from other elevated roles, deployed processes, secret separation and activation are not proved by this inventory. Do not reprovision merely because the service is unconfigured.
* No backup/export-named role was returned by the scoped role-name query; that does not prove no differently named export role exists. No approved PostgreSQL export connection/credential is available to this session. MCP OAuth and its read-only SQL session are not pg_dump credentials.
* No PostgreSQL large objects were observed (count 0). Recheck during backup if writers resume.
* The previously checked application migration ledger is absent: P11 historical execution remains UNKNOWN; current catalog evidence establishes the expected 001/002 state and checked 003 absence, not execution timestamps.

Exact new queries/results are in `results/stage-a003-initialization-preparation/`; prior baseline evidence is in `results/stage-a003-direct-preparation/`.

## A. Dashboard steps — you / an authorized administrator

1. Open **only** project `rcgyuwiidqvrgbxswhqj`. Verify its reference in Dashboard project settings/URL before copying any connection details.
2. Click **Connect**. Choose **Direct connection** if the local network supports its IPv6 endpoint or the project's existing IPv4 add-on; otherwise **Session pooler** on port **5432**. Copy the actual host, port, database and username shown. Do not guess a pooler region/hostname, use transaction pooling on 6543, enable an add-on or alter network settings as a shortcut. [Supabase connection guide](https://supabase.com/docs/guides/database/connecting-to-postgres).
3. Under **Database Settings → SSL Configuration**, download the database CA certificate. Configure the client with `sslmode=verify-full` and that certificate. Downloading the certificate changes no database setting; do not toggle SSL enforcement or reset a password here. [Supabase SSL guide](https://supabase.com/docs/guides/platform/ssl-enforcement).
4. Identify an **existing, explicitly approved export login** and obtain its password privately from its administrator/secret store. Connect normally shows the `postgres` owner username; it does not reveal an existing dedicated export password. Do not send the password/credential URI in chat. No privileged owner password is silently substituted.
5. If no suitable export login exists, **approve a separate, narrowly scoped administrator provisioning operation** before anyone creates it. Required capability is complete read/export over all schemas, sequences and catalog metadata, including rows protected by RLS. Supabase documents a dedicated backup-reader pattern using `pg_read_all_data`, BYPASSRLS and a read-only default; these are privileged role/grant changes requiring your explicit approval. The default alone is not a tamper-proof read-only boundary, and BYPASSRLS exposes all rows. It is not a worker or Flutter credential. We have not created/granted anything. [Supabase backup-role guidance](https://supabase.com/kb/troubleshooting/pg_dump-fails-with-query-would-be-affected-by-row-level-security-policy).
6. Inspect **Database → Backups** for available provider backup/PITR recovery points and any existing restore record. Record actual coverage/time/recovery operator; do not assume this project's plan includes a feature or initiate a restore. Download/export Storage object bytes and service configuration separately where required; database backups contain Storage metadata, not object bytes. [Supabase backup scope](https://supabase.com/docs/guides/platform/backups).

An owner-run export can be an alternative only if you explicitly approve that exact DEV owner credential for this export; it is not currently approved/used. Creating an export role, changing a password, altering grants, purchasing/activating PITR and restoring DEV are separate operations.

## B. Local commands — secure export connection and current backup

Use installed PostgreSQL 17 tools. Keep all archive/data/password files in an operator-private encrypted location outside tracked source; `backups/stage-a003/` is ignored by Git but ignoring is not access control. Do not put secrets in command arguments, environment values, terminal transcripts or screenshots.

Create a private **libpq service file** locally with an entry named `geolock_dev_backup`. It contains connection parameters, **no password**. For direct mode, the template is:

```ini
[geolock_dev_backup]
host=db.rcgyuwiidqvrgbxswhqj.supabase.co
port=5432
dbname=postgres
user=APPROVED_EXPORT_LOGIN
sslmode=verify-full
sslrootcert=C:/PRIVATE/PATH/dev-database-ca.crt
options=-c default_transaction_read_only=on
```

Replace the login with the actual administrator-approved login; no such login is claimed to be provisioned. For Session pooler use its exact Dashboard host and username `<approved-login>.rcgyuwiidqvrgbxswhqj`, not the direct host/username. The project-bearing username must match DEV. Verify the actual endpoint out of band; the service name is not identity proof.

Set `PGSERVICEFILE` to the private service-file location in the operator's terminal. A custom service-file path is supported by [libpq service files](https://www.postgresql.org/docs/17/libpq-pgservice.html). For a first export, use password prompts so no password file or URI is needed:

```powershell
# Replace only this non-secret path, not a credential URI.
$env:PGSERVICEFILE = 'C:\PRIVATE\PATH\pg_service.conf'
$stage003BackupDir = Join-Path (Get-Location) ('backups\stage-a003\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
New-Item -ItemType Directory -Path $stage003BackupDir -ErrorAction Stop | Out-Null
psql -X --password --dbname='service=geolock_dev_backup' --set=ON_ERROR_STOP=1 --command="SELECT current_database(),current_user,session_user,current_setting('transaction_read_only'),clock_timestamp();"
if ($LASTEXITCODE -ne 0) { throw 'Export identity/access check failed: STOP' }
# Manually review approved identity, READ ONLY on and verified DEV endpoint first.
$stage003Archive = Join-Path $stage003BackupDir 'dev-pre003.dump'
pg_dump --password --dbname='service=geolock_dev_backup' --format=custom --lock-wait-timeout=5s --file=$stage003Archive
if ($LASTEXITCODE -ne 0) { throw 'Archive incomplete: STOP; do not use for recovery' }
$stage003RolesPath = Join-Path $stage003BackupDir 'roles-no-passwords.sql'
pg_dumpall --password --dbname 'service=geolock_dev_backup' --roles-only --no-role-passwords --file $stage003RolesPath
if ($LASTEXITCODE -ne 0) { throw 'Role export incomplete: STOP; resolve/document missing scope' }
pg_restore --list $stage003Archive | Set-Content -LiteralPath (Join-Path $stage003BackupDir 'toc.txt')
if ($LASTEXITCODE -ne 0) { throw 'TOC unreadable: STOP' }
pg_restore --file=NUL $stage003Archive
if ($LASTEXITCODE -ne 0) { throw 'Archive payload unreadable: STOP' }
Get-FileHash -LiteralPath $stage003Archive -Algorithm SHA256
Get-FileHash -LiteralPath (Join-Path $stage003BackupDir 'roles-no-passwords.sql') -Algorithm SHA256
```

Supply passwords **only at the hidden PostgreSQL prompt**, not by pasting command text. For unattended use, an operator-controlled restricted password file is supported; on Windows the standard path is `%APPDATA%\postgresql\pgpass.conf`. Exact host/port/database/user matching and escaping matter. [PostgreSQL password-file documentation](https://www.postgresql.org/docs/17/libpq-pgpass.html).

Stop on any denied object. Do not use row-filtered/RLS-limited exports, omit private/auth/storage schemas, suppress ACLs/ownership or switch to unapproved postgres credentials to call the result complete. A dedicated backup login should use raw pg_dump: Supabase documents that CLI dump attempts SET ROLE postgres. [Backup-reader export instructions](https://supabase.com/kb/troubleshooting/pg_dump-fails-with-query-would-be-affected-by-row-level-security-policy).

The full custom archive preserves maximum catalog evidence, but is **not automatically a portable Supabase restore artifact**. It includes managed internals that can fail when replayed into another platform baseline. Supabase's CLI uses filtering for portable restores; a filtered dump must separately account for excluded schemas/roles and must not silently replace the complete recovery inventory. No source security controls are disabled. [Managed restore limitations](https://supabase.com/docs/guides/self-hosting/restore-from-platform).

Review all schemas/functions/triggers/policies/configuration/data, roles/memberships/grants/default ACLs and exact extensions against the captured source catalogs. The older `geolock_dev_before_lifecycle.backup` stays unchanged. Payload-read success is **readability only**. For restorability, use the prepared **restore-only isolated** procedure in `BACKUP_AND_RECOVERY.md`, or obtain an applicable successful restore record with scope/limitations. Do not execute 003 in that isolated copy and never restore over DEV. If no actual restore/comparison succeeds, record **NOT VERIFIED**. Physical extension binaries, managed credentials, decrypted Vault key material, Storage bytes and external service/function secrets need their own recovery handling.

## C. Exactly what routing data is needed

All 11 tables below already exist from 001. **None needs seed rows before applying 003** in the observed zero-dispatch/zero-route state. Chosen order is initialize only **after 003 and its postflight**. 001/002 technically expose policy/graph/snapshot APIs already, but do not issue routes before 003 enforces pickup authority. “Approve once” below means explicit operator approval of exact initialization/activation, not new manual approval for every ordinary NGO action after the operating workflow is authorized.

| Table | Stored facts | Approved producer / timing | Approval and missing dependency |
|---|---|---|---|
| `routing_private.policies` | Immutable explicit business/solver/execution policy JSON and digest | `install_routing_policy(p_request,p_body)`, under `geolock_graph_worker`; initialize after postflight, before overview can show eligible tasks/snapshot generation | **Approve exact policy once.** No values are invented. Requires mandatory boolean; horizon >0 and ≤1440; nonnegative finite margin/direct/hub service durations; solver and execution objects. Worker contract imposes further exact solver/version/objective requirements; SQL's basic JSON check is insufficient. |
| `routing_private.graphs` | Manifest/digest/counts for real operational road data; speed/precision/output profile | `freeze_routing_graph(p_request,p_snapshot,p_speed_profile,p_precision_policy)`, graph-worker role; initialize after postflight, before graph-dependent matrices | **Approve exact freeze once.** Existing coverage is only a candidate input, not approval of this operation. Requires approved active operational coverage, real road nodes/edges, explicit justified speed profile, `EXACT_MAX_6_DECIMALS`. Full graph hashing/lock/runtime/memory and precision remain relevant. |
| `routing_private.snapshots` | Owned NGO/depot/vehicle/task/source/lease observations, policy and cutoff; later matrix binding/seal | NGO `begin_my_routing_snapshot(p_request,p_policy,p_vehicle_ids)`; then planner `seal_routing_snapshot(p_snapshot,p_matrix)`; generated per planning request after initialization | Approved workflow/DEV pilot writes. Requires verified active NGO/depot, owned eligible vehicles, policy and current tasks. Do not insert fake observations. Snapshot capture alone does not assert every observed task is admissible. |
| `routing_private.matrices` | Real directed road distance/time/status matrices with digest and graph reference | Graph-worker `store_routing_matrix(p_request,p_graph,p_body)` called by real worker; produced for snapshot's required nodes, then snapshot sealed | Approved worker writes, not hand-seeding. Requires full trusted frozen export, matching provenance/speed profile, 1–100 unique nodes, exact bounded matrices and FAIL_SCENARIO unavailable-pair behavior. |
| `routing_private.candidates` | Actual proposed plan, snapshot link and digest | Planner `submit_routing_candidate(p_request,p_snapshot,p_body)` after matrix sealing/solver execution | Approved worker operation; no fabricated success/plan. A candidate remains advisory. |
| `routing_private.validations` | Independent validator's digest-bound report, role/build/time | Validator `attest_routing_candidate(p_candidate,p_digest,p_report)` after re-reading/rebuilding actual inputs | Approved independent validator. Exact candidate/snapshot/matrix/input digests and valid/feasible/build checks; never seed a PASS report. Required before authorization. |
| `routing_private.bindings` | Managed route ↔ candidate/NGO/vehicle/version/plan/departure; started/closed times | NGO `authorize_my_routing_candidate(p_request,p_candidate,p_depart_at)` from 002 after actual attestation | Approved normal NGO authorization. Revalidates live source/lease/depot/vehicle/window/capacity; route starts DRAFT transactionally and commits AUTHORISED. Do not prepopulate. |
| `routing_private.items` | Per-route task order, observation digest, transaction-bound planning/dispatch/completion/release bookkeeping | Same authorize RPC creates reservations; 003 start/complete/cancel/reconciliation/close update protected fields | Approved lifecycle operations. Never client-written. Requires bindings/current source data and authority triggers. |
| `routing_private.requests` | NGO authorization request digest and cached result for replay | Same authorize RPC, atomically with publication | Runtime idempotency history; **not a seed prerequisite**. Stable request UUID/payload required on retries. |
| `routing_private.legacy_inflight` | Cutover capture of tasks already DISPATCHED and protected completion bookkeeping | 003's own INSERT captures DISPATCHED tasks; protected completion/reconciliation updates permits | **Do not initialize manually.** Current count and dispatch count 0, so it may correctly remain empty. Migration approval covers capture of the reviewed cutover set only. |
| `routing_private.cancelled_stop_history` | Immutable evidence of cancelled unstarted route stops | `cancel_my_unstarted_route(p_route)` archives actual public stops | **No initial rows required.** Written only on an approved real cancellation. |

Public/upstream dependencies must also exist through their own protected workflows:

* `road_network_coverage`, `road_network_nodes`, `road_network_edges`: actual approved operational source, not fabricated graph rows. Existing coverage does not prove every path/sum meets contract.
* NGO/user/depot profiles plus `public.vehicles`: valid C.1 state. `register_my_vehicle`, `update_my_vehicle`, availability/deactivation RPCs manage fleet. Existing one vehicle is not automatically proof of eligibility; NGO checks must confirm active/available/unheld/version/depot compatibility.
* `donations`/`listings` (or whole HUB_BATCH/inventory): existing valid source lifecycle. `claim_listing(p_listing,p_request)` creates `donation_claims`, `claim_leases` and **CONFIRMED** `pickup_tasks` atomically. Do not seed these tables directly.
* `pickup_routes`, `pickup_route_stops`, `active_task_route_assignments`: populated by **authorize_my_routing_candidate**, not by claim, worker advisory output, old `assign_task_to_route` or Flutter table inserts. Task becomes PLANNED; only 003-authorized start yields DISPATCHED / route IN_PROGRESS.

**Graph-freeze consequence requiring explicit approval:** 001 already installed triggers on road nodes/edges/coverage; once any graphs row exists, their writes/TRUNCATE fail `GRAPH_REVISION_FROZEN`. The hash covers whole relations, not a hand-cropped export. Refresh/version maintenance requires separate design, not deletion of the manifest or disabling triggers.

Worker activation must use the existing three separate logins, SET ROLE correctly, secrets outside Flutter, exact graph ID, independent private validator endpoint/token, persistent journal, trusted HTTPS planner endpoint (debug emulator HTTP only where allowed), and actual approved policy. No new worker membership or password is presumed needed merely from empty routing tables. Credentials/process readiness remain unverified.

## D. Two expired ACTIVE leases — decision

At 19:41:44 MYT the same two claims remain expired: `dd1be70f-0e42-4b75-9124-cac3702d76f6` and `b4bea793-9755-470a-95bb-6b02bc0c4443`. Both are direct donations, claim/lease ACTIVE, one correctly owned CONFIRMED task each, source/listing CLAIMED, listing expiry NULL, one outstanding claim per listing, no open/manual-review case, active assignment, route stop, held routing item or legacy capture. Expiry times were 25 October around **09:37:43/09:37:48 MYT**.

**Before deployment:** no 003 guard requires automatic recovery of these rows, and neither belongs to the DISPATCHED capture set. They can be retained untouched while installing 003. Do not use them as eligible routing tasks or pretend their lease is renewed.

**Before routing these donations again:** an approved lifecycle recovery or a separately approved valid new claim/source path is needed. The observed shape supports reviewing the normal `recover_expired_claims(integer)` safe-release branch rather than immediately asserting reconciliation is required. This is not a recovery PASS: lock-time source/ownership/custody/listing-expiry checks remain authoritative and could select reconciliation. Expected safe branch: claim/lease RELEASED, task STALE, direct donation/listing AVAILABLE, preserved audit plus new recovery/custody events. Do not change statuses directly or invoke the scheduler automatically.

Recommend handling the exact pair **after 003 postflight and before reclaim/planning**, with separate explicit approval of a freshly pinned, guarded operation and exact population. Do not invoke an unguarded queue RPC with a limit and assume it selects only these two. Older exact-two proposal pins differ from current reviewed recovery source; it must not be reused blindly. Recheck all affected records and audit boundaries. Then legitimate NGO claims create new valid leases/tasks; no lease renewal is invented. If uncertainty appears, retain holds and use the existing approved participant reconciliation workflow, not forced release.

## E. Shortest execution sequence and approval ownership

| Order | Who / place | Action | Approval checkpoint |
|---|---|---|---|
| 1 | You/admin — Dashboard | Verify DEV, copy direct/session connection parameters, download CA, identify approved export credential; inspect backup/PITR/restore record | Approve exact export credential; separate role/grant provisioning only if needed. No secrets in chat. |
| 2 | You locally; Codex may inspect resulting metadata | Capture new pre-003 database archive + password-free role export; verify full scope/readability/checksums; obtain scoped restore evidence or perform approved isolated **restore-only** validation | No recovery PASS from readability. Keep recovery NOT VERIFIED absent evidence; no DEV restore. |
| 3 | You approve; operator coordinates | Record P11 **history UNKNOWN**, accept state-based guarded upgrade plus C.5 unvalidated runtime risk; approve exact recovery plan and writer/DDL maintenance window | Stop/drain writers/jobs via approved operations; refresh read-only preflight at cutover. Do not treat this message as approval. |
| 4 | Approved DEV installer / Codex only if separately authorized | Execute only exact unchanged 003 file with its transaction/guards, postgres/postgres, READ COMMITTED | **Explicit approval of pinned single-file command**. No 001/002 replay or B.2/B.4.3 ahead of it. |
| 5 | Codex — read-only DEV | Full `postflight.sql`: all 17 new/replaced functions, preserved 28 baseline functions, trigger, ACL/RLS, source/capture counts and intended deltas | Keep writers/workers paused on mismatch. No automatic repair. |
| 6 | Operator/Codex under exact approval | Resolve the two expired claims through newly reviewed bounded lifecycle operation if reusing those donations; verify postconditions; real NGOs reclaim valid sources | **Separate lifecycle write approval**. Existing expired claims need not block step 4. |
| 7 | Administrator approves; graph-worker identity executes | Approve full policy JSON and exact operational graph-freeze inputs; install policy/freeze manifest; verify rows/digests/counts/grants | **Explicit policy/freeze approval**, especially global network-maintenance freeze. No invented settings. These are the only two upfront routing_private seed-like operations. |
| 8 | Operator/Codex after service approval | Verify existing worker logins/secrets/TLS/private validator/journal; set graph ID and activation record; warm the real graph; start independent validator/planner | **Separate activation/provisioning approval**; no postgres/service-role worker credentials. No graph scale timing claim without measurement. |
| 9 | NGO Flutter + approved backend | `claim_listing` → snapshot with selected owned eligible vehicle(s) → real `/v1/plan` matrix/seal/solve/candidate/independent attestation → NGO publication authorization | Approved normal operating/DEV pilot scope; stable UUIDs, live lease/window checks. No candidate authority from local calculation. |
| 10 | You + Codex, approved synthetic DEV pilot | View actual assigned route → fresh backend authorization → start → physical-handover completion → explicit depot-return close; test cancel/reconcile/negative/rollback/regression cases | Approve exact test records/accounts/writes and failure scope. Follow `POST_DEPLOYMENT_TESTS.md`; don't use operational data or rerun 003 for rollback tests. |

Steps 7–8 should have their exact plans/credentials/policy/freeze approval prepared **before step 4** to avoid an indefinite pickup outage, even though their writes execute after postflight. If backup/recovery and operational approvals cannot be closed, remain NO-GO to execute. Separately accepted C.5 risk does not require creating a migration TEST environment.

Deployment file remains `docs/stage8/stage-a/forward-migrations/20261103_routing_pickup_and_reconciliation.sql`, SHA-256 `6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea`. Exact guarded command is in `DIRECT_DEV_DECISION.md`. It remains unexecuted.

After approved initialization/activation, example existing local service commands (do not run now):

```powershell
.venv-stage8/Scripts/python.exe -m backend.routing.worker_service --mode validator
.venv-stage8/Scripts/python.exe -m backend.routing.worker_service --mode planner --warm-graph
.venv-stage8/Scripts/python.exe -m backend.routing.worker_service --mode planner
```

Validator and planner run as separate processes with separate secret scopes; the warm-graph invocation is a preparatory run, not another always-on planner. `GEOLOCK_ROUTING_ALLOW_DEV_WRITES=APPROVED` and an exact activation reference are set only following approval, never merely to pass startup. For Android emulator debug, run from the Flutter directory with `flutter run --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=http://10.0.2.2:8787`; production/device URLs require approved HTTPS configuration. Do not use an example host as a real service.

**Codex can do now:** additional focused read-only checks, inspect non-secret service/backup metadata and restore records, validate a user-supplied proposed policy against actual contracts, prepare exact freeze/recovery/activation operations and maintain the Flutter/tests locally. **Codex cannot infer authorization:** creating roles/grants, changing passwords/settings, executing 003, recovering leases, installing policy/freezing graph, activating workers or mutating fixtures. Each waits for the relevant exact operation approval. No DEV mutation occurred in this preparation.
