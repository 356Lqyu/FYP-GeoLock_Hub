# Routing initialization approval package — 27 October 2026 MYT

**Superseding evidence:** native current-DEV export `20261026T190933Z-native-23ecce`
completed **PASS / SCOPED STORAGE EQUIVALENCE**, including all six diagnostic
directed pairs. See [CURRENT_APPROVAL_CHECKPOINT.md](CURRENT_APPROVAL_CHECKPOINT.md)
for reviewed scope, qualifications, current hashes and separate policy/freeze gates.
Historical NOT VERIFIED/export/authentication next actions below are superseded.
No policy, freeze or worker activation is approved or executed.

**Current priority:** authentication and failed-export investigation are paused by the owner. The working local integration result and minimum DEV path are in [IMPLEMENTATION_RESULT.md](../../../functional-routing/IMPLEMENTATION_RESULT.md). Historical password-diagnostic next actions below are superseded. This does not waive graph-source gates, change proposed policy/freeze inputs or authorize DEV writes.

**PREPARED ONLY. Every value and operation below is NOT YET APPROVED. No initialization was executed.**

Stage A 003 milestone is CLOSED, status **DEPLOYED / POSTFLIGHT PASS**. No replay or deployment review is needed. This package implements the next preparation step of [ROUTING_INITIALIZATION_PROCEDURE.md](../ROUTING_INITIALIZATION_PROCEDURE.md); it does not supersede its boundaries. Target DEV project: `rcgyuwiidqvrgbxswhqj` only. Operator: owner/user; maintenance start and approval references remain undecided.

## A. Exact proposed policy — NOT YET APPROVED

Complete input: [policy.proposed.json](policy.proposed.json).

* File SHA-256: `30826f3fdb5c52bde2b29605e54b30b19692740fbbb97d098daf4b22a3c0b030`.
* Stable request UUID: `0b8db479-20c8-4595-9d41-d831650cba93`.
* RPC: `public.install_routing_policy(p_request uuid,p_body jsonb) RETURNS uuid`.
* File hash identifies exact UTF-8 file bytes; database policy digest hashes PostgreSQL JSONB text. These are different digests, not an expected equality.

Every row is a proposal, including values constrained by implementation. Business choices are recommendations for a small interactive FYP pilot, not measured operating assumptions or approved defaults.

| Setting | Proposed value — NOT YET APPROVED | Simple meaning and reason |
|---|---|---|
| mandatory | false | Maximize served tasks while allowing an infeasible task to remain unserved. Does not cancel/release its claim or permit expired tasks. Recommend best effort for a pilot; true makes admitted tasks compulsory and can make the whole plan infeasible. |
| horizon_minutes | 240 | Plan four hours ahead from snapshot cutoff. Short enough to fit inside a fresh six-hour claim lease. A shorter horizon excludes later availability; a longer one requires longer remaining leases. |
| dispatch_margin_minutes | 15 | Keep 15 minutes of extra lease/listing safety beyond the horizon. Admission requires expiry strictly after cutoff + 255 minutes, not merely after estimated arrival. |
| direct_service_minutes | 10 | Reserve ten minutes at an individual donor pickup for handover/loading. Owner must confirm realism. |
| hub_service_minutes | 15 | Reserve fifteen minutes at a hub batch pickup. No invented hub opening hours; captured donation windows still constrain service. |
| solver.engine | OR_TOOLS | Required engine identifier in this implementation. |
| solver.version | 9.15.6755 | Actual version installed in `.venv-stage8`, verified locally. Planner and independent validator runtime versions must match before activation. |
| solver.time_limit_seconds | 15 | Interactive per-engine solve budget. Does not include graph download, matrix construction, validation or all compared engines combined; no guarantee an HTTP job finishes in 15 seconds. |
| solver.workers | 1 | Required single solver worker for controlled comparisons. Not the count of deployed HTTP processes. |
| solver.seed | 42 | Fixed CP-SAT seed for repeatable experiments. Does not guarantee identical time-limited outcomes or mean the RoutingModel engine applies this seed. |
| solver.first_solution | PATH_CHEAPEST_ARC | Required initial route construction strategy. |
| solver.local_search | GUIDED_LOCAL_SEARCH | Required route improvement strategy. |
| solver.tie_break | TASK_ID_THEN_VEHICLE_ID | Required stable input ordering for equal choices. |
| solver.timeout_policy | VALIDATED_INCUMBENT_ONLY | On timeout, only a feasible result that passes validation may be used; an incomplete search is never fabricated into a successful route. |
| execution.fixed_cost_weight | 1.0 | Use the supplied vehicle fixed costs at their existing scale. Recommend equal weighting initially. |
| execution.distance_cost_weight | 1.0 | Use supplied per-distance costs at their existing scale. This does not mean fixed and distance costs contribute equally in every route. The objective serves tasks first, then minimizes weighted cost. |
| execution.deterministic_seconds_per_pass | 0.25 | CP-SAT deterministic search budget per pass. Start small for the pilot; this is not a RoutingModel wall-time cap or a complete job deadline. |

