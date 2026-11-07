# Route resolution — dependency-ordered LOCAL plan and acceptance checklist

Version 1 checklist with LOCAL implementation review, 29 October 2026.
D01-D10 and narrow custody edges were approved for LOCAL source/tests only.
Current results are in ROUTE_RESOLUTION_RELEASE_GATE.md and the 58-row mapping in
results/route-resolution-local-review/20261029-d02-corrected/acceptance-evidence.json.
D02 is corrected and verified: 57 scoped checks PASS, 1 remains BLOCKED for the
unapproved DEV fixture/discovery-isolation manifest. No DEV approval.

## Authorized scope if separately approved

LOCAL ONLY: forward SQL source preparation, protected API/Flutter source changes,
contract/FYP/API draft documentation, unit/widget tests and isolated PostgreSQL 17
roles/auth identities/fixtures for genuine transaction/security/concurrency tests.
No real Supabase accounts are needed for disposable testing.

Explicitly excluded: connection to DEV, migration/grants or identity/fixture creation
in Supabase, existing-service restarts, writer/scheduler activation or pause, pilot
generation/pickup/reconciliation writes, APK build/install, changes to the frozen
graph or any routing algorithm/objective. Do not reuse live record IDs as fixture
action targets. No completion or release of the preserved route is in local scope.

The existing independent-pilot manifest is unchanged. It is still unbound and
unapproved; null account/category/photo/address fields do not authorize guessing.

## Dependency-ordered work packages

### L0 — Approvals and baseline inventory

Depends on: approval of D01-D10 and this local scope.

- Review Git working tree and instructions; preserve prior work and route evidence.
- Pin available deployed-baseline captures and reviewed migration hashes locally.
  Inspect route TEXT/CHECK, existing constraints, guards, signatures, ACLs, audit
  helpers and source snapshots. Distinguish captured state from fresh DEV proof.
- Map every route terminal-state consumer, receipt caller and recovery interaction.
- Draft exact authority-contract amendments; mark clause/supervisor review status.
- Resolve any baseline/design contradiction before writing migration bodies.

Exit: approved transition/permission/evidence matrix and a complete scoped change
list. An unexpected need to weaken authorization or change recovery is a STOP.

### L1 — Data/permission model and migration skeleton

Depends on: L0.

- Prepare one new forward migration package; choose final filename/version during
  implementation after checking existing files. Never edit/replay historical SQL.
- Define case/item/evidence/request/release-history/provenance records and their
  FK, uniqueness, exact task-manifest and versioning invariants.
- Extend the captured route-status CHECK for ABANDONED, preserving column type.
- Define restricted resolver and participant permissions for disposable roles;
  no real operator login/password creation or production grants.
- Define synthetic registry enrollment, audit-derived labels and access checks.
- Pin expected old definitions in guards; review SECURITY DEFINER search paths,
  ownership, SQL name qualification and narrow grants before function exposure.
- Arrange migration transaction boundaries so no executable RPC is exposed before
  every required guard/table exists. No partially deployed usable feature.

Exit: schema/ACL invariants and initial disposable migration/replay/rollback tests.

### L2 — Shared locking, authority, receipts and evidence versions

Depends on: L1.

- Implement shared NGO/source/vehicle/route/case lock order, including exact
  interaction with existing recovery and reconciliation locks.
- Add private transaction-bound settlement permits; no caller-set flag/GUC bypass.
- Implement same-actor/request/canonical-payload receipts, expected-version checks,
  authorized replay and owner/participant-scoped lock-free readers.
- Implement immutable evidence submission/supersession, derived participants,
  matching assertions and conflict/staleness outcomes.

Exit: access, genuine READ ONLY, replay and competing-evidence SQL tests pass.

### L3 — Interruption reporting and execution fence

Depends on: L2.

- Implement proposed report_my_route_interruption and case linking under locks.
- Preserve collected records; move only unresolved qualifying claim/lease statuses
  to reconciliation without touching original expiry/issue/start timestamps.
- Fence ordinary Start/Complete and stale legacy entrypoints through database
  authority; preserve the normal unaffected-route paths and original signatures.
- Report creates no release and never fabricates handover, depot return or success.
- Ensure replay reuses the same case/evidence scope and cannot duplicate cases.

Exit: report vs Start/Complete/recovery races pass; every reported route remains
held with no new ordinary pickup permission. No recovery function change without
a demonstrated defect and separate scope approval.

### L4 — Restricted finalization, audits and terminal integration

Depends on: L3.

- Validate all current case/item/participant/evidence/vehicle conditions under
  locks; reject unsupported custody and unsafe expired-listing dispositions.
- Preserve valid collected outcomes and existing guarded reconciled collections.
- Settle only approved no-handover items using private authority permits and the
  appropriate verified lifecycle transitions; never revive an old task/lease.
