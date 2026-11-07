# Reconciliation compatibility proposal — NOT approved for deployment

No SQL writes, database connections, graph freezing or worker activation were
performed to prepare this package. Existing migrations and their manifest are
unchanged. The new proposal has its own manifest.

## Files and intended future order

* `003_reconciliation_compatibility_proposal.sql`: standalone extension requiring
  the original 003 already installed. Do not use before its prerequisite exists.
* `003_with_reconciliation_proposal.sql`: original 003 plus the extension inside
  **one** BEGIN/COMMIT. This is the proposed first-installation checkpoint because
  003 is not deployed. It avoids committing a guard that breaks reconciliation.
* These are ALTERNATIVES, not two migrations to execute in sequence. They are
  guarded first installations, not repeat-installable upgrades.
* `compatibility_prefix.sql` is a build template, not a standalone migration.
* `build_proposal.py` regenerates only these new review artifacts from repository
  sources. It never imports a database client or edits existing migrations.

## Change and authority

The original reconciliation function is rebased with three narrow hook locations:
scope locking plus cached-response replay, permit minting immediately before the
validated COLLECTED update, and route-item finalization after RESOLVED_COLLECTED.
Every original participant/evidence/idempotency/manual-review/audit branch remains
verbatim. Public signature, SECURITY DEFINER/search_path and existing ACL remain.
The replay addition returns only a stored response matching claim, request,
authenticated actor and answer, after participant authorization and locking. It
does not issue another permit or audit. A first participant's stored waiting
response remains its historical response; a fresh request after closure is not a
new collection authorization.

Four private helpers have EXECUTE revoked from PUBLIC, anon, authenticated,
service_role and all three worker scopes. The only input is a claim UUID. NGO,
task, route, participants, case and transaction ID are derived from locked rows.
Existing private table write restrictions are preflight requirements.

The permit independently requires the reconciliation state and the two distinct
authorized parties' positive evidence. It runs only in the original successful
handover branch after mixed-batch/custody validation. It stamps the existing
`items.complete_xid=pg_current_xact_id()` (or the cutover legacy permit for a
captured unmanaged dispatched task). The original routing authority trigger is
**not changed, disabled or replaced**. No GUC, client flag or role-only exemption
can authorize collection. A missing/drifted managed binding fails closed.

After the original task, claim, lease and case updates succeed, route-item
`collected_at` is set atomically with COALESCE. A later exception rolls everything
back, including the evidence/permit/bookkeeping. Already collected states retain
their timestamp; an unchanged task status needs no new transition exemption.

Expired leases remain invalid for dispatch and normal completion. Reconciliation
may acknowledge physically completed handover under the existing two-party rules;
this does not renew the lease or grant dispatch. No vehicle, assignment, route
status, binding closed_at or item released_at is changed by the bridge. The NGO
must still explicitly confirm depot return through protected route closure.

## Locks and unresolved cases

The outer prefix matches routing: NGO profile share lock, derived NGO advisory
lock; managed routes then lock all claims, leases, listings, source donations /
inventory / hubs, vehicle, route, tasks and binding in the existing order. This
occurs BEFORE the legacy reconciliation claim/lease/listing/task prefix. Donor
and hub-admin callers do not call the NGO-only actor_lock with a forged NGO ID.
They pass explicit participant authorization while locking the derived owner scope.
Recovery/cancel_claim retain their claim-first prefix and serialize on those rows.
The proposal does not change recovery, cancellation or reconciliation release
rules. A PLANNED task, disputed evidence, no-handover-after-start or inconsistent
route still requires manual review. It intentionally does not invent a way to
release a disputed vehicle hold.

## Evidence and tests

Repository source pins are in `proposal-manifest.json`; user confirmation of
function behavior is not a byte-for-byte catalog capture. Actual DEV hashes,
owners, ACLs, public evidence-table RLS and current 001/002/003 state must match
the reviewed expectations before deployment approval. Latest recovery baseline
is the 20261030 function; the proposal only verifies it, never replaces it.

Run-safe checks (no SQL or network):

```powershell
.venv-stage8/Scripts/python.exe supabase/tests/stage8_reconciliation_proposal_static_test.py
```

Prepared, NOT executed: 17 isolated PostgreSQL tests cover managed/hub and legacy
success, conflicting/mixed evidence, unauthorized actors/helper access, expiry,
reserved tasks, idempotency, transaction binding and concurrent evidence,
duplicate requests, recovery, normal completion, cancellation and depot closure.
They use a new loopback cluster, reduced schema, synthetic auth and roads, with
the actual proposal and latest repository recovery/reconciliation sources. They
do NOT establish actual Supabase JWT/RLS behavior or full-schema compatibility.
They require initdb/pg_ctl/psql on PATH, the existing Stage 8 Python dependencies
and explicit approval for even local SQL writes. Do NOT run yet:

```powershell
.venv-stage8/Scripts/python.exe supabase/tests/stage8_reconciliation_compatibility_isolated_test.py --run-isolated
```

Without that explicit entry-point flag, database setup is skipped. The prepared
database suite has been Python syntax-checked only; SQL compilation and race
outcomes are unverified until approved isolated execution.

Windows harness transport: the reconciliation runner now writes owned temporary
UTF-8 SQL files and invokes psql with `-f`; no SQL payload reaches the process
command line, including concurrent requests. Files close before psql opens them
and are removed after success, errors or timeouts. Explicit transaction scripts
are preserved; unwrapped multi-statement batches use `--single-transaction` to
retain the old `-c` batch atomicity. Standalone database creation/deletion stays
outside an explicit transaction. Connection guards also require an owned input
file and reject reconnect meta-commands. Transport-only regression checks run no
database processes:

```powershell
.venv-stage8/Scripts/python.exe supabase/tests/stage8_psql_sqlfile_static_test.py
```

## Verification and rollback checkpoint

1. Run `verification_readonly.sql` and the parent `review/003_compatibility_readonly.sql`
   manually in DEV; export definitions, security, triggers, counts and anomalies.
2. Resolve every source/security mismatch, unexpected existing helper and evidence
   forgery possibility. Never relax the fingerprint guard merely to deploy.
3. Approve and run isolated tests; review failures before updating any SQL.
4. Capture a fresh recovery point and hold routing/pickup writers for the reviewed
   atomic installation checkpoint. No deployment is authorized by this document.
5. Postflight: helper EXECUTE false for clients/workers, original authority trigger
   hash/enabled state unchanged, recovery unchanged, expected revised public RPC
   hash/settings/ACL, and unchanged data counts. No authenticated test writes
   without their own approval. SQL catalog checks cannot prove race safety.
   The allowed definition changes are the already reviewed 003 scope plus this
   public reconciliation revision and four private helpers. Compare protected
   fingerprints using that explicit allowlist; do not claim that all historical
   712 fingerprints remain unchanged after an intentional lifecycle-RPC change.
6. A pre-COMMIT failure rolls back the whole combined package. After commit, use a
   reviewed forward fix or state-aware rollback. Do not remove the trigger,
   erase active permits/holds or restore an incompatible RPC while work exists.
