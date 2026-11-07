# Final graph-freeze checkpoint — Option A

27 October2026 MYT. GO for exact-operation approval; HOLD for execution. Owner chose
Option A; this is not freeze/worker/recovery authorization. No export or policy
installation repeated. StageA003 unchanged.

## Confirmed evidence

Fresh approved DEV MCP READ ONLY/ROLLBACK inspection at03:32 MYT confirms:
policy80db858b-93e8-4a0a-94e2-dbe14940f0a1, request0b8db479-20c8-4595-9d41-d831650cba93,
exact approved body and valid JSONB digest
b4f97b8c5ec2f41b986ea5a9bcd805cd16877d77c1d99c047c788ba4e81f734c.
One policy, zero graphs/all other routing artifacts/routes/assignments. Source
counts tasks/claims/leases/donations/listings/audits remain7/7/7/10/6/58.
Six freeze triggers enabled; exact freeze RPC source/config/owner and expected
role EXECUTE restrictions. Recovery disabled.

Fresh coverage inventory: approved active OPERATIONAL OSM-OPS-20261018,
926414 nodes/2145828 directed edges recorded,500m maximum snap distance.
Three diagnostic nodes active in that snapshot:

| Purpose | OSM ID | Latitude | Longitude |
|---|---|---|---|
| Diagnostic depot | 1755847853 | 3.217539 | 101.6241686 |
| Diagnostic pickup | 2308277456 | 3.2228554 | 101.6200512 |
| Diagnostic pickup | 5735535080 | 3.2205116 | 101.6210669 |

The native capture20261026T190933Z-native-23ecce already passed full scoped
storage equivalence and all six distinct directed diagnostic pairs. Reuse its
report; no repeated export. This is the approved Peninsular study-area coverage,
not all Malaysia or every address. Owner must confirm the first pilot uses these
locations or identify actual additional locations for snap/pair verification. Existing
expired claims at diagnostic locations are not approved pilot inputs.

No live traffic: modeled OSM maxspeed/highway-default travel times. REAL storage
matches expected source-decimal conversion, not lossless decimal equality or travel
accuracy. Maximum observed expected errors1.05133056640625e-7km and
2.3345947265625e-7minutes. Historical builder differs from current code; exact original
builder/PBF not recovered/rehashed. Current rows match pinned import artifacts.
No fresh full-data equality proof since that capture; owner must confirm no intervening
road imports/edits and keep road maintenance paused through freeze.

## Exact unchanged inputs

* Policy JSON SHA256:30826f3fdb5c52bde2b29605e54b30b19692740fbbb97d098daf4b22a3c0b030.
* Freeze SQL SHA256:cfa8b9b8ad1830e1cdcf0c0febf44d5baa848f8441cae973549bb36c60f17b95.
* Profile SHA256:01882460fe521e0ea1a50082a3d576c9b2a20208dd4d3ef943b0741cc5adb745.
* Postflight SQL SHA256:597549ddeb75baef028f598dc4bb92862f5f226609a9fa29bc023b1c8077bf7b.
* Graph request:eb29d74d-d556-4135-b200-a691902cfbba; snapshotOSM-OPS-20261018.
* Speed profile:OSM_MAXSPEED_OR_CLASS_DEFAULT_BUILD_188bde7568b4d9eb_DIST5DP_TIME4DP_NO_LIVE_TRAFFIC_PG_REAL_OUTPUT_0.
* Precision:EXACT_MAX_6_DECIMALS; serializationPG_REAL_OUTPUT_0.

Fresh catalog: geolock_graph_login can login, graph-worker member, not planner/
validator member, NOSUPERUSER/NOBYPASSRLS/NOCREATEDB/NOCREATEROLE. Freeze EXECUTE is
allowed to graph-worker, denied to anon/authenticated/service_role/planner/validator.
Use the dedicated graph login's password locally, not owner/export credentials.
Native connection/SET ROLE still must succeed at execution; no credential retry
or privilege repair is authorized.

Backup backups/stage-a003/20261026T123006Z-fb09b6 remains available; all six saved
artifact hashes/sizes independently rechecked PASS. It predates003 and policy:
not a current pre-freeze restore point. Restore/exact data equivalence remain NOT
VERIFIED; managed services/Storage bytes excluded. Native road export plus immutable
SQL/policy evidence are retained, but do not constitute a tested whole-database restore.
Owner must accept these recovery limitations or request a fresh backup separately.

