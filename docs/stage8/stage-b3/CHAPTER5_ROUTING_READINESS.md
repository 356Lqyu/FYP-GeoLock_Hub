# Chapter 5 routing readiness after Stage B.3

**PARTIAL for formal experiments. B.3 local diagnostic investigation is complete.**
No Chapter 5 experiment ran; 24 synthetic runs are technical verification only.
No changes to B.4/Stage C work or deployment assumptions are made here.

## Verified configuration

- OR-Tools 9.15.6755; native single-threaded RoutingModel CP, CP-SAT fallback off.
- PATH_CHEAPEST_ARC; GUIDED_LOCAL_SEARCH; unchanged coverage-first/secondary cost.
- Shared 30-second per-snapshot search/model budget, not 30 seconds per pass.
- 240-minute maximum per vehicle; 10-minute service; capacity/windows and required
  depot departure/return; fixed directed graph-derived matrix per scenario.
- Stable task/vehicle input order and exact/scaled numeric handling unchanged.
- Declared seed 42 is not a supported RoutingModel seed parameter. No CP-SAT
  deterministic-time/seed setting was silently translated.

## Repeatability evidence

Eight frozen synthetic scenarios × three fresh processes = 24 runs. All inputs,
matrices, route/vehicle assignments, objective/metrics, native statuses and strict
semantic results match within each case. 21 feasible plans and three proven
infeasibility reports pass independent consistency validation. Eighteen runs reach
the search limit; six finish early. Raw artifact digests vary with measured
runtime, as expected from the unchanged candidate payload/hash contract.

Original 60-run short replay varied only in timing-derived timeout metadata.
Native-limit correction yields one result across the corrected 60-run replay.
The original guard accepts all eight saved groups and still rejects a controlled
semantic mutation. It remains unchanged and active.

## Required formal preparation

Retain the report's 100 immutable paired snapshots, primary Nearest-Next versus
proposed RoutingModel comparison, FCFS descriptive and distance-only supplementary
baselines. Freeze eligible/claimed task sets, graph/matrix provenance, fleet,
depot, cost policy, windows, service, lease/cutoff and source/environment manifests.
Review the benchmark bridge/exclusions and resolve any stale legacy metadata
before a formal manifest is approved. No current diagnostic result authorizes
that freeze or operational dispatch.

The inactive proposal recommends prespecified technical repeats and per-snapshot
median/range/IQR, with snapshot-level paired tests/resampling and retained failed,
timeout, no-incumbent and invalid outcomes. Three diagnostic repeats are not
independent empirical samples or evidence for narrow confidence intervals.
Approve repetition count, balanced execution order, aggregation and failure
denominators before any formal run. Preserve existing report statistical rules
unless a change is separately approved; never silently report the best repeat.

## Required raw evidence and acceptance

Save frozen inputs and graph/matrix hashes, task/vehicle ordering, actual native
search protobufs, solver/runtime/hardware versions, source hashes, raw plan bytes,
PostgreSQL candidate digests where operational, route/objective components,
distance/travel/service/waiting/return durations, load/window invariants, runtime,
native status/limit flags, independent validation and all rejected/unknown cases.
Keep exact replay artifacts distinct from new computations with different
telemetry. A diagnostic route fingerprint must not replace a bound candidate hash.

Current acceptance still requires input/config parity, valid independent reports,
feasibility for positive cases and the unchanged strict semantic guard. Any
semantic mismatch stops the guarded run pending review. Native success does not
prove a global optimum; proven infeasibility is not a successful zero-distance
route. Operational pickup additionally requires all existing database authority
checks and explicit authorization; this stage does not establish deployed parity.

See REPORT.md for results and REPRODUCIBILITY_POLICY_PROPOSAL.md for the
**NOT ACTIVATED** policy. Universal/cross-platform repeatability, representative
corpus behavior, real gateway acceptance and deployment remain unverified.
