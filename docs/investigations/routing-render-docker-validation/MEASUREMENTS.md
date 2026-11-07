# Local Linux Docker measurements — 7 November 2026 MYT

Historical graph-stage/small-fixture checkpoint. The later full-graph provisional 3/10/25/100-pickup sweep and current capacity interpretation are in [workload measurements](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/investigations/routing-render-workload-validation/MEASUREMENTS.md) and readiness-report section 8. Original rows/receipts below are retained unchanged.

These are isolated offline Docker Desktop measurements, not actual Render service measurements. Network was disabled; image UID was 10001. No live journals, credentials, DEV calls or routes were used.

The graph fixture is the sealed historical 926,414-node / 2,145,828-edge export. Its recorded three-node reference matrix is compared in full. The graph cases do not solve a real NGO routing bundle. Synthetic planner and frozen v3.3 solver cases are measured separately. Fresh process is not a guarantee of a cold host/VM page cache.

## Full-network graph stages

| Case | Outcome | Process peak MiB | Cgroup peak MiB | Process CPU s | Export/artifact load s | Compile/seal s | Matrix calls s |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| full-graph-8gb-compact-bootstrap | PARITY PASS | 1508.3 | 1501.2 | 68.846 | 21.717 | 58.635 | 0.00482 / 0.00448 |
| 512mb-0.1cpu-full-graph-legacy | OOM, exit 137; cap 512 MiB | N/A | N/A | N/A | N/A | N/A | N/A |
| 512mb-0.1cpu-full-graph-compact | OOM, exit 137; cap 512 MiB | N/A | N/A | N/A | N/A | N/A | N/A |
| 512mb-0.1cpu-full-graph-artifact-restart | PARITY PASS | 173.1 | 164.0 | 1.692 | 9.597 | 0.000 | 0.00182 / 0.00168 |
| 2gb-1cpu-full-graph-legacy | OOM, exit 137; cap 2048 MiB | N/A | N/A | N/A | N/A | N/A | N/A |
| 2gb-1cpu-full-graph-compact | PARITY PASS | 1508.0 | 1501.9 | 69.434 | 21.327 | 58.995 | 0.00395 / 0.00310 |
| 2gb-1cpu-full-graph-artifact-restart | PARITY PASS | 172.8 | 163.9 | 4.262 | 2.451 | 0.000 | 0.00810 / 0.00585 |
| 4gb-2cpu-full-graph-legacy | PARITY PASS | 3606.8 | 3605.2 | 139.610 | 21.745 | 0.000 | 61.68307 / 66.57470 |
| 4gb-2cpu-full-graph-compact | PARITY PASS | 1507.8 | 1502.2 | 62.246 | 24.675 | 50.186 | 0.00191 / 0.00151 |
| 4gb-2cpu-full-graph-artifact-restart | PARITY PASS | 173.0 | 164.1 | 2.210 | 1.326 | 0.000 | 0.00450 / 0.00858 |
| 8gb-2cpu-full-graph-legacy | PARITY PASS | 3606.7 | 3604.9 | 129.497 | 23.477 | 0.000 | 57.19539 / 60.78314 |
| 8gb-2cpu-full-graph-artifact-restart | PARITY PASS | 173.3 | 164.3 | 4.129 | 2.300 | 0.000 | 0.00471 / 0.00481 |

OOM cases have no completed in-process peak receipt; the exact configured cap and Docker OOMKilled flag are evidence, not a fabricated peak. The 8 GiB compact bootstrap includes artifact write/seal; later compact cases reuse that artifact path and do not write it again. Legacy repeats full graph conversion on both matrix calls. Artifact reload checks a controller-pinned SHA and historical manifest, with no export parse. Production still requires its protected live-manifest check.

## Synthetic planner (1,000 nodes / 3,000 edges, all four methods)

| Case | Process peak MiB | Cgroup peak MiB | Process CPU s | Process wall s | Three matrices s | Four-method wall s | Proposed wall s | All valid |
| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | --- |
| 512mb-0.1cpu-synthetic-planner-legacy | 106.3 | 58.4 | 2.466 | 23.500 | 1.4977 / 1.2010 / 1.2992 | 9.898 | 0.1997 | True |
| 512mb-0.1cpu-synthetic-planner-compact | 105.2 | 57.3 | 2.393 | 22.504 | 0.4966 / 0.5052 / 0.5024 | 7.699 | 0.1995 | True |
| 2gb-1cpu-synthetic-planner-legacy | 106.1 | 58.9 | 4.135 | 4.018 | 0.2740 / 0.1900 / 0.3048 | 1.312 | 0.0151 | True |
| 2gb-1cpu-synthetic-planner-compact | 106.1 | 58.5 | 3.401 | 3.253 | 0.0807 / 0.0764 / 0.0749 | 1.319 | 0.0177 | True |
| 4gb-2cpu-synthetic-planner-legacy | 105.9 | 58.4 | 4.281 | 3.823 | 0.1737 / 0.2971 / 0.2009 | 1.267 | 0.0179 | True |
| 4gb-2cpu-synthetic-planner-compact | 106.5 | 58.6 | 3.495 | 2.993 | 0.0712 / 0.0681 / 0.0727 | 1.212 | 0.0253 | True |
| 8gb-2cpu-synthetic-planner-legacy | 106.2 | 58.1 | 4.659 | 4.111 | 0.2153 / 0.2334 / 0.2579 | 1.250 | 0.0302 | True |
| 8gb-2cpu-synthetic-planner-compact | 106.3 | 58.5 | 4.060 | 3.594 | 0.1214 / 0.0602 / 0.0602 | 1.088 | 0.0179 | True |

