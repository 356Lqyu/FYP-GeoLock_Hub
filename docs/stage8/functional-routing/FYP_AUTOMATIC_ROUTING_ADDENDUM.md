# FYP implementation addendum for automatic route authorization

28 October 2026. Implementation description only; no new DEV experiment or
supervisor approval is claimed. Original report, supervisor material and authority
contract documents are preserved. This addendum describes the locally tested
implementation proposed for their next reviewed revision.

## Requirement traceability

The provided report requires valid post-claim tasks, immutable reproducible inputs,
independent validation, authoritative current-state checks and protected dispatch.
The supplied supervisor material requires equal-input baselines and constraint
validation; it does not mandate a manual departure picker. Coordination Authority
Contract 11.4–11.10 preserves the same input/algorithm/validator/authority boundaries.
Its historical 12.8 dispatch-gap note predates deployed A003 and is not used to
describe the current database contract as unenforced.

The UI now records a single explicit NGO intent: Generate & Authorize Route. The
optimizer remains advisory; after independent attestation, an orchestrator requests
authorization through the NGO's existing protected PostgreSQL RPC. Database time
is selected internally in the reviewed new NULL/AUTO_NOW mode. No route-planning
result by itself grants dispatch authority or changes donation ownership/custody.

Planned departure, actual first pickup start and per-stop start are distinct.
Waiting after authorization does not extend a claim lease. Start Pickup rechecks
the remaining route and can reject a previously authorized plan when its current
state/windows/leases no longer permit safe completion and return. Each subsequent
stop and actual handover remains an explicit protected operation.

## Research method remains unchanged

All four methods continue to receive the same frozen tasks, vehicles, depot, matrix,
constraints, solver settings and configuration. The Proposed objective remains
lexicographic: minimise unserved valid tasks, then fixed vehicle plus distance
operating cost. FCFS, Nearest Neighbour and Distance Only are hidden from NGO UI,
not deleted from Python experiments or retained raw outputs. Database retiming is
an operational authorization step, not a replacement for the nominal benchmark
schedule or a change to solver comparisons. Retain failure/timeout/incumbent and
optimality qualifications in Chapter 5.

## Evidence claims

The earlier physical phone result remains evidence of an ATTESTED saved Proposed
candidate, 110 kg from 50+60 kg, and working marker-map rendering. It does not prove
dispatch or actual physical collection. The automatic workflow is verified only
in local Flutter/Python tests and a disposable real PostgreSQL/validator lane with
documented auth/platform adapters. No real DEV authorization/pickup experiment
was conducted or simulated as an actual handover.

For report/contract revision, update the UI sequence/diagram, NULL/AUTO_NOW API
semantics, distinct time definitions, single-button consent, idempotency/uncertain
response handling and delayed-start revalidation. Do not rewrite historical
results, change the research objective, or infer formal supervisor acceptance of
new wording from this implementation.
