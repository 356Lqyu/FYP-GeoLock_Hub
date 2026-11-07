# Current claim-audit E2 harness compatibility validation

Scope: local preparation for deployed `20261031_claim_audit_and_failure_capture.sql`.
No Supabase connection, live DEV/shared execution, deployment, recovery activation,
protected-business fixture insertion in DEV, or production application change occurred.

| Suite | Final result | Scope |
|---|---|---|
| `claim_*offline_test.py` discovery | 45 PASS, 0 failures/errors/skips | Manifest/target/source/security guards, distinct identities, default preflight and execution gates, receipt classification, uncertain transport, history preservation, authorization, journaling and delayed-lock error paths |
| `claim_two_actor_isolated_test.py --run-isolated --pg-bin ...` | 8 PASS, 0 failures/errors/skips | New loopback PostgreSQL 17 cluster, actual nine revised definitions checked against catalogs, full two-actor flow, real blocked sessions, ten distinct local actors, all seven request-scoped failpoints, receipt deduplication/retry/authorization and preservation of uncertain registrations |
| Existing `claim_audit_isolated_test.py --run-isolated` | 22 PASS, 0 failures/errors/skips | Full migration guards and current audit/failure contract, including unavailable failure ledger, cancellation, hub linkage, actor-scoped retrieval, replay and recovery/reconciliation audit context in disposable-local databases |

**Total: 75 unique tests PASS. Live acceptance has not run.**
The local schemas deliberately use Auth/road/cron/HTTP doubles. These results are not
claims about genuine DEV account eligibility, HTTP delivery or live performance.

Commands are in [the current runbook](../../../claim_concurrency_test.md).
On Windows, pg_ctl required execution outside the restricted process sandbox;
all test databases were freshly created on random loopback ports and cleaned up.
No external DSN is accepted by either isolated entry point.

## Exact source, fixture and documentation files changed in this update

- `supabase/tests/claim_concurrency_test.py`
- `supabase/tests/claim_fault_injection_dev_test.py`
- `supabase/tests/claim_two_actor_acceptance.py`
- `supabase/tests/claim_e2e_contract.py`
- `supabase/tests/claim_e2e_offline_test.py`
- `supabase/tests/claim_two_actor_offline_test.py`
- `supabase/tests/claim_two_actor_isolated_test.py`
- `supabase/tests/claim_concurrency_test.md`
- `supabase/tests/claim_concurrency_test.env.template`
- `supabase/tests/review-only/stage3j/two_actor/01_health.sql`
- `supabase/tests/review-only/stage3j/two_actor/02_fixture.sql`
- `supabase/tests/review-only/stage3j/two_actor/approved_functions.json`
- `supabase/tests/review-only/stage3j/two_actor/fixture_manifest.template.json`
- `supabase/tests/review-only/stage3j/two_actor/dev.env.template`
- `supabase/tests/review-only/stage3j/two_actor/README.md`
- `supabase/tests/review-only/stage3j/two_actor/RESULTS.md`
- `supabase/tests/review-only/stage3j/two_actor/SHA256SUMS.txt`

The existing audit suite also generated local-only evidence under
`results/claim-audit-local-tests/`: `environment.json`, `operations.jsonl`, and
`postgresql-server.log`. Existing historical captured RPC inputs, prior benchmark
results, recovery packages and `SOURCE_PROTECTION.json` were preserved.

## Readiness and remaining prerequisites

The live runners now default to read-only preflight and require a reviewed private
fixture manifest, exact DEV target, explicit identities/mappings, current source
contract and pinned security/health baselines. Source expectations were refreshed
from actual local SQL definitions and checked against local PostgreSQL catalogs;
no deployed source baseline was invented or automatically accepted.

Before live use, obtain fresh authorized DEV read-only evidence for all ten contract
ACLs, the other-function aggregate, recovery history, worker health and the intended
accounts. Fill the external manifest and exact migration-file SHA256, then provision
fresh eligible dedicated direct donations through protected workflows. Two and ten
actor modes require exactly that many distinct real authenticated NGO identities.

The two-actor mode needs two listings; the ten-actor mode needs four. Fault mode
needs one separate listing, reviewed request-scoped support hooks and their exact
source/trigger pins in `fault_hooks`. Hooks were installed only in disposable local
tests, never DEV. Fault success retries consume the dedicated fault listing.

Preserve original request IDs and retained history on uncertain outcomes. No live
runner performs recovery or global cleanup; all recovery cron jobs must be inactive.
Live expiry/recovery remains pending a separate isolation/safety review.

**Next action:** review and fill the private manifest from fresh authorized read-only
DEV evidence, then run the updated two-actor preflight without `--execute`.

---

## Historical preparation results below (superseded for the current contract)

# Stage 3J minimum preparation validation results

**Preparation PASS. Live execution remains blocked pending fresh preflight,
approved disposable fixtures/sessions and separate execution approval.**

## Actual final results