With the existing 360-minute lease, a newly issued lease has less than 105 minutes of age headroom at snapshot admission for this proposal. Travel, service, actual availability, vehicle capacity and return-to-depot limits can still reject a plan. The two existing expired ACTIVE leases are ineligible regardless of this choice; initialization will not recover them.

Validation completed:

* Extracted the exact policy guard from the reviewed 001 SQL, checked its normalized function-body hash, and evaluated its predicate on this JSON in an explicit DEV READ ONLY transaction: `sql_policy_guard_pass=true`. No installation RPC called.
* Complete solver object passes actual `backend.routing.contract._solver`; execution object passes actual `ExecutionConfig`, including exact supported keys, finite nonnegative values and positive combined weighting. Top-level business fields have explicit types/ranges.
* Observed local OR-Tools `9.15.6755` equals the proposed version. Actual worker process versions/configuration and authenticated runtime acceptance remain separate prerequisites.
* Fresh catalog check at **00:35:52 MYT, 27 October** confirms both RPC signatures, argument names, owner postgres, SECURITY DEFINER, hardened configuration and graph-worker EXECUTE. Function-body hashes match after the same CRLF-to-LF normalization used by postflight; raw Windows line-ending hashes differ without indicating source drift.
* Prepared read-only postflight SQL was executed as a query-only syntax/access/current-state check at **00:45:04 MYT, 27 October**. Its single evidence result confirms all 11 private routing tables and public routes/stops/assignments remain empty, source counts7/7/7/10/6/58 remain unchanged, six freeze triggers remain enabled/exact, only graph-worker among the six tested client/worker roles can execute these two RPCs, and recovery remains disabled. This was not an after-initialization PASS. Evidence: `results/routing-initialization-preparation/current-state.readonly.json`.

## B. Exact proposed graph freeze — NOT YET APPROVED

Inputs are fixed in [requests.proposed.json](requests.proposed.json):

| Input | Exact proposed value — NOT YET APPROVED |
|---|---|
| p_request | eb29d74d-d556-4135-b200-a691902cfbba |
| p_snapshot | OSM-OPS-20261018 |
| p_speed_profile | OSM_MAXSPEED_OR_CLASS_DEFAULT_BUILD_188bde7568b4d9eb_DIST5DP_TIME4DP_NO_LIVE_TRAFFIC_PG_REAL_OUTPUT_0 |
| p_precision_policy | EXACT_MAX_6_DECIMALS |
| Stored output profile | PG_REAL_OUTPUT_0, set by the existing graph-table contract; not a fifth RPC argument |
| Expected actual full-table counts | 926414 nodes / 2145828 edges |
| Lock timeout / RPC statement timeout | 5 seconds / 120 seconds; proposed limits, not measured successful DEV hashing times |

The speed-profile label describes the recorded import assumptions and CSV representation; it does not change speeds, round database values or install traffic data. Any unresolved provenance qualification below accompanies this label. Changing a label or argument requires a revised approval package; never silently change the same request payload.

