# Inactive reproducibility policy proposal

**PROPOSAL ONLY — NOT APPROVED OR ACTIVATED.** The existing benchmark guard stays
unchanged. The diagnostic classifier is not imported by the worker, optimizer,
validator, benchmark or authorization code. No claim/route authority policy changes.

## Five distinct requirements

1. **Input reproducibility:** retain immutable scenario and matrix artifacts,
   canonical hashes, cutoff, task/vehicle/node order, ownership/lease/source
   facts, capacity/windows, depot and configuration. Different admitted tasks or
   constraints are different experiments, even if routes look similar.
2. **Execution reproducibility:** pin Python/environment, OR-Tools 9.15.6755,
   native single-threaded RoutingModel CP, PATH_CHEAPEST_ARC, GUIDED_LOCAL_SEARCH,
   30-second total per-snapshot budget, 240-minute route horizon and 10-minute
   service. Preserve complete effective native parameters for both passes. The
   current coverage-first/secondary-cost algorithm and shared-budget allocation
   are unchanged. Declared seed 42 is metadata: this native RoutingModel API has
   no supported seed setting; never claim it was applied or translate CP-SAT seed/
   deterministic work settings. Measure total runtime and native search time
   separately; budget is an upper bound, not a mandatory 30-second delay.
3. **Solution reproducibility:** report exact ordered routes/vehicle assignment
   equality as an observed property. Do not promise universal identical routes
   for wall-time-limited local search or equate a different valid tied solution
   with invalidity. A byte-level serialization check and a route-content check
   answer different questions.
4. **Metric reproducibility:** compare coverage/unserved first, then objective,
   distance, service/waiting/total duration, fleet usage and runtime. Preserve
   every outcome and actual native status. Different valid results are reported
   as variability, never silently collapsed to the best repetition. Equal metrics
   can coexist with different route order. Timeout with a validated incumbent is
   different from no incumbent, invalid output or proven infeasibility.
5. **Authority reproducibility:** planning and these diagnostic comparisons grant
   no authority. Each operational candidate must pass independent validation and
   existing database ownership, active-lease, source-freshness, attestation and
   explicit authorization guards. Exact payload/digest binding and request replay
   must remain. An infeasibility report may be validation-consistent but cannot
   proceed to pickup.

## Candidate and digest handling

Keep the existing candidate payload and PostgreSQL jsonb digest contract. Raw
candidate payload includes measured runtime fields; independent recomputations
can therefore have different candidate bytes/digests even with identical routes.
This is not a SHA-256 nondeterminism defect. Retain the precise payload and actual
digest of each artifact. Same-request retry should replay the persisted computed
payload and candidate, not solve again expecting the same runtime values.

A local route/metric fingerprint is diagnostic only and must never replace the
database candidate digest, attestation digest or authorization binding. Removing
runtime fields from the operational hash or splitting the bound payload would
change the protected contract and requires separate approval. No such correction
is implemented in B.3.

## Statistical treatment proposed for later Chapter 5 approval

The three B.3 repetitions per scenario are diagnostic technical repeats, not
independent empirical units or a basis for narrow stability confidence intervals.
For formal RQ4, retain the 100 frozen paired snapshots required by the report.
Pre-register the repetition count, balanced method/run order, aggregation and
failure handling before running. One candidate policy is three technical repeats
with per-snapshot median plus range/IQR for continuous metrics; do not select the
best run after seeing outcomes. This is a proposal, not an approved formal count.

Use snapshot-level paired comparisons and clustered/paired resampling where
technical repeats exist; never treat 300 technical runs or individual stops as
300 independent scenarios. Preserve coverage and infeasible/timeout/no-incumbent/
invalid rates alongside continuous results. Do not present zero-distance empty
plans as routing improvements. Retain the existing report protocol's paired
Wilcoxon-Pratt, effect estimates, intervals and within-RQ multiplicity treatment
where applicable; freeze any methodological amendment before formal execution.

## Proposed acceptance conditions

Frozen inputs/configuration/environment must match; every raw plan must be
retained and independently validated. Positive scenarios require feasible plans;
declared infeasible cases must be identified explicitly with justified proof flags.
Record runtime/search-limit termination without inferring global optimality.
Store discrepancies, excluded/blocked tasks, native status, objective components
and all hashes. Invalid routes cannot count as successful solutions.

**Until approved otherwise, any semantic mismatch still triggers the existing
NONREPRODUCIBLE_RESULT guard.** The proposal supplies interpretation and future
study design, not an activated exception. If a future corpus produces different
valid semantic plans, stop the guarded run and request review of this policy;
do not disable the guard or discard the variation.

Primary references for interpretation:
- https://developers.google.com/optimization/routing/routing_options
- https://github.com/google/or-tools/blob/v9.15/ortools/constraint_solver/routing.h
- https://github.com/google/or-tools/blob/v9.15/ortools/constraint_solver/routing_enums.proto
