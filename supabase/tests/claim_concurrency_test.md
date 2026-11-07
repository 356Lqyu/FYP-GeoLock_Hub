# Claim E2 harness: current audit and failure-receipt contract

Preparation only. No live run is implied by local validation.
The authoritative source is `../migrations/20261031_claim_audit_and_failure_capture.sql`.

## Entry points and fixture scope

All three runners now default to non-mutating preflight. They require `--env-file`,
`--manifest` and a new `--output-dir` outside the repository. No runner creates
accounts, donations, listings, claims, leases or fault hooks. They reject shared
project targets and retained recovery fixtures before network access.

| Runner | Sessions | Fresh direct listings | Manifest purpose |
|---|---:|---:|---|
| `claim_two_actor_acceptance.py` | exactly 2 | 2: race, delayed | `two_actor` |
| `claim_concurrency_test.py --actors 2` | exactly 2 | 2: race, delayed | `two_actor` |
| `claim_concurrency_test.py --actors 10` | exactly 10 | 4: 2-way, 10-way, delayed, discarded response | `concurrency_10` |
| `claim_fault_injection_dev_test.py --actors 2` | exactly 2 | 1 dedicated fault listing | `fault_injection` |

Fault testing also permits ten distinct sessions with `--actors 10`. Every
configured NGO must pass Auth user verification and actual authorized discovery
for every configured listing. Concurrent retries deliberately reuse one actor's
request; they are not counted as distinct-NGO experiments.

## Reviewed manifest and preflight

Copy `review-only/stage3j/two_actor/fixture_manifest.template.json` outside the
repository. Supply exact ordered actor IDs, listing/donation mappings, a unique
STAGE3J label, an approval reference and operator. Match these with env values
`GEOLOCK_STAGE3J_DONATION_IDS`, `GEOLOCK_TEST_LISTING_IDS`,
`GEOLOCK_STAGE3J_FIXTURE_LABEL` and the exact number of NGO JWTs.

Prepare baseline evidence manually from the SELECT-only `01_health.sql` on the
intended DEV project during a separately authorized inspection. Review the output;
never auto-adopt a drifted baseline. `health_baseline` must pin:

- SHA256 of the exact current local migration file bytes;
- `other_functions_md5` (the SQL now excludes the ten explicitly checked signatures);
- exact `function_acls` for all ten signatures, preserving JSON null where applicable;
- actual recovery-history total/failed/unfinished counts (failures and unfinished must be zero).

`approved_functions.json` is a **local source-derived expectation**, not a newly
captured DEV snapshot. Its nine migration bodies were compared with actual local
PostgreSQL definitions. The unchanged claim-card reader was compared with its
20261028 source. Live preflight must independently match every definition, signature,
owner, security setting, search path, ACL and failure index. Do not replace the
expected hashes merely to make a failed preflight pass.

Preflight uses READ ONLY PostgreSQL verification connections, GET Auth checks and
the read-only discovery RPC. It requires fresh manifest-mapped >=10 kg direct
fixtures with valid photos/items, no claims/failures/cases/routes, a resolved node,
NULL listing expiration and completed current eligibility refresh. It also requires
the unchanged 360-minute policy, healthy eligibility workers, all recovery cron jobs inactive,
no overdue active pair and no unresolved reconciliation case.

Create DEV fixtures later through protected donor onboarding/donation/photo and
trusted location workflows; let `claim_listing` create claims and leases. Do not run
`stage1_claim_recovery_dev_setup.py` unchanged: it inserts synthetic business rows.

Example for a later authorized **preflight only** (PowerShell, repository root):

```powershell
& '.venv-dev-fixtures/Scripts/python.exe' -B supabase/tests/claim_two_actor_acceptance.py --env-file '<private-env>' --manifest '<reviewed-manifest.json>' --output-dir '<new-private-output-folder>'
```

Execution additionally requires `--execute --execution-approval` with the exact
runner-specific token: `I_APPROVE_STAGE3J_TWO_ACTOR_ACCEPTANCE`,
`I_APPROVE_DEV_CLAIM_CONCURRENCY`, or `I_APPROVE_DEV_CLAIM_FAULT_INJECTION`.
These are operator attestations, not substitutes for scope approval or passed guards.