### Provenance and coverage

Recorded import manifest: `supabase/road_network/output/manifest.json`; approved operational coverage at `2026-10-20T11:03:49Z`.

* OpenStreetMap via Geofabrik `malaysia-singapore-brunei-261018.osm.pbf`; OSM timestamp `2026-10-18T20:25:06Z`; ODbL 1.0 / OpenStreetMap contributor attribution required.
* Recorded PBF MD5 `962e5488d557f21ed6f8cfba88eec0ad`, SHA-256 `bc65fdec223498d6a7d8d81d56a6b5128f0c6a7010cc2473fdf6729e2eba21e7`. These PBF hashes are historical manifest records, not newly recomputed source-file verification.
* Recorded import builder SHA-256 `188bde7568b4d9eb910ddc8876f9626275669b86a4f51ed8f7afdf08371ebf23`.
* Current local builder SHA-256 `c6aa72735d24cb9b4908dc550d9dbe347b5bdbc4d860e932e0eb6bf649c69c9a`. Its LF-normalized/git version is `4991c25e58c51f4acc187373f0fdae4428594f90c5265943e30998bb1139f362`, also different. This is not explained by Windows line endings. Exact import-time builder code has not been recovered; do not rebuild with current code and claim an identical import.
* Actual nodes CSV, edges CSV and coverage SQL SHA-256 all match the recorded manifest. Exact hashes and comparison results are in `results/routing-initialization-preparation/approval-validation.json`.
* Manifest describes Peninsular Malaysian study-area polygons/coastal band, excluding Singapore, service roads and private/no-access ways; retained largest directed strongly connected component drops 12078 disconnected nodes. It is not all Malaysian roads or proof that every donor address can be snapped. Maximum permitted snap distance is 500 metres; verified depot/pickup coordinates must match the source authority.
* Actual DEV node bounds: latitude 1.2680329–6.6987306, longitude 100.1213564–104.294355. Manifest wording `minus SG and lat > 5.6` is ambiguous against the observed maximum latitude; do not infer a hard 5.6-degree cutoff from that text. Resolve intended service geography with the owner before approving wider coverage claims.
* Recorded maxspeed rule: valid numeric km/h or mph within 5–130 km/h, otherwise highway-class default. Defaults km/h: motorway90, motorway_link60, trunk70, trunk_link50, primary60, primary_link45, secondary50, secondary_link40, tertiary40, tertiary_link35, unclassified30, residential25, living_street10. Direction follows recorded one-way rules. Times are modeled, without live traffic. Current code may help interpret this manifest but is not the exact verified import builder.

### Checks already completed; no repeated full-network MCP computation

Saved inventory/endpoint evidence was observed **21:31 MYT, 26 October**. It confirms 926414 active nodes in the intended snapshot, 2145828 unique directed edges, expected coverage counts, zero invalid/nonpositive/nonfinite costs, zero missing/cross-snapshot/inactive endpoints. Three diagnostic nodes belong to this snapshot: depot1755847853 and pickups2308277456/5735535080. Pickup coordinates are diagnostics, not approval to use their expired claims.

Historical manifest: one retained strongly connected component; 25-source/573046-pair contraction comparison within 25km reported zero reachability mismatches and zero distance differences. Historical assertions do not establish today's database edge content.

Fresh offline alternative completed in 9–13 seconds across two bounded runs (the second also measured CSV representation), with a hard 60-second budget, pinned input file hashes, fixed node/edge bounds and only three BFS sources. All six distinct directed pairs (plus three self pairs) are reachable in the actual import CSVs. Observed maximum fractional decimal places are distance5/time4. It uses adjacency indexes, not a graph crop or invented edges. Evidence: `offline-reachability.json`. It does **not** prove shortest paths, paired time precision, whole-graph SCC or exact database/import equivalence.

**Current DEV directed reachability remains NOT VERIFIED.** The prior corrected read-only pgRouting query returned MCP HTTP 524 and no result rows. It was not retried. Stored component labels and equal counts cannot fill this gap.

