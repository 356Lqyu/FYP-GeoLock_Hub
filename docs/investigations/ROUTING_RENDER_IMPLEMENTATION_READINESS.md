# Render routing implementation readiness

**Owner decision, 7 November 2026: CLOUD HOSTING POSTPONED / NOT SELECTED.** The selected default is the existing [Windows laptop workflow](../LOCAL_ROUTING_WINDOWS.md). No Render or alternative cloud deployment, charge or journal redesign is planned/authorized. The dated research, source files and benchmark evidence below are retained intact as reference; previous hosting recommendations and next-deployment actions are superseded by this decision. Local verification is recorded in `LOCAL_ROUTING_WINDOWS_VERIFICATION.md`.

7 November 2026, Asia/Kuala_Lumpur. **Latest: provisional full-graph workload benchmarks complete; deployment remains NO-GO.** A modeled 3–10-pickup demonstration has a screened local resource envelope; 25/100-pickup CP-SAT cases fail to produce a usable incumbent under the unchanged benchmark budget. Existing SQLite remains the simplest managed-hosting recovery path for FYP; a Supabase PostgreSQL journal is feasible in principle but is design-only. **Section 8 is current and supersedes earlier capacity/next-approval statements. No production Render plan is capacity-qualified; provider ingress, actual policy/source-envelope and recovery/deployment gates remain open.**

Initial implementation checkpoint (historical; superseded by section 7): a separate Linux-oriented hosting entry point, planner/validator Docker definitions, guarded configuration, compact graph candidate and offline benchmark tooling were implemented locally. Docker was unavailable then. The original source-preservation receipts remain dated evidence; the later journal initialization change is listed explicitly in section 7. No Supabase connection, business write, SQL migration, live route, DEV worker activation, cloud deployment, charge, APK installation or GitHub push occurred during these local validations.

The detailed future operator procedure is [ROUTING_RENDER_DEPLOYMENT_GUIDE.md](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/investigations/ROUTING_RENDER_DEPLOYMENT_GUIDE.md). All new evidence is under `docs/investigations/routing-render-implementation/`; previous investigations and benchmark results were retained.

## 1. Implemented files and behavior

All application implementation is additive under `backend/routing/hosted/`:

| Exact relative file | Change |
| --- | --- |
| `backend/routing/hosted/__init__.py` | Separate hosted package; existing Windows imports/launcher unchanged |
| `backend/routing/hosted/__main__.py` | `--mode planner/validator`; Render PORT binding; guarded proxy ingress; liveness/readiness; bounded request handlers; SIGTERM drain |
| `backend/routing/hosted/config.py` | Disabled by default; exact DEV scope; role-specific secrets; CA verification; HTTPS roots; verified proxy peers; persistent planner configuration |
| `backend/routing/hosted/runtime.py` | Separate scoped Linux psycopg factory; readonly startup checks/graph warm-up; same business dispatcher, journal, planner, independent validator and NGO auth; instance lock |
| `backend/routing/hosted/compact_graph.py` | Opt-in immutable CSR graph/cache; exact matrix provenance/hash compatibility; independently sealed artifact format |
| `backend/routing/hosted/artifact.py` | Offline sealed-export compiler; exclusive output creation; no DB/network code |
| `backend/routing/hosted/benchmark.py` | Fresh-process graph/matrix/four-method/validator measurements, memory counters and optional enforced cgroup checks |
| `backend/routing/hosted/frozen_benchmark.py` | Read-only frozen v3.3 min/median/max admission sample; same four methods and independent validation |
| `backend/routing/hosted/run_resource_profiles.py` | Future offline Docker runs for all four requested limits; no network/pull; unique results, OOM/cgroup receipts |
| `backend/routing/hosted/docker/planner.Dockerfile` | Nonroot Python 3.12 Linux planner; existing pinned dependencies; no credentials/graph data |
| `backend/routing/hosted/docker/validator.Dockerfile` | Separate nonroot validator image/command; same validation dependency types |
| `backend/routing/hosted/docker/planner.Dockerfile.dockerignore` | Allowlisted source-only Docker context |
| `backend/routing/hosted/docker/validator.Dockerfile.dockerignore` | Same source-only context restrictions |
| `backend/routing/hosted/render.review.yaml` | Review-only two-service configuration, disabled activation/manual deploy, provisional paid plans and planner disk |
| `backend/routing/hosted/tests/__init__.py` | Test package |
| `backend/routing/hosted/tests/test_compact.py` | Directed/tie/unreachable/filter parity, immutable reuse, corruption and manifest guards |
| `backend/routing/hosted/tests/test_hosting.py` | Configuration/roles, proxy/auth, readiness/mount, singleton and restart/receipt recovery |
| `backend/routing/hosted/tests/test_artifact_packaging.py` | Compiler seal/no-overwrite, source import closure and context restrictions |

Documentation additions: this report and `docs/investigations/ROUTING_RENDER_DEPLOYMENT_GUIDE.md`. Evidence additions: `BASELINE_SEALS.json`, `VALIDATION_RECEIPT.json`, test logs and fresh benchmark JSON files listed below. No existing Flutter, SQL, worker or frozen input file was edited.

**Hosted request chain.** The existing stdlib HTTP dispatcher is reused instead of adding another framework/dependency. It retains strict JSON parsing, verified NGO JWT handling, original request/snapshot UUIDs, single-generation semaphore, protected RPC allowlists, all four `METHODS` including the existing CP-SAT proposed callable, independent trusted validation and original NGO-owned authorization receipts. The Linux entry point adds transport/configuration/readiness around that chain. It enables the normal combined workflow only via its explicit approval flag; the staged exact-two operator feature is not enabled by this new bootstrap. No validator state, database authorization or objective semantics changed.

Planner credentials and validator credentials are mutually excluded by configuration. Passwords are separate environment secrets or runtime files, absent from DSNs/argv/logs/images. The existing `RoleRpc` TLS/target/login/membership checks and RPC allowlists remain. No postgres/admin/service-role fallback exists. Startup remains disabled without explicit configuration; no credential or DB access occurs in that mode. Active startup uses only role/clock/graph/health reads before accepting generation. `/health` is not a DB query on every request; it reports completed startup readiness, not continuously verified dependency health. Runtime operations retain the existing failure/retry checks.

