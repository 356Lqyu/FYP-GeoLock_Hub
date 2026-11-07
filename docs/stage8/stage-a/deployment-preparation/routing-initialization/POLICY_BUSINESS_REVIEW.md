# GeoLock Hub policy business review — NOT YET APPROVED

All 17 leaf values below remain proposals, not approvals. JSON and request are unchanged:

* File: `policy.proposed.json`.
* SHA-256: `30826f3fdb5c52bde2b29605e54b30b19692740fbbb97d098daf4b22a3c0b030`.
* Stable request UUID: `0b8db479-20c8-4595-9d41-d831650cba93`.

| Exact field | Proposed value — NOT YET APPROVED | Meaning / recommendation |
|---|---|---|
| mandatory | false | Best effort: maximize tasks served but allow a task that cannot fit to remain unserved. Appropriate for a small FYP fleet. No implicit claim cancellation/recovery. Approve this business behavior or choose compulsory admission with greater whole-plan infeasibility risk. |
| horizon_minutes | 240 | Four-hour plan from snapshot cutoff. Suitable for same-session pickup/return demonstrations if planning starts promptly after claiming; not permission to retain expired claims. Keep if this matches your demo duration; consider a separately approved 120/180-minute horizon if claims commonly wait longer before planning. JSON stays240 until you decide. |
| dispatch_margin_minutes | 15 | Require another15 minutes of source-validity reserve beyond the entire horizon. Reasonable pilot buffer, not a measured guarantee against dispatch delays. Recommend keep15 and plan promptly. |
| direct_service_minutes | 10 | Ten minutes for donor handover/loading per direct stop. Plausible pilot assumption; confirm actual process/load size. Adjust before approval if unrealistic. |
| hub_service_minutes | 15 | Fifteen minutes for batch collection at a hub. Confirm the intended batch size; not a new hub opening-hours rule. |
| solver.engine | OR_TOOLS | Required implemented engine. Keep. |
| solver.version | 9.15.6755 | Verified installed locally. Keep, and ensure planner/independent validator deploy this exact version. Any upgrade needs renewed software/policy review. |
| solver.time_limit_seconds | 15 | Initial per-engine solve budget for an interactive FYP. Keep for initial pilot measurement; it does not bound full graph loading, matrices, all engine comparisons or HTTP latency. |
| solver.workers | 1 | Required single search worker. Keep; raising it violates the current contract. |
| solver.seed | 42 | Fixed experimental CP-SAT seed. Keep for comparison consistency; it is not a business priority and does not guarantee identical time-limited results. RoutingModel does not apply every CP-SAT setting. |
| solver.first_solution | PATH_CHEAPEST_ARC | Required initial route-building strategy. Keep. |
| solver.local_search | GUIDED_LOCAL_SEARCH | Required route-improvement strategy. Keep. |
| solver.tie_break | TASK_ID_THEN_VEHICLE_ID | Required stable ordering for reproducible inputs. Keep. |
| solver.timeout_policy | VALIDATED_INCUMBENT_ONLY | Use a timed-out solver's best result only if valid/feasible; never fabricate a successful route. Keep. Independent attestation/backend authorization still required. |
| execution.fixed_cost_weight | 1.0 | Preserve the supplied fixed vehicle-cost scale. Sensible neutral pilot starting point. Confirm that activating another vehicle should incur its real recorded fixed cost. |
| execution.distance_cost_weight | 1.0 | Preserve the supplied per-distance cost scale. Task service has first priority, weighted cost second. Equal weights do not mean equal cost contributions. Recommend keep until actual comparisons justify a business change. |
| execution.deterministic_seconds_per_pass | 0.25 | Small CP-SAT deterministic effort budget per pass; initial pilot responsiveness choice. Not a RoutingModel wall-clock limit or guarantee of optimality. Recommend keep initially, then assess actual solver results. |

`solver` and `execution` are the two JSON objects containing their listed fields; no additional unlisted policy fields are proposed. Required strategy constants/workers are implementation constraints, not freely adjustable business switches.

## Lease check: 240 + 15 against 360 minutes

Actual `routing_private.admissible` requires:

`lease.expires_at > snapshot.cutoff + horizon_minutes + dispatch_margin_minutes`

For this policy: **remaining lease strictly greater than255 minutes**. An expiring listing, when present, must also be valid strictly beyond this cutoff. Admission is deliberately stronger than merely reaching the stop before lease expiry.

| Snapshot age relative to a newly issued360-minute lease | Remaining lease | Lease part of admission |
|---|---:|---|
| Immediately after issue | about360min | Fits255min requirement |
| 60min after issue | 300min | Fits |
| 104min after issue | 256min | Fits |
| Exactly105min after issue | 255min | **Fails**, strict greater-than |
| Later or already expired | <=255min | Fails |

Thus four hours plus15 minutes fits the six-hour lease only while the claim is **less than105 minutes old**, assuming the actual lease lasts360 minutes. Equality/time precision and the actual issued/expires timestamps matter. This is not a105-minute grace period after snapshot: all later authorization/start guards still apply. Snapshot freshness, actual departure, return-to-depot, availability windows, vehicle capacity and service completion may still prevent routing. The two expired ACTIVE leases cannot be used and will not be renewed/recovered by this policy.

If your expected workflow is claim→plan promptly→pickup during that four-hour window, retain240/15. If NGOs should wait two or more hours after claiming before planning,240 is restrictive; choose a shorter horizon through a new explicit policy approval rather than extending claims, suppressing guards or silently editing this JSON.

## Decisions needed

1. Confirm best-effort service (`mandatory=false`) and expected claim-to-planning delay/horizon. This is the most important business choice.
2. Confirm10-minute donor and15-minute hub service assumptions against your actual handover process.
3. Confirm the fifteen-minute reserve and neutral1.0/1.0 cost weighting.
4. Accept the initial15-second solve/0.25 deterministic budgets as pilot settings, with actual latency/feasibility still to be measured. Keep required solver constants/version/workers.
5. When ready, give separate explicit approval for the exact policy file hash/request, graph-login operator and maintenance window. Business review or export completion alone does not authorize installation; graph freeze/worker activation remain separate approvals.

Complete SQL/Python policy validation already passed in the existing package. This review does not modify the JSON, UUID, installed database policy or migration files.
