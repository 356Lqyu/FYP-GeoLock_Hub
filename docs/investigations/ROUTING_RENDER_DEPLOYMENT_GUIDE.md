# Render DEV routing deployment guide — review only

**POSTPONED / NOT SELECTED — owner decision, 7 November 2026.** Use the existing [Windows laptop workflow](../LOCAL_ROUTING_WINDOWS.md). Everything below is retained historical preparation, not the selected workflow or authorization to deploy. No Docker, Linux or cloud service is required for local routing.

Prepared 7 November 2026 MYT. **No deployment is authorized by this guide.** The accompanying readiness report is PARTIAL / NO-GO for deployment. Commands below are future operator procedures, not actions executed during preparation. Do not create Render services until Linux builds, full-network capacity, ingress trust and recovery prerequisites are accepted and the owner separately approves costs and activation.

Docker follow-up: local Linux image builds, disabled CMD/PORT checks, regression, synthetic recovery and constrained graph-stage measurements have now been executed successfully as detailed in readiness-report section 7. A narrow Windows SQLite initialization retry is included in the final tested image IDs. Deployment remains NO-GO: graph-stage results are not complete operational capacity qualification, and provider ingress/current backup prerequisites are still open. Earlier untested-build statements are superseded by that dated evidence.

## 1. Services and compute selection

Use two separate Docker **web services**: planner and independent validator. The planner uses the graph and planner logins; the validator uses only its validator login. Neither has a Supabase service-role key, postgres login, or another service's database password. Flutter talks only to the planner over public HTTPS; the planner calls the validator over HTTPS with a server-only token. Authorization still executes under the original verified NGO JWT.

