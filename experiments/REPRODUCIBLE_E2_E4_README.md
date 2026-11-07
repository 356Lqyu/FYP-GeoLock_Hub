# Reproducing the actual GeoLock E2 and E4 experiments

Prepared 5 November 2026, MYT. This package executes the original teammate baselines and the actual current GeoLock PostgreSQL functions / CP-SAT optimizer. It accepts no remote database DSN and starts no hosted worker. Results are scoped local evidence, not a DEV/production experiment or supervisor approval.

## Inputs and environment

The teammate project was found at `C:\Users\User\Downloads\FYP-GeoLock_Hub-ss (1)\FYP-GeoLock_Hub-ss`. The original ZIP and extracted files were inspected, not rewritten. The current package is **GEOLOCK-BM-v3.3**, matrix **OSM-DIRECTED-v3.3**, dataset seed **20260915**. It contains the requested 150 CLAIM_COORDINATION, 100 LEASE_RECOVERY, 25 LEASE_ACTIVE_VERIFICATION and 100 ROUTE_PLANNING scenario IDs. All runs retain exact IDs.

The supplied Git/ZIP transport changed all 15 CSV files from CRLF to LF. Their raw hashes therefore differ from the generation manifest. For every file, restoring CRLF alone exactly reproduces the declared SHA256. The runner creates `experiments/repro_inputs/v33/` with those exact manifest-matching bytes; it never changes the originals. Any other difference fails the check. `generation_manifest.json` is copied unchanged. Its supplied LF SHA256 is `139c823a20753e16bf1d6c0aea137ff03a171b57def95723d1be9bd4c66afe34`; its CRLF hash is `5fdafca9baa69c4e1c84eb843d180ff0e2ea6319fccf02ae033a6d3fb595d16a`, matching the teammate's historical run record. Every per-CSV expected/source/canonical hash is retained in the run manifest. Do not regenerate donations or road costs to repair packaging.

Recorded execution environment: Windows, Python **3.12.14**, `psycopg` **3.3.6**, OR-Tools **9.15.6755**, PostgreSQL **17.11**. The baseline schema uses native PostGIS from the existing private PG17 runtime. Exact extension versions are recorded in the E2 manifest. The actual GeoLock fixture uses synthetic Auth/Storage/cron and the frozen directed road-matrix lookup, not hosted Supabase or a new pgRouting computation. Runtime DLL/extension availability must be checked on another host.

The available interpreter is `.venv-stage8\Scripts\python.exe`. Full installed package versions are in `experiments/repro_environment.json`; routing requirements are also in `backend/routing/phase_b/requirements-lock.txt`, baseline requirements in `baseline implementation/source code/requirements.txt`. Do not silently upgrade the solver. Existing binaries are at `.tmp/geolock-spatial-runtime-safe-cancel/pgsql/bin`. PostgreSQL's optional pgcrypto DLL in this bundle cannot load; the E2 SQL transport omits only its CREATE EXTENSION statement because PostgreSQL 17 provides the schema's required `gen_random_uuid()` in core. It does not replace any claim/recovery function body or fake an extension catalog entry.

Git HEAD during execution: `df626175c1413249ec2fceb314e0df431d5e692b`. The working tree is dirty, so HEAD alone is insufficient: each run records source hashes and applied SQL evidence. Keep the current reviewed source package alongside results. The original baselines are loaded from source without modifying their code or refreshing their bundled bytecode.

## Safe commands in PowerShell

Run at the project root. Use a NEW RunId every time. The runners refuse to overwrite an output folder and retain disposable runtime data/evidence after stopping the server. Do not use Python `-O` or set `PYTHONOPTIMIZE`; the portable launcher rejects that mode.

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$py = Join-Path (Get-Location) '.venv-stage8\Scripts\python.exe'
$team = 'C:\Users\User\Downloads\FYP-GeoLock_Hub-ss (1)\FYP-GeoLock_Hub-ss'

# Input/dependency verification only: no optimizer or database is started.
& $py experiments/run_repro_benchmarks.py --experiment E4 --run-id preflight --teammate-root $team --check-only

# Full E2. Windows must allow this NEW loopback PostgreSQL server to start.
& $py experiments/run_repro_benchmarks.py --experiment E2 --run-id e2-supervisor-01 --teammate-root $team
if ($LASTEXITCODE -ne 0) { throw 'E2 stopped; retain logs and partial evidence' }

# Full E4: original full-input baseline reproduction plus a labelled common-admission lane.
& $py experiments/run_repro_benchmarks.py --experiment E4 --run-id e4-supervisor-01 --teammate-root $team
if ($LASTEXITCODE -ne 0) { throw 'E4 stopped; retain logs and partial evidence' }

