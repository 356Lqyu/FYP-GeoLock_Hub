# Final deployment blockers — local resolution

2026-11-04. **GO for a separately approved current-baseline backup and renewed deployment preflight. NO-GO for deployment now.** The local privacy/patch defects are fixed and focused validation passes. Current recovery, history confirmation, fresh target comparison and coordinated Flutter packaging remain gates for the later deployment decision.

This report supersedes the earlier NO-GO report's assessment of the *local candidate*, not its historical DEV observations. The earlier report/evidence and original implementation report are preserved. No redesign of reconciliation, custody or vehicle workflows was made.

## Exact source/document changes

Paths are relative to the project root `C:\Users\User\Downloads\FYP-GeoLock_Hub`.

| File | Change |
|---|---|
| `supabase/migrations/20261104130000_unstarted_released_route_cancellation.sql` | Live location gates, immutable snapshot response projection, complete source pins, anchor counts and exact reader-set checks |
| `supabase/tests/coordination_deployment_blockers_isolated_test.py` | Focused loopback PostgreSQL privacy, authorization, snapshot and transaction-rollback regressions; three affected existing collection/review/closure cases |
| `docs/stage8/stage-a/deployment-preparation/backup_pre003.ps1` | Separate `-PreSimplifiedReconciliation` mode; previous modes retain their checks |
| `docs/stage8/stage-a/deployment-preparation/backup_simplified_reconciliation.ps1` | Current-baseline inventory/guard/archive-check definitions; no connection on load |
| `docs/stage8/stage-a/deployment-preparation/simplified_reconciliation_backup_baseline.json` | Reviewable 31-function DEV baseline metadata from read-only catalog evidence |
| `docs/stage8/stage-a/deployment-preparation/backup_current_verify.py` | Accept new purpose and require all nine routing metadata sections |
| `docs/stage8/stage-a/deployment-preparation/test_backup_current.py` | New-purpose archive verification regression |
| `docs/stage8/stage-a/deployment-preparation/test_simplified_backup_guards.ps1` | Offline synthetic baseline/security drift and PowerShell parsing checks |
| `docs/stage8/stage-a/deployment-preparation/SIMPLIFIED_RECONCILIATION_RECOVERY_PREPARATION.md` | Operator, exact future capture commands, verification gates and isolated restore procedure |
| `docs/stage8/stage-a/deployment-preparation/simplified_reconciliation_deployment_receipt.template.json` | Proposed manual receipt, explicitly NOT a deployment/history record |
| `docs/investigations/SIMPLIFIED_RECONCILIATION_DEPLOYMENT_BLOCKERS_RESOLVED.md` | This report |
| `docs/investigations/SIMPLIFIED_RECONCILIATION_BLOCKER_VALIDATION_MANIFEST.json` | Final source hashes and validation evidence references |

Generated test evidence is under `results/automatic-routing-local/20261104T144537Z-ba2523/`; diagnostic runs are retained separately. Logs: `.tmp/deployment-blockers-pg.log`, `.tmp/deployment-blockers-contract.log`, `.tmp/deployment-blockers-backup-python.log`. Temporary authoring scripts were removed. No Flutter source, worker config, older migration, pending history migration or unrelated work was modified.

## Privacy fix and compatible migration order

The pending `20261104_released_claim_history_readers.sql` was reviewed. It already attempted direct-donor masking in the base route reader, but was a larger optional history package, retained historical hub coordinates and did not protect snapshot replay. The smallest compatible fix is now inside the single canonical migration, against the actual deployed source. That pending migration is **not** a prerequisite and must not be applied before or after this release without reconciliation: its base-reader replacement could overwrite the new gate, and applying it first changes pinned source. Its optional history/constituent features remain separate pending work.

The protected chain is `get_my_authorized_route` → renamed `get_my_authorized_route_pre_coordination` → `get_my_authorized_route_pre_deferral`. The base reader now gates each pickup address/latitude/longitude/road-node expression using live claim ownership, active NGO, ACTIVE claim and lease, unexpired lease, CLAIMED listing and unexpired listing window. Route authorization must also remain valid. This protects both the public wrapper and the still directly callable base reader. The renamed intermediate reader remains revoked from clients. Keys and non-location route/history fields are retained; the NGO's own depot remains visible.