- Archive assignment membership, remove only this route's active assignments,
  release item/binding holds and set ABANDONED in one transaction.
- Update terminal route guards and hold checks consistently; keep historical
  stops and ensure no unsettled PLANNED/DISPATCHED stop survives finalization.
- Persist required resolution/lifecycle audits and immutable receipts atomically.
- Derive synthetic labels from registry binding; preserve normal behavior for
  unregistered real records, which cannot enter simulation via a client flag.

Exit: full SQL disposition, fault-injection, concurrency and history tests pass.

### L5 — Protected API and Flutter integration

Depends on: L4 stable SQL contracts; read-only UI work may be prototyped earlier
against synthetic test transports, but must not claim SQL integration success.

- Add Report cannot continue, evidence status/submission and resolution history.
- Keep finalization in the restricted operator surface, not ordinary NGO UI.
- Persist operation IDs across page navigation, process restart and lost replies;
  reconcile read-only before allowing another attempt; no automatic mutation.
- Opening history/cases never creates a report, submits evidence or finalizes.
- Recognize ABANDONED as terminal for history and local operation completion only
  after the authoritative receipt/read. Do not archive an unresolved case.
- Continue showing markers-only geometry and honest route outcome/metrics.
- Show server-derived synthetic labels without inventing physical verification.
- Keep new functionality disabled by default pending a future deployment gate;
  UI flags alone must not be a database authorization boundary.

Exit: Flutter analyzer/widget tests, API contract tests and local real-SQL adapter
tests pass, including account-switch and failed-read safety.

### L6 — End-to-end disposable verification and review package

Depends on: L1-L5.

- Run the acceptance matrix below and existing routing/lifecycle/recovery tests.
- Use small explicitly synthetic local graph inputs; do not reload/probe DEV's
  large frozen graph or alter its sealed cache. Preserve research algorithm tests.
- Record exact commands, database/tool versions, outcomes, fixture classes and
  current limitations. Do not label auth adapters as hosted Supabase proof.
- Review the migration/body fingerprints, final diff, rollback and postflight plan.
- Report READY/NOT READY for a separate DEV deployment review; no deployment.

Exit: reviewable local implementation and real disposable-SQL evidence. Any
failure, unsupported expiry disposition or permission drift is disclosed, not
patched with force-release, fixture resets or reduced guards.

## Original disposable PostgreSQL 17 checklist — actual results in review package

### A. Target isolation and reproducibility

- [ ] Assert loopback host, dedicated port/database, disposable-root marker and
      expected local roles before any setup/drop. Reject DEV/cloud endpoints.
- [ ] No DEV password/token/service profile used; no service calls to live APIs.
- [ ] Apply pinned baseline and new forward migration to a fresh local database;
      seed small synthetic data via the approved test harness only.
- [ ] Required extensions verified; cron is not enabled as an uncontrolled local
      daemon. Exercise the exact recovery function in controlled transactions.
- [ ] Fix/capture test clock boundary inputs in disposable rows only; never change
      server clock, bypass eligibility or reuse live route IDs as action targets.

### B. Schema, migration and effective privileges

- [ ] Fresh migration succeeds; old-client signatures/results remain compatible.
- [ ] Replay/drift guards fail cleanly without changes; failed install is atomic.
- [ ] Correct owner, search_path and effective function/table/column ACLs.
- [ ] No direct client DML/TRUNCATE or forged transaction-permit path.
- [ ] Captured TEXT/CHECK and every terminal-set consumer recognize ABANDONED.
- [ ] Ordinary closure/cancellation, explicit/automatic departure and authorization
      remain unchanged for routes outside resolution.

### C. Report/fence and classification

- [ ] Start-free reporting on wrong owner, absent/terminal route is rejected.
- [ ] Duplicate identical report returns one case/receipt/audit set.
- [ ] Started mixed route classified from server facts, not caller classifications.
- [ ] Active/expired unresolved claims enter reconciliation; issued/expires/start
      timestamps unchanged. Existing cases linked, not duplicated.
- [ ] Collected task/donation/claim/lease and their timestamps remain terminal.
- [ ] No assignment/vehicle release on report; no allowed ordinary pickup after it.
- [ ] Missing source, inconsistent task/item or mismatched manifest fails closed.

### D. Evidence and authorization

- [ ] NGO plus correct donor/hub participant can submit only their own statements.
- [ ] One party, self-counterparty, unrelated donor/NGO/admin, disabled/revoked
      access and wrong source membership cannot satisfy agreement.
- [ ] Matching no-handover requires source-possession statement for every item.
- [ ] Matching handover for a never-started item cannot create false collection.
- [ ] Existing guarded two-party collection for a dispatched item retains audits
      and does not prematurely release assignments or close the route.
