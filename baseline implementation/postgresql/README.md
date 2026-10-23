# Database setup for the two claim baselines (3 and 4)

Baselines 3 (Non-Atomic Claim) and 4 (Protected Claim without Lease Recovery) run inside
PostgreSQL, so they use real transactions, row locks, unique indexes and READ COMMITTED
isolation, exactly like the GeoLock claim. The other six baselines need no database, and
reading the results in `../result/` needs no database either.

| File | Run on | What it adds |
| --- | --- | --- |
| `00_local_postgres_supabase_shim.sql` | plain PostgreSQL **only** (skip on Supabase) | The Supabase objects the schema needs: roles `anon` / `authenticated` / `service_role`, table `auth.users`, functions `auth.uid()` and `auth.role()` |
| `01_GeoLock_Hub_Supabase_Schema_V3_10kg_360min.sql` | always | The GeoLock schema, including `claim_listing()`, the 20 km geofence and the 360-minute lease. Identical copy of `supabase/schema/GeoLock_Hub_Supabase_Schema_V3_10kg_360min.sql` |
| `02_e2_non_atomic_claim_baseline.sql` | always | Schema `e2_baseline`: the unsafe `non_atomic_claim_listing()` and its table `naive_claims`. Used by baseline 3 only |

Use a database that is only for the baselines, never the GeoLock app's own Supabase
project: the scripts insert many benchmark users, donations, listings and claims, and they
refuse to run if they find real (non-benchmark) donations.

## Option A – the Supabase baseline project (default, nothing to install)

A separate Supabase project made only for the baselines, region Southeast Asia
(Singapore, `ap-southeast-1`). Both claim scripts connect to it by default:

```
postgresql://postgres.wwmwjudfzislprjsekti:Geolock%402027@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres
```

The password is `Geolock@2027`; inside a connection string the `@` must be written as
`%40`, as above. This is the **Session pooler** (port 5432); the Transaction pooler (port
6543) does not keep the NGO sign-in between statements.

**One-time setup** (once for this project): open the Supabase dashboard → **SQL Editor**,
paste and run `01_GeoLock_Hub_Supabase_Schema_V3_10kg_360min.sql`, then
`02_e2_non_atomic_claim_baseline.sql`. Do **not** run `00`.

**Run** (PowerShell, from `baseline implementation\source code`):

```powershell
pip install -r requirements.txt
python non_atomic_claim_baseline.py
python protected_claim_without_lease_recovery_baseline.py
```

Results go to `../result/3_non_atomic_claim/` and
`../result/4_protected_claim_without_lease_recovery/`; `run_info.md` records which database
was used.

Notes:
- Keep the default number of NGOs per trial (2 / 5 / 10). The free plan allows only a small
  number of pooled connections, so `--workers 50` will fail.
- Each run creates its own rows, so runs never mix. To start from an empty database, run
  the one-time setup again on a new project.
- Ownership results (duplicate claims, expired leases released or not) are the same as on
  a local database. Response times include the network delay to Singapore, and the number
  of deadlock errors depends on timing, so final response-time numbers should come from
  Option B.

## Option B – PostgreSQL 16 + PostGIS on your own computer

1. Install PostgreSQL 16 with the EDB installer (postgresql.org/download/windows). Keep
   port 5432 and remember the `postgres` password.
2. When the installer finishes, open **Stack Builder** → *Spatial Extensions* → install
   **PostGIS 3.x for PostgreSQL 16**.
3. Add `C:\Program Files\PostgreSQL\16\bin` to PATH so `psql` works in a terminal.
4. Create the baseline database, from this folder:

```powershell
psql -U postgres -c "CREATE DATABASE geolock_baseline"
psql -U postgres -d geolock_baseline -v ON_ERROR_STOP=1 -f 00_local_postgres_supabase_shim.sql
psql -U postgres -d geolock_baseline -v ON_ERROR_STOP=1 -f 01_GeoLock_Hub_Supabase_Schema_V3_10kg_360min.sql
psql -U postgres -d geolock_baseline -v ON_ERROR_STOP=1 -f 02_e2_non_atomic_claim_baseline.sql
```

5. Run, from `..\source code`:

```powershell
python non_atomic_claim_baseline.py --dsn "postgresql://postgres:PASSWORD@localhost:5432/geolock_baseline"
python protected_claim_without_lease_recovery_baseline.py --dsn "postgresql://postgres:PASSWORD@localhost:5432/geolock_baseline"
```

To start clean, drop the database (`psql -U postgres -c "DROP DATABASE geolock_baseline"`)
and repeat step 4.

## Option C – Supabase CLI (needs Docker Desktop)

In an empty folder run `npx supabase init` and `npx supabase start`. The database is
`postgresql://postgres:postgres@127.0.0.1:54322/postgres`. Run only `01` and `02` (as in
step 4 of Option B, with `-d "postgresql://postgres:postgres@127.0.0.1:54322/postgres"`),
then run the scripts with `--dsn` and that connection string.

## Known issue in `claim_listing()` (affects baseline 4)

`claim_listing()` first inserts the request into `claim_requests`; its foreign key to the
listing makes PostgreSQL take a KEY SHARE lock on the listing. The function then asks for
`FOR UPDATE` on the same listing, which conflicts with the KEY SHARE locks of the other
simultaneous requests, so they wait for each other (deadlock) and PostgreSQL aborts one of
them about once per second. Ownership stays correct (an aborted request stores nothing),
but with 5 or 10 simultaneous NGOs most losing requests get a database error instead of a
clear "already claimed" answer, after several seconds. The deployed function has the same
order.

One-word fix in `claim_listing()` (schema and deployed function):

```sql
select * into v_l from public.listings where listing_id=p_listing for no key update;
```

`FOR NO KEY UPDATE` still lets only one request hold the listing at a time, but does not
conflict with foreign-key locks. Tested: 50 trials × 10 simultaneous requests, no deadlock,
no retry, exactly one claim each. Baseline 4 calls the real `claim_listing()`, so after
the fix is applied (to `01_…sql` and to the Supabase baseline project) baseline 4 must be
rerun.
