# Routing research tools

Use the existing Windows Stage 8 Python environment. Run the commands from the repository root. These tools reuse the shared routing planner, CP-SAT optimiser and independent validator.

## Synthetic planning demonstration

```powershell
$python = '.\.venv-stage8\Scripts\python.exe'
& $python -B -m experiments.routing_research.phase_c2_demo --output results/stage8-phase-c2-local/synthetic-demo.json
```

Use a fresh output path. The demo plans synthetic routes for the three operational methods and checks them independently. It opens no database connection and grants no route authority. The demo imports the canonical matrix and orchestration APIs from `backend.routing.planner`.

## Offline reproducibility diagnostics

```powershell
& $python -B -m experiments.routing_research.diagnostics.reproducibility --help
& $python -B -m experiments.routing_research.diagnostics.reproducibility --output results/routing-research/new-diagnostic
& $python -B -m unittest experiments.routing_research.algorithms.tests.test_reproducibility
```

The diagnostic runs synthetic fixtures in fresh processes and writes only to the new output directory. The regression suite also checks the historical benchmark guard against a saved Stage B.3 copy. An exact-byte comparison requires the original line endings.

`summarize.py`, `finalize.py`, and `postgres_candidate_hashes.py` are retained Stage B.3 tools. The summary and finalisation workflows expect the original source paths and evidence layout. Use a restored historical checkout and the original inputs for that work, as described in the [Stage B.3 report](../../docs/stage8/stage-b3/REPORT.md). The PostgreSQL digest tool starts a disposable database and is outside the offline checks.

The [published E4 snapshots](../../docs/research-preservation/e4/README.md) preserve the original diagnostic and demo paths. Current E4 uses the relocated benchmark adapter and the canonical optimiser and validator imports. For the operational Windows services, see the [routing guide](../../docs/LOCAL_ROUTING_WINDOWS.md).

## Versioned benchmark adapter

The [v3.2 benchmark package](benchmark_v32/README.md) contains the standalone v3.2 runner and the adapter used by current E4. The standalone commands require the original v3.2 inputs. E4 uses its own v3.3 admission setup.

## Offline algorithms and tests

`algorithms/` contains the paired benchmark, synthetic scenarios, plan serializer, and alternate RoutingModel solver. E4 uses the plan serializer with the shared production CP-SAT optimiser and independent validator. The Windows service continues to use the method registry in `backend.routing.planner.methods`.

```powershell
& $python -B -m experiments.routing_research.algorithms.benchmark --help
& $python -B -m unittest discover -s experiments/routing_research/algorithms/tests -t .
```

Run this research test suite alongside routing test discovery. The benchmark still requires the exact historical Phase A inputs checked by its source-preservation guard. Use the original checkout if that guard reports `PHASE_A_CHANGED`. The published E4 snapshots retain the original Phase B import paths.