All synthetic planner matrices have SHA256 `32dbb385501226b876d9a30486c89d0f80c90c4bc8acf3d55abbc814d1571e09`. Individual method/solver times, statuses, coverage proof and timeouts are recorded in resource-receipts.json. This is a unit workload, not a maximum task/fleet admission case.

## Separate validator process (synthetic work item)

| Profile | Process peak MiB | Cgroup peak MiB | Process CPU s | Process wall s | Validation calls s |
| --- | ---: | ---: | ---: | ---: | --- |
| 512mb-0.1cpu | 29.2 | 19.7 | 0.796 | 6.792 | 0.00384 / 0.08903 / 0.00294 |
| 2gb-1cpu | 29.0 | 19.7 | 1.234 | 1.059 | 0.00601 / 0.00458 / 0.00500 |
| 4gb-2cpu | 29.1 | 19.6 | 1.289 | 1.109 | 0.00927 / 0.00763 / 0.00579 |
| 8gb-2cpu | 29.1 | 19.2 | 1.262 | 1.083 | 0.00861 / 0.00707 / 0.00585 |

Validator RPC reads/attestations are in-memory doubles. These numbers exclude real database TLS/network/attestation latency and large work-item memory.

## Frozen v3.3 sample, three scenarios / four methods

| Profile | Plans valid | Process peak MiB | Cgroup peak MiB | Process CPU s | Process wall s | Proposed solve seconds (three scenarios) |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 512mb-0.1cpu | 12/12 | 97.2 | 50.6 | 1.861 | 16.893 | 0.29648 / 0.60160 / 0.50082 |
| 2gb-1cpu | 12/12 | 97.1 | 50.9 | 1.538 | 1.470 | 0.01613 / 0.04197 / 0.06139 |
| 4gb-2cpu | 12/12 | 97.7 | 50.6 | 2.469 | 2.028 | 0.01902 / 0.09086 / 0.07216 |
| 8gb-2cpu | 12/12 | 97.6 | 50.8 | 2.668 | 2.230 | 0.04249 / 0.09490 / 0.06013 |

Unchanged source CSV seals and frozen input/matrix hashes are verified. Three cases were selected by admitted-task count and ID (min/median/max positions): 3, 5 and 5 tasks. This is a sample, not the full 100-case E4 experiment or an operational maximum workload.

## Disabled cold process startup (no graph/DB)

| Profile | Role | To health s | Process peak MiB | CPU s |
| --- | --- | ---: | ---: | ---: |
| 512mb-0.1cpu | planner | 7.389 | 32.4 | 0.832 |
| 512mb-0.1cpu | validator | 6.301 | 32.4 | 0.738 |
| 2gb-1cpu | planner | 0.751 | 32.3 | 0.833 |
| 2gb-1cpu | validator | 0.731 | 32.4 | 0.881 |
| 4gb-2cpu | planner | 1.365 | 32.2 | 1.567 |
| 4gb-2cpu | validator | 1.402 | 32.2 | 1.589 |
| 8gb-2cpu | planner | 1.355 | 32.1 | 1.573 |
| 8gb-2cpu | validator | 1.725 | 32.4 | 1.945 |

Every disabled startup returned /live 200 and /health 503 DISABLED. Actual image CMD/PORT binding and SIGTERM were also tested in separate unmounted containers (actual-cmd-port-sigterm.json). Disabled health timings do not establish active readiness or app cold-start deadlines.

## Interpretation

Docker memory/CPU caps and no-extra-swap settings are in each receipt; CPU.stat captures actual throttling. Cgroup memory and process RSS differ because file-backed/shared pages can be charged to other cgroups. No cache flush was performed, and these are single runs, not confidence intervals. Wall time and CPU time are distinct; do not extrapolate desktop timings into a Render SLA.

Method order is the existing production order; the first CP-SAT method pays cold import/warm-up costs. These timings are not a fair algorithm-speed comparison or a replacement for formal E4 evidence.

Graph-only feasibility is established for the tested three-node reference at the passing rows. No paid Render plan is capacity-qualified for full routing: the complete approved sanitized operational bundle, maximum task/fleet/node set, real role/RPC latency, provider ingress trust and deployment recovery prerequisites remain unresolved. Render Free still lacks the required durable journal disk.
