# Graph updates: decision before the first freeze

27 October2026. Design assessment only; no SQL migration drafted/applied, no DEV
connection, freeze, worker activation or business-data mutation. Owner reports policy
80db858b-93e8-4a0a-94e2-dbe14940f0a1 installed; no independent policy postflight
performed in this assessment. StageA003 and the approved policy inputs are unchanged.

## What the current schema supports

* routing_private.graphs is append-only and permits multiple graph UUIDs/requests.
  Matrices reference graph_id; snapshots reference matrices; candidates, bindings
  and routes preserve their evidence chain. Worker caches are keyed by graph UUID.
* This is artifact identity, NOT independently stored historical road versions.
  network_digest hashes the entire public node/edge relations; read_frozen_routing_graph
  pages those same relations for ANY graph UUID, without version filtering.
* Public nodes have global osm_node_id PK; edges have global (source_node,target_node)
  PK and no snapshot column; coverage allows just one active OPERATIONAL snapshot.
  Two revisions sharing OSM IDs cannot simply coexist in these relations.
* freeze_network rejects INSERT/UPDATE/DELETE/TRUNCATE globally on nodes, edges and
  coverage once any graph manifest exists. graphs itself forbids UPDATE/DELETE/TRUNCATE.
* Matrix node admission uses current public nodes. Location resolution, eligibility
  and depot checks also depend on the active public road snapshot. Changing just
  worker configuration or read_frozen_routing_graph would leave these inconsistent.

Sources: supabase/migrations/20261020_operational_road_node_resolution.sql;
StageA001 routing_authority SQL; StageA002 publication SQL;
backend/routing/worker_service/graph_cache.py; backend/routing/integration/graph_worker.py.
Existing captured schema/contract evidence is reused; no fresh DEV catalog read.

Conclusion: no migration is needed for the verified current graph's first pilot.
A forward migration IS needed for safe future road replacement/versioning, whether
introduced before or after the first freeze. Multiple manifests do not solve it.

## A — freeze now, implement replacement later (recommended for first pilot)

Freeze the currently verified OSM-OPS-20261018 data with the unchanged reviewed
operation after separate approval. Keep all public road data immutable. Retain the
native export/receipt/report, source artifacts, returned graph manifest/digest and
all routing evidence. Complete policy postflight, graph postflight, scoped worker
readiness/warm-up, activation approval and the real Flutter pilot.

Advantages: no new contract migration, preserves existing claims and all evidence,
least delay and smallest immediate regression risk. Existing independent-validator
and NGO authorization paths stay intact. Scoped storage equivalence and six
diagnostic directed pairs already PASS; do not repeat the export.

Tradeoff: ordinary road updates are unavailable until a reviewed forward migration
is implemented. Freeze is permanent under TODAY'S contract, not physically
irreversible to a future approved schema change. This is NOT permission to delete
manifests, disable triggers or overwrite roads later. Later implementation must
archive and verify the original frozen dataset before any replacement, and prove
the original graph UUID still exports the original rows/digest. More accumulated
live work can make the eventual maintenance window harder to schedule.

Remaining freeze decisions: accept historical builder/PBF qualifications, intended
pilot geography/snaps, modeled time/REAL representation, global maintenance block
and named lock/statement-timeout window. Full-size graph warm-up/matrix performance
is an activation prerequisite, not something the source comparison demonstrated.

## B — minimum safe controlled replacement before freeze

Use maintenance-window replacement, NOT simultaneous live multi-version operation.
Keep existing public tables as the single operational projection so Flutter and
claim APIs do not need a broad rewrite. Add the following in a NEW reviewed migration;
these are proposed concepts, not existing tables or RPC names:

1. Private immutable per-graph node, edge and coverage storage, keyed by graph UUID
   plus source ID. Retain original generated edge IDs, full hashed node/edge rows,
   profiles, provenance and coverage; enforce both endpoints within the version.
   Snapshot current data before it can change. Preserve the current hash algorithm
   and old manifest values; supplemental archive/coverage verification must not
   rewrite old immutable manifests. Stage future imports outside live public roads.
