# Full-graph provisional workload measurements — 7 November 2026 MYT

**Offline modeled entities only. No authoritative DB snapshot metadata, grants, receipts or deployment approval were created.**
The complete sealed graph and all four unchanged methods were used. Separate processes run the independent raw-input plan validator. Production source-envelope/RPC attestation and authorization are not simulated or claimed.

## Workload provenance

Case sizes (3/10/25/100 pickups; 2/2/5/10 vehicles) were explicitly treated as provisional by the user. Their relation to actual NGO demand is unknown. The source template is the existing synthetic GEOLOCK-BM-v3.3 fixture; no original CSV or previous result was overwritten.

| Case | Pickups | Vehicles | Required road nodes |
| --- | ---: | ---: | ---: |
| small | 3 | 2 | 4 |
| typical-provisional | 10 | 2 | 11 |
| large-provisional | 25 | 5 | 26 |
| source-boundary-stress | 100 | 10 | 100 |

Selected source: SCN-ROUTE_PLANNING-0045, with 223 matched public benchmark road nodes within 17 km. Largest selected straight-line distance is 16.950 km. This is coordinate-based model locality, not observed trips or independently verified current DEV coordinates.
The graph remains complete for every shortest-path search; connectivity filtering selects workload locations only. At 100 pickups, two modeled tasks share one of 99 pickup nodes, plus the depot. Counts are not asserted to be real-world maxima.
Legacy/compact matrix parity at 100 nodes: PASS; compact 64.83 s, legacy 180.00 s (preparation run, 8 GiB / 2 CPU).
Raw graph matrix source tags are wrapped as SYNTHETIC_BENCHMARK for the unchanged benchmark contract; numeric costs, path policy, graph version and tie behavior are unchanged. Local frozen-input hashes/state tokens are not PostgreSQL digests or authority.

Inherited model policy: direct-only pickups; 10-minute service; optional tasks; 240-minute horizon; historical synthetic cutoff/windows/leases; 100kg/500kg vehicle templates; 30s solver wall budget, one worker, seed42, unchanged deterministic 0.25s per pass. Do not assume this is the current DEV policy.

## Planner results

| Case / profile | Process wall s | CPU s | Peak RSS MiB | Cgroup peak MiB | Proposed served / pickups | Proposed usable | Solver timeout flag | Review screen |
| --- | ---: | ---: | ---: | ---: | --- | --- | --- | --- |
| small-8gb-2cpu-planner | 9.69 | 9.49 | 279.5 | 331.3 | 3/3 | True | False | CANDIDATE |
| small-512mb-0.1cpu-planner | 52.90 | 5.40 | 280.0 | 271.1 | 3/3 | True | False | CANDIDATE |
| small-2gb-1cpu-planner | 5.24 | 5.14 | 280.1 | 271.3 | 3/3 | True | False | CANDIDATE |
| small-4gb-2cpu-planner | 4.65 | 5.06 | 279.8 | 270.8 | 3/3 | True | False | CANDIDATE |
| typical-provisional-8gb-2cpu-planner | 11.58 | 12.06 | 310.8 | 264.9 | 10/10 | True | True | CANDIDATE |
| typical-provisional-512mb-0.1cpu-planner | 121.79 | 12.28 | 310.7 | 264.6 | 10/10 | True | True | NO |
| typical-provisional-2gb-1cpu-planner | 9.78 | 9.80 | 310.6 | 264.7 | 10/10 | True | True | CANDIDATE |
| typical-provisional-4gb-2cpu-planner | 8.73 | 9.18 | 310.5 | 264.9 | 10/10 | True | True | CANDIDATE |
| large-provisional-8gb-2cpu-planner | 22.20 | 22.65 | 323.3 | 295.9 | 0/25 | False | True | NO |
| large-provisional-512mb-0.1cpu-planner | 256.61 | 25.76 | 322.7 | 296.2 | 0/25 | False | True | NO |
| large-provisional-2gb-1cpu-planner | 19.19 | 19.19 | 324.9 | 296.5 | 0/25 | False | True | NO |
| large-provisional-4gb-2cpu-planner | 21.53 | 21.94 | 323.0 | 296.1 | 0/25 | False | True | NO |
| source-boundary-stress-8gb-2cpu-planner | 85.01 | 85.02 | 543.8 | 499.3 | 0/100 | False | True | NO |
| source-boundary-stress-512mb-0.1cpu-planner | 300.48 (controller) | N/A | N/A | N/A | N/A | No result | HARNESS TIMEOUT | NO |
| source-boundary-stress-2gb-1cpu-planner | 84.75 | 84.67 | 543.3 | 498.9 | 0/100 | False | True | NO |
| source-boundary-stress-4gb-2cpu-planner | 86.95 | 87.25 | 543.4 | 498.3 | 0/100 | False | True | NO |

