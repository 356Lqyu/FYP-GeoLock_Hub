# Chapter 5 readiness after Stage B

No formal experiments ran. All eight tracks remain PARTIAL. The detailed design,
metrics, seeds, outputs, repetitions and statistics in
`../stage-a/CHAPTER5_READINESS.md` remain applicable; Option A RoutingModel below
supersedes its unresolved engine choice, without adopting new formal baselines.

| Track | Reusable runner/implementation | Dataset / baselines | Repeats / seeds | Evidence / criteria / remaining prerequisites |
|---|---|---|---|---|
| A Atomic claims | `supabase/tests/claim_concurrency_test.py`, protected SQL, Stage B transaction seams | Fresh claimable listing, distinct eligible NGO identities; non-atomic / protected-no-recovery / full | 2/5/10 NGOs, **50 independent trials per condition per worker count**; frozen schedule/seeds | requests.jsonl, trials.csv, committed_states.jsonl, audit/failures; latency ms, outcomes, duplicate rate, one winner; needs 5-NGO formal controller/reset/source-pinned baseline adapters and real eligibility/Auth |
| B Lease/recovery | Current recovery/reconciliation; `claim_recovery_*isolated_test.py` | 100 frozen independent lease cases; no-recovery vs full, safe/uncertain custody strata | Prespecified case/clock schedule, six-hour no-renewal | lease_cases.csv, expiry/recovery/reclaim timeline, invariant/audit logs; success %, release lag, zero unsafe release; needs formal controller, restart/whole-batch/recovery-race coverage and separately approved natural-expiry pilot |
| C Road eligibility | Road functions/preflight; synthetic graph export/matrix seam | Directed below/equal/above 20 km; 500 m snap; reverse/missing/coverage boundaries | Freeze oracle count/seeds before outcomes; no invented sample size | eligibility_pairs.csv, graph/snap hashes, raw m/decision/latency; exact oracle agreement; needs actual PostGIS/pgRouting and boundary runner; Stage B doubles prove no geography |
| D Hub baselines | `baseline implementation/source code/{nearest_hub_baseline,random_hub_baseline,weighted_hub_baseline}.py` | Same feasible heldout groups; nearest/seeded random vs weighted reference policy | Existing 337 test groups if validated; frozen random seed schedule | per-group rankings/splits/seeds; Top-1, NDCG@3, coverage, infeasible count; needs common policy-parity evaluator/new-output wrapper; protect retained results |
| E AI ranking | Existing 1368/295/337 split/feature work | 2,000 complete groups; RF/XGBoost policy approximation, same heldout baselines | 30 random configurations/family, 5-fold GroupKFold training; validation Top-1 then NDCG@3 then MAE; untouched test | Model/preprocessor/search/split hashes; Top-1/NDCG@3/coverage/MAE; needs trainer/controller/pinned ML runtime; zero leakage/infeasible choice; no observed-preference claim |
| F Aggregation | Direct-household baseline and protected hub lifecycle | 100 matched original-donation scenarios, direct vs hub; equal fleet/depot/matrix/solver | One paired execution/scenario; technical repeats dependent | Original IDs, donor/NGO km, dispatch/cost units, handling and batch invariants; needs paired builder/controller and full current hub acceptance; no operational 10 kg bypass |
| G Routing | `backend/routing/phase_b/benchmark.py`, real RoutingModel, gated `benchmark_v32/runner.py` | 100 immutable snapshots; Nearest-Next primary, FCFS descriptive, distance-only supplementary | PATH_CHEAPEST_ARC/GLS, 30-second upper bound, one native worker; seed/repeat policy unresolved | Input/matrix digests, candidates/validation, served %, km/min/cost units/status/runtime/timeout; zero invalid accepted plans; needs approved manifest/objective/repeat policy and bridge exclusion review; NONREPRODUCIBLE_RESULT remains blocking |
| H Validation | Independent `phase_b/validation.py`, work-item path, tamper tests/SQL schedule recheck | Every G plan plus frozen negative corpus | All 100 snapshots/methods; freeze extra negative count/seeds | validation.jsonl/digests/task accounting/violations/runtime; zero false acceptance in declared corpus; needs remaining SQL negatives and real gateway/worker separation; no authority from attestation alone |

Formal runs need fresh immutable outputs, input/source/environment hashes and raw
failures/unknown outcomes. Requests are not distinct NGOs or independent trials;
stops are not independent empirical units. Invalid plans cannot count as success.
Retain all 337 heldout groups if that manifest is approved. Use the Stage A
protocol's Wilson 95%, paired McNemar/Wilcoxon-Pratt, effect estimates and paired
bootstrap (10,000; seed 20260915), with within-RQ Holm adjustment where specified.
Model cost units are not observed RM. Preserve 10 kg, 360 minutes and no renewal.