**Proxy trust is fail-closed, not assumed verified on Render.** Binding is `0.0.0.0:PORT`. Public HTTPS is terminated by the hosting proxy. The actual socket peer must match explicitly verified ingress CIDRs, with one HTTPS forwarding header and exact configured Host; forged X-Forwarded-For/Host cannot create trust. No provider ingress-CIDR/forwarded-header-overwrite guarantee was established here. This must be resolved/tested before activation; no wildcard or guessed network is configured. [Render web-service transport](https://render.com/docs/web-services).

**Recovery.** An actual persistent planner mount is required; merely setting a state directory is insufficient. SQLite WAL/payloads and graph cache reside there; a lifetime file lock prevents a second planner on the same state directory. Generation is unavailable until graph and validator startup checks finish. Existing protected receipt lookup remains available after the application has initialized even if graph warm-up later fails. Accepted requests drain before lock release; a forced kill still relies on saved steps and same-UUID reconciliation. The existing SQLite file format and database receipts were not replaced. This is persistent single-instance recovery, not high availability or an external distributed journal. The Windows journal and activation workflow are untouched.

## 2. Graph optimization and parity

The prior repeated conversion is avoided **only in opt-in hosted compact mode**. The original default legacy graph implementation remains available. Compact compilation freezes the selected directed graph once into immutable byte-backed CSR arrays. Matrix generation reads these arrays directly; it does not re-freeze/canonicalize/JSON-decode an entire graph per request. The retained full export is released after compilation. Integer micro-units represent the exact existing six-decimal edge weights; shortest paths retain distance, then duration on that path, then lexicographic string edge-ID path and node-order ties. No reverse edges, alternative weighting, graph identity or solver policy is introduced.

The original canonical graph SHA256 is streamed during compilation and preserved in matrix IDs, version, provenance and the matrix hash domain. Tests compare the **entire matrix object**, not just distances: 30 randomized directed graphs × four node orders (120 comparisons), explicit ties/zero costs/unreachable nodes, asymmetric arcs, inactive-node filtering and artifact round trips. Artifact loading additionally requires an independently configured SHA256 and exact live manifest, with bounded file size, structural checks and version/scope checks. It is not trusted from a request payload or an adjacent untrusted hash file.

Remaining memory: raw export/JSON dictionaries still coexist during compilation; payload construction and artifact loading still make bounded byte copies. The current artifact reader uses bytes, not mmap. Dijkstra still needs per-source best/settled maps, heap entries and full tie-breaking path tuples, which can dominate for large graphs. CP-SAT/imports and up to 100 required nodes remain material. No graph partitioning, road pruning, approximate distances, contraction hierarchy or tie-policy change was made.

Packed payload size is `16*N + 28*E + 8` bytes. At the **historical** 926,414 nodes / 2,145,828 edges this is 74,905,816 bytes (~71.4 MiB) **for arrays only**, not a measured process peak or a Free-fit claim. Actual active filtering may differ; current graph counts/manifest were not queried. The historical ~3.51 GiB peak and ~294.5 s warm-up from the previous review remain dated risk evidence, not measurements of this candidate.

## 3. Tests and observed performance

All commands used `.venv-stage8/Scripts/python.exe -B`; only offline RPC doubles, local files and loopback HTTP were used. Test receipts:

| Suite | Result | Receipt |
| --- | --- | --- |
| New hosted tests | **21 passed** | `routing-render-implementation/hosted-tests-final-packaging-20261107.log` |
| Existing worker tests | **153 passed** | `routing-render-implementation/existing-worker-tests-20261107.log` |
| Existing matrix + integration worker tests | **44 passed** | `routing-render-implementation/matrix-integration-tests-20261107.log` |
| Frozen v3.3 sample | **12/12 valid plans** (three scenarios × all four methods) | `routing-render-implementation/frozen-v33-readonly-sample-20261107.json` |
| Baseline preservation | **13/13 captured source hashes unchanged**, frozen CSV hashes unchanged | `routing-render-implementation/VALIDATION_RECEIPT.json` |

Total unittest result: **218 passed**. New cases include disabled startup without credentials/connections; wrong project/role/CA/configuration rejection; unmounted disk rejection before any DB call; actual-peer proxy checks and duplicate forwarding-header rejection; unauthorized planner and direct validator calls without RPC side effects; generation blocked while warming; singleton contention; same-UUID receipt replay after constructing a new worker/journal instance; no second authorization or re-solving on recovery; sealed artifact tampering/mismatched manifest; no overwrite; repeated matrix reuse without graph reconstruction. Existing tests cover uncertain commits, stale snapshots, ownership, validator failures and protected request recovery. These are not live DEV tests.

Initial local failures were corrected: a test held a Windows lock past temporary-directory cleanup; a Docker parent-directory allowlist assertion was too strict; a new validator test expected 403 instead of the existing correct 401. Final passing logs are identified above; earlier logs/initial probes are not substituted for final results. The local source-only import closure test is not a Docker build or Linux dependency proof.

### Uncapped Windows graph/solver probe

Fresh sequential processes, Python 3.12.14, Windows 11, synthetic 1,000-node / 3,000-directed-edge graph, three required nodes, three matrix invocations. Files: `synthetic-legacy-sequential-20261107.json` and `synthetic-compact-sequential-20261107.json`. Earlier parallel exploratory probes are retained separately and are not used for the table. These are small-fixture observations, not statistically powered capacity benchmarks; the compact run also exercises artifact serialization/restoration before timed matrix invocations.

| Measurement | Legacy | Compact candidate |
| --- | --- | --- |
| Imports + fixture construction | 0.482 s | 0.497 s |
| One-time CSR compile | N/A (legacy conversion occurs per matrix) | 0.0482 s |
| Matrix invocations | 0.0931 / 0.0864 / 0.0859 s | 0.0308 / 0.0324 / 0.0349 s |
| Four-method evaluation including proposed CP-SAT | 0.752 s | 0.826 s |
| Independent validator code | 0.00206 s | 0.00231 s |
| Final process peak working set | 87.3 MiB | 87.8 MiB |
| Final peak committed process memory | 283.2 MiB | 283.4 MiB |

Compact array payload: **100,008 bytes**. Artifact restore: **0.00103 s**, with the raw export already loaded in this probe. This is not an export-free cold-start memory measurement. Both matrix SHA256 values are exactly:

```text
32dbb385501226b876d9a30486c89d0f80c90c4bc8acf3d55abbc814d1571e09
```

Small-graph matrix CPU improved; whole-process peak did **not** materially improve because imports/solver and retained benchmark fixtures dominate. Windows committed bytes/working set are not Linux cgroup RSS. These measurements cannot establish Free feasibility, maximum task count, real HTTP latency or a separately capped validator footprint.

### Realistic frozen workload sample

Frozen GEOLOCK-BM-v3.3 CSV checksums are verified read-only. The existing E4 adapter/policy and current CP-SAT callable were used without altering data/scenarios. Selection was fixed by admission count and ID (minimum, median, maximum positions among 100), not measured performance. Existing matrices are precomputed benchmark road costs; they are not the operational full-network export.

| Scenario | Admitted tasks | Proposed solve | Independent plan validation | All four valid |
| --- | --- | --- | --- | --- |
| SCN-ROUTE_PLANNING-0016 | 3 | 0.0284 s | 0.00241 s | Yes |
| SCN-ROUTE_PLANNING-0045 | 5 | 0.0793 s | 0.00233 s | Yes |
| SCN-ROUTE_PLANNING-0100 | 5 | 0.0724 s | 0.00198 s | Yes |

Across these methods/cases, the largest process peak working set was ~193.1 MiB and committed peak ~390.2 MiB. Validator timings here are plan-validation code inside the benchmark process, **not** a standalone validator-service peak or DB read/attestation time. All four methods, per-method times, validation metrics and input/matrix seals are in the receipt. This sample neither repeats/changes historical E4 results nor constitutes a full E4 benchmark or maximum operational fleet test.

### Requested Render limits

| Memory / CPU | Linux constrained run | Full-network outcome |
| --- | --- | --- |
| 512 MB / 0.1 CPU | **NOT RUN** | Unknown; cannot claim fit |
| 2 GB / 1 CPU | **NOT RUN** | Unknown; cannot claim fit |
| 4 GB / 2 CPU | **NOT RUN** | Unknown; historical graph peak leaves little headroom |
| 8 GB / 2 CPU | **NOT RUN** | Unknown; provisional planner test target only |

`VALIDATION_RECEIPT.json` records Docker/Podman unavailable and no cgroup measurements. No approved complete operational graph export was supplied/used for this run; frozen matrices and synthetic roads cannot replace it. No credentials were extracted to obtain one. Consequently startup, full-network warm-up, matrix/solver end-to-end time, validator-service memory, concurrency and recovery under those exact limits remain unmeasured. The offline harness and exact future command are in the guide. **Minimum tested paid Render plan: NONE.**

## 4. Render Free and external recovery investigation

Render Free currently has 512 MB / 0.1 CPU; its filesystem is ephemeral, it sleeps after idle periods, and persistent disks are unavailable. Its 750 monthly instance-hours are shared per workspace, and Free private ingress is unavailable. [Compute resources](https://render.com/docs/compute-plans), [Free service limits](https://render.com/docs/free).

The current planner journal contains immutable step payloads and binding/locking state used between matrix storage, sealing, candidate submission, validation and authorization. Supabase's final authorization receipt helps recover committed outcomes but is not an existing durable replacement for **all** intermediate journal steps. Skipping or deleting them on restart is not proved equivalent. Thus the implemented planner **rejects ephemeral activation**. Render Free cannot satisfy that mount requirement. This is a concrete recovery incompatibility independent of the unknown compact full-graph footprint.

| External system | Assessment under current restrictions |
| --- | --- |
| Existing Supabase tables/RPCs | Preserve protected receipts; no reviewed general journal API with the required immutable-step, compare-and-set and locking semantics was found. No new table, SQL or permission was added. An external journal would require a separate design/approval/test cycle. |
| Supabase Storage / generic object storage | Potentially suitable for an immutable approved graph artifact with an independently trusted seal and matching manifest. No approved credentials/bucket policy/provisioning or downloader is implemented. A graph artifact does not solve journal durability. |
| SQLite on object/FUSE storage or periodic file upload | Not accepted: WAL/locking/atomicity and failure windows cannot be assumed equivalent. Raw live-file copies are unsafe. |
| Free cache/volatile Redis | Not an accepted durable authority for request steps/locks; persistence, eviction and availability would need explicit guarantees/review. |
| Paid mounted Render disk | Supported by this candidate's single-instance recovery path; still needs backups and an isolated restore rehearsal. It is paid and is not high availability. |

An independent validator remains mandatory. Its code does not load the road graph, but a full isolated service memory/CPU test is missing, so a 512 MB validator fit is unproved. Two always-running Free services need 1440–1488 hours for a 30–31-day month, exceeding 750. Demand-driven sleeping could fit the quota for low usage, but introduces cold start/readiness delay and does not fix the journal. The app's existing five-second health check would not tolerate normal cold startup; no timeout/authentication workaround was added.

**Verdict: Render Free NO-GO for the prepared end-to-end path.** This does not prove every conceivable future external-journal/compact architecture impossible; it proves this safe implemented path requires paid persistence and that neither memory nor recovery evidence supports a Free deployment. No safe zero-cost external journal was demonstrated under the restriction against new schema/permissions.

## 5. Remaining blockers and exact next steps

1. Review the additive source/configuration and approve access to a Linux Docker runtime for local testing. Build both images, verify pinned Linux dependencies/imports/nonroot execution, inspect image contents and seal image/base/dependency versions. No image was built here.
2. Provide an already approved sealed full-network offline export and matching sanitized operational fixtures; verify current graph identity read-only through the approved channel. Compile compact artifact offline, run full matrix parity against legacy, then all four constrained profiles, standalone validator and larger task/fleet/concurrency/restart cases. Measure cold and warm HTTP deadlines. Do not choose compute from the small probes.
3. Establish verified Render ingress peer/header behavior and test the fail-closed configuration. Resolve any Host/forwarding variation through review, without broadening proxy trust indiscriminately.
4. Name the deployment/recovery operator. Obtain a current approved DB recovery baseline and consistent planner journal backup; verify an isolated restore/reconciliation procedure, keeping live credentials out of the offline environment. This task neither inspected current DEV backup status nor performed a backup/restore.
5. Obtain separately approved read-only DEV catalog/network preflight for exact scoped logins/RPCs, graph manifest, validator/authorization contract and connection limits. No new grants, migrations or privileged fallback are proposed here.
6. After capacity evidence, select and explicitly approve two compute plans plus disk/usage budget. The review Blueprint's 8 GB planner / 2 GB validator is provisional and chargeable; there is no proven minimum paid plan. Validate Blueprint with the current provider tooling before creation; it was inspected locally but not submitted to Render.
7. Only after separate deployment/activation approval: create disabled services, configure runtime secrets/CA/disk/proxy trust, controlled single-owner cutover, activate validator then planner, confirm `/health`, perform approved auth/generation/recovery tests, then build and seal a hosted-URL supervisor APK. The existing loopback build script is unsuitable for the hosted APK; the guide provides the correct defines.

**Stop point:** local implementation, offline tests and documentation are complete to the extent supported by available fixtures/runtime. Deployment approval should remain withheld until the above measured/provider/recovery prerequisites are satisfied. No deployment, DEV mutation or paid operation was attempted.

## 6. Next-stage Docker / full-network verification — 7 November 2026 MYT

### Current decision and evidence

**NO-GO.** This follow-up inspected local files, streamed the historical full-network export, ran synthetic-only health/component probes, and added a disposable journal recovery rehearsal. No Supabase connection, live routing request, live journal read/copy, software installation, migration, worker activation, Render operation, charge or push occurred. Existing hosting/business/Windows/Flutter/SQL sources were not modified; the only new application-tree file is the recovery test.

| Requested result | Verified status |
| --- | --- |
| Planner Docker build | **NOT TESTED** — no available Linux container runtime |
| Validator Docker build | **NOT TESTED** — same blocker |
| Linux Python/OR-Tools dependency installation, nonroot UID, image secret inspection | **NOT TESTED** — Dockerfile intent/source guards are not image proof |
| Full-network fixture | **FOUND, historical seal/counts/cursors/endpoints PASS**; current DEV identity not rechecked |
| Complete approved sanitized workload | **NOT ESTABLISHED** — matching partial DEV capture found, unsuitable as supplied |
| Four constrained profiles, separately capped planner and validator | **NOT TESTED** at all four sizes |
| Minimum capacity-qualified Render plan | **NONE** |
| Proxy | **Conditionally compatible design; actual Render ingress compatibility UNVERIFIED** |
| Recovery | **PARTIAL / BLOCKED** — four restore/replay cases pass, forced-crash WAL reopen fails reproducibly on this Windows runtime |

Fresh receipts and tools: `docs/investigations/routing-render-next-validation/`. `local-inventory.json` records availability, graph verification, workload limitations and all four NOT TESTED profiles. `component-measurements.json` records fresh independent Windows processes. `recovery-final-diagnostic.log` is the final recovery result; `existing-hosted-regression.log` confirms **21/21 previously implemented hosted tests still pass**. The other 197 historical tests were not needlessly repeated. **Do not report the expanded suite as fully passing: the five new tests yield four PASS and one ERROR.**

### Docker availability and installation needed

`docker`, `podman`, `nerdctl`, `wslc`, `lima` and `colima` are absent from PATH. Docker Desktop's system/per-user paths and the checked Podman paths do not exist. Windows reports no `com.docker.service`, `docker`, `podman`, `LxssManager` or `WslService` service. `wsl.exe` exists, but `--list --verbose` exits 1 with help text and `--status` exits 50; no functioning WSL distro/engine was demonstrated. No approved remote Linux environment was supplied/discovered. CIM OS inspection was denied, so virtualization/edition were not inferred from it. Python reports Windows build **22621**.

Install a supported **Docker Desktop for Windows with the WSL 2 Linux-container backend**, or provide an approved existing Linux Docker/cgroup-v2 machine. The current official Docker prerequisites specify Windows 11 build 22631 or higher and WSL 2.1.5 or later, so this machine first needs a supported Windows update and WSL setup/verification; do not silently install an older unsupported Docker version. Verify hardware virtualization and sufficient host/VM memory before the 8 GiB profile. Docker Desktop licensing/terms must be accepted by the owner. No software was downloaded or installed. [Official Windows installation requirements](https://docs.docker.com/desktop/setup/install/windows-install/).

**Future owner/admin actions, NOT executed:** update Windows to a supported release; install/enable WSL 2 (restart if requested); install Docker Desktop from the official download and select Linux containers. Example WSL setup commands, only after explicit system-change approval:

```powershell
wsl --install --no-distribution
wsl --update
wsl --version
wsl --status
```

Microsoft documents WSL installation/restart requirements in [Install WSL](https://learn.microsoft.com/en-us/windows/wsl/install). Then start Docker Desktop manually and verify `docker version`, `docker info`, and `docker info --format '{{.OSType}}'` reports `linux`; the CLI alone is insufficient. The existing deployment guide contains both exact image-build commands. Keep activation disabled and do not mount live state/credential directories. Allow enough Linux-VM RAM beyond an 8 GiB container plus OS/runtime overhead; test one profile at a time. An approved Linux machine avoids requiring changes to this Windows installation.

### Full-network fixture discovery and approval boundary

The broader inventory corrected an earlier incomplete search. The readable repository **already contains**:

```text
results/worker-readiness/20261027T083653Z-5f56bb/graphs/eab1f7ee-a8e0-4bed-a0e1-2c4bff024936.jsonl
```

- File length: **319,523,682 bytes**, **215 JSONL pages**.
- Actual streamed SHA256: **`a525f79eada8fc65ce0568fd0cdba66237f1e5e6e3009bb4fa0e7482fc70accb`**, matching both the sidecar and the independent historical value in `docs/stage8/functional-routing/LOCAL_SERVICE_PREPARATION.md`.
- Graph: **`eab1f7ee-a8e0-4bed-a0e1-2c4bff024936`**; coverage **`OSM-OPS-20261018`**.
- Database content digest in the historical manifest: **`5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a`**, matching `FROZEN_DEV_PILOT.md` and the original probe receipt. This differs intentionally from the file-byte SHA256; it is not a fresh database attestation.
- Stream verification PASS: identical manifest on every page; 926,414 unique ordered nodes, 2,145,828 ordered directed edges; manifest totals; endpoint membership; positive paired costs. No matrix was generated, graph downloaded or full Python dictionary graph materialized. These structural checks do not replace legacy/compact full-network shortest-path parity.

The matching candidate `results/proposed-only-routing/runtime-compatibility-input.json` has SHA256 **`efaa5bf99367138c7ca9e316d265046d7ba154a70fde30c582d9f6e6b45724b2`**. It contains five required road nodes and four observations, matching this graph/coverage. Its companion `runtime-compatibility.json` identifies it as an actual historical DEV SELECT capture for saved-result presentation replay. It is **not established as an approved sanitized performance fixture**, and lacks snapshot `cutoff`, `sealed_at`, `digest` and complete matrix envelope metadata required by the prepared solving/validation path. Do not invent those fields, treat a newly computed checksum as prior approval, or place raw capture data in images/reports. Only structural metadata/checksums were retained here; the bundle was not copied into benchmark inputs or used for planning.

The search also found small disposable local graphs/captures and frozen E4 precomputed matrices. Those are not a substitute for the operational graph plus representative bundle. Six protected backup/result directories returned access denied; they were not bypassed. The conclusion is **no approved complete sanitized pair found in the readable inventory**, not proof that no such bundle exists anywhere.

**Safe acquisition procedure under separate approval:** first reuse the verified graph above and search for a separately approved complete historical bundle. Have the data owner approve a dedicated offline derivative of the existing capture: deterministic identifier remapping with preserved references, removal of personal names/addresses/contact/vehicle identifiers, explicit approval for road-node/coordinate disclosure, complete policy/time/lease metadata, and preservation of matrix costs, capacities, time inequalities and admission outcomes. Any synthetic time rebasing or recomputed local digest must be labelled as an offline derivative, never a live attestation. Review small/typical/largest task/fleet workloads, not only the five-node capture; record source and derivative hashes plus approval receipt in an access-controlled fixture manifest. Do not fabricate missing authoritative evidence.

**A fresh graph export is not currently necessary.** If the owner requires freshness or the cache fails verification later, approve a narrowly scoped READ ONLY export first: exact DEV project/frozen graph, existing dedicated graph login only, verified TLS, `read_frozen_routing_graph` SELECTs with existing keyset cursors/page and total limits, no graph freezing/snapshots/candidates/activation. Use a new restricted output directory, keep credentials out of command arguments/logs, require one immutable manifest across all pages, verify cursor/count/endpoint integrity, seal the exact file bytes, and record operator/time/query/source hashes. A second operator verifies the seal/provenance. No postgres/service-role fallback, privileged credential extraction, new grants or SQL migration is permitted. Missing bundle metadata may require its own separately approved bounded READ ONLY capture; no new live routing request is needed or authorized.

### Separate component measurements; full-network capacity remains unknown

All new probes were uncapped Windows processes, Python 3.12.14. Disabled startup binds a temporary **loopback** HTTP listener and checks readiness; it does not activate a worker, load a graph, authenticate to Supabase or generate a route. The validator workload is an explicitly synthetic work item prepared outside its measurement process and served by an in-memory RPC double. Its three recorded attestations are **mock counters**, not database attestations.

| Fresh process | Time | Peak working set | Peak committed memory | Interpretation |
| --- | --- | --- | --- | --- |
| Planner disabled startup to `/health` | 0.325 s | 27.6 MiB | 19.0 MiB | HTTP 503 DISABLED, no graph/solver/DB |
| Validator disabled startup to `/health` | 0.469 s | 27.5 MiB | 19.1 MiB | HTTP 503 DISABLED, no DB |
| Independent validator, three synthetic checks | 0.00813 / 0.00546 / 0.00715 s | 24.6 MiB | 16.2 MiB | Validation code only; separate process, no real DB/TLS/HTTP attestation |

The existing 21 hosted tests also reconfirm API/JWT/proxy/UUID/receipt compatibility with offline doubles. These fresh component values do **not** qualify a 512 MB validator or any full-network planner plan. Prior small-graph/solver and historical full-network values remain explicitly dated in section 3.

| Resource profile | Planner full-network | Validator separately capped | Cold/restart/full-network HTTP |
| --- | --- | --- | --- |
| 512 MB / 0.1 CPU | NOT TESTED | NOT TESTED | NOT TESTED |
| 2 GB / 1 CPU | NOT TESTED | NOT TESTED | NOT TESTED |
| 4 GB / 2 CPU | NOT TESTED | NOT TESTED | NOT TESTED |
| 8 GB / 2 CPU | NOT TESTED | NOT TESTED | NOT TESTED |

No profile harness was launched because the runtime/approved workload prerequisites were not met. The prepared harness currently measures solver and independent validation in the planner benchmark process; it is **not yet a complete separate-validator-service or container cold/restart harness**. Extend the validation tooling to cover those separate stages before using it for plan qualification. Do not convert a successful harness exit or synthetic component footprint into a capacity PASS. **Minimum qualified paid plan remains NONE**; appropriate peak/concurrency headroom and the app's actual deadlines remain untested.

### Render proxy findings

New official Render material confirms its TLS-terminating load balancer and forwarded-protocol usage; a tutorial explicitly recommends `X-Forwarded-Proto` for the original scheme. This supports the transport choice but does not establish our exact peer allowlist/header contract. [Render authentication example](https://render.com/articles/how-to-implement-authentication-and-authorization), [Render web-service transport tutorial](https://render.com/tutorials/web-service-vs-static-site/web-services).

Render's security guidance recommends restricting forwarded-header trust to load-balancer IPs/CIDRs and validating hosts. It does not supply the actual Singapore ingress socket-peer networks or guarantee duplicate/forged X-Forwarded-Proto handling for this service. [Render proxy guidance](https://render.com/articles/fastapi-production-best-practices). The documented service **outbound** ranges are egress addresses, not evidence of ingress proxy peers; do not put those in `GEOLOCK_TRUSTED_PROXY_CIDRS`. [Outbound IP documentation](https://render.com/docs/outbound-ip-addresses).

Current code remains unchanged: actual peer CIDR membership + exactly one `https` protocol value + exact configured Host; no trust derived from client-controlled X-Forwarded-For/Host. **Compatibility is conditional, not proved incompatible or proved working.** Remaining evidence needed: provider/operator confirmation of ingress ranges or another verified exclusive ingress boundary; Host and X-Forwarded-Proto preservation/overwrite/duplicate behavior; bypass/private-ingress behavior and network changes. Prepare these questions for Render support/the service owner; no message was sent. No service was deployed to observe headers. Never solve this by trusting `*`, all private addresses or headers from arbitrary peers. Any transport adaptation needs review and negative tests, preserving NGO JWT and validator-token checks.

### Recovery rehearsal result and remaining gate

New reproducible test: `backend/routing/hosted/tests/test_recovery_rehearsal.py`. All journal files, SQLite backups and restores were created inside disposable synthetic temporary directories; no live DEV journal was opened, copied or modified. Production `Journal`, runtime and business functions were reused unchanged.

Four cases PASS: consistent SQLite backup/isolated restore with original request bindings and immutable step protection; backup no-overwrite/corrupt-restore rejection; committed mock authorization receipt recovered after journal restore without re-solving or a second authorization; older journal snapshot reconciles the committed mock DB receipt using the original UUID. Receipt replay still performs the expected protected ownership/snapshot read; that read was correctly retained in the test expectation.

**One case ERROR, reproducible:** a subprocess commits a synthetic journal step, holds the request OS lock and a deliberately open WAL read transaction, and is forcibly killed. Lock contention is correctly detected before termination. Fresh `Journal` bootstrap then fails at `PRAGMA journal_mode=WAL` with SQLite **3.53.1**, extended error **1546 / `SQLITE_IOERR_TRUNCATE`** (`disk I/O error`). The failure occurred again in isolated and fresh-bootstrap rechecks; final diagnostic log records it. The test does not reach the subsequent backup/restore stage in this crash case. Earlier logs are retained; no assertion was weakened or error marked as an expected success.

This establishes a **local Windows crash/WAL recovery failure under the tested temporary-filesystem/runtime conditions**, not a confirmed Render/Linux SQLite defect or a complete root-cause diagnosis. Do not claim full recovery readiness or change WAL settings, discard WAL/SHM, delete journal history, retry under a new UUID or repair live state based on this test. Investigate file-lock/truncation behavior locally and repeat abrupt termination on the actual Linux container/persistent-volume combination, alongside normal restart, SIGTERM drain, kill during each persisted step and restored receipts. Current production journal recovery/backup readiness remains unqualified.

### Exact next approval and stopping point

**Next approval needed: a supported local Linux container test environment.** The owner should authorize either (a) Windows update + WSL 2 + Docker Desktop installation and any restart, with owner acceptance of licensing/resources, or (b) use of a named existing approved Linux Docker/cgroup-v2 machine. Nothing was installed automatically. This is system/environment approval, **not** Render deployment or DEV write approval.

Separately approve the offline sanitized, complete workload derivative and local diagnosis of the reproduced crash case. Reuse the already verified historical graph; a new DEV graph export is not the next required action. After those prerequisites, build/inspect both images, verify Linux dependencies/nonroot/default-disabled/API behavior, resolve crash recovery, extend/run all separate-component/cold/restart resource profiles, establish proxy trust and backup/restore readiness, then review paid capacity and costs. All deployment/activation decisions remain withheld. No deployment, charges or live database operation occurred in this follow-up.

## 7. Docker-enabled validation — current verified result, 7 November 2026 MYT

**LOCAL DOCKER / REGRESSION / SYNTHETIC RECOVERY PASS. RENDER DEPLOYMENT NO-GO.** Container availability and the original Linux build/recovery blockers are resolved. Full-network **graph-stage** resource evidence is now available, including real failures under smaller limits. These results do not qualify a compute plan for a complete large operational routing request. No DEV/production connection or modification, live routing request, live journal/credential copy, SQL migration, hosted worker activation, cloud service, charge or push occurred. Public base-image/PyPI dependencies were downloaded only for the authorized local image builds.

### Docker, image and startup verification

Actual accessible environment: **Docker Desktop 4.98.0**, Engine **29.9.2**, context **desktop-linux**, Linux/amd64, WSL2 kernel `6.18.40.1-microsoft-standard-WSL2`, eight available CPUs and 10,314,182,656 bytes VM RAM. The execution shell's inherited PATH was stale. The installed CLI at `%LOCALAPPDATA%/Programs/DockerDesktop/resources/bin/docker.exe` worked with approved sandbox access; adding its directory to the individual build process PATH also resolved an initial credential-helper lookup failure. No Docker configuration, login, Windows installation or system PATH was changed.

Both **existing Dockerfiles** built successfully, without changing dependency pins or Dockerfile semantics. The final images include the narrow journal initialization fix described below:

| Image | Result | Final image ID |
| --- | --- | --- |
| `geolock-planner:validation-fixed-20261107` | **BUILD PASS** | `sha256:9dad7a112d031c65cd92c83880c9ce876b0ce79de36c1220b787c0b19e186173` |
| `geolock-validator:validation-fixed-20261107` | **BUILD PASS** | `sha256:73141a58d0e949a11a794e344ee19ed4ca0d46f88bb9699e8ebb3ddff0179371` |

Actual Linux Python **3.12.16**, OR-Tools **9.15.6755**, NumPy **2.5.4**, pandas **3.1.0**, psycopg **3.3.6**, SQLite **3.40.1** loaded successfully; `pip check` passed during both builds. Original pre-fix image tags/build logs are retained as separate evidence. Do not replace these tested image IDs with a later floating-tag rebuild and assume equivalence.

Image-only inspection, with no test/fixture mounts, found **60 application files, zero embedded tests and no graph exports, artifacts, journals, backups, CA/private-key or environment files** in either image. No GEOLOCK/PG credential environment values are baked in; runtime role configuration still comes from secrets/environment. An additional AST literal audit of **54 Python files per image** found no private-key, Supabase-secret, JWT or credentialed-PostgreSQL-URL literals; matched values would never be printed. Both images run as **UID/GID 10001:10001**. Dockerfile context restrictions and separate credential/role guards remain intact. These are scoped application filesystem/configuration/literal audits, not universal secret or dependency-vulnerability certifications.

The **actual image CMD**, not just an imported test handler, was run separately for both roles with no credentials, no published host ports and `--network none`. With explicit test PORT values, both bound **0.0.0.0:PORT**, returned `/live` **200** and `/health` **503 DISABLED**, and exited **0** after SIGTERM. No planner or validator was activated against DEV. `actual-cmd-port-sigterm.json` records commands, identity, binding and termination. Active readiness with real graph/role/validator connections remains a separately approved integration check.

### Forced-crash root cause and minimal mitigation

The unchanged Linux image first passed **26/26** hosted tests, including the original forced-crash case. The original Windows crash test also passed on this session's pre-fix rerun: the prior failure is intermittent, not a deterministic data-binding failure. A controlled Windows-only reproducer then established the mechanism: while a synthetic SQLite `-shm` file remained memory-mapped, SQLite **3.53.1** failed at WAL initialization with **1546 / SQLITE_IOERR_TRUNCATE**; after unmapping it, the same database reopened with its committed payload intact. See `windows-mapped-shm-root-cause.log`.

This matches the SQLite Windows VFS mapped-view truncation issue, acknowledged and fixed upstream by a SQLite maintainer. The direct reproduction confirms the mechanism; attribution of the earlier crash to delayed mapped-view release is supported by the identical error/context, not an unavailable syscall trace of that historical process. [SQLite maintainer discussion and fix reference](https://sqlite.org/forum/info/ba7afbd0e81501118563617430fe06d0aca052e55ece2b0d457f8e16fcf85bba).

Minimal production change: **`backend/routing/worker_service/journal.py`** extracts existing idempotent initialization into `_initialize()` and retries **only Windows OperationalError code 1546**, at up to 50 ms intervals for a three-second bounded retry window. It closes/rolls back each failed connection before retrying. The existing `PRAGMA journal_mode=WAL` and `CREATE TABLE IF NOT EXISTS` statements are preserved. All other errors, Linux errors and persistent failures propagate. There is **no general retry of payload/business writes, no WAL/SHM deletion, no journal-mode downgrade, no binding repair or new request UUID**. No global Python/SQLite library was installed or replaced. The Windows launcher/configuration workflow is unchanged.

New `backend/routing/hosted/tests/test_journal_initialization.py` checks transient success with preserved evidence, exact platform/error scoping, bounded failure with unchanged evidence, and actual Windows mapped-view release. The Linux code path retains one-attempt initialization. The mitigation handles this known transient initialization race; it does not claim to repair arbitrary SQLite damage or guarantee storage durability under power loss.

### Regression and isolated recovery results

| Final suite | Result | Evidence in `routing-render-docker-validation/` |
| --- | --- | --- |
| Windows hosted/recovery/init tests | **30 passed** | `windows-hosted-after.log` |
| Windows existing worker regression | **153 passed** | `windows-worker-regression.log` |
| Linux hosted/recovery/init tests | **29 passed, 1 Windows-only skip** (30 run) | `linux-hosted-after.log` |
| Linux matrix/integration/worker/combined/HTTP core | **88 passed** | `linux-core-regression.log` |
| Frozen v3.3 sample at four resource caps | **48/48 plans independently valid** | `frozen-resource-receipts.json` |
| Separate-container SIGKILL + Linux-volume reopen | **PASS** | `container-crash-state.json`, `linux-volume-crash-reopen.log` |

The container crash test used a **new, uniquely named synthetic-only Docker volume**, verified as a real mount owned by UID 10001. A process committed a step, held the request lock and an open WAL read transaction, then was killed with SIGKILL. A fresh container reopened that volume and recovered the exact step/request binding. Journal mode **0600** and directory mode **0700** were verified. Separate backup/restore tests checked SQLite integrity, no-overwrite, corrupted input rejection, ownership/request conflicts, immutable payloads, original-UUID receipt recovery, and an older synthetic journal reconciling a committed mock DB authorization without another solve/authorization. No live state was copied. All test containers and the disposable volume were removed after receipt capture; local images/logs remain for review.

This clears the local Linux process-crash/restore blocker for the tested storage configuration. It is not a rehearsal on a real Render disk, a real DEV journal or an off-service backup, and does not replace the named recovery operator/current verified baseline required before deployment.

### Measured full-network resource results

Detailed CPU, process RSS, cgroup peaks, load/compile/matrix timings, per-method solver results and startup timings are in [MEASUREMENTS.md](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/investigations/routing-render-docker-validation/MEASUREMENTS.md), backed by raw JSON/logs. **38 isolated main cases completed: three real OOM failures, zero timeouts.** Four additional frozen-sample resource runs passed. Limits were enforced with Docker memory, equal memory+swap limit, CPU quotas, read-only roots, nonroot users and disabled networking. Receipts include actual `memory.max`, `cpu.max`, CPU usage/throttling, Docker OOM state and image IDs.

The complete historical graph was loaded from the **unchanged 319,523,682-byte sealed export** already verified in section 6. It contains **926,414 nodes and 2,145,828 directed edges**. Every successful graph case generated the **entire recorded three-node reference matrix twice** and matched its identity, weights, durations, policies, provenance and statuses exactly, including canonical graph SHA256 **`cbccfa866bebbffe8382f6f54f9fdacb3a470d84d581e954e59014fd9454d005`**. No graph was obtained from DEV.

| Profile | Legacy JSON/conversion path | Compact compile from JSON | Independently sealed artifact reload |
| --- | --- | --- | --- |
| 512 MiB / 0.1 CPU | **OOM, exit 137** | **OOM, exit 137** | **Graph-stage PASS**, 173.1 MiB peak RSS; load 9.60 s |
| 2 GiB / 1 CPU | **OOM, exit 137** | **Graph-stage PASS**, 1508.0 MiB peak RSS | **Graph-stage PASS**, 172.8 MiB peak RSS; load 2.45 s |
| 4 GiB / 2 CPU | **Graph-stage PASS**, 3606.8 MiB peak RSS | **Graph-stage PASS**, 1507.8 MiB peak RSS | **Graph-stage PASS**, 173.0 MiB peak RSS; load 1.33 s |
| 8 GiB / 2 CPU | **Graph-stage PASS**, 3606.7 MiB peak RSS | **Graph-stage PASS**, 1508.3 MiB peak RSS | **Graph-stage PASS**, 173.3 MiB peak RSS; load 2.30 s |

At 8 GiB, compact export load took **21.72 s**, compilation/artifact write+seal **58.63 s**, and matrices **0.00482 / 0.00448 s**, with **68.85 process CPU seconds**. Legacy export load took **23.48 s**, matrices **57.20 / 60.78 s**, with **129.50 process CPU seconds**. Compact moves full conversion out of repeated requests; the reference nodes are close together, so the Dijkstra work is small once the graph exists. This is not a timing bound for long-distance/100-node matrices.

Artifact SHA256 **`7958972d08ea412c7515a47521640588528daa206440a198db2ad47507b8bd01`** was captured in the controller's receipt after compilation and passed explicitly into new processes. The artifact and historical manifest were checked before reload; no full-export parse was performed in artifact cases. The test artifact lived only on the disposable volume and was removed with it. The production path still requires the protected current frozen-manifest read. No artifact was baked into an image or provisioned to cloud storage.

Cold here means **fresh process/import/file-load**. Host/VM file caches were not flushed; tests exclude network export/download, Supabase TLS/RPC latency and real active service readiness. OOM cases have no completed in-process peak receipt; the exact cap/`OOMKilled=true` is reported instead of an invented peak. A single passing graph run and a small matrix do not establish a workload distribution or safe operational headroom. In particular the legacy 4 GiB graph peak already consumes about 88% of its cap before a complete operational capacity review.

At **512 MiB / 0.1 CPU**, even disabled planner/validator startup-to-health took **7.39 / 6.30 s**, longer than the existing Flutter five-second diagnostic deadline, before any graph or database warm-up. This is an observed cold-readiness limitation, not a reason to weaken TLS/authentication or silently extend client timeouts. Actual active-service readiness still needs a coordinated acceptance test after deployment approval.

### Planner, validator and solver measurements

The existing synthetic **1,000-node / 3,000-edge** fixture was reused separately from the real graph. Both graph engines produced the same matrix seal as prior Windows evidence. All four existing methods, including the unchanged proposed CP-SAT implementation, returned independently valid plans at every resource cap. No protected business operation ran.

| Profile | Synthetic planner peak RSS (legacy / compact) | Four-method wall s (legacy / compact) | Separate validator peak RSS | Validator process CPU s |
| --- | --- | --- | --- | --- |
| 512 MiB / 0.1 CPU | 106.3 / 105.2 MiB | 9.90 / 7.70 | 29.2 MiB | 0.796 |
| 2 GiB / 1 CPU | 106.1 / 106.1 MiB | 1.31 / 1.32 | 29.0 MiB | 1.234 |
| 4 GiB / 2 CPU | 105.9 / 106.5 MiB | 1.27 / 1.21 | 29.1 MiB | 1.289 |
| 8 GiB / 2 CPU | 106.2 / 106.3 MiB | 1.25 / 1.09 | 29.1 MiB | 1.262 |

Validator checks used an existing synthetic unit work item with in-memory read/attestation doubles, in a **separate validator-image process**. Three checks ran per profile; at 0.1 CPU their wall times were 0.0038 / 0.0890 / 0.0029 s, showing scheduler/throttle variability. They exclude real DB/HTTP latency and do not establish maximum work-item memory. Per-method wall/solver/status/coverage information, per-process CPU time and cgroup counters are retained in raw receipts. RSS and cgroup peaks differ because shared/file-backed pages may be charged elsewhere; do not silently substitute one for the other.

The unchanged frozen **GEOLOCK-BM-v3.3** CSVs were verified against their manifest and exported into new synthetic snapshots for the same three min/median/max admission positions used in earlier local evidence (3, 5 and 5 tasks). Input/matrix hashes were checked again inside Linux before solving. Each resource cap ran all four methods on all three snapshots: **12 valid plans per cap, 48 total**. This is a sample using precomputed benchmark matrices and its existing policy, not the full E4 experiment or a replacement for an operational bundle. Original datasets/results were not changed. Exact per-scenario/method times, memory/CPU and outcomes are in `frozen-resource-receipts.json` and the measurement table.

### Remaining security, capacity and deployment blockers

**Minimum end-to-end capacity-qualified Render plan: NONE.** Graph-stage evidence supports compact compilation at 2 GiB and sealed-artifact matrix reload at 512 MiB for this three-node probe; it does not qualify complete routing, worst-case fleet/tasks, 100 required nodes, contention or uncertain-commit recovery at those caps. The raw saved-result capture identified in section 6 is still partial and not an approved sanitized solving fixture. Its missing authoritative envelope fields were not fabricated and it was not used in these tests. No full-network operational **matrix → all four methods → independent validator → authorized receipt** benchmark was performed.

**Render Free remains NO-GO for this implementation.** The artifact result removes a blanket claim that the immutable graph alone must exceed 512 MiB. It does not provide a durable planner journal, eliminate cold-start readiness constraints, establish large-workload fit or solve the two-service instance-hour budget. The hosted path still rejects ephemeral planner activation. No external journal, new database table, grant, bucket policy or alternate authority was implemented.

**Actual Render proxy compatibility remains unverified.** Current code and negative tests retain actual-peer CIDR membership, exact Host and single HTTPS forwarding-header checks; NGO JWT and independent validator-token checks remain. Official Render documentation supports edge TLS/forwarding and constrained proxy trust, but the exact ingress-peer ranges, Host behavior and forged/duplicate protocol-header handling needed for these services were not established. Public egress ranges are not ingress proof. No service was deployed to discover them and no support message was sent. [Render security guidance](https://render.com/articles/fastapi-production-best-practices), [web services](https://render.com/docs/web-services), [egress ranges](https://render.com/docs/outbound-ip-addresses).

Required next steps, without repeating already approved Docker setup:

1. **Next approval needed:** preparation/use of a complete sanitized offline operational workload derivative, with authoritative envelope metadata, preserved references/time/lease/policy constraints, approved location handling and a reviewed workload range up to the largest intended task/fleet/node set. Prefer existing historical data; no new live routing request or privileged graph download is required. Approve a separately scoped READ ONLY capture only if complete historical evidence is unavailable. No live journal/credential copy is implied.
2. Run that workload end-to-end offline, including real CP-SAT/independent validation, larger matrices, concurrency, restart/lost-response cases and headroom measurements. Set a capacity recommendation only afterward; keep legacy/compact/artifact paths and graph seals explicit. The review Blueprint's plans remain provisional, not automatically reduced from these results.
3. Obtain verified Render ingress/header guarantees or a separately reviewed exclusive ingress adaptation; never use a wildcard/private-network blanket allowlist. Leave activation disabled.
4. Name the recovery/deployment operator and verify the current approved DEV baseline plus off-service backup/isolated recovery procedure. Synthetic Linux-volume success is useful evidence, not proof that a current real backup exists. Read-only deployed-role/RPC/graph/network preflight and actual Render disk/runtime validation remain outstanding.
5. After those gates, separately approve exact image/configuration, paid compute/disk budget and deployment/activation. No creation, charge, deployment or activation is authorized by this report. A hosted supervisor APK and physical-phone live acceptance require that later coordinated approval.

### Changed files and receipt integrity

Existing production file changed: **`backend/routing/worker_service/journal.py` only**, for the exact Windows initialization retry. New test: **`backend/routing/hosted/tests/test_journal_initialization.py`**. Dockerfiles, graph/optimizer/validator semantics, protected transports, existing Windows launcher, Flutter, SQL and constraints were preserved. New local validation tools, sanitized synthetic fixture derivatives, raw receipts and measurements are isolated under **`docs/investigations/routing-render-docker-validation/`**. This report and the deployment guide's dated verification note were updated. The earlier failing logs and source/checksum receipts remain historical evidence; new seals identify the current version rather than rewriting them.

**Stop point: local validation and reporting only. Overall deployment decision remains NO-GO pending the explicit gates above.**

## 8. Provisional workload capacity and hosting choice — current result

7 November 2026 MYT. **Offline modeled benchmarks complete. No production code or journal redesign changed in this stage.** No DEV/production database access, live journal/credential copy, cloud deployment, charge, worker activation or push occurred. Prior image/regression/recovery evidence remains historical evidence; it was not needlessly rerun. New work is isolated in `docs/investigations/routing-render-workload-validation/` and the design-only hosting comparison.

Detailed artifacts:

- [Current workload measurements](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/investigations/routing-render-workload-validation/MEASUREMENTS.md), backed by `run2/receipts.json`, per-case logs and offline plans.
- [Workload fact/approval gaps](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/investigations/routing-render-workload-validation/WORKLOAD_GAPS.md).
- [Hosting and durable-recovery options](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/investigations/ROUTING_HOSTING_RECOVERY_OPTIONS.md).

### What was authorized and modeled

The user authorized provisional offline workloads and a design comparison of Render Free/external recovery, paid Render/SQLite and other free/low-cost alternatives, **without implementing the journal redesign**. The modeled cases are:

| Case | Pickups | Vehicles | Distinct required road nodes |
| --- | ---: | ---: | ---: |
| Small | 3 | 2 | 4 |
| Typical — provisional | 10 | 2 | 11 |
| Large — provisional | 25 | 5 | 26 |
| Source-boundary stress | 100 | 10 | 100 |

These are not measured NGO demand distributions, observed fleet maxima or deployment approvals. At the 100-task boundary, two tasks share one of 99 pickup nodes plus the depot. Local source permits at most 100 observations and 100 matrix nodes; that is not evidence that 100 distinct pickup locations plus a depot are supported or that deployed limits are unchanged.

The original synthetic v3.3 templates supply timing, weights, direct-donation structure and 100 kg car/500 kg van facts. Replicas use explicitly synthetic identities. The inherited benchmark policy remains optional tasks, 10-minute service, 240-minute horizon, 30-second solver wall budget, one worker, seed42 and deterministic 0.25s/pass. **This is not asserted to be current DEV policy.** Source/input hashes and state tokens are local canonical benchmark hashes, not invented PostgreSQL snapshot metadata, approvals, attestations or database receipts. Every input has `source.kind=SYNTHETIC_BENCHMARK`, `project_ref=null`, and no dispatch authority.

The actual saved-result capture is still partial and was not filled with guessed envelope fields. To avoid fabricating DB authority, these benchmarks use the same four production method callables and independent **raw-input plan validation**. They do not claim to exercise protected source work-item reads, DB digest/claim/lease joins, attestation RPCs or final NGO authorization. The exact missing operational facts are enumerated in `WORKLOAD_GAPS.md`.

### Full graph, geographic selection and parity

The existing sealed export is unchanged: 926,414 nodes, 2,145,828 directed edges; file SHA256 `a525f79eada8fc65ce0568fd0cdba66237f1e5e6e3009bb4fa0e7482fc70accb`. The compact artifact rebuilt to the same independently expected SHA256 `7958972d08ea412c7515a47521640588528daa206440a198db2ad47507b8bd01`. It was not baked into images or uploaded anywhere.

Initial preparation failed safely: the original selected benchmark depot had only 77 known matched road nodes within 17 km. A second preparation checked existing sample depots; one depot was absent from the graph, while benchmark **NGO001 / SCN-ROUTE_PLANNING-0045** supplied 223 mutually reachable known public benchmark nodes inside the radius. The case factory explicitly selected that depot and recorded the decision. Initial failed logs/receipts are retained. No coordinates or operational facts were invented to force a desired count.

The largest selection spans 16.95 km straight-line distance using public benchmark coordinates. Those coordinates were not freshly checked against DEV. Connectivity/radius filtering selects workload locations only: **all shortest paths still search the complete graph**, without cropping, road-weight changes, approximations or tie-policy changes. The full 100-node matrix matched the legacy implementation in its entirety: compact **64.83 s**, legacy **180.00 s** during preparation at 8 GiB / 2 CPU. The prior nearby three-node millisecond result was not a representative upper bound for larger geography/node sets.

Because the entities are modeled, the unchanged benchmark contract requires a synthetic trust/provenance wrapper around the real-graph matrix. Numeric costs, path rules and the graph version remain unchanged; raw graph-matrix hashes and wrapped local input/matrix hashes are separately recorded. No wrapper is passed to a live protected RPC.

### Resource and routing outcomes

The successful second run contains **34 isolated cases**: artifact compile, preparation/parity, 16 planner runs and 16 separate validator runs. **Zero OOM kills, one externally enforced 300-second timeout.** All containers used the existing sealed images, UID 10001, no network, capped memory with no extra swap and CPU quotas. Only public/synthetic fixtures and the disposable graph-artifact volume were mounted. That volume/test containers were removed after receipt capture.

| Workload / selected profile | Planner wall | Peak process RSS | Proposed outcome |
| --- | ---: | ---: | --- |
| 3 pickups, 512 MiB / 0.1 CPU | 52.9 s | 280.0 MiB | Usable, all three served |
| 3 pickups, 2 GiB / 1 CPU | 5.2 s | 280.1 MiB | Usable, all three served |
| 10 pickups, 512 MiB / 0.1 CPU | 121.8 s | 310.7 MiB | Usable incumbent, all ten served; insufficient review reserve |
| 10 pickups, 2 GiB / 1 CPU | 9.8 s | 310.6 MiB | Usable incumbent, all ten served |
| 25 pickups, 2 GiB / 1 CPU | 19.2 s | 324.9 MiB | CP-SAT UNKNOWN/no usable incumbent |
| 25 pickups, 8 GiB / 2 CPU | 22.2 s | 323.3 MiB | Same solver-budget failure |
| 100 pickups, 512 MiB / 0.1 CPU | stopped at 300 s | No completed peak receipt | External timeout, not an OOM result |
| 100 pickups, 8 GiB / 2 CPU | 85.0 s | 543.8 MiB | Matrix completed; CP-SAT UNKNOWN/no usable incumbent |

Every completed planner ran all four unchanged methods and independently checked their outputs. Structural validity includes correctly unusable no-incumbent reports; it does not mean a route exists. At 25 pickups both heuristics served all 25, but both CP-SAT methods reported UNKNOWN and zero served. At the 100-pickup 8 GiB run, FCFS served 65 and nearest-neighbour 90, while CP-SAT produced no usable incumbent. **These are not mathematical proofs of infeasibility or successful proposed-route generation.** No objective/budget was relaxed and no baseline route was substituted for the required proposed candidate. The failures apply to the retained benchmark policy; current operational policy remains unverified.

All 16 independent validator processes successfully checked their four reports. At the failed 512 MiB/100-node planner, validator-only testing used the completed 8 GiB reference plans and labels that fallback; it does not imply the failed planner succeeded. The largest validator peak was **31.4 MiB RSS / 22.8 MiB cgroup memory**, including inputs with 100 tasks and baseline routes. **512 MiB / 0.1 CPU is the smallest tested raw-plan-validator resource profile**, with substantial component memory reserve. The largest 512 MiB validator process took about 10.7 seconds including cold imports. Actual trusted work-item envelope, DB/TLS/network/freshness/attestation overhead remain unmeasured in this stage.

### Minimum tested envelope and headroom interpretation

For review, an explicit screening assumption was used: usable proposed route; process wall time at most **120 s** to leave a nominal 30 s inside the existing 150 s app POST deadline; and at least **30% RAM reserve**, using the greater of observed RSS/cgroup peak plus a conservative **72 MiB cold-artifact page-cache allowance**. No host cache flush/P95 study was performed. These are engineering screening assumptions, not provider guarantees or a claim that 30 seconds always covers real network/database work.

- The modeled three-pickup case screens at 512 MiB / 0.1 CPU.
- The modeled ten-pickup case first screens at **2 GiB / 1 CPU among the four tested profiles**. Its 512 MiB run falls short on reserve and time despite returning a valid incumbent. Intermediate capacities/paid 0.5-CPU SKU were not tested.
- There is **no passing full proposed-routing capacity** for the modeled 25/100 cases under the unchanged search policy, even where RAM is ample. More RAM alone is not the fix for that deterministic solver-budget limit.
- There is **no production-qualified Render plan** yet: real policy/envelope, larger/mixed-source demand, repeated/concurrent/provider measurements and remaining deployment gates still matter.

### External journal feasibility and recommended FYP path

Replacing SQLite with durable state in the **existing Supabase PostgreSQL backend is feasible in principle**, but current tables/receipts do not establish a complete drop-in journal. Exact computed payloads, pre-authorization negative outcomes/intents, original owner/request bindings, immutable equality-on-replay and fenced execution ownership must survive every commit gap. New narrow RPCs/private storage or another justified equivalent, grants/ownership review, pooler-safe locking, cross-role fencing, rollback and disposable crash/concurrency tests would need separate approval. Final authorization must still use the NGO's valid JWT; no bearer/refresh tokens should be stored. A PG journal would not fix graph/solver latency, Free cold starts, shared instance hours, database pause/quota or missing backup readiness. **No journal redesign, new table, SQL migration or grant was implemented.**

The [hosting/recovery comparison](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/investigations/ROUTING_HOSTING_RECOVERY_OPTIONS.md) gives requirements, guarantees/limits and sourced cost assumptions. Preferred FYP choices:

1. **If a maintained university VM with public HTTPS/persistent storage is genuinely available:** investigate that first for zero incremental compute cost, retaining two isolated service identities and the existing SQLite design. Availability/operator permission is unknown.
2. **For simplest managed hosting:** retain SQLite and use two always-on paid Render services, with sealed compact artifact and planner disk. A conservative demonstration budget candidate is **2 GiB / 1 CPU planner + 512 MiB validator + 1 GiB disk ≈ $32.25/month**, plus the existing Supabase plan/other usage/tax costs. This is not deployment approval. Approve a bounded demonstration scope (currently modeled 3–10 direct pickups/two vehicles), then verify actual policy/source/roles and remaining gates. A smaller $14.25 two-512-MiB budget is not the recommended ten-pickup envelope on present evidence.
3. **Render Free + PostgreSQL journal:** potentially $0 incremental compute for intermittent usage, but requires the substantial unimplemented recovery/readiness/client/artifact work and existing Supabase headroom. It is not the shortest safe demonstration path. Oracle Always Free may retain SQLite on a VM but has account/capacity/ARM/idle-reclamation uncertainty; Railway starts with a $5 minimum plus actual resource usage, not guaranteed free. No account or service was created.

List prices/limitations and explicit assumptions are sourced in the comparison; account entitlements, current Supabase costs and available free capacity were not inspected. Recommendations are architecture judgments, not claims that any hosting option has passed deployment gates.

### Remaining gates and stop point

Confirm the bounded demonstration scope and actual policy; approve a complete sanitized operational work-item fixture or separately reviewed disposable-DB equivalent if full trusted integration validation is required. If 25/100 pickups must be supported, review an explicit solver-budget experiment separately while preserving the objective, correctness and freshness/custody protections. Do not call the current no-incumbent result a successful route or silently replace it with a baseline.

Render ingress peer/Host/forwarded-header guarantees remain unverified. The real backup/operator/isolated restore and actual mounted-disk/role/network preflight remain outstanding; earlier local recovery PASS does not substitute for them. Public HTTPS endpoint and hosted supervisor APK acceptance need later coordinated deployment approval. The user has authorized neither journal implementation nor cloud creation/activation/charges. **Stop after this offline report. Overall deployment decision remains NO-GO.**
