# E2 and E4 reproducible benchmark results

Executed locally on 5 November 2026. **E2 readiness: PARTIAL. E4 readiness: PARTIAL.** The actual proposed implementations execute in isolation and all requested scenario counts completed. These labels reflect observed errors and methodology differences, not missing runs. No shared Supabase connection, hosted worker, deployment, production change or push was used.

## Requirements and provenance

The original report is `C:\Users\User\Downloads\RSW_LimQianYu_LowSusan_FullText.docx`, SHA256 `fc0db20769d2117907173b317a19824b8784a1ba46603407cda8d79d19ad5c5b`. Section 3.8.2 requires comparable frozen valid-task inputs. Section 3.8.3/Table 3.9 specifies 50 contention trials at each of 2/5/10 requests, 100 lease-expiry trials and 100 paired routing scenarios. Section 3.8.5 covers freezes, versions and seeds; Appendix Table A.4 records parameters. Treat a complete scenario/trial as the experimental unit, not each competing request or pickup.

Supervisor reply: `C:\Users\User\Downloads\第6组_Lim Qian Yu与Low Susan_GeoLock Hub.pdf`, SHA256 `7b0d2b3a86239f85cbb1f76bd03b08c295cfa9132a04bd8a600c762258c9bb61`. Pages 14–15, Stage 8, require fixed inputs, research baselines, a mature solver, independent validation and metrics; pages 19–20 discuss E4 comparisons. Neither these documents nor this execution constitute fresh approval of a changed admission policy or solver-method description.

Teammate source was located in `C:\Users\User\Downloads\FYP-GeoLock_Hub-ss (1)\FYP-GeoLock_Hub-ss`. Its `baseline implementation/source code/README.md` and `baseline implementation/postgresql/README.md` define the implemented benchmark. Existing algorithms were loaded unchanged. Original result files were retained.

Inputs: **GEOLOCK-BM-v3.3**, **OSM-DIRECTED-v3.3**, seed **20260915**. All 15 CSVs in the supplied ZIP/extraction have LF transport bytes, whereas the generation manifest declares CRLF hashes. Restoring only CRLF into the separate `experiments/repro_inputs/v33/` mirror matches every declared CSV SHA256 and row count exactly. Original files were not rewritten; per-file transport/source/canonical evidence is in each run manifest. The supplied manifest SHA256 is `139c823a20753e16bf1d6c0aea137ff03a171b57def95723d1be9bd4c66afe34`; its CRLF representation is `5fdafca9baa69c4e1c84eb843d180ff0e2ea6319fccf02ae033a6d3fb595d16a`, matching historical run metadata. No rows, matrices or scenarios were regenerated.

Revision: `df626175c1413249ec2fceb314e0df431d5e692b`, with existing unrelated dirty work preserved. Per-file source hashes, rather than HEAD alone, identify execution. Python 3.12.14; psycopg 3.3.6; PostgreSQL 17.11; native PostGIS 3.6.2 in the baseline database; OR-Tools 9.15.6755. Package versions and native checksums are in `experiments/repro_environment.json` and `experiments/repro_runtime_checksums.json`.

## E2: actual PostgreSQL execution

Final run: `experiments/e2_atomic_claiming/results/e2-20261105-v33-actual-01/`. Proposed: all 150 contention, 100 expired-lease and 25 active-lease scenarios completed. Both baselines ran all supported cases: 150 non-atomic contention cases and 275 protected-without-recovery cases. Total: **700 method/scenario evaluations**, including 450 contention and 250 lease cases. Non-atomic lease recovery is not implemented and is not counted as a pass.

The real current protected claim and recovery function bodies ran with database locks, constraints, lifecycle and audit. Normalized source MD5: claim `2c1f60c876797c61b44b3cb43591bab8`, recovery `05fe46d8b76085f71c87fcc5f6520775`. Source stability is recorded. Auth/Storage/cron and road eligibility are local adapters: the latter reads the exact frozen directed matrix. Relative historical ages replay against server time as in the original driver. The full current schema includes the reconciliation migration applied only to the disposable local fixture. The baseline schema omits only its optional pgcrypto extension load because this private DLL is incompatible and PG17 provides core UUID generation; no claim/recovery body was replaced.

| Method | Contention trials | Duplicate trials | Exactly one committed claim | Success responses | Conflicts | Database errors |
|---|---:|---:|---:|---:|---:|---:|
| Original non-atomic | 150 | 150 | 0 | 753 | 97 | 0 |
| Original protected, no recovery | 150 | 0 | 150 | 150 | 700 | 0 |
| Actual GeoLock | 150 | 0 | 150 | 150 | 9 | **691** |