## Proposed command — only after separate explicit approval

Owner/operator names start time. Quiet window starts before final preflight and
ends after reviewed freeze postflight; pause road imports/DDL and competing
initializers, keep workers/recovery off and lifecycle writes paused for unchanged
count verification. No measured wall-clock duration is promised.

From repository root, READ-ONLY before-state command (also immediate postflight):

```powershell
$repo = 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$pkg = Join-Path $repo 'docs\stage8\stage-a\deployment-preparation\routing-initialization'
$psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
$run = Join-Path $repo ('results\routing-initialization-execution\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $run -ErrorAction Stop | Out-Null
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue
$env:PGSERVICEFILE = Join-Path $repo 'backups\stage-a003\pg_service.conf'
& $psql -X -W --dbname 'service=geolock_dev_owner_export' --set ON_ERROR_STOP=1 --file (Join-Path $pkg 'postflight.readonly.sql') --output (Join-Path $run 'before-freeze.txt')
if ($LASTEXITCODE -ne 0) { throw 'Preflight incomplete: STOP' }
```

STOP and review expected before-state above; rerun only this small inspection if
the approved window is delayed. This does not repeat export or policy installation.
Separate approved freeze command:

```powershell
$sql = Join-Path $pkg 'freeze_routing_graph.proposed.sql'
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $sql).Hash.ToLowerInvariant() -ne 'cfa8b9b8ad1830e1cdcf0c0febf44d5baa848f8441cae973549bb36c60f17b95') { throw 'Freeze SQL drift: STOP' }
$env:PGSERVICEFILE = Join-Path $pkg 'pg_service.proposed.conf'
& $psql -X -W --dbname 'service=geolock_dev_graph_initializer' --file $sql --output (Join-Path $run 'freeze-result.txt')
if ($LASTEXITCODE -ne 0) { throw 'Outcome failed/unknown: STOP and inspect same request UUID' }
```

Profile pins DEV session pooler5432, geolock_graph_login.rcgyuwiidqvrgbxswhqj,
postgres database, TLS verify-full and supplied CA. Wrapper uses BEGIN, SET LOCAL
ROLE, exact identity/function guards, lock_timeout5s, statement_timeout120s,
SHARE locks on all three road relations, complete hash chains, one RPC, COMMIT.
Do not increase timeouts or change guards automatically.

Immediate postflight (READ ONLY):

```powershell
$env:PGSERVICEFILE = Join-Path $repo 'backups\stage-a003\pg_service.conf'
& $psql -X -W --dbname 'service=geolock_dev_owner_export' --set ON_ERROR_STOP=1 --file (Join-Path $pkg 'postflight.readonly.sql') --output (Join-Path $run 'after-freeze.txt')
if ($LASTEXITCODE -ne 0) { throw 'Postflight incomplete: STOP' }
```

Require exactly one graph, approved request/snapshot/profiles/counts, returned
graph_id and nonempty64-hex content_digest; retain digest and all logs. Same exact
policy remains, all other routing artifacts empty, source counts unchanged, six
triggers enabled/exact, permissions intact, recovery off. No deliberate prohibited
write used to test triggers. Independent graph hash-chain recomputation is not
claimed by this postflight.

Pre-COMMIT SQL/timeout error rolls back; connection-loss outcome requires read-only
inspection of SAME UUID and confirmation original transaction ended before any
retry. Never auto-retry, delete manifests, disable triggers or restore DEV. After
COMMIT no approved inverse exists: defects require separate forward-repair approval.

## Explicit decisions still needed

1. Confirm pilot geography/locations and accept recorded provenance/model/precision
   qualifications; no all-address or performance guarantee.
2. Confirm Option A's global maintenance consequence: once a graph commits, existing
   triggers block ordinary INSERT/UPDATE/DELETE/TRUNCATE on ALL nodes, edges and
   coverage, including adding snapshots/editing coverage. Future safe versioning
   requires a reviewed forward migration retaining original data/evidence.
3. Name operator/start time, confirm no intervening road changes, writer pause,
   dedicated credential availability, and accept5s/120s limits and backup limitations.
4. Explicitly authorize only this exact freeze SQL hash/request/DEV command.

Full-size graph warm-up, matrix/validator acceptance, scoped worker readiness and
Flutter pilot remain later separately approved gates. Freeze does not activate
workers, resolve expired leases or demonstrate live routing performance.
