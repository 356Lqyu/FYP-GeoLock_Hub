# E4 — Plan routes after donations are claimed

E4 gives three planners the same 100 scenarios and 500 admitted pickups. It compares how many pickups they serve and how far they drive when they serve the same tasks. E4 runs locally without PostgreSQL, Supabase, or a live road service.

| Method | Rule |
| --- | --- |
| Nearest-Next | Pick the nearest feasible next stop. |
| First Come, First Served (FCFS) | Pick the oldest feasible task first. |
| Proposed OR-Tools CP-SAT | Maximize the number of served tasks, then minimize road distance at that coverage. |

The older routing diagnostic admitted 483 tasks because it applied a synthetic listing expiry. Current E4 ignores that benchmark-only field for post-claim planning and admits 500. Claim leases, ownership, task status, pickup windows, capacity, route limits, depot return, and directed road connectivity still apply. See the [experiment plan](EXPERIMENT_PLAN.md).

## How to run

**1. Set up Python.** Install Windows x64 CPython **3.13.9**, then run these commands from the repository root in PowerShell. Dependency installation normally needs internet access.

~~~powershell
py -3.13 --version
py -3.13 -m venv .venv-e4
$e4Python = '.\.venv-e4\Scripts\python.exe'
& $e4Python -m pip install -r experiments/e4/requirements.txt
& $e4Python -m pip check
~~~

Check that the version command reports `Python 3.13.9`. Keep the shared [routing package](../../backend/routing/) and the [frozen dataset](../../benchmark%20dataset/dataset/) in the checkout.

**2. Check the setup offline.** In a new shell, set `$e4Python` again using the line above.

~~~powershell
& $e4Python -B experiments/e4/run_e4.py --preflight-only
& $e4Python -B -m unittest discover -s experiments/e4/test_harness
~~~

Preflight should report 100 snapshots, 500 admitted tasks, and 50 snapshots each for one-vehicle and two-vehicle fleets. The tests cover admission, matched comparisons, and safe publication.

**3. Run the full experiment.** This command replaces the managed active results only after successful validation. It automatically runs Nearest-Next, FCFS, and CP-SAT, validates their routes, and generates the comparison. All outputs share one run ID.

~~~powershell
& $e4Python -B experiments/e4/run_e4.py
~~~

A successful run prints `Published E4 run`, the new run ID, and the manifest path. Work is staged under `experiments/e4/.work/`. Failed stages can hold diagnostics.

**4. Open the results.**

~~~powershell
Invoke-Item -LiteralPath 'experiments/e4/experiment_result/summary.md'
~~~

| Folder or file | What it contains |
| --- | --- |
| [baseline/1_nearest_next/](baseline/1_nearest_next/) | Nearest-Next scenario results, routes, and manifest |
| [baseline/2_fcfs/](baseline/2_fcfs/) | FCFS scenario results, routes, and manifest |
| [or_tools_route_optimiser/result/](or_tools_route_optimiser/result/) | Proposed planner's scenario results, routes, and manifest |
| [experiment_result/](experiment_result/) | Summary, metrics, comparison CSVs, figures, and active run manifest |

Read coverage across all snapshots first. Use the matched-task figures to compare distance on the same pickups.

**5. Verify the saved outputs offline.** Use the first command for the active files. Use the second for the original paper run `ac1b77db93634b7d8da371ee59105679` while its artifacts are still the active set. The paper verifier checks the original manifest, frozen inputs, source hashes, and artifacts. A [saved source snapshot](experiment_result/published_provenance/backend/routing/hosted/frozen_benchmark.py) supplies the exact diagnostic bytes recorded by that run.

~~~powershell
& $e4Python -B experiments/e4/run_e4.py --verify-active
& $e4Python -B experiments/e4/experiment_result/published_provenance/verify.py
~~~

**6. Recover an interrupted publication only if requested by the driver.** For example, Windows may terminate the process while it is replacing the published files. This command can restore the previous active outputs. It runs no routing method.

~~~powershell
& $e4Python -B experiments/e4/run_e4.py --recover-publication
& $e4Python -B experiments/e4/run_e4.py --verify-active
~~~
