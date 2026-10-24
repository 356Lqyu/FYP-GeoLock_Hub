# Stage 2 atomic claim tests (isolated DEV only)

## Current-version review — 23 October 2026

**Minimum acceptance preparation follow-up:** the confirmed delayed-race defect
is now corrected and validated by 25 offline regressions and four isolated
PostgreSQL tests. Use the [two-actor package](review-only/stage3j/two_actor/README.md)
and its new entry point, which requires exactly two sessions/two fresh fixtures.
The original ten-actor suite below is retained; do not run it for this step.
The original findings below describe the pre-fix review. No live tests ran and
the saved DEV account/cron snapshot has not been refreshed in this preparation.

The [Stage 3J evidence matrix](review-only/stage3j/EVIDENCE_MATRIX.md) and
[acceptance plan](review-only/stage3j/ACCEPTANCE_PLAN.md) qualify the historical
preparation notes below. Current road eligibility, asynchronous workers and
Flutter workflows are implemented; they are not pending algorithm development.
Fresh SELECT-only DEV inspection found two active NGO profiles, only one with
verified road-node evidence. Ten eligible authenticated sessions and dedicated
fresh fixtures are therefore still unproven prerequisites for this runner.

Original defect, now fixed: executor shutdown previously waited
for blocked requests before the outer finally releases their listing lock.
The fix and isolated validation are recorded in the two-actor package; current
live execution still needs preflight and separate approval. No production SQL
change is indicated. The original runner
also has no 50-client cohort or full deployed-source/build result manifest.
Historical 2/10/50 G16 results are retained, but use an older RPC/fixture contract
and do not establish current-version acceptance. Stage 3I supervised direct
recovery remains PASS; job 3 stays inactive; unattended recovery is not approved.
No stateful execution is authorized by this documentation update.

`claim_concurrency_test.py` and `claim_fault_injection_dev_test.py` are
state-changing integration tests. They have been prepared but **not run**.
Never use the original shared project (`mffccmlimmbrgasgfnnq`). The runners
hard-require isolated DEV project `rcgyuwiidqvrgbxswhqj`, a matching exact
allowlist, HTTPS, and the typed disposable-project confirmation.

## Required test data and authentication

Prepare these records through the approved trusted test workflow in the
isolated DEV project. Do not use this suite to set `location_verified_at`,
invent coordinates, insert road nodes, or bypass discovery/claim checks.

- Ten distinct, active NGO users with genuine authenticated Supabase sessions.
- Each NGO must have a trusted verified location and be within 20 km of each
  listing assigned to that NGO, according to deployed backend rules.
- Four distinct, dedicated `AVAILABLE` listings for: two-way race, ten-way
  race, delayed-lock race, and discarded-response retry. Each must have a valid
  trusted road-node assignment and pass `discover_eligible_listing_cards()`
  for its assigned NGO set.
- One additional dedicated `AVAILABLE` listing for rollback/fault injection.
- The singleton coordination config must exist with `claim_lease_minutes=360`.
- These claims commit and are not cleaned up by the runner. Use a fresh set of
  disposable listings for every normal-suite run; preserve audit history.

Historical setup note (superseded for current implementation status by Stage 3J):
the repository fixture setup creates only two NGO accounts and does
not produce trusted operational verification or road-node assignments. Since
those trusted-fixture prerequisites were not established by that setup, the two-way and ten-way
success/conflict races, delayed race, and discarded-response retry case are
**BLOCKED** until ten legitimate eligible accounts and valid operational
listings are provisioned through the approved trusted workflow. The test does
not fabricate those prerequisites.

## Local configuration

Copy `claim_concurrency_test.env.template` to a file outside the repository,
for example `%LOCALAPPDATA%\GeoLockHub\dev\stage2-claims.env`. Restrict that
directory to the current Windows user. Fill in the DEV publishable key, service
role JWT, Session Pooler URL, ten user JWTs, four listing UUIDs, and fault-listing
UUID. The service-role JWT is used only for test verification reads. The NGO
JWTs are used for claim/discovery RPC calls. Do not print them or add the filled
file to Git.

The existing setup script creates only two synthetic NGO accounts. It is not
an acceptable source of ten test users until the trusted verification and
operational road-node dependencies are implemented. Use actual DEV-approved
test accounts and sessions; do not borrow accounts from the shared project.

## Windows CMD commands (for later, after explicit test approval)

```cmd
cd /d C:\Users\User\Downloads\FYP-GeoLock_Hub
if not exist "%LOCALAPPDATA%\GeoLockHub\dev" mkdir "%LOCALAPPDATA%\GeoLockHub\dev"
copy /Y supabase\tests\claim_concurrency_test.env.template "%LOCALAPPDATA%\GeoLockHub\dev\stage2-claims.env"
icacls "%LOCALAPPDATA%\GeoLockHub\dev" /inheritance:r /grant:r "%USERDOMAIN%\%USERNAME%:(OI)(CI)F"
icacls "%LOCALAPPDATA%\GeoLockHub\dev\stage2-claims.env" /inheritance:r /grant:r "%USERDOMAIN%\%USERNAME%:F"
notepad "%LOCALAPPDATA%\GeoLockHub\dev\stage2-claims.env"
py -m venv .venv-dev-fixtures
.venv-dev-fixtures\Scripts\python.exe -m pip install -r supabase\tests\requirements-dev-fixtures.txt
.venv-dev-fixtures\Scripts\python.exe supabase\tests\claim_concurrency_test.py --env-file "%LOCALAPPDATA%\GeoLockHub\dev\stage2-claims.env"
```

