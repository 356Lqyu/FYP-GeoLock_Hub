# Current approval checkpoint — 27 October 2026 MYT

PREPARED ONLY. No database connection or write during this review. StageA003 stays
closed. This checkpoint supersedes older NOT VERIFIED/current-export next actions
in APPROVAL_PACKAGE.md; it preserves every proposed operation/input and its hash.

## Reviewed source evidence

Capture: results/routing-current-export/20261026T190933Z-native-23ecce.
Report: equivalence-20261026T191003391877Z.json; observed2026-10-26T19:09:41Z
(27 October03:09:41 MYT), completed comparison50.891 seconds, zero mismatches.
Receipt confirms psql17.11 exit0, READ ONLY repeatable-read snapshot, TLS1.3,
approved DEV identity/profile and completed ROLLBACK. Local review rehashed both
export CSVs, three pinned source files and capture implementation/query sources.
All matched. Full review/hash record: results/routing-initialization-preparation/native-export-review.json.

Satisfied gates, as of that capture:

* All926414 source nodes: IDs, binary64 coordinates, snapshot/component/active metadata.
* All2145828 directed natural-key edges: no missing/extra pairs, valid endpoints,
  positive finite costs, exact expected decimal→REAL storage bits and supported
  PG_REAL_OUTPUT_0 serialization. Current generated edge IDs unique and mapping
  pinned by SHA256 bcfbc64b8982776b06da22e6fe5e83aae7c4a7df86b5b4d600a8d5ae75469df4.
* Approved OPERATIONAL coverage geometry/WKB and metadata/provenance match pinned
  coverage; active, SRID4326, valid2D MULTIPOLYGON, max snap500m, expected counts.
* All six distinct directed pairs among1755847853/2308277456/5735535080 reachable
  on the complete current exported graph (plus three self pairs).

Qualifications remain: generated historical edge IDs are absent from source CSV;
exact import-time builder/original PBF not recovered/rehashed; no whole-network
SCC proof, shortest paired-cost matrix, independent graph hash-chain recomputation,
geographic service guarantee or actual DEV worker acceptance/performance proof.
New pilot node pairs require their own availability/reachability checks. Operator
receipt is evidence, not independent remote-server attestation. Capture is not a
lock: pause road maintenance/imports through freeze and review intervening changes.

REAL precision is now a quantified expected conversion, not an equivalence failure:
2145122 distances and2142748 times differ from source decimals as expected, with
maximum absolute differences1.05133056640625e-7 km and2.3345947265625e-7 minutes.
This establishes representation fidelity, not realistic travel-time accuracy.

## A — policy: GO for separate approval; HOLD for execution

Recommend the unchanged proposed policy for a prompt claim→plan FYP pilot:
best effort,240-minute horizon,15-minute reserve,10/15-minute donor/hub service,
neutral1/1 cost weights,15-second per-engine budget and0.25 deterministic budget.
Keep all pinned solver constants/version. The lease/listing must have strictly
more than255 minutes left at snapshot; a360-minute lease must be less than105
minutes old. Fresh claims only; initialization does not repair expired claims.
Full17-field business review: POLICY_BUSINESS_REVIEW.md. These remain proposals.

Exact inputs, rehashed locally:

| Artifact | SHA256 / value |
|---|---|
| policy.proposed.json | 30826f3fdb5c52bde2b29605e54b30b19692740fbbb97d098daf4b22a3c0b030 |
| install_routing_policy.proposed.sql | 6f8312520c112a2993046645c84c50804edef0200aeb3001c7b17382ef930ba1 |
| pg_service.proposed.conf | 01882460fe521e0ea1a50082a3d576c9b2a20208dd4d3ef943b0741cc5adb745 |
| postflight.readonly.sql | 597549ddeb75baef028f598dc4bb92862f5f226609a9fa29bc023b1c8077bf7b |
| Stable policy request UUID | 0b8db479-20c8-4595-9d41-d831650cba93 |

