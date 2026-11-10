# Direct-access dependency review

Review only. Evidence is the captured DEV catalog and the local source fingerprinted in `captured/source-files-sha256.json`. No application workflow or test runner was invoked.

## Flutter

The entire `frontend/geolock_hub_app/lib` tree was searched for RPCs, table access, Storage and realtime subscriptions. The 36 literal RPC names and exact call sites are in `RPC_INVENTORY.md` and `captured/flutter-rpc-call-sites.json`. No direct public-table query or Postgres Changes subscription was found. Non-Storage `Map.from` calls construct Dart values rather than database requests.

The observed external data paths are:

- `auth/auth_controller.dart`: `get_my_profile`, `geolock_app_capabilities`, `register_role_profile`, plus Supabase Auth metadata operations.
- `dashboard_pages.dart` and `donation_pages.dart`: lifecycle/discovery/history/audit/reconciliation/hub RPCs.
- `location/road_routing.dart`: `preview_location_routing`.
- `donation_pages.dart`: Storage signed URLs, list, upload and remove via `storage.from('geolock-donation-images')`. Metadata is read/written through RPCs.

All called public functions execute as their owning postgres role. Revoking client table privileges does not remove that role's privileges. The app's existing validation, statuses, auth checks and request shapes remain unchanged. No profile-edit or registration-policy change is included.

Current `supabase_config.dart` defaults to DEV and requires explicit shared selection. Older environment documentation says otherwise; use current source and verify the actual DEV build configuration before future testing. No configuration file was changed.

## Public functions and triggers

The snapshot includes definitions/configuration/grants for all 72 non-extension public functions, not just the Flutter subset. Sixty-six use SECURITY DEFINER; six are SECURITY INVOKER trigger functions:

| Function | Direct table dependency / effect |
|---|---|
| `enforce_donation_transition()` | Reads coordination_config for weight/transition constraints; updates NEW timestamp |
| `guard_batch_immutability()` | Reads/locks hub_batches when validating batch members |
| `guard_donation_items()` | Reads/locks donations before item mutations |
| `enforce_listing_transition()` | Validates OLD/NEW listing state |
| `prevent_role_change()` | Validates immutable OLD/NEW role and user ID |
| `prevent_audit_mutation()` | Raises an append-only exception |

When a postgres-owned SECURITY DEFINER RPC writes these tables, invoker triggers use that effective postgres context. Direct service_role writes retain their own exact privileges and BYPASSRLS. Owner/admin fixture operations retain their privileges. A direct anon/authenticated write becomes denied at the table boundary; keeping such writes working is outside the intended application contract.

Fourteen non-internal public triggers are captured. Road-node, listing eligibility, required-photo and reservation-route triggers are postgres-owned SECURITY DEFINER where applicable. No deployed public application body was found to reset database ROLE through SET ROLE or set_config('role',...). Dynamic pgRouting SQL runs inside the existing trusted helper context; no routing function, extension, graph or sequence owner changes.

The catalog dependency query returned no function-to-relation/view rewrite dependency rows. **This is not proof of no dependencies**: PostgreSQL does not reliably record references inside string-bodied SQL/PLpgSQL or dynamic SQL. Source definitions and the trigger map were inspected as additional evidence. There are no public views, materialized views or foreign tables in the supplementary catalog inventory.

## Sequence

Only `public.road_network_edges_edge_id_seq` exists in public. It has an internal identity dependency on `road_network_edges.edge_id`; no nextval column-default expression was found. Existing road data is not touched. Future trusted imports may need identity generation/sequence access and retain the postgres/service_role grants. An external importer running as anon/authenticated will fail by design and must not be silently reauthorized.

The operational importer `supabase/road_network/import_operational_road_network.py` uses a guarded direct DEV database connection and COPY into road tables. It is an administrative writer, not a mobile RPC path. No import or sequence increment was run. Its connection role must be verified as a retained trusted role before any separately approved import.

## Storage

All 13 deployed Storage policies are on `storage.objects`; the four public metadata policies are on `donation_images` and `hub_batch_images`. All expressions are retained in the raw snapshot.

Authenticated Storage insert/read/delete policies call:

- `geolock_storage_can_upload_donation_image(text,text,jsonb)`
- `geolock_storage_can_upload_batch_image(text,text,jsonb)`
- `geolock_storage_can_read_image(text,text)`
- `geolock_storage_can_delete_unattached_image(text,text)`