Non-atomic produced 603 extra committed claims. Its exact number depends on scheduling; reproduction establishes duplicate failure, not byte-identical historical request outcomes. GeoLock maintained single ownership, but **691 of 850 contention requests returned generic ERROR following SQLSTATE 40P01 (deadlock)**. Every such request has a matching rollback-confirmed failure-audit entry. This is not clean conflict handling or an overall functional pass. The original driver's retry covers raised transient exceptions; the actual RPC catches the database exception and returns ERROR, so that exception retry does not mask these outcomes.

| Method | Expired lease replacements | Active lease incorrect releases | Lease request errors |
|---|---:|---:|---:|
| Original protected, no recovery | 0/100 | 0/25 | 0 |
| Actual GeoLock | **100/100** | **0/25** | **0** |

All 275 proposed committed-state captures have exactly one active owner. Expired cases replace the previous holder; active cases retain it. Actual original-holder setup calls are separate from measured competing/replacement request latencies.

| Concurrent requests | Non-atomic median / p95 ms | Protected baseline median / p95 ms | Actual GeoLock median / p95 ms |
|---|---:|---:|---:|
| 2 | 130.700 / 233.215 | 102.300 / 155.295 | 1055.950 / 1109.310 |
| 5 | 176.050 / 273.810 | 131.400 / 201.695 | 3049.150 / 4103.485 |
| 10 | 236.800 / 398.370 | 163.300 / 258.210 | 5096.750 / 9142.620 |

Latency includes error responses. The baseline's older V3 schema includes a documented FOR NO KEY UPDATE correction, while current GeoLock retains FOR UPDATE and additional lifecycle/audit work. The known lock-mode issue is a plausible explanation for deadlocks, but SQLSTATE evidence alone does not establish an identical lock graph for every failure. No production fix was attempted. These differences prevent causal attribution of runtime solely to atomic locking. All methods used the same local cluster, READ COMMITTED isolation, actors/scenarios, request barriers, frozen road inputs, 360-minute leases and configured retry behavior.

## E4: actual current optimizer execution

Final run: `experiments/e4_post_claim_routing/results/e4-20261105-v33-actual-02/`. All **100 frozen scenario IDs** executed for all three methods. The proposed callable is the actual `backend.routing.phase_b.optimizers.proposed`, exported by `METHODS` and used by the worker's `solve_bundle`; this is not a substitute optimizer. It uses CP-SAT, seed 42, one solver worker, 30-second total wall budget (15 seconds/pass), 0.25 deterministic seconds/pass, maximizing served tasks before minimizing directed road km. Legacy metadata still mentions RoutingModel/cost; actual source and plan objective metadata record the executed method.

Original Nearest-Next and FCFS were also rerun on the original 500-task admission. Both reproduce **all 100 published non-runtime scenario records exactly**:

| Original method | Admitted | Served | Road km | Feasible scenarios |
|---|---:|---:|---:|---:|
| Nearest-Next | 500 | 453 | 3849.889 | 100/100 |
| FCFS | 500 | 453 | 4575.154 | 100/100 |

Current worker admission rejects 17 tasks with `LISTING_EXPIRES_BEFORE_HORIZON`. The unchanged original baselines admit these at claim time. The supplemental comparison applies current admission equally to all three algorithms: **483 admitted tasks**, identical per-scenario inputs/matrices/depot/fleet/windows/services/limits. The 17 original tasks remain in saved input and exclusion evidence. This is **not an unchanged 500-task formal E4 experiment**; changing product safety or listing timestamps to force admission would misrepresent the actual implementation.

| Common-admission method | Served / admitted | Weighted coverage | Road km* | Travel min | Route duration min | Feasible | Median / p95 planner ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| Nearest-Next | 437/483 | 90.476% | 3732.22677 | 4445.80953 | 8815.80953 | 100/100 | 0.2631 / 0.6956 |
| FCFS | 437/483 | 90.476% | 4429.11178 | 5152.83116 | 9522.83116 | 100/100 | 0.2594 / 0.6790 |
| Actual GeoLock | 439/483 | 90.890% | 3380.07299 | 4070.70276 | 8460.70276 | 100/100 | 107.1825 / 241.3605 |

*Totals are descriptive; coverage differs, so do not use these totals as a fair distance-saving claim. All 300 saved plans were independently revalidated from frozen input. Capacity, time-window and route-duration violations: zero for each method; recorded timeouts: zero. Feasible does not mean every task served or route dispatch authorized.

| Paired comparison | Equal served-count scenarios | Count-qualified reduction | Identical served-task-set scenarios | Strict task-set distance reduction |
|---|---:|---:|---:|---:|
| GeoLock vs Nearest-Next | 98/100 | 9.909% | 91/100 | **9.178%** |
| GeoLock vs FCFS | 98/100 | 24.006% | 79/100 | **22.742%** |