Practical remaining check: export current DEV nodes/edges through the existing approved read-only TLS export profile into a new local directory in one REPEATABLE READ / READ ONLY transaction, then run the same bounded local BFS on those exported files. This moves graph computation off Supabase and avoids MCP response limits. See the exact read-only export command below. Keep the identity/TLS log, file hashes, snapshot observation and BFS result together; do not label arbitrary CSVs as a DEV export. The read-only export has not been run and requires the operator's local password prompt. Stop on export timeout/incomplete files or changed counts. No cropped query may establish unreachable pairs.

### Precision and downstream requirements

Both stored cost columns are REAL. They are binary floats, not lossless original source decimals. Under the required `extra_float_digits=0` serialization, all inspected distance/time texts fit at most six fractional decimals and are positive/finite. This verifies the edge projection accepted by the current code, not original-value fidelity, accurate travel predictions or all path totals.

Python C.2 uses Decimal on serialized costs, rejects unsupported precision rather than silently rounding, and finds directed shortest **distance**, with time on that same path; time and stable edge IDs break distance ties. Matrices require 1–100 unique nodes, complete selected directed pairs, zero diagonals, positive off-diagonals, and `FAIL_SCENARIO` for unavailable pairs. Real matrix generation/SQL acceptance and independently validated candidates remain untested. Freeze does not create any matrix or validate these runtime paths.

Graph-worker export must download the complete hashed node/edge relations, match total counts and profiles, then select this active snapshot. Freeze hashes entire relations, not just a chosen local area. DEV-scale memory/runtime remains unmeasured; current C.2 graph validation includes list membership checks per edge, so large-graph warm-up may be particularly slow. The 15-second solve setting does not bound this work. No operational readiness claim follows from approving freeze.

### Permanent network maintenance consequence

All six existing triggers are enabled `O`: `routing_graph_freeze` (BEFORE INSERT/UPDATE/DELETE, each row) and `routing_graph_truncate` (BEFORE TRUNCATE, each statement), on each of `public.road_network_nodes`, `public.road_network_edges`, `public.road_network_coverage`. All call `routing_private.freeze_network()`.

Once **any** `routing_private.graphs` row commits, these triggers raise `GRAPH_REVISION_FROZEN` for ordinary maintenance of all three relations, including changing coverage approval or adding another snapshot. This is global, not limited to the frozen snapshot. There is no approved refresh/retirement/unfreeze RPC. It is permanent under the current contract, not physically irreversible to a database administrator.

A later network update requires a separately designed, reviewed and approved forward contract change: graph versioning, dependent matrix/snapshot/candidate/binding consistency, active-route handling, invalidation/cache strategy, permissions, recovery and tests. Do not delete the manifest, disable triggers, widen privileges or restore DEV as an initialization rollback shortcut.

## Execution gates and separate packages

**None of these write commands may be run on this preparation request.** Review each SQL file and its exact hash in [approval-file-hashes.json](approval-file-hashes.json). Do not regenerate requests or edit files after approval; any input/hash change requires renewed approval. No 001/002/003 migration command is involved.

Common preconditions before either write:

1. Explicit approval naming operation, exact file hash, stable request/input values, target project, operator and maintenance window. Policy approval never implies graph approval, worker activation or recovery.
2. Read-only inspector confirms expected empty/partially initialized state immediately before the operation and no source/ACL/trigger drift. Reuse 003 postflight, do not replay its audit. Before A: zero policies/graphs. Before B: exactly approved policy, zero graphs. If an exact existing request is found, inspect outcome; do not blindly add another request.
3. Approved dedicated graph-login credential available locally. Observed login is NOSUPERUSER/NOBYPASSRLS/NOCREATEDB/NOCREATEROLE; graph-role membership true, planner/validator memberships false. Actual password/TLS connection for this identity is not yet tested. Missing credential or SET ROLE failure is a stop, never an owner/service-role substitute or automatic GRANT.
4. Owner pauses road imports/maintenance and competing initializers for the window, and prevents live routing operations. Allow read-only app activity; defer new claim/planning lifecycle activity if verifying unchanged source counts. Keep workers/recovery disabled. Confirm backup remains available; existing logical backup is not a verified restore point for complete managed/external recovery.

