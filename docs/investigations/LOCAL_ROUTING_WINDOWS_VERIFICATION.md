# Local Windows routing verification

7 November 2026 MYT. **LOCAL OFFLINE PASS; Windows laptop workflow selected.** Live Supabase connectivity, current permissions and real route generation were deliberately not tested or authorized. This is not a new end-to-end DEV acceptance result.

The existing planner, independent validator, graph/matrix and CP-SAT path are intact. `windows/Start-Worker.ps1` invokes `native_worker` -> `server`, which creates foreground HTTP servers (8787 planner, 8788 validator). The default is loopback and disabled until explicit activation. No hosted module is required by these entrypoints. SQLite state remains under `%LOCALAPPDATA%\GeoLockHubRoutingDev\state\journal\jobs.sqlite3`; no PostgreSQL journal redesign was implemented.

## Changes in this review

- Added `docs/LOCAL_ROUTING_WINDOWS.md`: owner/teammate/supervisor prerequisites, install commands, native profile limitations, credentials, separate startup, health, USB/emulator/LAN HTTPS, shutdown and safe recovery guidance.
- Added `backend/routing/worker_service/windows/Test-LocalRoutingSetup.ps1` and `local_setup_check.py`: opt-in offline checker; no saved credential import, DEV access, live journal or worker activation. Uses temporary loopback ports, child environments stripped of activation/DB settings, then stops its own children.
- Updated `backend/routing/README.md`, `worker_service/README.md` to point to the selected Windows workflow. Added `hosted/README.md` to mark retained implementation postponed.
- Added decision notices to Render readiness/deployment/architecture, graph/free-hosting review and hosting/recovery comparison documents. Preserved their historical content, code and measurements; no old checksum manifest was rewritten.
- Added this report and local verification receipts/source fingerprints under `local-routing-windows-verification/`.

No existing runtime source, SQL, migration, routing algorithm, Flutter source, credentials or saved environment was edited. No rollback was necessary to select the original default: hosted implementation was already isolated. Documentation now removes ambiguity about the selected path.

## Hosted-work impact review

The pre-hosting `routing-render-implementation/BASELINE_SEALS.json` covers 13 files: server, transport, graph cache, orchestrator, validator, journal, native entrypoint/Windows launcher, matrix implementation, optimizer and three Flutter routing files. Twelve remain byte-identical. The sole difference is the **previously applied** `journal.py` initialization fix: Windows-only bounded retry (up to three seconds) for SQLite extended error 1546 during idempotent schema initialization. It does not retry payload/business writes, change IDs or discard WAL. It fixes the reproduced Windows mapped-SHM truncation failure and is deliberately retained; reverting it would restore a known laptop recovery problem. The current journal matches its previously validated Docker-stage fingerprint.

Hosted graph memory optimization remains opt-in within the hosted directory; it has not replaced the original local `GraphCache` or matrices. Full-network resource findings for the compact artifact do not automatically apply to the original local memory representation. All 18 source files in the original hosted implementation manifest remain unchanged; added documentation does not affect them. Current source hashes are recorded separately, without overwriting historical evidence.

## Checks actually run

| Check | Result |
| --- | --- |
| Existing worker service unittest discovery | **153 passed**, 23.943 seconds |
| Shared journal initialization regression module | **4 passed**, 0.286 seconds |
| Five existing Flutter routing test files | **42 passed, 1 skipped**; actual disposable SQL capture test skipped because no fresh capture was supplied |
| New offline setup checker | **PASS**; pinned profile/CA present; native client ready, not connected; planner and validator DISABLED HTTP health passed on temporary ports, both children stopped |
| Installed dependency consistency (`pip check`) | See receipt; no install/upgrade performed |

Worker tests exercise real OR-Tools CP-SAT invocation with synthetic RPC facts, directed roads, separate-role boundaries, independent validation, authorization/error handling, same-ID retries and local SQLite recovery/immutability. Flutter tests cover transport configuration, pending UUID persistence, unknown outcomes, explicit resume and feedback. They use mocks/fixtures and do not establish current DEV grants or phone connectivity. The skipped SQL capture integration check is not counted as passed. No Flutter implementation changed; full analyzer and unrelated UI suites were not needed.

Runtime verified here: Python 3.12.14, OR-Tools 9.15.6755, psycopg 3.3.6, SQLite 3.53.1, native libpq 170011 (`python` psycopg implementation). Linux/Docker tests were not required or rerun. The first sandboxed Flutter invocation produced no result and was stopped; rerun using access to the installed SDK cache completed successfully with `--no-pub` and analytics suppressed. No package download was requested.

## Remaining operator prerequisites

1. Each independent backend operator needs approved scoped credentials and native client/TLS setup. Native launcher currently fixes three LOGIN names and a CA path under `C:/Users/User/Downloads`; these are pre-existing portability restrictions. Do not copy the owner's secrets or rewrite the historical profile/hash. A supervisor using only the app needs their own authorized NGO account, not DB passwords.
2. A current session activation approval, existing frozen graph/policy and legitimate eligible NGO/fleet/work inputs are required before live generation. No existing DB/grants/graph were freshly inspected here.
3. USB/ADB debug connection is simplest. Actual devices/installed APKs were not accessed. LAN access additionally requires trusted HTTPS, correct DNS/IP/certificate, narrow firewall rule and reachable network; its optional proxy example is documented, not installed or tested.
4. Use the same host/journal for retries. No arbitrary failover between laptops or shared journal on a network/sync drive. Keep protected request IDs/receipts; unknown outcomes require reconciliation, not fresh requests.
5. Retain state and arrange a separately approved consistent backup/restore procedure. No live journal was read, copied, backed up, restored or deleted in this review.

**Decision:** original local implementation is intact and selected as default; no production restoration patch is needed. Ready for local setup review. Live operation remains behind explicit approval and the prerequisites above. No DEV/production access, deployment, migrations, worker activation, costs or GitHub push occurred.
