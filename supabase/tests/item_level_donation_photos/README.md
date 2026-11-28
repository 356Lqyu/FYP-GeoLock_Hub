# Item-level donation photos: local tests

Tests for `supabase/migrations/20261126120000_item_level_donation_photos.sql`. They run against a disposable local PostgreSQL 16 database only, never against a Supabase project.

## Files

| File | Purpose |
|---|---|
| `harness/00_supabase_stubs.sql` | Minimal `auth`/`storage` schemas, roles, `auth.uid()` |
| `harness/load_baseline.sh` | Loads the NEW-project bootstrap SQL (01–06) plus `20261123210000` into an empty database |
| `harness/90_spatial_and_eligibility_stubs.sql` | Replaces the two PostGIS/pgRouting functions with table-driven stubs |
| `rebuild.sh` | Drops and rebuilds one local database to the audited baseline |
| `10_fixtures_before_migration.sql` | Test users and hubs, legacy donations created with the legacy RPC, and a catalogue snapshot |
| `20_tests_after_migration.sql` | 165 assertions; prints PASS/FAIL per test |
| `30_rollback_checks.sql` | Rollback checks (`-v scenario=used` or `unused`) |
| `20261126120000_item_level_donation_photos.rollback.sql` | Rollback. Not a migration, so it is kept out of `supabase/migrations` |
| `KLSEL_ITEM_PHOTO_POSTDEPLOY_VERIFY.sql` | Read-only post-deployment check for the SQL Editor |
| `run_all.sh` | Rebuilds the database, then runs the fixtures, the migration and the tests |

## Run

```bash
# a local cluster on socket dir /tmp/pgip, port 55433, superuser postgres
BOOT=<new-project-bootstrap/bootstrap> REPO_MIGRATION=<20261123210000 file> ./run_all.sh t1
```

The scripts expect the migration file next to them. Copy it from `supabase/migrations` first.

## Not covered locally

PostGIS, pgRouting and pg_cron are not available locally, so three things are simulated:

- Road eligibility comes from `test_harness.road_eligibility`.
- The claim fixture writes the same rows `claim_listing()` writes.
- The hub reservation row is inserted directly.

The authorisation functions under test (`can_read_geolock_donation_image`, `get_*_constituents_v2`, `get_my_hub_donation_detail`) are the unchanged deployed bodies.