2. A verified mapping from each graph UUID to its retained dataset. Adapt protected
   graph export/hash verification and matrix-node validation to use that exact
   dataset. Existing and new cache keys remain graph UUIDs. Old export results,
   matrices, candidates, routes and audits must remain interpretable unchanged.
3. An explicit approved active-graph pointer plus append-only activation history.
   Graph-worker import/freeze must not implicitly activate. Separate maintenance
   approval/role authorizes activation; graph/planner/validator runtime logins get
   no direct DML or arbitrary maintenance privilege. Fail on wrong role, missing
   verification, digest mismatch, payload conflict or concurrent activation.
4. Activation under a serialized maintenance window: stop new claim/planning work,
   quiesce workers/in-flight transactions and require no affected live claims,
   ACTIVE leases, assigned/in-progress routes or vehicle holds. Expired ACTIVE leases
   still count as unresolved; reconcile only by a separately approved lifecycle
   action, never force-clear them. If a drain cannot be proven, activation fails.
   New graph selection applies only to new planning; preserved old snapshots and
   candidates cannot acquire fresh authority against a mismatched active graph.
5. Atomically publish the verified staged roads to the public projection and move
   the active pointer through a tightly bounded maintenance operation. Replace the
   unconditional freeze guard with equally restrictive version/maintenance guards
   in the migration; never bypass it ad hoc. Keep source eligibility, resolver,
   vehicle/depot and listing triggers consistent. For the minimum design, reject a
   replacement that removes/changes any referenced node anchor without an explicit
   reviewed remapping plan. Do not silently clear listing/depot/task node fields.
   New-geography or coordinate-changing activation may therefore remain blocked.

All old historical data remains retained; already completed work is not rewritten.
Any abort before activation COMMIT leaves the current graph selected. Selecting a
prior version again is another explicitly approved activation subject to the same
drain/source checks, not deletion or a general backup restore.

Required local tests before approval: old/new datasets with overlapping IDs;
old graph export and digest unchanged after staging/activation; complete endpoint/
precision/provenance checks; wrong-role/direct-write rejection; unverified activation
rejection; live/expired ACTIVE claim and active-route/hold rejection; stale candidate
fail-closed; concurrent activation; rollback/crash outcomes; actual resolver/depot/
eligibility behavior and the existing complete local routing lifecycle. Measure
archive/publication locks, storage headroom and DEV-scale copying/hash time.

This is more than changing one trigger or adding a version column. It requires
SQL and worker integration work plus regression testing; no reliable fixed duration
is established. At this graph size, retained archive plus staged/live rows also
require a storage-capacity check. No extra testing environment is proposed; reuse
the existing disposable LOCAL integration harness.

## Comparison and decision

| | A: freeze now | B: controlled replacement first |
|---|---|---|
| Immediate contract changes | None | New forward migration + RPC/worker integration |
| First Flutter pilot | Shortest existing path | Delayed until version/activation regressions pass |
| Current claims/routes/evidence | Stay unchanged | Must be protected by version storage and drain gates |
| Future imports | Blocked until future reviewed migration | Staged immutable versions supported after implementation |
| Future activation | New approved migration/window required | Explicit approval + quiet/drained window; no automatic switch |
| Main risk | Maintenance constraint persists until later work | New source/permission/cutover regressions before first pilot |

Recommendation: A if the verified road snapshot covers the first pilot and updates
are not needed during it. Freeze does not foreclose a later safe forward migration;
it prevents unsafe ordinary updates. Choose B only if update capability must exist
before the first freeze. If uninterrupted routing across changing geographies is
required, neither the minimum drained-replacement design nor a trigger patch is
sufficient; full version-aware business anchors would be a larger separate design.

Next concrete step: owner chooses A or B. For A, first review the installed policy's
read-only postflight, then prepare the existing exact freeze approval/window with
the maintenance limitation expressly accepted. For B, authorize LOCAL implementation
and tests of the forward design only; DEV migration approval stays separate.