Each is postgres-owned SECURITY DEFINER with `search_path=pg_catalog, pg_temp`, authenticated/service_role EXECUTE and no anon EXECUTE. Public objects inside their bodies are schema-qualified. Read helpers call postgres-owned SECURITY DEFINER `can_read_geolock_donation_image` / `can_read_geolock_batch_image`. Storage policy evaluation therefore does not depend on the caller retaining direct SELECT on public metadata/profile/batch tables.

The four public metadata SELECT policies also call those trusted helpers. Removing authenticated table SELECT intentionally stops direct metadata queries; RPC reads and policy helpers retain the owner context. No direct metadata SELECT dependency was found in Flutter.

Seven Storage triggers use five managed trigger functions. Their deployed bodies were captured separately; none references a public application table. They operate on Storage records, caller role checks, timestamps and managed-delete guards. The proposals do not change their owner, body, search path, ACL or behavior.

Storage ACLs, policies, functions, bucket/object records, Auth objects, schemas and other schemas' default ACLs are outside the correction. Bucket configuration/data was not read or altered. Actual signed URL, upload/list/read/delete behavior still needs a DEV API regression after a separately approved change.

## Test and tooling dependencies

| Source | Direct-access context / implication |
|---|---|
| `supabase/tests/claim_concurrency_test.py` | Real authenticated NGO JWTs call RPCs. Committed-state REST reads use service_role. The delayed-lock connection explicitly requires the DEV postgres Session Pooler identity. Retained grants cover these paths. Current concurrency counts are 2 and 10; do not claim an automatic 50-session test from older docs. |
| `supabase/tests/claim_fault_injection_dev_test.py` | Authenticated claim RPC; service_role verification; postgres connection for a private test schema and catalog/row assertions. Installing failpoint triggers is a separate unapproved change, not required by this ACL proposal. |
| `supabase/tests/stage1_claim_recovery_dev_test.py` | Authenticated role RPC calls, service_role committed-state reads and recovery. Client table grants are not required for these paths. |
| `supabase/tests/hub_reservation_lifecycle_dev_test.py` | Authenticated donor/hub/NGO RPCs and service_role direct verification. Its allowlist must be exactly DEV for future runs; it accepts a configured allowlist rather than inherently requiring only this DEV ref. |
| `supabase/tests/stage1_claim_recovery_dev_setup.py` | Explicitly requires database/user postgres and seeds fixtures directly; preserved privileges. It still contains VALIDATED transitions, so its lifecycle compatibility needs review before reuse. This package does not fix or run it. |
| `supabase/tests/*readiness.sql`, `*preflight.sql`, `registration_compatibility_verification.sql` | Mostly catalog inspections. Several expect anon/PUBLIC EXECUTE to be absent. Existing anonymous-grant mismatches will remain because function grants are intentionally unchanged. Some files document manual RPC invocations: inspect statements before running any whole file. |
| `supabase/tests/claim_write_failpoints_dev*.sql` | Changes separate test schema/triggers and can mutate test data. Not installed or run, and not part of the ACL correction. |
| Original paths `experiments/geofence/*.py`, `experiments/atomic_claim/*.py` (files later relocated unchanged under `docs/audits/legacy-claim-geofence/`) | Legacy experiments mix authenticated REST/RPC calls with direct psycopg connections and older test_* RPCs. They were inspected, not executed. Roles/configuration and legacy fixture compatibility cannot all be proven from source; do not run them automatically. Direct trusted admin connections keep access; any client-role SQL expectation is intentionally invalidated. |
| `baseline implementation/source code/*.py` | Benchmark/simulation processing, not a source of required public-table client grants in the reviewed code. |

Test credentials and local env files were not opened or copied. Existing test runners were not changed.

## Restore/rebuild and external consumers

`geolock-v3-public-schema-with-grants.sql` and `geolock-v3-permissions-dev.sql` retain broad historical grant/default-grant material. Reapplying these sources can reintroduce the problem. They were inspected but not edited. A separate approved rebuild-source update is required before using them as a future baseline; do not rewrite historical applied migrations.

This repository cannot establish the behavior of teammate routing clients, external dashboards, notebooks, reporting tools, scheduled workers, uncommitted remote implementations or plugins. Obtain their confirmation before execution. In particular, direct image-metadata reads under authenticated would fail even though current Storage policies remain compatible.

Full catalog snapshots and drift guards cover the reviewed objects, not every external system or future role creator. Keep concurrent DDL paused while applying or rolling back. Do not treat a successful catalog check as proof of successful user workflows or of secure anonymous RPC authorization.
