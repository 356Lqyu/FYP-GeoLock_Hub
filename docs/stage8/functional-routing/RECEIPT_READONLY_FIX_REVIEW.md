# Receipt read-only correction and simplified NGO UI

28 October 2026. READY for separate DEV deployment approval; NOT DEPLOYED.
No live route generation, blocked-request dismissal, service restart, recovery,
cron update, graph load, APK build/install or DEV write occurred in this task.

## Exact SQL and preserved contract

Migration: docs/stage8/stage-a/forward-migrations/20261105_routing_receipt_readonly.sql
SHA-256: a189c875e16c959bfa415c1fea7b53579c87f2abfc69f76064ae75b2e90f7e1a
Old normalized prosrc MD5: 29161768ed763f7a2ac9b34c0fe0abe7
Expected new normalized prosrc MD5: 71203f7bc55086683d60f3d0afabbe54
Unchanged fleet_private.require_ngo MD5: 15d5c2547cabd5df199e104451f5c2d6

Only get_my_routing_authorization_receipt(uuid) is replaced. Its NGO identity comes
from auth.uid; a non-locking EXISTS checks the identical active_flag, NGO role,
and matching NGO/user-profile role conditions. Receipt lookup remains restricted
to the actor's ngo_id, original request_id and AUTHORIZE operation. FOUND and
NOT_FOUND JSON remain identical. No owner existence leaks across NGOs.

STABLE, SECURITY DEFINER, postgres ownership, pinned pg_catalog/pg_temp search_path,
UTC and postgres/authenticated-only EXECUTE are preserved. No grants are issued.
The writer helper and protected authorize/start/complete/reconcile functions are
not changed. The migration refuses a source/security/guard mismatch or a repeated
application and validates the new body and unchanged security before COMMIT.

Historical 20261104 SQL SHA-256 remains
74b098e891c49ee71a9cf1dde7c4e6d2fb9fdf31875ebc94488321fd48557dc4.
The earlier receipt_readonly_fix.PROPOSAL.sql is superseded for execution by the
guarded migration; do not run both or edit the deployed historical migration.

## Actual tests

Disposable PostgreSQL **17.11**, fresh temporary cluster bound only to 127.0.0.1:
**15/15 PASS**, cluster stopped. Original exact DEV function and writer helper were
captured via READ ONLY catalogs. The original reader reproduced SQLSTATE 25006
inside BEGIN READ ONLY. The full guarded migration then passed. Corrected calls
used genuine READ ONLY transactions, SET LOCAL ROLE authenticated and synthetic
auth.uid GUC identity (no real JWT or DEV account impersonation).

Tests cover owner FOUND, cross-NGO NOT_FOUND, absent receipt, repeated reads,
unauthenticated/donor/inactive access rejection, null request, anon/service-role
EXECUTE denial, STABLE/security metadata, unchanged writer helper, preserved
request row count and safe refusal to reapply the migration. This is an actual
PostgreSQL transaction-mode regression, not a claimed hosted PostgREST run.
Original failure reproduction intentionally failed; initial Windows harness
startup/pipe handling was corrected before the final passing run.

Run: .\.venv-stage8\Scripts\python.exe -B supabase/tests/receipt_readonly_regression.py
Evidence: results/receipt-readonly-fix/test-result.json and deployed-catalog.json.

Flutter focused suite: **71 PASS, zero skipped/failed**. It includes transport,
combined operations, resume UI, feedback, connection visibility, NGO routing,
pending requests and Proposed map tests, with the prior disposable PostgreSQL
capture at results/automatic-routing-local/20261027T164147Z-e1313d/flutter-combined-capture.json.
New checks preserve HTTP409/DATABASE_REJECTED_REQUEST, reject arbitrary upstream
error text, persist failure status/code without snapshot writes, and retain the
same request. Existing tests verify receipt reconciliation, duplicate taps, owner
route restore, map/stop display, advisory-only research output and protected pickup.
Final static analysis on 4 changed production files and 5 changed tests: no issues.
Intermediate test/import/old-navigation expectation failures were fixed; these
are not outstanding failures. No business-write integration test ran on DEV.

## Other routing reader assessment

Catalog scan of STABLE/IMMUTABLE functions in public/fleet_private/routing_private
found only this receipt reader directly invoking the locking NGO helper or the
searched locking operations. preview_location_routing calls a non-locking stable
road-node resolver. get_my_routing_overview and get_my_authorized_route use auth.uid
and source observations; inspected check_remaining is non-locking.

list_my_vehicles is a read-intent RPC that DOES call require_ngo, but is VOLATILE:
its existing POST path can take the locks and passed during the failed request's
authentication stage. Do not switch it to GET, mark it STABLE or force it into
READ ONLY without a separate review. Other worker read RPCs are VOLATILE with
non-locking role guards in the inspected paths. This source/dependency review is
not an exhaustive runtime proof of arbitrary future helper paths.