Review screen (an explicit engineering assumption, not a provider guarantee): require a usable independently valid proposed route, <=120s process wall time (30s nominal reserve inside the app 150s POST budget), and at least 30% RAM reserve after taking the larger of observed process/cgroup peaks plus a conservative 72 MiB extra cold-artifact page-cache allowance. No host cache flush was performed. Passing is a local model candidate, not deployment approval.
A timeout flag with a valid feasible incumbent is distinguished from UNKNOWN/no incumbent. Partial heuristic routes and structurally valid no-route reports do not make the required proposed candidate usable. No solver budget/objective was changed and no baseline route was substituted for authorization.

## Separate independent plan validator

| Case / profile | Wall s | CPU s | RSS MiB | Cgroup MiB | Four reports structurally valid | Proposed usable | Plan source |
| --- | ---: | ---: | ---: | ---: | --- | --- | --- |
| small-512mb-0.1cpu-validator | 4.198 | 0.515 | 24.5 | 16.4 | True | True | small-512mb-0.1cpu-planner-plans.json |
| small-2gb-1cpu-validator | 0.325 | 0.397 | 24.5 | 16.2 | True | True | small-2gb-1cpu-planner-plans.json |
| small-4gb-2cpu-validator | 0.429 | 0.510 | 24.7 | 16.0 | True | True | small-4gb-2cpu-planner-plans.json |
| small-8gb-2cpu-validator | 0.407 | 0.497 | 24.5 | 16.4 | True | True | small-8gb-2cpu-planner-plans.json |
| typical-provisional-512mb-0.1cpu-validator | 3.796 | 0.439 | 24.6 | 16.2 | True | True | typical-provisional-512mb-0.1cpu-planner-plans.json |
| typical-provisional-2gb-1cpu-validator | 0.448 | 0.538 | 24.7 | 16.4 | True | True | typical-provisional-2gb-1cpu-planner-plans.json |
| typical-provisional-4gb-2cpu-validator | 0.602 | 0.716 | 24.5 | 16.7 | True | True | typical-provisional-4gb-2cpu-planner-plans.json |
| typical-provisional-8gb-2cpu-validator | 0.526 | 0.690 | 25.0 | 16.6 | True | True | typical-provisional-8gb-2cpu-planner-plans.json |
| large-provisional-512mb-0.1cpu-validator | 4.794 | 0.558 | 24.7 | 16.4 | True | False | large-provisional-512mb-0.1cpu-planner-plans.json |
| large-provisional-2gb-1cpu-validator | 0.714 | 0.793 | 24.7 | 16.4 | True | False | large-provisional-2gb-1cpu-planner-plans.json |
| large-provisional-4gb-2cpu-validator | 0.700 | 0.837 | 25.0 | 16.6 | True | False | large-provisional-4gb-2cpu-planner-plans.json |
| large-provisional-8gb-2cpu-validator | 0.742 | 0.853 | 24.6 | 16.0 | True | False | large-provisional-8gb-2cpu-planner-plans.json |
| source-boundary-stress-512mb-0.1cpu-validator | 10.692 | 1.169 | 31.4 | 22.8 | True | False | source-boundary-stress-8gb-2cpu-planner-plans.json |
| source-boundary-stress-2gb-1cpu-validator | 1.041 | 1.142 | 31.0 | 22.8 | True | False | source-boundary-stress-2gb-1cpu-planner-plans.json |
| source-boundary-stress-4gb-2cpu-validator | 0.895 | 0.994 | 31.2 | 22.8 | True | False | source-boundary-stress-4gb-2cpu-planner-plans.json |
| source-boundary-stress-8gb-2cpu-validator | 1.502 | 1.740 | 31.3 | 22.7 | True | False | source-boundary-stress-8gb-2cpu-planner-plans.json |

Where a planner failed before producing plans, validator-only measurements use the completed 8 GiB reference plans; this is not recovery or proof that the failed planner succeeded. The validator checks all four plans/reports, including baseline routes and correctly unusable CP-SAT outcomes. It does not attest a DB work item or issue database authorization.
512 MiB / 0.1 CPU is the minimum tested raw-plan-validator profile if all its rows pass with headroom. Actual trusted validator source reads, DB joins/digests, TLS/network latency and private work-item shape remain unmeasured here.

## Limits and unresolved prerequisites

One depot, direct pickups, one deterministic modeled location selection and one run per profile do not establish a fleet/demand distribution, worst geography, hub batching/body-size behavior, concurrency, P95 latency or an actual Render CPU/memory SLA. The initial depot had only 77 matching in-radius nodes, and another sample depot did not exist in the frozen graph; preparation switched explicitly to the matching 223-node depot. Initial failed preparation receipts remain in the parent folder.
No production routing/grant/journal code changed in this stage. Real work-item envelopes, current operational policy, provider ingress, actual backup/recovery and deployment approval remain separate prerequisites. PostgreSQL journal replacement is design-only; see ROUTING_HOSTING_RECOVERY_OPTIONS.md.
