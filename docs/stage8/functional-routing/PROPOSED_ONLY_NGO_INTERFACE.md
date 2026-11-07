# Proposed only NGO routing interface

Implemented locally on 27 October 2026. No DEV database reads or writes, live
planning requests, authorization, pickup actions, recovery, service restarts or
graph probes were performed for this implementation. Existing DEV candidates,
snapshots, audits, routing policy and frozen graph were not altered.

## User interface

Only the Proposed method is rendered to NGO users. All four methods remain in
the worker response and Python research pipeline, including original metrics,
inputs, solver settings and independent validation. The lexicographic objective
and candidate payload/digest contract are unchanged.

Each vehicle has its own card: snapshot vehicle label, road-matrix distance,
estimated elapsed route duration including service/waiting/depot return, assigned
load, pickup/task count, distinct pickup-location count and ordered pickup list.
Names and addresses are display metadata obtained through existing owned reads;
they never replace snapshot coordinates, weights or authority. Missing metadata
is explicitly unavailable rather than invented. Address reads have a bounded
eight-second total budget and cannot cause a planning retry.

The selected card shows Google Maps depot and numbered pickup markers. The depot
marker represents both start and return. The polyline set is empty. The interface
says "Road geometry unavailable" and distinguishes modeled times from live traffic.
The existing Android Maps key configuration is reused without changing credentials.

## Displaying the existing successful candidate

The app preserves its existing request/snapshot IDs across `adb install -r`.
When the saved status is candidate_ready or infeasible, use **View saved Proposed
result (read only)**. This explicitly calls authenticated POST
`/v1/planning-result` with those IDs, never `/v1/plan` and never the snapshot RPC.

The planner validates the real NGO JWT and matching local-journal owner/request.
Journal retrieval uses SQLite mode=ro and query_only. It reads the existing sealed
snapshot bundle through read_routing_snapshot_bundle, projects summary data and
returns the original advisory receipt. No optimizer, graph load, candidate submit,
attestation, freshness assertion or business write is performed. Historical results
may be displayed when stale; protected database authorization must still recheck
current state. Foreign-owner/wrong-request requests fail before the bundle read.
The stored journal result is not rewritten. A missing endpoint/result never falls
back to planning. Completed saved results disable the Generate button until the
user explicitly starts a new request; no new request is approved by this document.

If app storage or the original worker journal was cleared, the saved-result button
may not be available. Do not regenerate, clear preferences or guess IDs to fix that;
inspect preserved evidence read-only first.

## Runtime loading and authority boundary

The APK alone cannot add presentation fields or the read-only endpoint to an
already running planner. Loading those changes requires a separately approved
restart of the existing planner with the same protected profile, original native
credential handling and approved activation reference. The validator protocol and
implementation are unchanged; no validator restart is needed for this change.
Do not start a second planner instance or enable recovery.

After approval, while idle, stop the existing planner gracefully in its terminal.
From the repository root, the reviewed startup command is:

```powershell
$ref = Read-Host 'Existing approved service-activation reference'
.\backend\routing\worker_service\windows\Start-Worker.ps1 -Mode planner -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -Activate -ApprovalRef $ref
```

No new activation/reference approval is inferred from this document. No startup
command was executed by Codex. A health check and viewing a saved result are read
operations; Generate, database authorization and pickup operations remain separate.

Departure selection and authorization require CANDIDATE_READY, candidate ID and
ATTESTED validation. Generation and viewing never authorize dispatch. Existing
authorize_my_routing_candidate, start_pickup, complete_pickup and
close_my_collected_route calls retain the protected database lifecycle. Current
lease/claim validity must be checked by those contracts, not inferred from a map.

## Offline verification

- 33 focused Python integration/worker/event tests passed, including exact
  preservation of all research outputs/inputs, per-route totals, owned saved
  retrieval without replanning, historical receipt preservation and foreign-owner
  rejection.
- 48 focused Flutter tests passed, covering Proposed-only display, multi-vehicle
  selection, summary values, numbered/depot markers, invalid/mismatched coordinates,
  explicit authorization gates, saved read transport without planning fallback,
  pending request preservation, connection-button visibility and replay of an
  existing local PostgreSQL lifecycle capture. The replay is not live DEV evidence.
- Changed Flutter production files and the new UI test pass static analysis.
- Phone map tiles, real JWT saved-result retrieval and the new UI have not yet been
  tested live. Offline map tests use a renderer double; they do not prove Google
  Maps key restrictions, billing or tile availability.

## Exact road geometry options

1. Recommended: create a separate immutable geometry artifact offline from the
   original pinned OSM source and verified import/contraction mapping. Retain the
   exact deterministic distance/time/edge-ID path used for each matrix leg. Map its
   directed edges to original OSM shape points; verify orientation, continuity,
   endpoint identity, REAL-aware stored-cost agreement and binding to graph ID,
   digest, matrix, candidate and ordered stops. Ambiguous parallel ways must be
   resolved from evidence, not guessed. Add appropriate OSM attribution. This can
   avoid frozen-road-table changes, subject to actually recovering the mapping.
2. If original shapes cannot be verified: retain markers only for the current
   graph, and design a future explicitly approved versioned graph/geometry import.
   Do not mutate or relabel the frozen historical graph. A migration/import would
   require its own review and approval.
3. Google Directions could only be an explicitly separate navigation estimate in
   future. It cannot be described as the optimizer's exact path or used to replace
   its frozen distance/time metrics. No Directions integration was implemented.

The frozen export omits node coordinates, edges have no shape column, and recorded
contraction removes intermediate OSM nodes. The current builder differs from the
recorded import-time hash. Exact geometry is therefore NOT VERIFIED. No geometry
artifact, source provenance, graph contract or frozen table was modified.

The verified APK path, SHA-256, build flags and changed-file hashes are recorded in
results/proposed-only-routing/verification.json. Install that named APK with -r;
never uninstall/clear data or replace it with an unconfigured generic build.
