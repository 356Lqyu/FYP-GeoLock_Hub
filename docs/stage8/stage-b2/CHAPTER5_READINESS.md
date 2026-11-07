# Chapter 5 readiness after Stage B.2

All eight **formal experiment tracks remain PARTIAL**. B.2 completes only local
spatial corrections/regressions and this accounting. No final experiment was run.
The detailed protocol in `../stage-a/CHAPTER5_READINESS.md` and the eight-track
matrix in `../stage-b/CHAPTER5_READINESS.md` remain reference specifications;
this update supersedes their unavailable-local-spatial status only for the
synthetic cases actually executed in B.1/B.2.

| Track | Current evidence / reusable runner | Remaining prerequisite and formal protocol |
|---|---|---|
| A Atomic claims, RQ2 | Current protected claim; Stage B contention seams; B.2 real spatial claim/replay/audit smoke; `supabase/tests/claim_concurrency_test.py` | Current-version disposable formal controller and baseline adapters; **2/5/10 distinct eligible NGOs, 50 independent trials per condition per worker count**. Freeze seeds/request schedules, collect request timings/outcomes/committed authority/audit/failure receipts. One winner, no duplicate authority; requests are not independent trials. |
| B Lease/recovery, RQ2 | Current SQL and Stage B reserved-task/reconciliation tests; existing `claim_recovery_*isolated_test.py` | 100 declared independent cases, controlled disposable fixture clock, safe/uncertain custody strata; recovery-versus-pickup/whole-batch/crash verification still open. Preserve 360 minutes/no renewal. Log expiry/recovery/reclaim timeline, lag, invariants and audit; no live timestamp manipulation. |
| C Road eligibility, RQ2 | **Real PG17/PostGIS3.6.2/pgRouting4.0.1, corrected helper SQL; 69 B.2 checks**, including all 22 previous spatial cases. Runner: `stage8_spatial_correction_isolated_test.py` | Freeze a formal oracle case manifest/count/seeds. Expand graph/coverage/snap/component/precision cases and performance on trusted OSM data; compare versions only with separate authorization. Retain raw m, expected/actual outcomes, graph hashes and latency. Current tiny graph is synthetic verification, not empirical geographic accuracy. |
| D Deterministic hub baselines, RQ1 | Existing Nearest-Hub, seeded Random-Hub and weighted reference code under `baseline implementation/source code/` | Common feasible-set/policy evaluator and immutable-output wrapper. Validate existing 337 heldout groups, freeze seed schedule and tie policy. Collect Top-1/NDCG@3/coverage/runtime and infeasible selections without overwriting results. |
| E AI hub ranking, RQ1 | Existing 1368/295/337 split manifest and feature work | RF/XGBoost trainer/search/controller and pinned ML runtime. 2,000 complete grouped scenarios, 30 random configurations/family, training 5-fold GroupKFold; validation Top-1 then NDCG@3 then MAE. Freeze selected model before untouched test; zero leakage/infeasible choices. Save split/search/model/preprocessor hashes and per-group rankings. |
| F Hub aggregation vs direct, RQ3 | Existing direct-household baseline and protected hub lifecycle; current whole-batch runtime acceptance unexecuted | 100 matched original-donation scenarios, same fleet/depot/matrix/downstream solver. Protected batch/member/inventory/collection verification first. Freeze scenarios/seeds; record donor and NGO km, dispatches, cost units and capacity/membership invariants. No operational 10 kg bypass. |
| G Post-claim route optimization, RQ4 | Actual RoutingModel primary plus FCFS/Nearest-Next/distance-only; existing `phase_b/benchmark.py` and gated benchmark_v32 runner | Resolve NONREPRODUCIBLE_RESULT, repeated 30-second verification and supported seed/repeat policy. Then freeze 100 immutable paired snapshots, 240-minute limit, 10-minute service, same directed matrix/constraints, 30-second budget and one native worker. Save plans/status/runtime/timeouts/digests; independent validation mandatory; no unproven optimality. |
| H Independent feasibility validation, RQ4 | Existing independent validator, tamper tests, SQL schedule recheck; B.2 matrix agreement and unreachable-arc checks | All G outputs across 100 snapshots plus a prespecified negative corpus; real gateway/role separation and remaining SQL negatives still open. Freeze counts/seeds and record digest/task accounting/violations/runtime. No invalid route counted successful; attestation grants no authority. |

Across tracks: preserve raw failed/unknown outcomes and denominators; frozen
inputs/source/environment/seed manifests; new output directories. Retain Wilson
95% intervals, paired McNemar/Wilcoxon-Pratt and effect estimates/paired bootstrap
(10,000, seed 20260915), with within-RQ Holm correction where specified by the
Stage A protocol. Model cost indices are not observed RM. No track becomes
COMPLETE because a local unit/regression suite passes.