| Suite | Actual result | What ran |
|---|---|---|
| claim_two_actor_offline_test.py | 25/25 PASS, 0.344 s | Corrected real-thread executor lifetime; success/inconclusive/observation/worker/rollback/partial-submit/extra-waiter/lock-error paths; DEV allowlist and retained-fixture fence; two-vs-ten compatibility; explicit execution guard/default preflight; health/source/security drift guards; exact holder errors; fixture mapping and eligibility guards; safe request journal; current captured RPC body equality |
| claim_two_actor_isolated_test.py --run-isolated | 4/4 PASS, 14.369 s | NEW disposable loopback PostgreSQL 17 cluster; real claim/cancel/pickup function bodies, lifecycle/deferred checks and listing triggers; real row-lock waiters and transitive blocker observation; entire two-actor sequence committed; replay/payload/nonholder/released-holder failures; audit-write failure rollback; read-only SQL parsing and unapproved-source rejection |
| Existing *contract_test.py discovery | 106/106 PASS, 0.621 s | Existing offline source contracts, no network/database calls |
| Whitespace, documentation links, source protection and checksums | See SHA256SUMS.txt and SOURCE_PROTECTION.json | Exact prepared files and unchanged protected source hashes; no secrets included |

Commands from repository root:

```powershell
& '.venv-dev-fixtures/Scripts/python.exe' -B -m unittest discover -s supabase/tests -p 'claim_two_actor_offline_test.py'
& '.venv-dev-fixtures/Scripts/python.exe' -B supabase/tests/claim_two_actor_isolated_test.py --run-isolated --pg-bin 'C:/Program Files/PostgreSQL/17/bin'
& '.venv-dev-fixtures/Scripts/python.exe' -B -m unittest discover -s supabase/tests -p '*contract_test.py'
git diff --check
```

The isolated entry point accepts only local executable paths and initializes a
new temporary cluster bound to 127.0.0.1 at an ephemeral port. It strips inherited
PG connection variables and accepts no external DSN. The temporary cluster is
stopped/removed afterward. The active/installed PostgreSQL instance is not used.
Windows sandbox blocked pg_ctl's restricted token; the same isolated test command
was run through the approved escalation mechanism, not redirected to DEV.

## Defects found and resolved during local validation

1. Original executor scope waited for blocked workers before the outer finally
   released their blocker. Fixed by rollback/close inside the executor scope.
2. Original parameterized query contained a literal `%claim_listing%` pattern;
   psycopg rejected `%c` as a placeholder. The pattern is now a bound parameter.
3. A waiting claimant may itself queue another claimant; requiring both to list
   the root PID directly can return INCONCLUSIVE. Observation now follows the
   transitive pg_blocking_pids graph to the harness's own root PID, and rejects
   extra competing claim waiters.
4. Activity snapshots cached within the lock-holding transaction caused repeated
   stale observations. The observer clears its own statistics snapshot before
   each poll. This is session-local view refresh, not resetting statistics or
   modifying records. Both actual delayed tests pass with fresh observations.

Initial local runs were not acceptance passes: first, Windows prevented server
startup; next, the driver placeholder bug and a missing fixture-only recovery
sentinel were found; then stale activity observations produced INCONCLUSIVE.
These are superseded by the final 4/4 run. The sentinel raises if invoked; no
recovery function call occurs anywhere in this new test sequence.

## Reused actual logic and explicit doubles

Reused fixtures/helpers: claim_recovery_automatic_isolated_test.py setup,
claim_recovery_expiration_isolated_schema.sql reduced tables,
claim_recovery_automatic_live_rpcs.sql exact captured current claim_listing,
start_pickup, complete_pickup and cancel_claim, actual lifecycle helpers/deferred
validator/transition triggers, and claim_recovery_guarded_live_triggers.sql.
No previously deployed source file was edited. An offline test confirms the
four captured bodies match the frozen actual deployed source, CRLF-to-LF only.

The isolated full-sequence test uses PostgreSQL `SET LOCAL ROLE authenticated`
and auth.uid GUC fixtures. HTTP and REST are adapters to the local PostgreSQL
functions/tables; fake token strings are NOT valid Supabase JWTs. The real Auth
endpoint, PostgREST, gateway permissions, RLS/storage policies, photo-upload
validation and directed routing algorithm are not tested by these adapters.
Road eligibility/resolution, cron health and photo/item metadata are explicit
doubles/reduced tables. Full approval metadata is exercised by offline drift
tests; the isolated health query deliberately returns unapproved fixture source
and is correctly rejected. No local cron scheduler runs.

Both local race fixtures finish AVAILABLE, v3/g2, RELEASED claim and lease with
NGO_CANCELLED_BEFORE_PICKUP, STALE task and exactly five new audit rows each:
two CLAIM_ATTEMPT outcomes, donation claim transition, cancellation and donation
release transition. No reconciliation or LEASE_RECOVERY event appears. The
normal cancellations enqueue generation 2; worker completion is not fabricated.
Audit-write injection rolls back the request, claim, lease, task, listing,
donation and audit writes, including deferred validation. All test mutations are
restricted to the disposable cluster.

## Remaining live execution conditions

- Supabase MCP tools were not available during this preparation. Do not treat
  the 23 October snapshot as fresh. Execute the prepared SELECT-only checks.
- Existing second NGO authentication may suffice for rejection-only cases, but
  both actors must actually discover both fresh listings for two-winner-capable
  contention. No ten-NGO provisioning is justified yet.
- Require separate approval before ordinary Flutter fixture/profile changes or
  any live claim/cancel/negative-pickup RPC attempt. Default runner is preflight.
- Keep job 3 inactive; no recovery, activation or timestamp edit is needed.
- Real HTTP/JWT/managed-role observation visibility and transport failures are
  live integration evidence still missing. Failure/INCONCLUSIVE must preserve
  request IDs and inspect committed state; do not retry consumed fixtures.
- Two actors provide meaningful current authority evidence, not 10/50 load,
  genuine unknown-commit loss, real hub acceptance or unattended recovery approval.
