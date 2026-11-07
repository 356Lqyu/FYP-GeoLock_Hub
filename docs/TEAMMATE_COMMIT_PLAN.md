# GeoLock Hub teammate distribution review

Scope is the current Android Flutter app and original Windows planner and independent validator. The exact incremental selection appears below. A fresh source package also needs the unchanged tracked Dart source, Android scaffold and Flutter manifests.

## Release gates

Two tracked experiment environment files contain populated database connection settings. One also contains populated NGO password fields. The introducing commit `7bea6df` is reachable from local `lqy`, `main`, `ss` and the recorded `origin/lqy`, `origin/main`, `origin/ss` refs. Remote-tracking refs describe this clone's last recorded state. The administrator should establish which credentials are active, revoke or rotate active exposed credentials, and audit use before distribution. Git history filtering and credential rotation each require separate authorization. An ignore rule leaves the existing tracked files and historical blobs in place.

For a teammate package with no inherited history, use a new Git repository or a reviewed source archive built solely from the allowlisted source and required tracked Android baseline. Review the resulting tree for secrets and private data before distributing it. If the existing repository must be retained, coordinate removal from its current tree, history cleanup across affected refs and forks, and replacement clones with the repository owner. A new history can prevent redistribution of those blobs, while rotation addresses copies already held elsewhere.

## Windows operator provisioning

The launcher currently requires libpq 17.11 and a byte-pinned PostgreSQL service profile. The pinned profile refers to a public CA at an absolute path on the original laptop. Provision that exact approved profile and public CA securely outside the distribution package as an interim operator step. The profile must be placed at the existing path expected by the checkout, and the CA at the path encoded in the profile. A configurable operator-local CA path with explicit project/host pinning and TLS verify-full is the proposed portable follow-up. It requires a separate code review and offline verification.

For the portable setup, keep the operator profile and CA in a directory controlled by the current Windows account. Distribute a credential-free template and have the administrator supply the approved host and CA fingerprint through a trusted channel. Validate project, host, port, role mapping and CA fingerprint separately from the operator's local file path. Keep TLS hostname verification, the native client version check and explicit activation. Check that altered hosts, certificates and role mappings fail before any connection.

Each backend operator needs administrator-approved graph, planner and validator credentials for the existing scoped login model. Enter them locally through the approved prompts. Keep the worker token and DPAPI configuration local. For separately revocable operator logins, review a launcher and provisioning change because the current launcher expects fixed role-specific login names. An app-only teammate needs their own authorized NGO account and the chosen backend URL.

See [Windows setup](LOCAL_ROUTING_WINDOWS.md) for the commands. The offline checker in the minimal package can run dependency and disabled-worker checks. Its pinned-profile check requires separate provisioning. The full development test commands in the Windows guide require additional test files and fixtures.

For an Android debug build, run `flutter build apk --debug --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=http://10.0.2.2:8787` in `frontend/geolock_hub_app` for the Android emulator. For a USB phone, use `http://127.0.0.1:8787` and the ADB reverse procedure in the Windows guide. Maps rendering needs a separately authorized Maps key in the local Android properties file under `google.maps.apiKey`. Keep that file outside Git.

## Disposable validation

The source snapshot was materialized from individual allowlisted paths and the tracked Android baseline without creating a Git clone. This kept the tracked experiment environment files and repository history outside the test directory. It used fresh Python, Pub and Gradle dependency directories and the machine's installed SDKs.

- Python 3.12.14 environment creation, pinned dependency installation and `pip check` passed.
- Native libpq 17.11 loaded without connecting. Both native configuration checks returned `DISABLED`.
- Planner and validator each returned `DISABLED` on a temporary loopback health listener. The checker stopped both child processes.
- The full offline checker returned nonzero at the missing pinned profile check. This snapshot deliberately omits the operator profile and CA. It proves disabled startup and leaves live operator provisioning unverified.
- Android debug APK assembly passed on 7 November 2026 using the emulator planner URL. Flutter generated the Gradle wrapper and Android local properties in the snapshot. The build used no Maps key and did not install or launch the APK. The tracked Flutter dependency lockfile matched the copy after dependency resolution.

## Exact GitHub Desktop selection