Offline preparation can be rerun without connecting: `.venv-stage8/Scripts/python.exe -B docs/stage8/stage-a/deployment-preparation/routing-initialization/prepare_package.py`. This preserves existing request UUIDs but regenerates proposed wrappers/hash records; run it before approval, never as an unreviewed post-approval step. `validate_package.ps1` contains supplementary hash/parser/static checks. Windows execution policy blocked running that helper as a script; the same documented command blocks were instead parsed as data with the built-in PowerShell parser, and hashes/wrappers checked locally with Python. No execution-policy setting was changed. These are syntax/static checks, not a claim that write RPCs were exercised.

### A — install policy

[install_routing_policy.proposed.sql](install_routing_policy.proposed.sql) uses BEGIN, SET LOCAL ROLE geolock_graph_worker, lock_timeout5s, statement_timeout30s, exact session/role/security/function-source guards, one approved RPC call, then COMMIT. It uses existing security controls and changes no definitions. Contract source MD5 after CRLF normalization: `7b3549f82b239d6c6abbd4a5fee58b4e`.

Expected delta: one row in `routing_private.policies` (or an inspected exact replay), returned policy_id, matching approved body and database-computed digest. Graphs and all other routing/lifecycle tables unchanged. Policy immutability and newest-policy selection mean this is an operating policy commitment, not a temporary preview.

**A approval gate:** owner confirms all proposed business values, software settings/version, request/hash, graph-login use and window. Recommendation: ready for this separate approval after confirming credential/window and fresh empty-state check. Graph proof gaps do not require installing an invented substitute policy.

### B — freeze graph

[freeze_routing_graph.proposed.sql](freeze_routing_graph.proposed.sql) uses a separate BEGIN/COMMIT, the same dedicated identity/role guards, lock_timeout5s and statement_timeout120s. Source MD5 after normalization: `8e1434ea2727e30f898ddff289ac2df3`. RPC takes SHARE locks on all three network tables, computes 10000-row keyset hash chains over all nodes/edges and inserts the real graph manifest. Ordinary reads continue; writers wait until transaction finishes. No matrix, route, worker or claim is created.

Expected delta: exactly one `routing_private.graphs` row for the approved request, exact snapshot/speed/precision/output profiles, actual counts926414/2145828, returned graph_id and database-derived content_digest. Record that digest; an independent full chain recomputation has not been performed. Existing network rows remain unchanged; their maintenance becomes blocked by the six existing triggers. Exactly approved policy remains. All other routing/lifecycle data unchanged.

**B approval gate: HOLD / NO-GO for execution now.** Complete current-export directed reachability or obtain an explicit narrowly stated decision to accept that remaining gap; recover exact import builder or explicitly accept the qualified historical provenance; owner confirms intended geography, float projection/model limitations, permanent global maintenance freeze, runtime/lock bounds and window. Any failed path/precision/source check requires review, not a waiver disguised as PASS. Existing source coverage approval alone is not graph-freeze approval.

### Exact Windows commands — after the respective approval only

From the repository root, common setup (no password in file/environment):

```powershell
$repo = 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$package = Join-Path $repo 'docs\stage8\stage-a\deployment-preparation\routing-initialization'
$psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
$env:PGSERVICEFILE = Join-Path $package 'pg_service.proposed.conf'
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue
$run = Join-Path $repo ('results\routing-initialization-execution\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $run -ErrorAction Stop | Out-Null
```

For **approved A only**:

```powershell
$sql = Join-Path $package 'install_routing_policy.proposed.sql'
Get-FileHash -Algorithm SHA256 -LiteralPath $sql # compare with approved hash record
$psqlArgs = @('--no-psqlrc','--password','--dbname','service=geolock_dev_graph_initializer','--file',$sql,'--output',(Join-Path $run 'policy-result.txt'))
& $psql @psqlArgs
if ($LASTEXITCODE -ne 0) { throw 'Policy failed/unknown: preserve evidence; inspect before any retry.' }
```

Run read-only postflight and review before considering B. For **separately approved B only**, create a new `$run` directory using common setup again:

```powershell
$sql = Join-Path $package 'freeze_routing_graph.proposed.sql'
Get-FileHash -Algorithm SHA256 -LiteralPath $sql # compare with approved hash record
$psqlArgs = @('--no-psqlrc','--password','--dbname','service=geolock_dev_graph_initializer','--file',$sql,'--output',(Join-Path $run 'graph-result.txt'))
& $psql @psqlArgs
if ($LASTEXITCODE -ne 0) { throw 'Freeze failed/unknown: preserve evidence; inspect before any retry.' }
```

Use `-W/--password` native secure prompt; never paste a password in chat, arguments, a repository file or logs. Session-pooler port5432 and verify-full CA settings are explicit in the proposed password-free service profile. Role guards reject an installer/export login even if its password is available. These operator psql service settings are not accepted as worker runtime DSNs.

### Immediate read-only postflight — after EACH approved operation

Codex can run [postflight.readonly.sql](postflight.readonly.sql) through the approved read-only MCP connection. Or the owner can use the existing approved read-only export profile locally:

```powershell
$env:PGSERVICEFILE = Join-Path $repo 'backups\stage-a003\pg_service.conf'
$sql = Join-Path $package 'postflight.readonly.sql'
$psqlArgs = @('--no-psqlrc','--password','--dbname','service=geolock_dev_owner_export','--file',$sql,'--output',(Join-Path $run 'postflight.txt'))
& $psql @psqlArgs
if ($LASTEXITCODE -ne 0) { throw 'Postflight incomplete: stop; do not claim PASS.' }
```

This is the previously approved read-only profile, not authorization to use the owner identity for initialization. Graph login deliberately lacks direct private-table inspection; do not grant it SELECT just to run postflight.

Evaluate results, not merely exit code: A has one exact request/body/digest policy and zero graphs; B retains that policy and has one exact request/metadata graph with nonempty 64-hex content_digest. All other 9 private routing tables stay empty; public routes/stops/assignments stay0; baseline tasks7/claims7/leases7/donations10/listings6/audits58 unchanged during the quiet window. Six freeze triggers remain enabled/exact; prior application trigger/ACL contracts remain intact; recovery job remains inactive. Time-sensitive source facts must be refreshed immediately before approval if the window is delayed. Record returned IDs, actual digests, logs, input/file hashes and observed deltas. Unexpected delta or incomplete evidence stops the next operation.

### Failure handling and recovery

ON_ERROR_STOP plus an explicit transaction means a SQL error/lock/statement timeout before COMMIT aborts the transaction; psql exits and disconnect rolls it back. Do not auto-increase timeouts, bypass guards, repair rows or change request IDs. Preserve stderr locally and all partial output files; output alone before COMMIT is not proof of installation.

Connection loss/COMMIT ambiguity: inspect by the SAME request UUID with the read-only inspector. Exact row present means committed; absent only establishes absence at inspection time. Confirm the original session/transaction ended before considering retry. Same request/same payload is the existing idempotent API contract, but retry requires outcome review; different payload raises REQUEST_CONFLICT. Freeze has a unique request constraint rather than a per-request advisory lock, so concurrent attempts can fail—allow one operator only.

After a successful A commit, a failed B leaves the approved policy installed and graph uninitialized; stop there. After successful freeze commit, there is no approved inverse operation. A backup restores only captured logical scope, not provider-managed/external state, and restorability remains unverified. Do not restore into DEV, delete manifests or disable triggers. Any post-commit defect requires a new forward-repair/recovery approval.

## Optional next read-only export for remaining reachability blocker