Embedded SQL policy JSON equals the standalone proposed JSON. Database JSONB
digest is deliberately different from the file-byte SHA256.

Credential: session pooler aws-0-ap-northeast-2.pooler.supabase.com:5432,
database postgres, user geolock_graph_login.rcgyuwiidqvrgbxswhqj, session role
geolock_graph_login → SET LOCAL ROLE geolock_graph_worker. Use THIS login's password
in native psql's hidden prompt, not the postgres owner/export password. No password
is included in this package. Login presence is known; credential availability and
successful TLS/scoped access for this login remain to be confirmed. Do not reset
credentials, grant privileges or substitute an owner/service role to proceed.

Preflight, during owner-named quiet window:

1. Owner approves exact policy/SQL hash, UUID, DEV target, operator and start time.
   Keep workers/recovery disabled; pause competing initialization and road imports.
2. Run the existing postflight.readonly.sql via owner-export READ ONLY profile as
   a before-state capture: zero policies/graphs/other routing rows, expected source
   counts, exact enabled triggers/ACLs and inactive recovery. Compare source counts
   to refreshed before-state; historical7/7/7/10/6/58 are not presumed current.
   Confirm existing backup remains available; restorability is still unverified.
3. Graph-login policy-install-preflight.readonly.sql must show correct identity,
   read_only=on, ssl=true, identity_matches=true; exact signature argument names
   p_request/p_body, owner postgres, SECURITY DEFINER, volatile, hardened config,
   normalized source MD5 7b3549f82b239d6c6abbd4a5fee58b4e and EXECUTE=true.
   No write RPC is called by this check. A SQL success exit alone is insufficient.
4. Unexpected state/permissions/hash/connection error: STOP; preserve evidence.

Prepared native commands from repo root (do not run installation before approval):

```powershell
$repo = 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$pkg = Join-Path $repo 'docs\stage8\stage-a\deployment-preparation\routing-initialization'
$psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
$run = Join-Path $repo ('results\routing-initialization-execution\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $run -ErrorAction Stop | Out-Null
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue
$env:PGSERVICEFILE = Join-Path $repo 'backups\stage-a003\pg_service.conf'
& $psql -X -W --dbname 'service=geolock_dev_owner_export' --set ON_ERROR_STOP=1 --file (Join-Path $pkg 'postflight.readonly.sql') --output (Join-Path $run 'before.txt')
if ($LASTEXITCODE -ne 0) { throw 'Before-state incomplete: STOP' }
$env:PGSERVICEFILE = Join-Path $pkg 'pg_service.proposed.conf'
& $psql -X -W --dbname 'service=geolock_dev_graph_initializer' --file (Join-Path $pkg 'policy-install-preflight.readonly.sql') --output (Join-Path $run 'graph-login-preflight.txt')
if ($LASTEXITCODE -ne 0) { throw 'Graph identity/access incomplete: STOP' }
# STOP and review both results; only after exact policy execution approval:
$sql = Join-Path $pkg 'install_routing_policy.proposed.sql'
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $sql).Hash.ToLowerInvariant() -ne '6f8312520c112a2993046645c84c50804edef0200aeb3001c7b17382ef930ba1') { throw 'SQL drift: STOP' }
& $psql -X -W --dbname 'service=geolock_dev_graph_initializer' --file $sql --output (Join-Path $run 'policy-result.txt')
if ($LASTEXITCODE -ne 0) { throw 'Outcome failed/unknown: STOP and inspect request UUID' }
$env:PGSERVICEFILE = Join-Path $repo 'backups\stage-a003\pg_service.conf'
& $psql -X -W --dbname 'service=geolock_dev_owner_export' --set ON_ERROR_STOP=1 --file (Join-Path $pkg 'postflight.readonly.sql') --output (Join-Path $run 'after-policy.txt')
if ($LASTEXITCODE -ne 0) { throw 'Postflight incomplete: STOP' }
```