- [ ] Disagreement/unknown/mixed hub custody enters review without release.
- [ ] Amendment preserves history, increments version and invalidates old readiness.
- [ ] Post-terminal disagreement creates only a linked incident; no resurrection.
- [ ] Ordinary NGO/donor/worker/anon cannot finalize; resolver cannot override
      missing evidence or supply another actor's statement.

### E. Finalization, custody and holds

- [ ] Complete valid no-handover manifest settles old task STALE, claim/lease
      RELEASED, and permits reopening only when validity/lifecycle checks pass.
- [ ] New claim after release has a new identity/deadline; old claim never revives.
- [ ] Expired/ineligible listing stays under review; no AVAILABLE shortcut.
- [ ] Mixed retained-collection/no-handover outcome preserves collected records.
- [ ] Unknown custody, no vehicle/depot assertion, vehicle/version drift or other
      unresolved item blocks terminalization and retains holds.
- [ ] ABANDONED transaction archives membership, clears exactly this route's
      assignments, closes binding/case and releases items without fake collected_at.
- [ ] No PLANNED/DISPATCHED stop remains to strand a successfully finalized hold.
- [ ] Another route's assignments/hold and vehicle active/availability flags remain
      unchanged. Fleet eligibility is recalculated, not forced true.
- [ ] Original route stops, snapshot, matrix, candidate, attestation, request and
      audit evidence remain; ABANDONED cannot transition back or count as COMPLETED.

### F. Races and failure atomicity

- [ ] Report vs Start, Complete, scheduled-equivalent recovery and reconciliation.
- [ ] Finalize vs amendment, another finalizer, recovery, vehicle edit and report.
- [ ] Two new claims after legitimate reopening: one owner wins under normal rules.
- [ ] Cross-route/NGO locks do not delete another route's evidence/holds.
- [ ] Capture lock order and bounded timeouts; detect deadlocks without retries
      that conceal an uncertain business outcome.
- [ ] Inject failure after each finalization write, audit and receipt: no partial
      release, terminal state, false success or vehicle availability escapes rollback.
- [ ] Earlier committed legitimate collection survives a failed later finalization.

### G. Idempotency, receipts and read-only behavior

- [ ] Lost response after COMMIT reconciles to one committed result on same ID.
- [ ] Same actor/request/payload replay has no second settlement/audit side effect.
- [ ] Changed payload/operation/case or wrong actor conflicts or is denied.
- [ ] NOT_FOUND during an in-flight operation never triggers a different-ID retry.
- [ ] Readers execute repeatedly inside genuine BEGIN READ ONLY / ROLLBACK with no
      locking helper, row writes or unscoped owner information leakage.
- [ ] Donor sees only its items; other donors/NGOs/workers cannot read case content.
- [ ] Revoked actor cannot exploit replay to recover data it no longer may read.

### H. Synthetic semantics and frontend regression

- [ ] Trusted registry enrollment binds project/manifest/identities/record IDs;
      unregistered or mixed real/synthetic records fail simulation scope checks.
- [ ] Client test flags/titles cannot bypass authorization, leases or custody checks.
- [ ] New simulated handover/return/resolution audits carry server-derived test-run
      and manifest labels. No retrospective audit rewrite or physical-success claim.
- [ ] Normal non-test audit behavior/signatures remain compatible.
- [ ] Fixture-visibility safeguards are specified before any future publication;
      a registry alone is not mistaken for discovery isolation.
- [ ] UI never mutates on navigation; stable IDs survive restart/duplicate taps.
- [ ] Uncertain/failed reads never enable release or archive unresolved operations.
- [ ] ABANDONED summary preserves mixed outcomes, map markers and diagnostics;
      no fabricated polyline, GPS guarantee or successful-route comparison.

## Mandatory review artifacts and exit gate

Provide full changed-file list, final forward migration filename/SHA-256, function
fingerprints and permission matrix; exact Flutter/Python/SQL commands and actual
pass/fail logs; independent custody/state/audit/hold/receipt assertions; contract
amendment draft; unresolved decisions/limitations; and DEV deployment/rollback/
reconciliation plan. Code compilation or mocks alone do not constitute SQL PASS.

Do not automatically proceed from local PASS to DEV. Future DEV review requires
fresh approved read-only access, exact baseline checks, backup/recovery controls,
writer/operator approvals and compatibility with the currently active scheduler.
Existing route resolution and the new synthetic pilot each require separate exact
operation approvals after deployment. Historical evidence cannot authorize them.

V1 intentionally excludes unsafe expired-listing withdrawal, collected-goods
return, operator overrides, attachments, GPS proximity, background auto-resolution,
new routing algorithms and graph changes. If any is required to meet the approved
contract, stop for scope amendment before coding that feature.