`get_claimed_listing_detail` uses the same live gate. Released, expired, completed, cancelled, missing-authority and unresolved-reconciliation claims do not return claim-derived pickup locations. The gate covers direct and hub pickup projections, while valid active pickups retain their contract and location access. Independent access to a donor's own donation or a hub administrator's own hub is not derived from an expired NGO claim and remains unchanged.

A targeted catalog source/dependency review also found `begin_my_routing_snapshot` returns stored observations on retry. Those observations contain listing/task/donation coordinates and road nodes. Both its new-snapshot return and replay return now use a private response projection, retaining only observations whose current owning claim still passes the live gate and whose task remains eligible. The stored snapshot, digest, immutable audit evidence, receipts and worker inputs are unchanged. Returned metadata gains `client_projection=true`; its digest continues to identify the stored snapshot, not a recomputed client projection. Existing Flutter uses only snapshot_id from this response and the worker reads the protected stored snapshot, so no Flutter source change is required.

Other inspected claim cards/reconciliation readers do not project pickup locations. Routing overview's task-node projection remains behind the existing live admissibility check. Snapshot authorization receipts contain identifiers rather than embedded snapshot bodies. No new public endpoint/table/state/administrative role was introduced; both new private projection helpers receive the existing final private-function revokes and pinned search paths.

The existing historical baseline order is unchanged through claim-scoped reconciliation. Apply only the newly reviewed canonical file after fresh preflight; do not replay baseline migrations or mass-push the local migration directory.

## Fail-safe migration patches

The original three exact source fingerprints remain required. Twelve additional source contracts pin all other patched routines and round-aware readers, including the base route reader, snapshot API, claim detail, collection permit and lifecycle/route guards. Hashes normalize carriage returns consistently with the prior preflight. A missing or changed signature/body raises `COORDINATION_SOURCE_DRIFT` before installation effects.

Collection's two round-filter anchors now require exactly one match each. The base route privacy patch requires one match per location expression; snapshot patching requires one match for each return path. Mixed closure now checks 1 depot-confirmation anchor, 1 MIXED_OUTCOME literal, 2 final_pickup_count keys and 1 depot_return_confirmed key, in addition to its original whole-body fingerprint. Existing donation/task/remaining-route/collected-close/deferred-commit checks remain.

The expected round-reader set is exactly the three known signatures, with no unexpected overloads. Each body is pinned. Donation reconciliation must have exactly two evidence-table references; claim cards/inbox each have exactly zero direct references because their pinned bodies delegate. They are no longer rewritten opportunistically by name. A source or count mismatch raises an exception. The complete migration remains one BEGIN/COMMIT transaction, so even a late reader-patch exception rolls back prior column, function, ACL and rename changes. Authorization, immutable evidence, custody permits, depot accountability and checkpoint guards remain in place.

## Version history and proposed recording

Local searches of docs/results, deployment/execution/receipt filenames and Git history found no DEV publication receipt for version `20261104130000`. Matching applied.json files are explicitly NON-PARITY disposable-loopback test receipts, not DEV history. Earlier design/implementation records explicitly describe the canonical file as undeployed. The prior DEV catalog shows no coordination package and no `supabase_migrations.schema_migrations` relation.

Conclusion: no evidence of prior DEV publication was found in the available records; historical non-publication cannot be proven solely from an absent ledger. The deployment operator must confirm any external/manual history before deployment. No DEV ledger was created or repaired. If an external publication record is found, preserve that published hash/history and prepare a newly versioned reviewed forward migration; do not deploy this rewritten version under its old number.

The minimal compatible approach is an append-only manual deployment receipt using the supplied template, stored with the existing manual release records. Before execution record target/version/approved file hash, operator/approval, history review, backup/restore and preflight references. After execution record exact UTC interval, command/log hash, exit status and catalog/grant verification. Mark COMMITTED_VERIFIED only after postflight; a disconnect is UNKNOWN until inspected. Retain failed/reverted/unknown attempts rather than overwriting them. This is a proposal only. A future Supabase ledger adoption should import reviewed receipts through its own approved process, not guess historic versions during this installation.

