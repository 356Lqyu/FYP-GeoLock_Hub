# Stage 8 Phase B Offline Routing Results and Phase C Proposal

Phase B implements four offline routing approaches, a separate independent route
validator and a reproducible synthetic benchmark. All 54 accepted Phase A tests
and its 17 source/fixture files are preserved byte-for-byte. The complete suite
passes 117 tests (54 original + 63 new). No live integration was implemented.

The benchmark runs all four methods against the same 21 immutable scenarios,
three repetitions each: 252 executions and 84 comparison rows. Every execution
passed independent route/report validation, and each method reproduced its
non-timing result across repetitions. There were zero capacity, time-window,
duration or other hard validation violations in accepted output reports.

## Sources and authority boundary

Design references remain the supplied v3.2 contract Sections 11.2-11.8 and 12,
thesis Algorithms 7-9/Equations 4.12-4.17, supervisor Stage 8 PDF pages 14-15,
the accepted Phase A contract/architecture, and captured 24 October DEV evidence.
Exact document paths/fingerprints are in phase-a-dev-evidence.json and the Phase A
architecture report. No fresh database verification is claimed in this phase.

The explicit Phase B request supersedes the earlier architecture's suggestion
to begin Phase B with a live snapshot adapter: this phase is entirely offline.
No Supabase MCP calls, database mutations, migrations, fleet RPCs, Flutter changes,
cron changes, credential changes or existing lifecycle-function changes occurred.
Input assertions/hashes do not grant ownership or prove current database state.

## Implementations

| Method | Implementation | Selection objective |
|---|---|---|
| FCFS | backend/routing/phase_b/baselines.py: fcfs | Creation instant then task ID; fixed vehicle order; defer infeasible candidates. |
| Nearest-neighbour | Same module: nearest_neighbour | Shortest feasible directed next arc, task ID tie, fixed vehicle order. |
| Distance-only | backend/routing/phase_b/optimizers.py: distance_only | Prove minimum unserved count, fix coverage, minimize raw directed km. |
| Proposed aggregated VRP | Same module: proposed | Prove minimum unserved count, fix coverage, minimize configurable fixed + distance operating cost. |

Both optimizers use Google OR-Tools 9.15.6755 CP-SAT optional-node circuit and
integer constraint modelling. There is no custom VRP search. Mandatory pickups
are hard constraints; the primary objective maximizes other admitted task coverage
subject to mandatory feasibility. Model constraints cover ownership-admitted
membership, exactly-once assignment, cumulative pickup capacity, time windows,
service/waiting, same depot start/return, maximum duration and unavailable arcs.

All methods plan the existing frozen direct/hub-batch task set. A hub batch is
already aggregated before routing and remains one pickup at its selected hub.
The proposed method does not create/regroup batches, pick alternative hubs,
create claims or change custody. Its aggregation benefit is conditional on those
already-authorized batch inputs; this experiment does not measure a new aggregator.

## Objective distinction from the thesis

The thesis Algorithm 8/Equation 4.16 uses distance as its secondary objective.
The distance_only implementation preserves that coverage-then-distance design.
The user-requested proposed method instead minimizes:

`fixed_weight * sum(fixed_cost of used vehicles) + distance_weight *
sum(vehicle distance_cost_per_km * route km)`

Default weights are 1 and 1; weights/configuration are recorded separately from
the immutable input. Primary unserved count is never traded for cheap cost via
an arbitrary penalty. Only a proven first-pass optimum allows the secondary pass.
If proof is unavailable at the search limit, the incumbent/proof status is retained
honestly and a secondary optimum is not claimed. Thesis wording should identify
the monetary-cost version as an explicit extension rather than equating it with
distance optimization. All example costs are synthetic cost units, not MYR or
measured NGO operating costs.

## Independent validation

validation.py is separate from the solving modules and imports no solver-side
feasibility/schedule/arc helpers or OR-Tools. It independently recomputes from the
raw frozen Phase A input using Decimal arithmetic:

- Every served task exactly once; no duplicate/unauthorized tasks or vehicle trips.
- Exact served/unserved complement and unserved reasons; exclusions kept separate.
- Owned available vehicle and correct NGO depot start/return.
- Authorized donor or selected hub pickup location/node.
- Every traversed directed matrix arc AVAILABLE; no null-to-zero substitution.
- Every pickup load prefix within capacity; reported load independently checked.
- Travel, waiting, service duration, pickup-window start and service completion.
- Maximum vehicle/scenario duration including required depot return.
- Lease validity through service plus margin and stale-input/hash rejection.
- Mandatory service, or an explicit infeasible/failure report with feasible=false.

Reported solver success and OPTIMAL labels do not bypass these checks. Corruption
tests include duplicate stops, foreign tasks/vehicles, wrong hubs/depots, fabricated
arrival/service/return/load, over-capacity, expired/blocked source authority,
missing arcs, incorrect unserved lists and attempted offline dispatch authority.

