# Database for the two claim baselines (3 and 4)

Baselines 3 (Non-Atomic Claim) and 4 (Protected Claim without Lease Recovery) run inside
PostgreSQL, so they use real transactions, row locks, unique indexes and READ COMMITTED
isolation. The proposed E2 method must run on the **same database** so that only the claim
mechanism differs.

| File | Run on | What it adds |
| --- | --- | --- |
| `00_local_postgres_supabase_shim.sql` | plain PostgreSQL **only** (skip on Supabase) | Roles `anon` / `authenticated` / `service_role`, table `auth.users`, functions `auth.uid()` and `auth.role()` |
| `01_GeoLock_Hub_Supabase_Schema_V3_10kg_360min.sql` | always | The GeoLock V3 schema: `claim_listing()`, `recover_expired_claims()`, 10 kg rule, 20 km geofence, 360-minute lease |
| `03_reset_baseline_database.sql` | only to start again | Empties the baseline database: removes everything `01` and baseline 3 created, all runs and the `@geolock.example.com` accounts |

Nothing else needs to be installed. Baseline 3 creates its own schema `e2_baseline` (the
unsafe `non_atomic_claim_listing()` and table `naive_claims`) when it starts; this does not
change any GeoLock table.

Use a database that is only for the baselines and experiments, never the GeoLock app's
own project. The scripts refuse to run if they find donations from accounts other than
`@geolock.example.com`.

## Option A – Supabase baseline project

1. Supabase dashboard → **SQL Editor**: run `01_…sql`. Do **not** run `00`.
2. Copy the **Session pooler** connection string (port 5432; the Transaction pooler, port
   6543, does not keep the NGO sign-in between statements). In the URL, write `@` inside
   the password as `%40`.
3. Run the scripts with `--dsn "<connection string>"` or set `GEOLOCK_BASELINE_DSN`
   (see `../source code/README.md`). Do not save the password in a file in the repository.

The free plan allows only a few pooled connections, so keep the default 2 / 5 / 10 NGOs per
trial. Response times include the network delay to Singapore.

## Option B – PostgreSQL 16 + PostGIS on your own computer

1. Install PostgreSQL 16 (postgresql.org/download/windows) and, with **Stack Builder**,
   PostGIS 3.x for PostgreSQL 16.
2. From this folder:

```powershell
psql -U postgres -c "CREATE DATABASE geolock_baseline"
psql -U postgres -d geolock_baseline -v ON_ERROR_STOP=1 -f 00_local_postgres_supabase_shim.sql
psql -U postgres -d geolock_baseline -v ON_ERROR_STOP=1 -f 01_GeoLock_Hub_Supabase_Schema_V3_10kg_360min.sql
```

3. Run the scripts with `--dsn "postgresql://postgres:PASSWORD@localhost:5432/geolock_baseline"`.

## The claim fix in `01`

`01` is the team's V3 schema with one line changed in `claim_listing()` (section 15). It
locks the listing with

```sql
select * into v_l from public.listings where listing_id=p_listing for no key update;
```

instead of `for update`. The request row inserted just before holds a foreign-key lock on
the listing, and `FOR UPDATE` conflicts with it, so simultaneous NGOs deadlocked: with 10
NGOs, 8–9 requests failed with a database error after about 12 seconds instead of getting
CLAIM_CONFLICT. `FOR NO KEY UPDATE` still lets only one request hold the listing.
Tested on PostgreSQL 16: 150 trials, exactly one claim each, every losing request answered
CLAIM_CONFLICT, no errors.

Baseline 4 checks this before it writes anything and stops if the database still has
`for update`. If a database was set up with the original file, open `01_…sql`, copy
section 15 (`claim_listing`), change `create function` to `create or replace function`,
and run it in the SQL Editor.

**Apply the same one-line change to `claim_listing()` in the app database**, because the
proposed E2 method must use the same function as baseline 4.

## Starting again

To clear old runs, open the SQL Editor and run `03_reset_baseline_database.sql`. It ends
with a check row that should show 0 in every column. Then run `01_…sql` again and rerun
**both** baselines. `03` stops without changing anything if the database holds donations
from accounts other than `@geolock.example.com`, so it cannot empty the app database.