## Flutter implementation (local only)

- Normal Pickup Routes retains vehicles, eligible claimed donations, Generate &
  Authorize, friendly outcome and database-owned routes. Detail/map, ordered stops,
  fresh protected Start/Complete/Return gates remain the existing implementation.
- Raw IDs, phases, saved advisory result and read-only connection/reconciliation
  checks moved into separate Route support screen via help icon. No ordinary
  Resume/Authorize/Archive developer buttons remain on the main screen. Support
  never resumes planning or authorization; local completed-operation archival
  still invokes repository guards and preserves history.
- Proven preflight interruption retains explicit confirmation-based local
  dismissal. Unknown operations retain their IDs, automatic read-only owner
  receipt reconciliation and short attention message; NOT_FOUND is not rollback.
- Transport retains fixed allowlisted backend codes plus HTTP status; repository
  persists failure_http_status. Arbitrary body/header/token/error text is not
  saved. Historical missing status cannot be reconstructed by this new code.
- A saved candidate remains advisory, never an authorized route. All four Python
  research methods, inputs, metrics and Proposed objective are unchanged. Existing
  markers-only map continues to disclose unavailable road geometry.

Changed production Flutter files (under frontend/geolock_hub_app):
lib/routing/ngo_routes_page.dart, ngo_routing_repository.dart,
routing_worker_client.dart, routing_diagnostics_page.dart (new).
Changed tests: automatic_route_operation_test.dart, routing_worker_client_test.dart,
routing_connection_visibility_test.dart, routing_feedback_test.dart,
ngo_routing_test.dart. New SQL regression: supabase/tests/receipt_readonly_regression.py.
No planner/validator production Python source changed; no service restart is
required solely for the SQL receipt correction. UI needs a new verified APK later;
no Android physical verification of these newest UI changes is claimed.

## Preflight and separately approved execution

1. Operator selects DEV rcgyuwiidqvrgbxswhqj and approved geolock_dev_installer
   connection, database postgres. Native tools/TLS verify-full/hidden prompts stay
   unchanged. Reconfirm file checksum and current old receipt fingerprint with
   receipt_fix_catalog.readonly.sql; stop if already applied or source/grants drift.
2. Save the current catalog/definition and run receipt_fix_preservation.readonly.sql
   immediately before/after. Latest baseline: 142 other functions, digest
   5c4dc017cd921cb12063859bf3bb749f; 19 leases; 4 snapshots, 1 candidate, 1 validation,
   0 routes/assignments; approved policy/graph match; recovery job 3 active unchanged.
   The baseline is an observation, not permission to freeze/pause writers. Concurrent
   authorized cron/application writes can change row hashes: investigate audits,
   never overwrite records to force equality. No frozen road table is scanned.
3. Obtain explicit approval for this exact migration/checksum. Proposed command
   (existing approved PGSERVICEFILE configured; no execution-policy bypass):

```powershell
& 'C:\Program Files\PostgreSQL\17\bin\psql.exe' -X -W --dbname 'service=geolock_dev_installer' --set ON_ERROR_STOP=1 --file '.\docs\stage8\stage-a\forward-migrations\20261105_routing_receipt_readonly.sql'
```

No migration history entry is invented by this file. Do not use another account
if the approved installer is unavailable. Migration timeouts are 5s lock/10s
statement; a guard/error aborts, with no partial committed replacement.

## Postflight / recovery / approval gate

Run receipt_fix_catalog.readonly.sql and preservation query. Require new body
71203f7b..., same security/grants and writer helper hash, same unrelated-function
aggregate, policy/graph/cron configuration and explained routing/data counts.
Then perform ONLY an authenticated read-only capability/receipt check under the
real NGO JWT, reusing blocked request 20a8b059-63fc-40b6-bea9-0751ef1a199b. Expected
HTTP200, geolock.routing-auto-now.v1, correct ngo_id, automatic_departure=true and
the actual combined_generation_enabled flag; unknown receipt returns NOT_FOUND.
Do not invoke /plan, /plan-and-authorize or any snapshot writer to verify the fix.
No hosted capability success is claimed before this deployed check.

On an uncertain installer response inspect catalog hashes before any retry. Old
hash means not applied; new hash means applied; other state means STOP. Before
COMMIT, failure rolls back. After commit prefer a reviewed forward correction;
restoring the old reader would restore the known failure. Never replay A004 or
alter business states, delete receipts or clear blocked requests as rollback.
Service shutdown/disable/restart and writer pauses require their own approval.
Existing unverified backup restorability remains unverified; this change replaces
one function and does not improve or test database restoration.

Decision: local correction and UI READY FOR REVIEW. Await approval before DEV SQL,
new APK installation or any business attempt. Blocked operation and historical
evidence remain intact. Next gate is deployment of this exact receipt-only SQL,
followed by read-only capability verification, not another Generate attempt.