`validation_valid=true` means the report is internally consistent. A truthful
infeasible/blocked report is validation-valid but is not a feasible plan. In
particular, zero travel for a failed run is never interpreted as an improvement.
Heuristic failure to serve a mandatory task marks that candidate INFEASIBLE;
it does not prove that no different plan exists. CP-SAT INFEASIBLE is distinguished
with infeasibility_proven=true for the defined model.

## Benchmark results

The main run has 34 COMPLETE, 6 feasible PARTIAL, 20 INFEASIBLE, 12 NO_VALID_TASKS,
8 ROUTE_UNAVAILABLE and 4 NO_FEASIBLE_PLAN comparison rows. That is 40 feasible
plans and 44 honest infeasible/blocked reports among 84 comparisons. Each was
executed three times. No main-run search budget was exhausted; real primary and
secondary timeout/fallback behavior is covered by the unit/integration tests.

| Synthetic scenario | FCFS | Nearest-neighbour | Distance-only | Proposed |
|---|---|---|---|---|
| Original mixed direct + batch | 2 served; 15.5 km; 51 min; 2 routes; cost 30.7 | Same | 2 served; 11 km; 42 min; 1 route; cost 21.2 | Same |
| Vehicle cost tradeoff | 2 served; 11 km; cost 111 | Same | 2 served; 11 km; cost 111 | 2 served; 15.5 km; cost 17.5 |
| Urgent optional hub pickup | 1 served/1 unserved; 4.5 km | Same | 2 served/0 unserved; 11 km | Same |
| Coverage over very large fixed cost | 2 served | 2 served | 2 served | 2 served despite fixed cost 1,000,000 |
| Disconnected optional hub | Direct served, hub explicitly unserved | Same | Same coverage | Same coverage |
| Mandatory capacity/window/duration/no-return failures | Candidate explicitly infeasible | Same | Model infeasibility proven | Model infeasibility proven |

The urgent case demonstrates why raw distance is interpreted after task coverage:
the greedy methods travel less because they miss a valid task. The cost-tradeoff
case demonstrates that the monetary objective may deliberately increase distance
to avoid an expensive vehicle. It does not establish real operational savings.

Both optimizers prove coverage and secondary optimality for their 10 feasible
cases in this small benchmark. Their genuinely available fixed-coverage secondary
gaps are zero. Other rows and all heuristic gaps are N/A. Raw scaled incumbent and
lower bound, gap scope, runtime, proof flags and timeout status are retained.

Runtime is measured and intentionally not part of the deterministic result hash.
Measured method and solver runtimes, repetition ranges and medians are recorded
for every comparison in CSV/JSON. These tiny synthetic timings are environment-
specific, not scalability or operational latency evidence. Re-running the benchmark
will change timing fields without changing the non-timing result digest.

## Artifacts and reproducibility

- results/stage8-phase-b/comparison.md: readable all-case comparison.
- comparison.csv / comparison.json: distance, summed route duration, vehicles/
  routes, served/unserved IDs/counts, violations, runtime min/median/max, solver
  runtime, timeout/status, genuine gap/bounds and objective components.
- results.json: all 252 plan/validation executions and per-stop evidence.
- snapshots.json: exact 21 sealed inputs and shared snapshot/matrix hashes.
- non-timing-results.json + manifest.json: deterministic result content/digest,
  code/package/environment/configuration evidence.
- docs/stage8/phase-b-phase-a-preservation.json: original 17 file hashes, checked
  before and after every benchmark run.

All nine Phase A fixtures are unchanged. Twelve additional cases are reproducible
transformations in phase_b/scenarios.py. The synthetic line-graph method and its
directed km/minute edge values remain documented in the Phase A README. Missing
data and graph disconnection are distinct; no value is represented as a live
Supabase road-network measurement. Synthetic fleet edits never enter real NGO data.

Execution instructions and dependency locks are in backend/routing/phase_b/README.md.
Validated commands:

```powershell
.\.venv-stage8\Scripts\python.exe -m unittest discover -s backend/routing -t . -p 'test*.py' -q
.\.venv-stage8\Scripts\python.exe -m backend.routing.generate_examples --check
.\.venv-stage8\Scripts\python.exe -m backend.routing.phase_b.benchmark --output results/stage8-phase-b --repeats 3
```

## Limitations and decisions still requiring review

1. Twenty-one small constructed cases establish correctness properties, not
   representative geography, operational savings, statistical significance or
   large-instance solver scalability. Broader matched benchmark evaluation is
   still required before thesis effectiveness claims.
2. CP-SAT is a mature solver with explicit proof/bounds, but this integer circuit
   model has quadratic arc growth per vehicle. Larger instances may need a
   separately evaluated OR-Tools RoutingModel adapter or another mature solver.
   The existing input contract can remain unchanged.
3. Phase A RoutingModel first_solution/local_search fields are preserved but not
   applied by CP-SAT. The manifest explicitly records the actual engine/settings.
   Seed/single worker/stable construction support pinned-environment replay, not
   a promise of the lexicographically smallest tied optimum or portable wall-time
   reproducibility. This engine choice needs review before live integration.
