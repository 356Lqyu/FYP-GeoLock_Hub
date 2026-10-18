# Stage 1 recovery fixtures — isolated DEV only

This guide and its scripts are preparation artifacts. They have **not** been
run. The fixture creator has a hard allowlist for project reference
`rcgyuwiidqvrgbxswhqj` and blocks `mffccmlimmbrgasgfnnq`. It performs no remote
request until the operator supplies the expected DEV values and types an exact
confirmation phrase.

## What the existing recovery test needs

`stage1_claim_recovery_dev_test.py` needs these synthetic identities:

| Identity | Count | Role / purpose |
|---|---:|---|
| Donor | 1 | Owns the direct donations; supplies the second party's reconciliation evidence; also exercises denied recovery authorization. |
| NGO A | 1 | Owns the test claims and initiates cancellation, pickup, recovery, reconciliation, and audit reads. |
| NGO B | 1 | Owns one separate claim so NGO A's foreign-claim audit request can be rejected. |
| Service role | Existing DEV credential | Calls `recover_expired_claims()` and reads committed rows. It is not an Auth test user and never belongs in Flutter. |
| Anon | Existing DEV anon JWT | Verifies that recovery is denied to an unauthenticated caller. |

The script expects **13 separate direct-donation listings, claims, leases, and
pickup tasks**, plus the four pre-opened reconciliation cases and one routed
task:

| Fixture | Initial state | Expected exercise |
|---|---|---|
| `expired_safe` | Active claim and lease expired; task `CONFIRMED`; no route; donation ready | Safe lease recovery releases and makes listing available. |
| `cancel_same` | Active, unexpired, confirmed | Ten concurrent identical cancel request UUIDs produce one stable result. |
| `cancel_distinct` | Active, unexpired, confirmed | Ten different cancellation requests produce one successful release. |
| `cancel_start_race` | Active, unexpired, confirmed | Donor/NGO cancellation versus `start_pickup`; committed rows must agree. |
| `expired_pickup` | Active claim/lease expired; task confirmed | Expired lease rejects pickup start and completion. |
| `cancel_recovery_race` | Active claim/lease expired; task confirmed | User cancellation cannot bypass expiry recovery. |
| `route_linked_expired` | Active claim/lease expired; route `IN_PROGRESS`, stop and active assignment exist | Recovery must preserve reconciliation instead of reopening. |
| `reconcile_positive` | Claim/lease `RECONCILIATION_REQUIRED`; task `DISPATCHED`; donation `PICKUP_IN_PROGRESS`; open case | NGO and donor both confirm handover; committed states become collected/completed/closed. |
| `reconcile_dispatched_no_handover` | Same uncertain dispatched state | Both deny handover; remains in manual review/reconciliation. |
| `reconcile_conflict` | Same uncertain dispatched state | NGO and donor evidence disagree; remains in reconciliation. |
| `reconcile_safe_release` | Reconciliation claim; task confirmed; listing claimed; donation ready; open case; no route | Both deny handover; safe release can return listing to available. |
| `audit_own` | Active claim owned by NGO A | NGO A can read its claim audit scope and reconciliation inbox. |
| `audit_foreign` | Active claim owned by NGO B | NGO A cannot read that claim's audit scope. |

Every donation has one actual, small synthetic PNG uploaded to the existing
private `geolock-donation-images` DEV bucket and one matching
`donation_images` row. This satisfies the V3 deferred photo constraint without
creating dangling image metadata. Each donation also gets one positive-weight
item in the first active category. Weights are 18 kg and collection path is
`DIRECT_PICKUP`; these scenarios test claim recovery, not the 10 kg boundary.
Direct listing expiry remains `NULL`.

The route node value on synthetic pickup tasks is explicitly
`DEV_FIXTURE_ONLY_NOT_OPERATIONAL_NODE`. The test never calls listing discovery
or `claim_listing()` with these seeded claims. This fixture must not be treated
as road-network coverage or an operational route node.

The four expired claims are recovered together in the test's overlapping
worker phase. That phase concurrently races a donor cancellation against both
recovery workers, and checks the exact four committed outcomes. The preceding
expired-pickup checks run before recovery so the lease is still expired when
`start_pickup()` and `complete_pickup()` are tested. The setup refuses to run
if unrelated expired active claims already exist, because they would make the
worker's batch results ambiguous.