# Recompute summaries and independently verify stored E4 plans; no new solve/DB call.
& $py experiments/summarize_repro_benchmarks.py --e2 experiments/e2_atomic_claiming/results/e2-supervisor-01 --e4 experiments/e4_post_claim_routing/results/e4-supervisor-01
```

On another machine, put this project and the extracted teammate project at accessible paths and supply `--teammate-root`. Supply `--pg-bin 'C:\approved-PG17-with-PostGIS\bin'` if the reviewed native binaries are elsewhere. No username/password/remote profile parameter exists. Use the recorded Python/package/PG versions, retain binary checksums, and disclose version differences rather than claiming identical execution environments. A missing spatial runtime is a prerequisite failure; never substitute a shared Supabase DSN.

**Do not invoke the upstream E2 scripts unwrapped:** they contain a remote default connection. This local controller overrides DSN resolution with a strict generated-loopback-port/database check and supplies an explicit local connection before invoking their untouched main functions. No remote fallback is allowed. It never invokes the upstream reset script.

## Actual preserved runs and outputs

- E2: `experiments/e2_atomic_claiming/results/e2-20261105-v33-actual-01/`.
- E4 final: `experiments/e4_post_claim_routing/results/e4-20261105-v33-actual-02/`.
- E4 `actual-01` is an earlier executed exploratory lane, retained separately. Its reported adapter-call time included external validation/I/O, so use `actual-02` for separated planner timing and full original-baseline reproduction. These are not two independent 100-scenario samples.

Each run has a manifest/environment/source fingerprints, raw scenario records and completion evidence. A directory's existence or RUNNING manifest is not PASS. E2's `cluster-stop.json` must confirm shutdown and zero remote connections. Setup/smoke failures are retained with logs and are not counted as completed benchmarks.

| Output | Meaning |
|---|---|
| E2 `non_atomic_claim/` | Untouched teammate baseline, all 150 contention trials, raw request CSV and summary |
| E2 `protected_claim_without_lease_recovery/` | Untouched teammate baseline, 150 contention + 125 lease cases |
| E2 `proposed_results_per_scenario.csv`, `proposed_requests.json` | Actual GeoLock results for all requested scenarios/requests |
| E2 `proposed_committed_states.json` | Committed claim/owner/state evidence after each scenario |
| E2 `database_errors.csv` | Actual failure-audit SQLSTATEs behind generic rollback responses |
| E2 `comparison.csv`, `comparison_per_scenario.csv`, `lease_comparison.csv` | Method/worker-level, raw scenario and lease comparisons |
| E4 `original_nearest_next/`, `original_fcfs/` | Original methods on all original 500 admitted tasks, using the teammate's sealed snapshot protocol |
| E4 `raw/*-input.json` | All source observations, common frozen input/matrix hashes and additional exclusion reasons |
| E4 `raw/*-METHOD.json` | Full plan, timings, solver statuses/bounds and independent validation per method/scenario |
| E4 `results_per_scenario.csv` | 300 evaluations in the common-admission lane |
| E4 `comparison.csv`, `summary_statistics.csv`, `paired_distance_summary.csv` | Coverage, constraint checks, timings and coverage-qualified distance summaries |
| E4 `additional_admission_exclusions.csv` | The 17 listing-horizon mismatches, not silently removed from source data |
| Each run `COMPARISON.md` | Presentation-ready tables and validity limitations |

## Interpretation limits that must accompany the tables

**E2:** The original baseline schema is older than current GeoLock. Its protected claim has the teammate's FOR NO KEY UPDATE correction; current GeoLock retains its actual reviewed claim source. The actual recovery/claim function hashes are checked and retained, not patched to make results look better. Both baseline and proposed execute in the same PG17 cluster and use the same benchmark cases, actor order, 2/5/10 concurrent request barriers, road inputs, READ COMMITTED isolation, 360-minute lease and one transient-exception retry. Schema/lifecycle/audit differences prevent a clean causal latency attribution solely to atomic locking. Actual generic rollback errors count as database errors, not clean conflicts. Non-atomic recovery is not a capability of that baseline and is marked not applicable, not invented.

**E4:** The actual current worker's admission rule rejects 17 tasks whose listings do not survive the complete horizon. Original Nearest-Next/FCFS admit them at claim time. The original baselines reproduce 500 admitted tasks; the supplemental fair-input lane applies the existing worker admission to all three methods, yielding 483. All 100 scenario IDs still run and every source task/exclusion is retained. This lane is not an unchanged reproduction of the 500-task original experiment. Resolving the formal policy mismatch needs explicit requirements/protocol review; do not weaken product checks or silently null/extend listing expiry.

The supplied baselines use the route horizon as the pickup time window and 10-minute services; they do not enforce separate donor-specific windows. The bridge uses those same declared windows for all methods. It therefore measures algorithm feasibility under that benchmark contract, not the complete live donor-window/dispatch workflow. No HTTP, graph-download latency, Supabase Auth, real vehicle/driver behavior or physical collection is measured.

The proposed callable is exactly `backend.routing.phase_b.optimizers.proposed`, exported in `METHODS` and reached by the current worker's `solve_bundle`. It is CP-SAT with one worker, seed 42, 30-second total wall budget (15 seconds per pass) and 0.25 deterministic seconds per pass. It maximizes served pickup-task count, then minimizes directed road km. Historical schema fields still have RoutingModel/cost naming; actual source and per-plan objective/status/bound metadata identify the executed method. Do not claim an engine/thesis amendment has supervisor approval from these runs.

Distance summaries exclude coverage-different scenarios. Both equal served-task counts and the stricter identical served-task sets are reported. Aggregate distances over all 100 cases must not be described as a fair distance saving when coverage differs. Capacity/time/duration validation remains required even for a shorter plan. Feasible/PARTIAL can mean valid constraints with some unserved tasks, not complete pickup coverage or dispatch authorization.

These are one-run paired scenario measurements. Runtime varies with host load/cache and concurrent local work; it is not an end-to-end app latency or a claim that CP-SAT is faster. No favourable rerun selection, statistical significance or independent replication is inferred. The full FYP's paired uncertainty/statistical protocol and any formal admission amendment remain to be reviewed.