4. Integer precision/range is explicit: microsecond times, millionths of kg/km/
   cost, conservative 2^53 bounds. Unsupported values fail instead of rounding.
   Freeze production numeric/time resolution and cost-currency policy in Phase C.
5. One trip per vehicle, fixed cutoff departure, pickup-only loads, no reloads,
   split service, traffic, driver breaks, perishable-specific rules or overlapping
   vehicle bookings. Current heuristics are conservative about immediate return
   feasibility and do not backtrack or repair missed urgent tasks.
6. Mandatory tasks are hard constraints in the optimizer. An infeasible mandatory
   request returns no optimizer dispatch plan. Whether a separately approved
   partial operational pickup plan is allowed requires a new explicit policy;
   it must never be silently published as fully feasible.
7. Source tokens in synthetic fixtures are fictional labels; offline validation
   checks supplied state and hashes, not live authentication, physical custody or
   current authority. A real immutable producer and final DB-time revalidation
   remain necessary. The prior dispatch bypass, audit/replay gaps and inactive
   recovery cron are unchanged; no new readiness claim is made for those systems.
8. Approve real fleet costs/capacities/availability, service durations, donor and
   hub window derivation, lease margin, unavailable-arc policy, matrix path policy,
   solver budget/weights and the manual-pickup compatibility policy before live
   migrations or screens. None is inferred from the toy defaults.

## Proposed Phase C Live Integration Plan

Phase C requires separate user approval and review of concrete database changes.

1. **Owned vehicle management.** Extend the existing vehicles entity with explicit
   type, costs/currency, maximum duration, planning availability and versioning.
   Keep NGO registration unchanged and permit zero/multiple vehicles. Protected
   idempotent RPCs derive ownership from authentication, reject foreign updates,
   audit changes and retain referenced history. Configure real values explicitly;
   never copy synthetic fleet defaults. Add busy-window/reservation protection
   against overlapping dispatches using the same vehicle.
2. **Authoritative immutable snapshots.** Add reviewed planning-run/task/exclusion
   persistence. A protected NGO-scoped producer uses one DB cutoff and consistent
   canonical joins for active claim/lease/listing/task/source, membership and
   reconciliation/assignment guards. Freeze actual source versions or an approved
   canonical state-token projection, verified depot/location generation, fleet,
   windows, service policy and configuration. Snapshot creation cannot claim,
   release, renew, reassign or dispatch anything.
3. **Operational road matrices.** Acquire paired directed distance/time on the
   same actual shortest-distance edge path from one approved pinned graph. Record
   graph/edge/speed-profile provenance, search scope, units, method, matrix hash
   and missing/unreachable distinctions. Current distance-only cropped eligibility
   helper is insufficient. Resolve immutable edge-snapshot binding and cache
   invalidation; never substitute synthetic matrices or live-traffic claims.
4. **Live planning and independent acceptance.** Consume the exact contract with
   explicit owned fleet; persist method results separately from frozen inputs.
   Re-run independent validation before protected acceptance/publication. Store
   plan/validation digests, solver environment, objective/proof/timeout/bounds,
   served/unserved/mandatory evidence and all relevant version references.
5. **Database-enforced dispatch authority.** Revalidate current identity, vehicle,
   depot, graph/matrix, claim/lease/listing/task/source versions, custody and
   remaining lease time using fresh DB time in a protected transaction. Bind a
   short-lived single-use permit to the exact NGO/vehicle/validated plan/snapshot/
   tasks/claims/leases, then consume it atomically with dispatch and audit. Preserve
   existing lifecycle transitions; reconcile lock order with current writers.
   Add idempotent result lookup for outcome-unknown retries.
6. **Close every bypass.** Adding a validated wrapper while leaving direct
   start_pickup unrestricted does not enforce routing safety. After explicit
   approval, introduce a shared gate covering every dispatch entry point. Review
   a validated single-stop depot-return path for legitimate individual pickups,
   or an explicitly separate manual policy with documented safeguards. Do not
   silently block existing authorized behavior or call manual pickup validated
   routing. No start_pickup/claim/lease changes were made in Phase B.
7. **Isolated tests, then reviewed DEV rollout.** Exercise stale location/vehicle/
   graph changes, foreign owners, concurrent use, expiry/recovery/dispatch races,
   disputed custody, permit reuse, replay and unknown outcomes against an isolated
   database first. Review migration/RPC diffs and rollback checks before any DEV
   mutation. Keep recovery cron and unrelated lifecycle/audit fixes under their
   own approvals. Flutter fleet/route screens follow protected backend acceptance.

Phase B stops here. No Phase C implementation, migration or live dispatch is
authorized by this report.

Official solver reference: [Google OR-Tools CP-SAT](https://developers.google.com/optimization/cp/cp_solver/)
documents integer modelling and OPTIMAL/FEASIBLE/INFEASIBLE/UNKNOWN statuses;
[solver limits](https://developers.google.com/optimization/cp/cp_tasks) documents
bounded search. Actual environment/version/bounds above come from the executed
pinned solver and captured benchmark outputs.