Distance reductions aggregate only the stated qualifying pairs. Equal count alone can select different pickups; the strict columns compare identical served identities. Each comparison has two coverage-different scenarios excluded from count-qualified distance calculation.

All use benchmark 240-minute routes, 10-minute service, zero exploratory safety margin, horizon windows, one depot-return trip per vehicle and original fixed fleet order. The corpus does not test separate donor windows or hub tasks. This measures the offline algorithm, not HTTP/Auth/graph-download latency, dispatch, custody or real driving. No statistical significance or independent replication is claimed. Earlier E4 `actual-01` remains exploratory: its timing included adapter validation/I/O. Final `actual-02` separates planner runtime and adapter-call time and adds original baseline reproduction. Do not pool the runs as 200 independent scenarios.

## Validation, reproduction and tomorrow

Six focused artifact/launcher tests passed (`.venv-stage8/Scripts/python.exe -m unittest experiments.test_repro_benchmarks -v`): canonical hash/value integrity; 300 E4 shared-input/validation records; complete E2 ownership/function evidence; error-to-audit matching; unsafe run-ID rejection; overwrite refusal. Offline summary verification independently revalidated 300 E4 plans and both original baselines. All five newly owned E2 setup/smoke/full clusters have `stopped: true`, `remote_connections: 0`; logs/data remain available. Setup failures are not counted as completed benchmarks.

Exact PowerShell setup, full commands, dependencies and portability prerequisites: `experiments/REPRODUCIBLE_E2_E4_README.md`. Use `experiments/run_repro_benchmarks.py --experiment E2 --run-id NEW-ID --teammate-root PATH` or `--experiment E4` under the recorded Python environment; never invoke the original E2 CLI directly because it contains a remote default DSN. The local wrapper restricts connection resolution to its generated loopback port/database. Output overwrite is refused.

Tomorrow's executable single-case demonstration and expected files: `experiments/E2_E4_DEMONSTRATION_GUIDE.md`. Routing case `SCN-ROUTE_PLANNING-0003` serves the same four tasks: Nearest-Next 47.55281 km, proposed 42.94797 km; saved routes and independent feasibility evidence are included. A single-case rerun is a demonstration, not a new full benchmark.

Before presenting an unqualified PASS: disclose/review the actual deadlock robustness gap, resolve the formal 500-versus-483 admission policy mismatch, align the thesis method description with current CP-SAT, and review the specified paired uncertainty protocol. Do not imply new supervisor approval. A product correction would require separately authorized work and new measurements. The current outputs support an honest demonstration of single ownership, protected recovery and offline optimization with these limitations.

## Created files and evidence inventory

No production algorithm, original baseline or original frozen input was edited for these experiments. Existing unrelated work was preserved. Added:

- `experiments/repro_benchmark.py`: integrity, original-source loading and environment helpers.
- `experiments/run_repro_benchmarks.py`: portable local-only launcher and overwrite guards.
- `experiments/e2_atomic_claiming/run.py`: disposable real PostgreSQL experiment controller.
- `experiments/e4_post_claim_routing/run.py`: original baselines/current-worker adapter and raw plan capture.
- `experiments/summarize_repro_benchmarks.py`: result verification, comparison tables and statistics.
- `experiments/test_repro_benchmarks.py`: six focused artifact/guard checks.
- `experiments/repro_environment.json`, `experiments/repro_runtime_checksums.json`: dependencies/native evidence.
- `experiments/repro_inputs/v33/`: exact manifest-matching transport mirror.
- `experiments/REPRODUCIBLE_E2_E4_README.md`, `experiments/E2_E4_DEMONSTRATION_GUIDE.md`, this report.
- Both final result directories named above: raw scenarios/requests/plans, manifests, completion records, comparison CSVs, statistics, presentation-ready `COMPARISON.md`, audit/ownership/validation evidence. E2 additionally retains stopped private runtime data; E4 additionally retains original full-input baseline outputs.
- Retained exploratory/setup directories under the same result roots; these are explicitly excluded from final sample counts.
- `experiments/REPRODUCIBILITY_MANIFEST.json`: final source/artifact inventory with SHA256, excluding disposable database binaries/data and itself.

E2 tables: `comparison.csv`, `lease_comparison.csv`, `comparison_per_scenario.csv`, `summary_statistics.json`. E4 tables: `comparison.csv`, `summary_statistics.csv`, `original_baseline_summary.csv`, `paired_distance_summary.csv`. Full presentation tables are in each final run's `COMPARISON.md`. These outputs, rather than rounded prose, are the authoritative measured records.