## Credential handling and setup

1. Create a disposable Supabase DEV project with reference exactly
   `rcgyuwiidqvrgbxswhqj`. Never use the original shared project.
2. In the DEV Dashboard, obtain the publishable key, legacy anon JWT, server-side
   service-role JWT, and the DEV PostgreSQL connection string. Prefer the
   verified Session Pooler if the direct endpoint is unreachable over IPv6:
   host `aws-0-ap-northeast-2.pooler.supabase.com`, port `5432`, database
   `postgres`, username `postgres.rcgyuwiidqvrgbxswhqj`, and
   `sslmode=require`. The script also accepts the direct DEV endpoint
   `db.rcgyuwiidqvrgbxswhqj.supabase.co` with username `postgres` and SSL
   required. For either URL, enter the DEV database password locally and
   URL-encode reserved characters. Keep the
   service-role JWT and database password outside the repository. The
   development Auth users are created with fresh random passwords by the setup
   script; passwords are held in memory only. Their access JWTs are saved to a
   local generated file and are not printed.
3. Copy `stage1_dev_setup.env.template` to
   `%LOCALAPPDATA%\GeoLockHub\dev\stage1-setup.env`. Fill it in a text editor.
   URL-encode special characters in the database password in the PostgreSQL
   URI. The allowlist must contain only the DEV reference.
4. Restrict the local config directory before entering secrets. In CMD:

   ```cmd
   if not exist "%LOCALAPPDATA%\GeoLockHub\dev" mkdir "%LOCALAPPDATA%\GeoLockHub\dev"
   icacls "%LOCALAPPDATA%\GeoLockHub\dev" /inheritance:r /grant:r "%USERDOMAIN%\%USERNAME%:(OI)(CI)F"
   icacls "%LOCALAPPDATA%\GeoLockHub\dev\stage1-setup.env" /inheritance:r /grant:r "%USERDOMAIN%\%USERNAME%:F"
   notepad "%LOCALAPPDATA%\GeoLockHub\dev\stage1-setup.env"
   ```

   The generated JWT file is written to the same directory with a current-user
   ACL. Do not paste its contents into messages, logs, or source control.

## Exact Windows CMD commands

Run these from a fresh CMD window. The setup script's required interactive
confirmation is an additional guard after the project and schema checks.

```cmd
cd /d C:\Users\User\Downloads\FYP-GeoLock_Hub
if not exist "%LOCALAPPDATA%\GeoLockHub\dev" mkdir "%LOCALAPPDATA%\GeoLockHub\dev"
copy /Y supabase\tests\stage1_dev_setup.env.template "%LOCALAPPDATA%\GeoLockHub\dev\stage1-setup.env"
icacls "%LOCALAPPDATA%\GeoLockHub\dev" /inheritance:r /grant:r "%USERDOMAIN%\%USERNAME%:(OI)(CI)F"
icacls "%LOCALAPPDATA%\GeoLockHub\dev\stage1-setup.env" /inheritance:r /grant:r "%USERDOMAIN%\%USERNAME%:F"
notepad "%LOCALAPPDATA%\GeoLockHub\dev\stage1-setup.env"
py -m venv .venv-dev-fixtures
.venv-dev-fixtures\Scripts\python.exe -m pip install -r supabase\tests\requirements-dev-fixtures.txt
.venv-dev-fixtures\Scripts\python.exe supabase\tests\stage1_claim_recovery_dev_setup.py
```

At the prompt, type exactly:

```text
CREATE SYNTHETIC FIXTURES IN DEV rcgyuwiidqvrgbxswhqj
```

The setup runs a read-only schema/config preflight first, then creates or resets
only three Auth identities with fixed synthetic `.invalid` addresses, uploads
the synthetic photos, and seeds the fixture rows using the configured DEV
database connection. Psycopg 3 uses the standard PostgreSQL connection protocol
and supports the Supabase Session Pooler URI. It seeds initial claims directly
because recovery and ambiguous handover states cannot be reached safely through normal public user RPCs. This
does not change a database function, policy, or production record. The NGO
locations are explicitly synthetic fixture approvals for this runner; they are
not verified operational locations.

Run the recovery suite from the same fresh CMD window:

```cmd
cd /d C:\Users\User\Downloads\FYP-GeoLock_Hub
.venv-dev-fixtures\Scripts\python.exe -m py_compile supabase\tests\stage1_dev_env.py supabase\tests\stage1_claim_recovery_dev_setup.py supabase\tests\stage1_claim_recovery_dev_test.py
.venv-dev-fixtures\Scripts\python.exe supabase\tests\stage1_claim_recovery_dev_test.py
```

The test runner loads `%LOCALAPPDATA%\GeoLockHub\dev\stage1-generated.env`,
checks that the URL, project reference, and exact allowlist all match the one
approved DEV project, and blocks the known shared reference. Do not run the
test script against a different reference by editing its guard.

## Repeatability and cleanup

Each setup run gets a new UUID namespace for its donation/claim graph, so a
fresh run does not reuse consumed state or confuse new audit events with older
ones. The three synthetic Auth users are reused; the setup resets their random
passwords and refreshes local JWTs. Test fixture rows and photo objects remain
in the disposable DEV project. Run setup sparingly and keep the generated env
file for the active run.

### Recovering from the first failed setup attempt

The reported `fk_request_result` error happened inside the single PostgreSQL
fixture transaction. Psycopg rolls that transaction back when the seed fails,
including fixture rows and any audit rows written by database triggers in that
transaction. Auth user creation and Storage uploads happen outside PostgreSQL,
so those are separate: the three synthetic Auth users remain, and the setup
attempts to delete only the exact photo object paths it uploaded. If it did not
print a Storage cleanup warning, the Storage delete request succeeded. Do not
delete the Auth users or any existing audit records.

If cleanup was reported as unconfirmed, inspect the private
`geolock-donation-images` bucket in the DEV Dashboard. Locate objects only
under the synthetic donor's UUID folder and only the PNG paths from this failed
attempt. Before manually deleting any candidate object, verify in the DEV SQL
Editor that no `public.donation_images.storage_path` references that exact
object path, using a read-only check with that exact path substituted:

```sql
select count(*)
from public.donation_images
where storage_path = '<exact-candidate-object-path>';
```

Delete only individually confirmed orphan objects when this returns `0`; if
you cannot identify an object as belonging to this failed attempt, leave it
untouched. Do not delete the whole donor folder or run a broad cleanup query.
The setup now refuses to
reset an Auth account that uses its reserved synthetic address without the
expected fixture metadata marker.

After this partial-state review, another setup attempt uses a new UUID fixture
namespace. The failed transaction left no database fixture rows, and retained
synthetic Auth users are safely reused. A leftover unreferenced photo, if any,
does not collide with the new attempt's paths.

V3 deliberately freezes donation items after submission, and audit rows are
append-only. The setup therefore does not offer a broad delete/reset mode that
would disable triggers or erase audit history. For complete cleanup, retain
any required audit evidence, then delete the disposable DEV Supabase project
through the Dashboard and remove the local files:

```cmd
del "%LOCALAPPDATA%\GeoLockHub\dev\stage1-setup.env"
del "%LOCALAPPDATA%\GeoLockHub\dev\stage1-generated.env"
rmdir /s /q .venv-dev-fixtures
```

The generated Auth accounts have synthetic addresses and can be reused for
another run. Do not delete their Auth rows individually while audit events
still reference them.

## Boundaries and remaining test dependencies

- This fixture set satisfies `stage1_claim_recovery_dev_test.py`. It does not
  seed the larger hub-reservation lifecycle runner or the 2/10/50 claim race
  runner; those require their own separately reviewed fixture graphs, hub
  capacity setup, and eligible listing fixtures.
- Direct seed writes use the DEV PostgreSQL `postgres` role and create only
  test rows. No service-role credential is used for SQL, and no SQL statement
  is run by this preparation task.
- The test suite is state-changing and intended only for the disposable DEV
  project. A fresh fixture setup is required before every full run.
- Supabase Auth admin API, Storage upload metadata, PostgreSQL constraints,
  exact deployed grants, and state-transition behavior have not been exercised
  here. These require running the setup and tests in the isolated DEV project.
- Setup is blocked until the DEV private bucket exists, the October 19 tables
  and function signatures pass preflight, the three configuration values
  match, and the local PostgreSQL Python driver is installed.