## Recovery preparation

The separate recovery preparation document contains the exact `-PreSimplifiedReconciliation` capture/ValidateOnly/offline verification commands and a reviewed isolated restore sequence. The runner uses a fresh private Git-ignored directory, existing export service/native hidden prompts and a full unfiltered database archive plus roles/memberships without passwords. New baseline checks cover current fingerprints/owners/definer modes/ACLs, task/fleet triggers and the observed absence of the package/ledger, without relying on obsolete historical business-route statuses.

The existing October execution record identifies the project owner/user as self-declared recovery and deployment operator. Record current identity/approval again for this capture; do not infer independent delegation or reuse an old waiver. A successful logical export still does not establish restorability. A compatible isolated PostgreSQL 17.11/PostGIS 3.3.7/pgRouting 3.4.1/Supabase restore, role/ACL/trigger/data comparisons and external-service recovery coverage remain required before a deployment GO. The synthetic runtime has newer spatial extensions and is not restore parity. No capture, ValidateOnly runner invocation, restore or worker pause was executed here; only definition-level offline tests ran.

## Focused validation

| Check | Final result |
|---|---|
| `coordination_deployment_blockers_isolated_test.py --run-isolated --runtime .tmp/geolock-spatial-runtime-safe-cancel` | PASS: 9 selected cases, 126.744 seconds, zero DEV connections |
| `unstarted_released_route_contract_test.py` | PASS: 6 source-contract checks |
| `test_backup_current.py` | PASS: 16 offline Python tests |
| `test_simplified_backup_guards.ps1` | PASS: positive 31-function baseline, 14 synthetic negative checks, PowerShell parsing; no connection/capture/restore |
| `git diff --check` and explicit changed-text whitespace check | PASS |

PostgreSQL cases exercise the complete route reader chain, valid active locations alongside released locations, actual elapsed lease expiry, foreign/unauthenticated denial, private-helper/intermediate-reader grants, historical hub masking, immutable snapshot replay storage, four changed source definitions, unexpected reader overloads, late full-transaction rollback, current-round collection, mutual review/old receipts and collected closure. Existing unrelated tests were not broadened. The 125 Flutter/37 PostgreSQL suites were not repeated; only the three relevant existing collection/review/closure cases were selected from the prior suite. No Flutter code changed and no new binary was built.

Evidence: `results/automatic-routing-local/20261104T144537Z-ba2523/deployment-blockers-result.json`, `applied.json`, `input-integrity-final.json`, SQL traces and `cluster-stop.json`. Final cluster is stopped with remote_connections=0. Earlier diagnostic runs encountered Windows restricted-token startup and two SQL guard-placement/syntax issues; they are not counted as passes. Both diagnostic clusters that started were stopped with zero remote connections. The final passing run applied the exact hash below.

## Final artifact and remaining gates

Canonical SHA256:

`7e77ede1b832d619dd3e3b9848e0501d5725bf57b1ad270c8b4c6e001d7430f1`

This replaces the previous locally tested `d80877ef...` candidate. Older reports remain historical evidence, not validation of the new hash. Use the updated hash/manifest for the next approved preflight.

Remaining before deployment:

1. Approve and run the current-baseline capture with the named operator and reviewed recovery/control disposition; obtain verified recovery evidence, including restore/external coverage or an explicitly reviewed provider recovery exercise.
2. Confirm external/manual non-publication of this version and approve the manual receipt process; choose a new forward version if previously published.
3. Repeat read-only target source/signature/ACL/trigger/privacy/caller checks against this revised file immediately before approved installation. Do not remove guards to accommodate drift.
4. Produce and identify the matching Flutter DEV artifact; the old APK remains stale. Coordinate schema visibility and upgraded clients before later review rounds/checkpoint-dependent workflows.
5. Obtain explicit approval for deployment of that exact hash and rollout scope. Backup approval is not deployment approval. Real-record/Food Can resolution remains separate.

No DEV/production writes, deployment, ledger repair, Food Can resolution, worker activation, backup/restore or GitHub push occurred. Stop after this local implementation/report.