**Current HOLD:** the latest diagnostic `20261026T174046Z-f90cdc` still reported an authentication-failure phrase after the owner reset the DEV password. Do not retry the full export or repeat Python authentication automatically. Use the **manual independent native-client** plan in [POST_RESET_AUTHENTICATION_REVIEW.md](POST_RESET_AUTHENTICATION_REVIEW.md). Pooler cache/credential state and client differences are hypotheses; no connection/security settings have been changed. All prior failed evidence remains preserved.

**Subsequent owner-reported native PASS:** see [NATIVE_PASS_PYTHON_COMPARISON.md](NATIVE_PASS_PYTHON_COMPARISON.md). One manual Python connection-only diagnostic is now the recommended next controlled action. Full export and all routing writes remain on HOLD.

**Latest checkpoint:** that Python diagnostic failed again (`20261026T175647Z-c59e3e`). Live retries are now on HOLD. Follow the offline-only next action in [PASSWORD_INPUT_AND_NATIVE_EXPORT_REVIEW.md](PASSWORD_INPUT_AND_NATIVE_EXPORT_REVIEW.md). No further authentication or export was executed by Codex.

**Updated preparation, 27 October:** use [CURRENT_DEV_EXPORT_AND_EQUIVALENCE.md](CURRENT_DEV_EXPORT_AND_EQUIVALENCE.md). The secure operator-run Python wrapper now exports storage-bit-preserving CSVs and automatically runs the complete offline comparison plus bounded directed reachability. It reuses the exact approved read-only profile, enforces READ ONLY and certificate validation, prompts securely in the operator console and creates a new output directory. It does not run any write RPC.

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
& '.\.venv-stage8\Scripts\python.exe' -B '.\docs\stage8\stage-a\deployment-preparation\routing-initialization\export_current_dev.py' --export
if ($LASTEXITCODE -ne 0) { throw 'Export/comparison incomplete or failed; preserve evidence. No equivalence PASS.' }
```

**Actual full current-DEV comparison is NOT VERIFIED: password-prompted local export has not run.** Coverage WKB/metadata and seven small REAL conversion probes passed independently; source CSV ordering/expected REAL precision passed a full offline reference scan. These are scoped preparation results, not database equivalence or current reachability PASS. Policy hash/request remain unchanged; review [POLICY_BUSINESS_REVIEW.md](POLICY_BUSINESS_REVIEW.md) for all values and the strict255-minute remaining-lease requirement.

The old `export-reachability.readonly.sql` is retained as historical draft only. It lacks storage hex and the new capture receipt, so its output is not sufficient input to the new comparison. Supply only the new export directory/report, never a password. Additional real pilot nodes need their own pair checks; the present expired claims remain ineligible.

## Decisions and recommended next action

1. Approve or change the seven top-level policy fields and every nested value; confirm the proposed 240/15/10/15-minute assumptions and best-effort service choice.
2. Confirm the actual intended FYP service geography and decide whether the recorded import is acceptable with the explicit missing-builder qualification. Prefer locating the exact import builder before irreversible freeze.
3. Complete current DEV export/BFS proof, or explicitly accept the specific remaining database reachability/equivalence uncertainty. Historical/offline PASS must never be relabeled current-DEV PASS.
4. Explicitly accept REAL projection/model limitations and the permanent all-network maintenance lockout, or defer freeze for a separately reviewed versioning design.
5. Name the maintenance start/window (MYT), confirm yourself as operator, graph credential availability, exact timeout budgets and separate A/B approval references/hashes. No policy/freeze write is authorized yet.

**Recommendation:** perform the read-only current export next; policy is technically validated and ready for its own exact-operation approval once owner choices/credential/window are confirmed. Hold graph-freeze execution for the reachability/provenance/maintenance decisions. Workers, independent validator deployment, full graph warm-up performance, eligible claims/vehicles, matrices/candidates/attestations and Flutter end-to-end testing remain later separately approved work. P11 history, C.5 runtime, restore and managed/external backup limitations remain recorded; none are silently resolved by initialization.
