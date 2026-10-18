# GeoLock Hub Stage 1 isolated development environment

This is a setup and test guide only. No SQL or Supabase project has been
accessed or changed during its preparation.

For the automated fixture creator for
`stage1_claim_recovery_dev_test.py`, use
[`supabase/tests/stage1_dev_fixture_setup.md`](../supabase/tests/stage1_dev_fixture_setup.md).
It has an exact project-reference allowlist for the supplied DEV project and
requires a typed confirmation before any Auth, Storage, or database writes.

## 1. Create an isolated disposable Supabase project

1. Create a new Supabase project named for GeoLock Hub development in the
   intended development organization. Do not fork/restore production data.
2. Record its project reference, publishable key, database connection string,
   and test-only Auth credentials in a local password manager. Do not commit
   these values or place a service credential in Flutter.
3. Create synthetic Auth users in this project for a donor, NGO, and hub admin.
   Use distinct addresses and synthetic profile/location data. Keep the shared
   production project's users and rows out of this environment.
4. Set project-level application configuration and Storage settings explicitly
   for development; do not copy production secrets or Auth users.

## 2. Recreate the deployed V3 schema without replaying proposal files

The repository does not contain one authoritative fresh-install baseline for
the actual deployed V3 database. The dated files in `supabase/migrations/` are
proposals and experiments; several overlap or depend on other unapproved
migrations. Do not replay the whole directory to approximate production.

Obtain a schema-only export from the database owner using the deployed V3
database's direct connection string and a supported `pg_dump --schema-only`
workflow, or use a separately reviewed Supabase schema export. The export must
exclude application data and Auth user rows. A public-schema-only example is:

```powershell
$env:GEOLOCK_SOURCE_DATABASE_URL = '<source database connection string>'
pg_dump --schema-only --no-owner --schema=public --dbname=$env:GEOLOCK_SOURCE_DATABASE_URL --file=geolock-v3-public-schema.sql
```

Review the dump before restoring. Do not add `--clean` or `--create`; restore
only to the new empty development project, using its connection string and
`psql -v ON_ERROR_STOP=1 -f geolock-v3-public-schema.sql`. This is a future
operator action, not something run during preparation. Keep connection strings
out of command history and logs. `coordination_config`, static categories, and
other reference rows are data and are not included in a schema-only dump. Seed
only reviewed non-user configuration/reference rows and synthetic test rows in
the disposable project; do not copy Auth users, profiles, donations, claims,
or benchmark records from the shared project. Confirm the known configuration
values from the current read-only inventory: 360-minute claim lease,
120-minute hub reservation, 10 kg path threshold, and 20 km geofence. Confirm
all other configuration values from the inventory instead of guessing.

Confirm these required managed dependencies are provided by the target
Supabase project or are present in the reviewed export:

- `auth.uid()` / `auth.role()` and Supabase roles (`anon`, `authenticated`,
  `service_role`), supplied by Supabase Auth/API setup;
- PostGIS in the `extensions` schema, plus the extension providing
  `gen_random_uuid()` if not supplied by PostgreSQL;
- `public` tables, constraints, indexes, triggers, functions, RLS policies,
  grants, and coordination configuration rows;
- Any app-owned Storage bucket and Storage policies needed by the currently
  deployed donation-photo flow. A schema-only dump may not reproduce managed
  bucket metadata, Auth settings, secrets, or Edge Functions.

Use `supabase/tests/stage1_claim_recovery_preflight.sql` and
`supabase/tests/hub_reservation_lifecycle_preflight.sql` to compare the restored
database to the deployed inventory. Stop if baseline function bodies,
signatures, return types, owner/search path, grants, triggers, constraints,
required configuration rows, or route writers differ. This repository and the
inventory CSV do not provide a substitute for the missing full schema-only
export or for confirming the export's extensions and managed Storage objects.

## 3. Local app configuration and shared-project protection