The normal runner will:

1. Require the exact isolated DEV reference, allowlist, confirmation, and URL.
2. Confirm ten distinct JWT subjects, the 360-minute config, fresh listing
   states, non-null road-node values, and actual per-user discovery eligibility.
3. Synchronize authenticated NGO attempts for 2 and 10 callers.
4. Verify committed `claim_requests`, active claims, leases, listing status,
   pickup tasks, and one `CLAIM_ATTEMPT` audit event for every initial attempt.
5. Replay the winning UUID, try changed-listing and changed-NGO payloads, and
   verify the original committed state is unchanged.
6. Discard the body of an HTTP 200 response, then retry the same UUID and
   verify the original claim and artifacts. This is a **discarded-response
   retry**, not a simulation of an unknown commit outcome: the client receives
   HTTP 200, so genuine post-commit response loss remains untested.
7. Hold a PostgreSQL row lock on the delayed-test listing and use
   `pg_blocking_pids()` to correlate waiting claim sessions specifically to
   that lock-holder backend PID. The case reports PASS only after both request
   sessions are observed blocked by that PID. Otherwise it reports
   INCONCLUSIVE after releasing the lock and draining the requests. The listing
   may still have been consumed on an inconclusive run; inspect committed DEV
   state and do not reuse it without confirming it remains fresh.

The delayed test needs `psycopg 3`, permission to observe relevant
`pg_stat_activity` rows, and the verified Session Pooler URL. It does not add a
production delay hook or alter the claim function. If visibility or matching
does not confirm both requests blocked by the test's own PID, it is
INCONCLUSIVE, never PASS. The two claim requests are released and may consume
the listing, so inspect its database state before reusing the fixture.

## Rollback and audit-write fault injection

The seven failure points are `claim_requests_insert`, `donation_claims_insert`,
`claim_leases_insert`, `listings_update`, `pickup_tasks_insert`,
`claim_requests_update`, and `audit_events_insert`.

`claim_write_failpoints_dev.sql` is a separate test-support script, **not a
production migration**. Its DDL is transactional. It refuses to proceed if
the helper schema or any named test trigger already exists, and it creates
plain new test objects rather than replacing existing ones. It adds a private
schema/table and narrowly targeted triggers on existing tables; a trigger
raises only for a request UUID explicitly registered in that private table.
It does not alter `claim_listing` or weaken any constraint. Review its SQL and
confirm the SQL Editor is connected to disposable DEV before manually
installing it. The runner checks that the seven trigger names, target tables,
and helper function match the expected test-only map and that no stale
failpoint rows remain. A PostgreSQL connection is used only to register and
clear test UUIDs and inspect rollback state.

After reviewing/installing those hooks and only with separate approval, run:

```cmd
.venv-dev-fixtures\Scripts\python.exe supabase\tests\claim_fault_injection_dev_test.py --env-file "%LOCALAPPDATA%\GeoLockHub\dev\stage2-claims.env"
```

The fault test expects all seven injected failures to return an error and leave
no request, claim, lease, pickup task, listing transition, or claim-attempt
audit row committed. It verifies each rollback before proceeding. It uses a
separate eligible fault listing that remains `AVAILABLE` after each rollback.

After testing, manually run `claim_write_failpoints_dev_cleanup.sql` in the
same isolated DEV project. The cleanup validates any matching trigger is
attached to the expected table and uses the expected helper before dropping
it, deletes and verifies all test-owned failpoint rows, then drops only the
named test triggers and helper objects. It uses no `CASCADE`, so unexpected
objects cause it to stop. It is safe to run again after successful cleanup.
Confirm its final result reports `test_schema_removed = true` and
`remaining_test_triggers = 0`.

If a test process or SQL Editor session is interrupted, do not immediately
rerun the tests. First inspect the dedicated listing, request UUIDs, and
`geolock_stage2_test.claim_write_failpoints` rows using read-only queries. If
the helper objects remain, execute the separate cleanup script in DEV after
reviewing its target-project banner. Then verify the helper schema is absent
and no failpoint registrations remain. Never delete claim/audit rows from the
normal concurrency suite; its successful claims intentionally consume their
listings and preserve audit evidence. A stale failpoint row is request-scoped,
but clean it up before continuing.

## Audit durability boundary

The RPC can durably audit ordinary returned outcomes (`SUCCESS`, `CONFLICT`,
and `INELIGIBLE`) because the request result and audit insert commit together.
An exception from any required write rolls the transaction back, including an
audit event attempted in that transaction. The fault test therefore expects no
`CLAIM_ATTEMPT` row after an injected write failure; it establishes atomic
rollback, not durable evidence for rolled-back failures. Durable logging of
those exceptional failures requires a separately trusted post-rollback logger
or another approved mechanism and is not implemented by these test changes.

The changed-payload idempotency check also raises an exception; the test checks
that the original claim/request/audit rows remain unchanged. That rejection
does not itself create a committed audit event under the current RPC behavior.