For the existing branch only, uncheck the full change list, then select exactly the individual paths below after approval. Existing unchanged Flutter build and runtime files stay at HEAD. The two tracked environment files and historical artifacts also stay at HEAD, so this selection alone cannot make the existing branch safe to share.

```text
.gitignore
backend/__init__.py
backend/routing/__init__.py
backend/routing/contract.py
backend/routing/integration/__init__.py
backend/routing/integration/graph_worker.py
backend/routing/integration/presentation.py
backend/routing/integration/worker.py
backend/routing/phase_b/__init__.py
backend/routing/phase_b/baselines.py
backend/routing/phase_b/models.py
backend/routing/phase_b/optimizers.py
backend/routing/phase_b/problem.py
backend/routing/phase_b/requirements-lock.txt
backend/routing/phase_b/routing_model.py
backend/routing/phase_b/validation.py
backend/routing/phase_c2/__init__.py
backend/routing/phase_c2/matrices.py
backend/routing/phase_c2/orchestration.py
backend/routing/worker_service/__init__.py
backend/routing/worker_service/__main__.py
backend/routing/worker_service/connection_diagnostic.py
backend/routing/worker_service/connection_diagnostic_native17.py
backend/routing/worker_service/errors.py
backend/routing/worker_service/graph_cache.py
backend/routing/worker_service/journal.py
backend/routing/worker_service/native_service_connection.py
backend/routing/worker_service/native_worker.py
backend/routing/worker_service/orchestrator.py
backend/routing/worker_service/password_transport_check.py
backend/routing/worker_service/probe_diagnostics.py
backend/routing/worker_service/requirements.txt
backend/routing/worker_service/server.py
backend/routing/worker_service/staged.py
backend/routing/worker_service/transport.py
backend/routing/worker_service/validator.py
backend/routing/worker_service/windows/Save-WorkerConfig.ps1
backend/routing/worker_service/windows/Start-Worker.ps1
backend/routing/worker_service/windows/Test-LocalRoutingSetup.ps1
backend/routing/worker_service/windows/local_setup_check.py
docs/LOCAL_ROUTING_WINDOWS.md
docs/TEAMMATE_COMMIT_PLAN.md
frontend/geolock_hub_app/android/app/src/debug/res/xml/routing_debug_network_security.xml
frontend/geolock_hub_app/lib/auth/auth_controller.dart
frontend/geolock_hub_app/lib/auth/auth_pages.dart
frontend/geolock_hub_app/lib/claim_pickup_detail_reader.dart
frontend/geolock_hub_app/lib/claim_request.dart
frontend/geolock_hub_app/lib/dashboard_pages.dart
frontend/geolock_hub_app/lib/donation_pages.dart
frontend/geolock_hub_app/lib/donor_claim_history.dart
frontend/geolock_hub_app/lib/main.dart
frontend/geolock_hub_app/lib/routing/claim_coordination.dart
frontend/geolock_hub_app/lib/routing/ngo_fleet_page.dart
frontend/geolock_hub_app/lib/routing/ngo_routes_page.dart
frontend/geolock_hub_app/lib/routing/ngo_routing_repository.dart
frontend/geolock_hub_app/lib/routing/proposed_route_view.dart
frontend/geolock_hub_app/lib/routing/route_card_view.dart
frontend/geolock_hub_app/lib/routing/route_display_formatters.dart
frontend/geolock_hub_app/lib/routing/route_execution_controller.dart
frontend/geolock_hub_app/lib/routing/route_resolution_page.dart
frontend/geolock_hub_app/lib/routing/route_resolution_repository.dart
frontend/geolock_hub_app/lib/routing/routing_diagnostics_page.dart
frontend/geolock_hub_app/lib/routing/routing_feedback.dart
frontend/geolock_hub_app/lib/routing/routing_page_support.dart
frontend/geolock_hub_app/lib/routing/routing_policy_display.dart
frontend/geolock_hub_app/lib/routing/routing_worker_client.dart
```

Leave every other changed path unselected. This includes Flutter and Python test changes, Supabase development files, hosted sources, investigations, research outputs, backups, caches, unrelated scripts and the operator-provisioned PostgreSQL profile. Preserve the local Flutter tests.