SQL is unchanged: BEGIN, graph role/identity/function guards, lock_timeout5s,
statement_timeout30s, one install RPC, COMMIT. Expected one policy row, exact request
and body, correct database-computed digest and returned policy_id; zero graphs and
unchanged other routing/source rows, permissions/triggers/recovery. No matrix/task/
claim/route mutation. Pre-COMMIT failure rolls back on disconnect. Commit ambiguity:
inspect SAME UUID read-only and confirm original session ended before any retry;
never invent a new request or change payload. After commit there is no approved
delete/rollback operation; stop and request a forward correction if necessary.

## B — freeze: source gates PASS within scope; execution HOLD

Unchanged freeze SQL SHA256
cfa8b9b8ad1830e1cdcf0c0febf44d5baa848f8441cae973549bb36c60f17b95;
request eb29d74d-d556-4135-b200-a691902cfbba; OSM-OPS-20261018,
EXACT_MAX_6_DECIMALS / PG_REAL_OUTPUT_0, recorded speed-profile label unchanged.
Exact command/transaction/postflight remain in APPROVAL_PACKAGE.md. Separate
approval required after policy postflight; no source export repetition needed
unless intervening road changes invalidate this capture.

Remaining owner decisions:

* Accept qualified historical provenance: import builder188bde7568b4d9eb… differs
  from current local builder; original PBF/build code not independently recovered.
  Current data matches pinned import artifacts; do not claim a reproducible rebuild.
* Confirm intended pilot service geography/actual coordinates inside approved
  coverage and within500m snaps. Recorded Peninsular study-area description is not
  universal Malaysia coverage; ambiguous manifest latitude wording remains. Three
  diagnostic nodes do not approve every donor/NGO location or expired claims.
* Accept modeled, no-live-traffic times and verified REAL representation; actual
  shortest-path matrices/validator acceptance still need runtime verification.
* Accept global network-maintenance freeze: six existing triggers block ordinary
  INSERT/UPDATE/DELETE/TRUNCATE on ALL nodes/edges/coverage once any graph exists,
  including new snapshots and coverage edits. No approved unfreeze RPC. Future
  updates require a separate reviewed forward contract change, not trigger bypass.
* Name window/operator and accept lock_timeout5s / statement_timeout120s for
  complete-table hash/SHARE locks. Timeout means rollback/STOP, not guard changes.

Graph warm-up memory/time for926414 nodes/2145828 edges and paired-cost matrix
acceptance remain unmeasured. The local set-membership fix removes one known
scaling problem but does not prove DEV-size readiness. Warm-up is an activation
gate, not evidence already supplied by freeze. Keep workers disabled until approved.

## Shortest route to the real Flutter pilot

1. Approve exact policy/business settings, graph-login use and quiet window;
   run read-only preflight, approved install, then policy postflight.
2. Resolve five graph decisions above; separately approve freeze and postflight.
3. Configure dedicated graph/planner/validator LOGIN secrets, returned graph UUID,
   DEV publishable key, private validator endpoint/shared token and persistent
   journal/cache. Keep owner credentials out of workers and secrets out of Flutter.
4. Separately approve worker graph warm-up/runtime readiness and request-driven
   writes; verify scoped connections, graph digest/cache and pilot matrix acceptance.
   Run separate independent validator/planner with matching pinned OR-Tools version.
5. Use Android emulator planner URL http://10.0.2.2:8787 for the shortest pilot,
   or trusted reachable HTTPS for a physical device. Real NGO JWT, verified depot,
   available owned vehicle and fresh eligible claim/listing are mandatory. Approve
   the narrow live claim→plan→authorize→pickup→depot-close pilot separately.

No recovery enablement, live fixtures, claim repair, migration replay or automatic
policy/freeze/worker activation is authorized by this preparation.