Review `backend/routing/hosted/render.review.yaml` using the repository root as Docker context. It specifies manual deploys, one instance each, Singapore, a planner disk mounted at `/var/data`, and disabled activation flags. Its **8 GB / 2 CPU planner and 2 GB / 1 CPU validator are provisional benchmark targets, not demonstrated minimum plans**. Even disabled services and disks incur charges when created. Do not apply this Blueprint as a free trial. Current plan identifiers are documented in [Render compute plans](https://render.com/docs/compute-plans).

Docker files:

```powershell
# Future local build checks after Docker is available. No DEV credentials needed.
docker build -f backend/routing/hosted/docker/planner.Dockerfile -t geolock-planner:review .
docker build -f backend/routing/hosted/docker/validator.Dockerfile -t geolock-validator:review .
docker run --rm --network none geolock-planner:review python -m backend.routing.hosted --mode planner --check-config
docker run --rm --network none geolock-validator:review python -m backend.routing.hosted --mode validator --check-config
```

Expected disabled check: `active:false, connected:false`. The image builds and pinned Linux wheels are now locally verified; use the final image/dependency receipts from readiness-report section 7. Keep the exact solver pins and revalidate any later rebuild/version change. Pin the accepted Python image digest and record dependency/build/image hashes before deployment. Inspect the built image for credential files and graph exports; Dockerfile-specific ignore files allow only source and dependency files. Never add a graph export, `.env`, backup or password to the image, repository, build arguments or build command. No database/build/predeploy hook is configured.

In Render, after separate approval: create validator first, then planner, choose Docker and the appropriate Dockerfile path, disable automatic deploys and previews, one instance, no autoscaling. Attach the planner's persistent disk before activation. The service command comes from each image's CMD. Render receives HTTP on `0.0.0.0:$PORT` (default 10000), terminating public TLS at its proxy. See [web services](https://render.com/docs/web-services). Use `/live` for Render liveness; **`/health` is application readiness and must return ACTIVE before any APK test**. A green liveness check alone does not authorize routing or establish graph readiness.

## 2. Runtime environment and separate credentials

Configure values through Render environment secrets and runtime secret files. No values are supplied in this guide. Do not reuse one environment group containing all three database credentials for both services.

| Variable | Planner | Validator | Requirement |
| --- | --- | --- | --- |
| `PORT` | Yes | Yes | Render-provided integer, bound on all interfaces |
| `GEOLOCK_PROJECT_REF` | Yes | Yes | DEV project `rcgyuwiidqvrgbxswhqj` only |
| `GEOLOCK_PUBLIC_URL` | Yes | Yes | This service's exact HTTPS root URL, no path, query or credentials |
| `GEOLOCK_TRUSTED_PROXY_CIDRS` | Yes | Yes | Verified actual socket-peer ingress networks; comma separated; no `/0` |
| `GEOLOCK_ROUTING_ALLOW_DEV_WRITES` | Yes | Yes | Initially DISABLED; APPROVED only after separate activation approval |
| `GEOLOCK_ROUTING_ACTIVATION_REF` | Yes | Yes | Approved activation/change receipt, never an invented authorization |
| `GEOLOCK_VALIDATOR_TOKEN` | Yes | Yes | Same randomly generated server secret, at least 32 characters; never in Flutter |
| `GEOLOCK_VALIDATOR_URL` | Yes | No | Validator's exact public HTTPS root URL |
| `GEOLOCK_GRAPH_DSN` | Yes | Forbidden | Existing dedicated graph login, DEV only |
| `GEOLOCK_PLANNER_DSN` | Yes | Forbidden | Existing dedicated planner login, DEV only |
| `GEOLOCK_VALIDATOR_DSN` | Forbidden | Yes | Existing dedicated validator login, DEV only |
| `GEOLOCK_GRAPH_PASSWORD` or `_PASSWORD_FILE` | Yes | Forbidden | Exactly one source; file alternative uses `GEOLOCK_GRAPH_PASSWORD_FILE` |
| `GEOLOCK_PLANNER_PASSWORD` or `_PASSWORD_FILE` | Yes | Forbidden | Exactly one source |
| `GEOLOCK_VALIDATOR_PASSWORD` or `_PASSWORD_FILE` | Forbidden | Yes | Exactly one source |
| `GEOLOCK_SUPABASE_PUBLISHABLE_KEY` | Yes | No | Existing DEV client publishable key; not a privileged key |
| `GEOLOCK_GRAPH_ID` | Yes | No | Previously approved frozen graph; reconfirm current identity/digest before deployment |
| `GEOLOCK_STATE_MOUNT` | Yes | No | `/var/data`, verified as a mounted filesystem at startup |
| `GEOLOCK_WORKER_STATE` | Yes | No | `/var/data/routing`, strictly beneath the mounted directory |
| `GEOLOCK_PERSISTENCE_MODE` | Yes | No | `mounted-disk`; ephemeral planner activation is rejected |
| `GEOLOCK_GRAPH_ENGINE` | Yes | No | `legacy` initially; `compact` only after full-network parity/capacity acceptance |
| `GEOLOCK_COMBINED_ROUTE_ENABLED` | Yes | No | Initially DISABLED; APPROVED for approved combined generate-and-authorize workflow |
| `GEOLOCK_MAX_SNAPSHOT_AGE_SECONDS` | Optional | Optional | Default 300, existing freshness checks preserved; do not extend merely to mask slow hosting |
| `GEOLOCK_CORS_ORIGINS` | Optional | Optional | Explicit HTTPS origins only if a browser client needs them; Android needs no CORS exception |
| `GEOLOCK_COMPACT_ARTIFACT` / `_SHA256` | Optional | No | Path and independently trusted SHA256 pair, only with compact engine; not request inputs |

DSNs contain **no password**. Use libpq conninfo for the existing dedicated `geolock_graph_login`, `geolock_planner_login`, or `geolock_validator_login`. For an already approved pooler, retain its project-qualified login syntax and reviewed host/port. Preserve `sslmode=verify-full`, `sslrootcert=/etc/secrets/dev-db-ca.pem`, DEV host, `dbname=postgres`, and existing role allowlists. Supply the verified database CA through a Render runtime secret file named `dev-db-ca.pem`; do not download a random CA or use `sslmode=require` as a substitute. Preserve the approved connection configuration; recheck Render egress/connectivity and Supabase network restrictions read-only before activation. Missing credentials, CA, mount, incorrect logins or cross-service credentials fail closed. `--check-config` reads configuration/files without connecting and prints no secrets.

**Ingress trust remains a blocker.** The implementation trusts forwarded HTTPS only when the actual TCP peer is in an explicitly configured verified CIDR, Host matches the configured public URL, and exactly one `X-Forwarded-Proto: https` is received. It ignores `X-Forwarded-For` and `X-Forwarded-Host`. No Render ingress CIDR/header-overwrite guarantee was established during this task. Obtain it from Render/operator evidence and test actual requests, including forged/duplicate headers, before activation. Do not guess egress IPs as ingress CIDRs or configure all IPv4/IPv6/private space to make it work. If Render cannot provide a suitable trust boundary, arrange an approved ingress configuration or separately reviewed transport adaptation. Public health responses disclose no secrets; validator mutation calls still require the separate token.

The hosted entry point supports the existing normal and combined RPC workflow, UUIDs, receipts and recovery endpoints. The staged exact-two operator workflow is intentionally not enabled by this separate bootstrap; it is not required for the normal four-method CP-SAT workflow and its Windows activation path remains intact.

## 3. Graph provisioning and offline capacity acceptance

No graph is baked into either image. Legacy startup uses the existing protected paged graph reader and disk-sealed JSONL cache; every startup checks the live frozen manifest. It does not change/freeze a database graph. Compact mode compiles that export once per process and drops the retained export afterward. Initial download/JSON parsing/compilation can still have a large peak.

A prebuilt artifact can avoid full-export loading in the hosted planner. Its operator-provided SHA256 and entire manifest must match; the live protected manifest page is still required. Provision only after approved export provenance, full-network matrix parity and isolated restart testing. Do not treat a hash next to an untrusted download as its own trust root. No external download adapter was implemented.

```powershell
# Offline only; substitute an ALREADY APPROVED sealed export and a fresh output.
python -B -m backend.routing.hosted.artifact --export <approved-graph.jsonl> --export-sha256 <reviewed-export-sha256> --output <new-graph.csr>
```

Transfer artifacts through a separately approved operator procedure to the persistent disk, not a Docker build. Record export, manifest, graph-canonical and artifact hashes. Restore old artifacts only with their matching graph identity/manifest; never ignore a manifest mismatch. The binary format is versioned and little-endian; it is an opt-in candidate, not a replacement for the original Windows cache.

For future local resource tests, provide `graph.jsonl` (approved full export) and `bundle.json` (matching, sanitized approved DB-shaped workload) in one read-only fixtures directory. Do not substitute the frozen E4 distance matrix for a full-network export.

```powershell
python -B -m backend.routing.hosted.run_resource_profiles --image geolock-planner:review --fixtures <approved-fixtures-directory> --export-sha256 <reviewed-sha256> --bundle-sha256 <reviewed-sha256> --scope APPROVED-FULL-NETWORK --output-root .tmp/render-capacity
```

This harness uses prebuilt local images only (`--pull=never`), no network, read-only fixtures/root, bounded memory/no extra swap, and CPU quotas. It creates a new run directory, measures legacy and compact separately at all four requested sizes, records OOM/container state, and makes the process verify cgroup-v2 limits. It never declares an automatic PASS. Review matrix hashes, all four valid plans, independent validation, timeouts, peak memory and OOM flags. Repeat with realistic largest fleet/task/node-order and concurrency cases; a three-stop sample is insufficient. Measure validator alone in an isolated process/service too; current timings measure independent validation code in the benchmark process, not an independently capped validator. Include cold/warm/restart readiness and total HTTP time under the APK's five-second health and 150-second POST deadlines. Admit new requests only after prewarm; retain the single-job generation guard. Verify enough memory headroom beyond the largest observed run before selecting a paid plan.

## 4. Persistent recovery and cutover

The planner disk retains `journal/jobs.sqlite3`, WAL/SHM files, payload steps, graph JSONL/seals and operation locks across process restarts. The runtime verifies the mount, restricts permissions, holds an exclusive instance lock, gates generation during graph warm-up, and drains accepted handlers on SIGTERM. Render's reviewed maximum shutdown delay is 300 seconds; a forced kill still requires same-UUID reconciliation. Disk-attached services are single-instance and have deployment availability tradeoffs; see [persistent disks](https://render.com/docs/disks).

Before any approved cutover, the named application/database recovery operator must:

1. Inventory existing pending request UUIDs and preserve the APK's saved operations. Prevent new generation on the old planner, drain operations and obtain a consistent journal baseline. Do not run old and hosted planners against the same generation workload during transfer. Never delete pending history to make startup succeed.
2. With the planner stopped/drained, copy its complete recovery state, or use SQLite's backup API to a new file and run `PRAGMA integrity_check` against that backup. A raw copy of a live SQLite database without WAL is insufficient. Restrict permissions; journal payloads can contain private route information. Store an encrypted, access-controlled off-service backup and source/image/config hashes. Do not capture passwords or JWTs in a deployment receipt. A disk snapshot alone is not evidence of a tested application restore.
3. Restore a copy to an **isolated offline** environment, with synthetic/mock RPCs and no DEV credentials/network. Verify SQLite integrity and the saved request/step bindings. Run the hosted tests' restart/receipt replay cases. No live replay is part of an isolated restore. For any previous production/DEV journal, do not merge databases or mutate binding fields.
4. Reconnect only under separately approved activation, reconcile existing requests using their original NGO identity/request UUID and the protected authorization/planning receipt readers, and confirm expected routes before admitting new generation. A timed-out HTTP response is not proof of a failed database commit. Never force a new UUID or directly edit route/claim records.

An old journal backup is not a database rollback: Supabase may contain later committed candidates/attestations/authorizations. Use protected receipts to reconcile these outcomes. Restoring a disk must not erase newer valid request history. This task has not produced or restored any DEV backup and has not demonstrated recovery of a real DEV journal; an operator-approved recovery rehearsal remains mandatory. Independent validator state is in protected Supabase records; its local service is stateless and receives no planner journal.

## 5. Flutter configuration and supervisor APK

The existing `scripts/Build-VerifiedRoutingDev.ps1` is a **USB/loopback** workflow and hardcodes `http://127.0.0.1:8787`. It remains unchanged. Do not use that script for a laptop-independent hosted APK.

After server readiness, authentication, capacity and recovery are approved, run from `frontend/geolock_hub_app`:

```powershell
flutter build apk --debug --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=https://<approved-planner-host> --dart-define=GEOLOCK_ROUTE_RESOLUTION_ENABLED=true
Get-FileHash -LiteralPath build/app/outputs/flutter-apk/app-debug.apk -Algorithm SHA256
```

Replace the host before invoking. No database DSN/password, validator token or Supabase privileged key belongs in Dart defines. Use the existing DEV public client configuration. Record the exact URL/defines, source and APK SHA256; copy to a new named APK instead of replacing prior evidence. Inspect the debug APK's `assets/flutter_assets/kernel_blob.bin` for the expected hosted URL and DEV project configuration. Verify installed APK identity/hash after installation. A release distribution additionally needs the project's reviewed signing/release procedure; this guide prepares supervisor testing only. No APK was built or installed in this task.

Use physical Android on mobile data and on unrelated Wi-Fi with laptop services stopped, no VPN/tunnel dependency and no `adb reverse`. Confirm the app's planner diagnostic targets the public HTTPS `/health` and reports ACTIVE before creating a snapshot. Don't increase app timeouts or suppress TLS checks to hide slow startup.

## 6. Approved acceptance tests and safe retest

These live tests **require separate approval** because route generation/attestation/authorization write to DEV:

- No/malformed/expired NGO JWT must fail with no snapshot/candidate/route mutation; another NGO must not read/recover this NGO's request. Direct calls to the validator with a client JWT or missing server token must fail. Verify proxy-header spoof rejection and real HTTPS/Host handling.
- One approved NGO with eligible pickups and vehicle: authenticate, create one saved request, generate all four methods, independently attest and authorize through the original protected chain. Inspect the resulting authorization receipt/route ownership read-only; no laptop component should be needed.
- Lose the response after the request, restart the planner, and resume from the same app with the **same saved UUID**. Use the existing authorization-result/planning-result readers first; never clear app data/history or automatically submit a replacement UUID. Verify one committed authorization result and unchanged ownership. Exercise validator unavailable, graph/manifest mismatch, timeout and concurrent generation: fail safely, retain request identity, recover without duplicate routes.
- Verify startup/redeploy with the disk, graph cache and journal, with a missing disk, and after isolated restore. Missing/corrupt recovery state is an incident requiring reconciliation, not permission to reconstruct arbitrary receipts.

## 7. Costs and rollback

Render Free is not the approved target for this implementation: no persistent disk, ephemeral restarts, idle sleep and shared instance hours conflict with dependable journal recovery and on-demand readiness. Two continuously running services consume `2 × 24 × days` instance-hours (1440 in a 30-day month), above the shared 750-hour Free allocation. Sleeping reduces hours, but not the storage/readiness problems. See [Render Free limits](https://render.com/docs/free).

Before creating anything, the owner must approve the current price for **both** compute services plus disk, bandwidth, build minutes and taxes. Review workspace spending controls and alerts; they are not a substitute for compute/disk cost approval. Do not enable autoscaling, previews, paid databases, external data stores, cron keep-alives or automatic plan upgrades. Recheck billing after any plan change. No amount or paid plan has been authorized here.

For rollback under separate approval: stop admitting new requests, drain/reconcile in-flight UUIDs, preserve the current recovery disk and export deployment receipts; disable hosted activation and combined workflow flags; restore the previously reviewed image/config while retaining compatible journal/graph state. Recheck readiness and scoped credentials before activation. The default graph engine can return to legacy only if capacity permits. Existing Windows services can be used through their existing approval workflow after a controlled single-owner handoff; do not start them automatically. Already-authorized routes remain database facts; code rollback does not undo them. Do not run a SQL rollback, recreate claims, delete receipts or replace a newer journal with an older copy as part of a hosting rollback.