Create `frontend/geolock_hub_app/.env.development.json` locally (it is ignored
by Git) with only the disposable project's URL and publishable key:

```json
{
  "GEOLOCK_SUPABASE_URL": "https://<exact-disposable-project-ref>.supabase.co",
  "GEOLOCK_SUPABASE_PUBLISHABLE_KEY": "<development-publishable-key>"
}
```

Run the app with `flutter run --dart-define-from-file=.env.development.json`.
Before each run, inspect that file and verify its project reference in the
development Dashboard. The committed defaults remain the shared project for
ordinary runs. Never put a service credential or database password in the
Flutter config; service-role JWTs are test-runner only.

For the destructive test runners, set these guards explicitly in a fresh
PowerShell session:

```powershell
$env:GEOLOCK_DEV_ISOLATED_CONFIRMATION = 'I_CONFIRM_DISPOSABLE_DEV_PROJECT'
$env:GEOLOCK_DEV_ALLOWED_PROJECT_REFS = '<exact-disposable-project-ref>'
$env:GEOLOCK_DEV_SUPABASE_URL = 'https://<exact-disposable-project-ref>.supabase.co'
$env:GEOLOCK_DEV_PUBLISHABLE_KEY = '<development-publishable-key>'
$env:GEOLOCK_DEV_ANON_JWT = '<development-anon-jwt>'
$env:GEOLOCK_DEV_SERVICE_ROLE_JWT = '<development-service-role-jwt>'
```

Do not put real values in the repository, terminal transcripts, screenshots,
or this guide. The runner rejects the known shared project reference, requires
the explicit allowlist and disposable confirmation, and refuses mismatched
inherited `SUPABASE_URL` values. Run only after visually checking the project
reference in the Supabase Dashboard.

## 4. Migration order for the disposable project

1. Restore and verify the schema-only deployed V3 baseline.
2. Run the read-only preflights and compare all emitted function definitions
   and route writers with the deployed inventory.
3. If the separate, previously approved hub reservation migration is part of
   the staging objective, apply
   `supabase/migrations/20261018_hub_reservation_reassignment_and_safe_cancellation.sql`
   first and repeat its preflight. This is separate from the claim migration.
4. Apply
   `supabase/migrations/20261019_stage1_claim_recovery_and_reconciliation.sql`
   to the isolated project only after reviewing the preflight. It adds NGO
   claim cancellation, claim reconciliation evidence and inbox, role-scoped
   audit reads, and the claim-first expired-lease recovery implementation. It does not
   install `pg_cron` or schedule work.
5. Run the focused claim recovery tests, the existing hub reservation tests,
   and the 2/10/50 concurrent-claim runner. Inspect committed table state and
   audit rows after each case.
6. Only after claim and hub tests pass, run the preflight for
   `supabase/migrations/20261019_retire_delivered_state.sql`. Apply it as a
   separate change only if the development database has zero `DELIVERED` rows.
7. Test the app against the development project. Confirm claim cancellation,
   reconciliation, and hub selection states in donor/NGO/hub accounts.
8. In a later separately approved scheduler step, enable `pg_cron` in the
   development project, create one five-minute recovery job as the trusted
   `postgres` database role, verify `session_user` authorization and inspect
   `cron.job_run_details`. Do not create that job in this preparation stage.

The legacy files `20261017_stage1_location_and_read_rpcs.sql`,
`20261017_donation_state_management.sql`, the photo migrations, and
`20261018_donation_photo_and_availability_transition.sql` are not prerequisites
unless the restored baseline and their own reviewed preflights prove that the
development database needs them. Do not rerun them as a set. The location,
road-node, geofence, photo, and listing-availability implementations are
outside this change.

## 5. Synthetic fixture preparation

Create every fixture in the disposable database only. Use synthetic Auth users
and synthetic coordinates. Do not import benchmark rows wholesale. Create
independent rows for:

- an expired, unstarted, unrouted claim safe for release;
- an expired route-linked claim that must enter reconciliation;
- a cancellable `CONFIRMED` NGO task and a second claim for a distinct-request
  race;
- a `CONFIRMED` claim for cancellation-versus-`start_pickup` concurrency;
- a `DISPATCHED` expired claim for positive and negative reconciliation cases;
- a direct donation/listing and a hub-batch listing for role-scope and audit
  checks;
- hub donations/reservations with capacity sufficient for exactly one of two
  concurrent reservations, plus receipt and reassignment fixtures used by the
  existing hub runner.

Use real fixture UUIDs in environment variables listed in
`supabase/tests/stage1_claim_recovery_dev_test.py`. Ensure every race uses a
fresh fixture because the operations are intentionally state-changing.

## 6. Test sequence

Read-only baseline and post-migration checks:

```powershell
psql $env:GEOLOCK_DEV_DATABASE_URL -v ON_ERROR_STOP=1 -f supabase/tests/stage1_claim_recovery_preflight.sql
psql $env:GEOLOCK_DEV_DATABASE_URL -v ON_ERROR_STOP=1 -f supabase/tests/hub_reservation_lifecycle_preflight.sql
```

Stateful disposable-project integration checks (never run against the shared
project):

```powershell
python -m py_compile supabase/tests/stage1_claim_recovery_dev_test.py
python supabase/tests/stage1_claim_recovery_dev_test.py
python supabase/tests/hub_reservation_lifecycle_dev_test.py
python supabase/tests/claim_concurrency_test.py
```

The claim concurrency test uses separate `GEOLOCK_TEST_*` variables and now
requires its own explicit confirmation and project-reference allowlist. Run
its three distinct `AVAILABLE` listing fixtures for exactly 2, 10, and 50
simultaneous claim attempts. It must find one active winner and inspect the
committed `donation_claims`, `claim_leases`, listing, task, and audit rows.

After the recovery tests pass, verify the Cron role and job using SQL read-only
queries. The direct-Cron guard relies on the job being created by `postgres`
so `session_user='postgres'` inside the SECURITY DEFINER function; otherwise it
fails closed. The existing `service_role` path remains server-side only. If
the isolated project's Cron runtime does not satisfy this assumption, use a
protected Edge Function that keeps its service-role secret server-side.

## 7. Current blockers / compatibility questions

- The supplied deployed inventory contains one route assignment writer,
  `assign_task_to_route(p_route,p_task,p_stop_order)`, which locks route then
  task. It does not lock claim or lease. The proposed recovery follows claim →
  lease → listing → task and never locks a route row, so this known writer has
  no lock cycle with recovery. Any route stop history is treated as uncertain
  and is not automatically released.
- No route dispatch, route-state transition, route-cancellation, or route
  assignment cleanup writer is present in the repository or supplied inventory.
  That prevents proving how a teammate's route implementation changes route
  and task state. Do not change `assign_task_to_route` in this migration. Before
  enabling recovery, obtain the teammate's current route writer definitions and
  test their lock order against the migration. If they lock task then claim or
  lease, a lock-order review is required.
- `PICKUP_IN_PROGRESS -> READY_FOR_PICKUP` is not a deployed donation
  transition. Therefore, when both parties report no handover after dispatch,
  the migration records `MANUAL_REVIEW` and keeps the claim/lease in
  `RECONCILIATION_REQUIRED`; it does not reopen the listing or make the claim
  available to another NGO. A separately approved trusted recovery policy is
  needed to resolve that case.
- Rejected state checks returned as JSON commit an audit row; unexpected
  exceptions roll the transaction back, including any same-transaction audit
  insert. A trusted server-side failure logger is still needed if those
  rollback failures must be durably recorded.
- SQL has not been parsed or run against PostgreSQL. `pg_cron` identity,
  PostgREST RPC responses, RLS, and race outcomes require an isolated live
  integration run before any shared-project deployment.
