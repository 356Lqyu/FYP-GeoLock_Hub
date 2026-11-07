# Freeze execution approval checkpoint — fresh backup verified

27 October2026,03:52 MYT. GO for separate execution approval; HOLD to execute.
No freeze, policy installation, worker activation or recovery performed.
This supersedes the old-backup availability limitation in FINAL_GRAPH_FREEZE_CHECKPOINT.md.

## Actual evidence

Fresh backup: backups/stage-a003/pre-freeze/20261026T194729Z-843e8c.
All seven recorded artifact sizes/SHA256 recomputed and matched; native17.11
pg_restore --list independently returned0, including policy and node/edge TABLE DATA.
Archive39387707bytes, SHA256
501d900d36651df6f3987630b00e8a0554b6e48e5cac46992b94ae59b9160064.
verification.json reports full payload decode/schema extraction and88-relation
coverage PASS, exact installed-policy archive check PASS; status complete. Backup
captures POST003/installed-policy/pre-freeze state. No restore attempted:
restorability/exact source data equivalence and complete managed/external recovery
remain NOT VERIFIED. Raw backup data/credentials were not printed.

Approved DEV MCP URL confirmed rcgyuwiidqvrgbxswhqj. Read-only transaction at
03:52:16 MYT confirms policy80db858b-93e8-4a0a-94e2-dbe14940f0a1,
approved request/body/digest all match, zero graphs and all other routing artifacts,
zero routes/stops/assignments, source counts7/7/7/10/6/58 unchanged, recovery disabled.
Freeze RPC normalized MD5 8e1434ea2727e30f898ddff289ac2df3, owner/search_path/UTC/float
settings/argument names and expected role EXECUTE restrictions match. Six triggers
enabled/exact. Graph login has expected isolated membership and no elevated attributes.

03:52:28 MYT scope/maintenance query confirms active approved OSM-OPS-20261018,
coverage counts926414/2145828 and three active diagnostic nodes. All three client
sessions inspectable; no road-table locks and no visible active road-network/freeze
operations. This is point-in-time evidence, not a promise against later operations,
external importers or future scheduled work. Operator must establish a quiet window.
Original native full scoped equivalence/reachability PASS reused; no export repeated
and no new full graph hash claimed. Policy/road data must remain unchanged through freeze.

Evidence: results/routing-initialization-preparation/prefreeze-backup-review.json,
prefreeze-final-preflight.json and prefreeze-maintenance.readonly.sql.

## Exact proposed command — NOT AUTHORIZED YET

Only after explicit approval of DEV target, exact hash/request, operator and window:

```powershell
$repo = 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$pkg = Join-Path $repo 'docs\stage8\stage-a\deployment-preparation\routing-initialization'
$psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
$sql = Join-Path $pkg 'freeze_routing_graph.proposed.sql'
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $sql).Hash.ToLowerInvariant() -ne 'cfa8b9b8ad1830e1cdcf0c0febf44d5baa848f8441cae973549bb36c60f17b95') { throw 'Freeze SQL drift: STOP' }
$run = Join-Path $repo ('results\routing-initialization-execution\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $run -ErrorAction Stop | Out-Null
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue
$env:PGSERVICEFILE = Join-Path $pkg 'pg_service.proposed.conf'
& $psql -X -W --dbname 'service=geolock_dev_graph_initializer' --file $sql --output (Join-Path $run 'freeze-result.txt')
if ($LASTEXITCODE -ne 0) { throw 'Failed/unknown outcome: STOP; inspect same request UUID read-only' }
```

Use dedicated graph-login password only at native prompt; no owner/export substitute.
The profile pins DEV session pooler5432, postgres database, graph-login project
username and verify-full CA. Session role geolock_graph_login, SET LOCAL ROLE
geolock_graph_worker. SQL unchanged, requesteb29d74d-d556-4135-b200-a691902cfbba,
snapshotOSM-OPS-20261018 and approved profiles unchanged. BEGIN/COMMIT,5s lock timeout,
120s statement timeout; SHARE locks and complete node/edge hash chains. No silent
timeout increase, guard changes or retries.

If window delayed or any intervening writer is possible, refresh only the small
postflight.readonly.sql before-state and saved maintenance query through the
approved read-only connection. Do not repeat backup/export/policy installation
without a reason such as intervening changes invalidating their evidence.

## Immediate read-only postflight

```powershell
$env:PGSERVICEFILE = Join-Path $repo 'backups\stage-a003\pg_service.conf'
& $psql -X -W --dbname 'service=geolock_dev_owner_export' --set ON_ERROR_STOP=1 --file (Join-Path $pkg 'postflight.readonly.sql') --output (Join-Path $run 'after-freeze.txt')
if ($LASTEXITCODE -ne 0) { throw 'Postflight incomplete: STOP' }
```

Evaluate rows: exactly one graph with exact request/snapshot/profiles,
926414nodes/2145828edges, nonempty64-hex content_digest and returned graph_id;
retain IDs/digest/logs. Exact policy stays installed; all other routing tables and
routes remain empty, source counts/triggers/permissions/recovery unchanged. No write
probe to test freeze triggers. Postflight does not prove full-size worker performance.

SQL/timeout failure before commit rolls back. Connection-loss/commit ambiguity:
inspect SAME request UUID read-only and confirm original transaction ended before
retry review. After commit no approved inverse exists; no deletion/trigger bypass/
DEV restore. Defect requires separately approved forward repair.

## Remaining owner decisions

* Explicit approval of the exact freeze hash/request/command and named start time;
  owner is operator/recovery coordinator. Confirm imports/DDL/competing initializers
  and lifecycle writers paused through reviewed postflight, workers/recovery stay off.
* Confirm first pilot geography/diagnostic locations or nominate additional locations;
  accept recorded builder/PBF qualifications, modeled no-live-traffic times and REAL
  representation limits, and remaining unverified restore/managed-service recovery.
* Confirm Option A's global road maintenance restriction: all ordinary node/edge/
  coverage writes, including future snapshots, blocked after first manifest. Future
  safe changes require a reviewed migration retaining immutable historical datasets.
* Accept5s/120s limits; actual full graph warm-up/matrix performance stays a later
  separately approved worker activation gate. No automatic activation follows freeze.

No technical failure found in current checked scope. These are approval/operational
conditions, not authorization to execute. Quiet-window assurance cannot be inferred
solely from a past empty pg_stat_activity/pg_locks result.