## Result semantics and assertions

Business `CONFLICT`/`INELIGIBLE` is distinct from confirmed rollback. Successful
claims and business rejections retain their request and audit. Claim audit outcomes
are SUCCESS/REJECTED, not CONFLICT/INELIGIBLE. Losing attempts have no invented lease.

A confirmed failure requires HTTP 200 with `outcome=ERROR`, boolean
`rollback_confirmed=true`, NULL claim, `replayed=false`, a valid failure UUID and
one of the migration's two failure reasons. Verify the actual ledger row and its
five-column deduplication key: actor, request, listing, operation, reason. Sequential
and concurrent failed retries reuse the receipt. Changed actor/listing request reuse
returns a durable ERROR receipt while original business rows and audits stay intact.

Every normal race requires one winner, N-1 conflicts, one claim/360-minute lease/task,
claimed donation/listing, N claim-attempt audits and one donation transition audit.
Check actor, claim, lease, request, correlation, reason, software/config version and
shared transaction ID. Unexpected ERROR receipts are verified and then stop the
normal race; they are never counted as business conflicts.

Two-actor acceptance additionally checks own/foreign failure retrieval, historical
replay, nonholder/released-holder denial and normal cancellation with exactly linked
release audits. It preserves failure records in stable replay snapshots. Ten-actor
execution retains committed claims. No audit/business-history deletion is permitted.

HTTP errors, timeouts, invalid JSON and network failures are not confirmed rollback
receipts. Stop and retain the original request UUID for read-only reconciliation.
Discarding a received HTTP-200 body is labelled discarded-response testing, not proof
of an unknown commit outcome. Lock visibility failures remain INCONCLUSIVE.

## Fault hooks and recovery

The fault runner never installs hooks. A later separate review must approve
`claim_write_failpoints_dev.sql`, its request-scoped helper and seven target triggers.
Capture `fault_hooks` as the ordered rows returned by `verify_hooks`: name, relation,
helper signature, enabled state, trigger definition and normalized helper-body MD5.
Pin them in the private manifest; review the exact source and trigger conditions.
The health fingerprint must include this approved test support installation.

Each fault verifies no partial business or audit writes, exactly one durable failure,
sequential plus concurrent receipt deduplication, and own/foreign retrieval. Only after
all checks pass is that exact test registration removed. After seven faults, the final
request is retried without its fault: it must succeed, preserve the failure and replay
without duplicates. This intentionally consumes the dedicated fault listing.

On uncertainty or assertion failure the registration is retained, journaled and never
cleared automatically. Do not blindly rerun or execute broad cleanup. The separate
cleanup script is operator-only after inspection; this task does not install or run it
in DEV. Failure-ledger-unavailability and cancellation fault cases stay local initially.

Live recovery remains disabled. No recovery RPC, cron activation or timestamp rewrite
is exposed by these runners. Any future expiry experiment needs a fresh normally
created claim, natural 360-minute expiry and a separate target-isolation/safety review.
`recover_expired_claims(1)` does not identify a particular claim.

## Evidence and local validation

Private JSONL journals record request UUIDs before calls, UTC times, HTTP and business
outcomes, receipt IDs, monotonic elapsed milliseconds, fixture/source baselines and
lock observations. Keep tokens, URLs with credentials, addresses and raw exception
messages out of exports. Preserve failed/interrupted journals and scoped audit history.

Local validation commands (no Supabase connection):

```powershell
& '.venv-dev-fixtures/Scripts/python.exe' -B -m unittest discover -s supabase/tests -p 'claim_*offline_test.py'
& '.venv-dev-fixtures/Scripts/python.exe' -B supabase/tests/claim_two_actor_isolated_test.py --run-isolated --pg-bin 'C:/Program Files/PostgreSQL/17/bin'
& '.venv-dev-fixtures/Scripts/python.exe' -B supabase/tests/claim_audit_isolated_test.py --run-isolated
```

Disposable-local schemas use explicit Auth/road/cron/HTTP doubles and local fixture
DML. They validate coordination and receipt behavior, not real DEV eligibility,
PostgREST delivery or operational account readiness. Existing historical benchmark
and Stage 3I evidence must not be relabelled as current live acceptance.
