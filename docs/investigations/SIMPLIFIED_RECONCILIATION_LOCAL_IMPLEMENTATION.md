# Simplified reconciliation and route lifecycle — local implementation

Date: 2026-11-04 (MYT). Implements the approved [design](STARTED_PICKUP_RECONCILIATION_ROUTE_LIFECYCLE_DESIGN.md). **Local implementation and validation only. Nothing was deployed. No DEV/production queries or writes, real-record resolution, routing-worker activation, formal E2/E4 experiment or GitHub push occurred in this implementation task.**

Food Can was not modified. Its prior investigation remains a historical snapshot; the new explicit action must revalidate current records after a separately approved deployment.

## Changed files

| File | Change |
|---|---|
| `supabase/migrations/20261104130000_unstarted_released_route_cancellation.sql` | Revised the single undeployed canonical migration into the complete protected reconciliation/lifecycle package |
| `frontend/geolock_hub_app/lib/routing/claim_coordination.dart` | New shared donor/NGO/hub participant panel, protected repository, durable request recovery and vehicle checkpoint UI |
| `frontend/geolock_hub_app/lib/donation_pages.dart` | Wired live donor details, NGO claim details and the reconciliation inbox to the new participant workflow; retained injected legacy test/history paths |
| `frontend/geolock_hub_app/lib/routing/ngo_routes_page.dart` | Checkpoint-before-continuation action; accurate started/no-collection closure confirmation and terminal wording; no extra resume checkpoint when final closure is ready |
| `frontend/geolock_hub_app/lib/routing/ngo_routing_repository.dart` | Restricted checkpoint transport; NO_COLLECTION/MIXED_OUTCOME use resolved closure, including saved-request recovery |
| `frontend/geolock_hub_app/lib/routing/route_card_view.dart` | Started NO_COLLECTION readiness/terminal wording separated from unstarted cancellation and collection |
| `supabase/tests/simplified_reconciliation_isolated_test.py` | New 22-case disposable PostgreSQL behavioral/security/concurrency suite |
| `supabase/tests/unstarted_released_route_isolated_test.py` | Updated 15 existing regressions for mixed unstarted cancellation, immutable evidence and explicit ordinary-cancellation outcome |
| `supabase/tests/unstarted_released_route_contract_test.py` | Six source-contract checks for the consolidated package |
| `frontend/geolock_hub_app/test/claim_coordination_test.dart` | New participant, receipt, account-change, joint-review, checkpoint and no-collection closure regressions |

Existing unrelated working-tree changes were preserved. No baseline migration, donor status mapper, dashboard source, legacy route-resolution migration or worker configuration was rewritten. The earlier investigation/implementation documents describe their earlier snapshots; this document supersedes their local implementation assessment.

## Implemented decisions

| Current effective evidence | Protected result |
|---|---|
| One authorized statement | AWAITING_COUNTERPART; no goods/claim release or collection |
| Two authorized false statements, all custody checks pass | RESOLVED_RELEASED; claim/lease RELEASED; task STALE; stop RESOLVED_UNCOLLECTED; direct goods AVAILABLE or hub goods/inventory BATCHED |
| Two authorized true statements, compatible custody/source state | RESOLVED_COLLECTED; claim/lease COMPLETED; task/goods COLLECTED; existing collection permit and finish helpers retained |
| Opposing statements | MANUAL_REVIEW/PARTY_EVIDENCE_CONFLICT, displayed as disagreement; no terminal custody transition |
| Matching statements with collection records, missing associations, source conflicts or unresolved incident/route hold | Remain protected with an explicit blocker |

The new release path requires actual NGO/source participants, complete locked source records, expired lease for no-handover release, consistent claim/lease/task/route authority and no contradictory collection evidence. It does not treat expiry or a route-start click as proof of handover. It retains route started_at, item consumed_at/dispatch_xid, original manifest and all statements. A started release receives RECONCILED_STARTED_NO_HANDOVER rather than pretending the task never started.

The existing task-and-transaction release permit authorizes the otherwise forbidden PICKUP_IN_PROGRESS → AVAILABLE/BATCHED donation transition. The task guard now requires a validated deferred-release permit or the existing legacy resolution permit for reserved-task release, rather than relying solely on a reconciliation status label. Existing participant collection hooks remain in place and validate only the active evidence round. No caller supplies a transaction ID, route membership or private permit.

Custody resolution is separate from listing discovery. Expired listing or source availability windows produce an AVAILABLE direct donation/BATCHED hub goods with a CLOSED listing. The deferred commit invariant was narrowly extended for this exact, fully evidenced released state; it still rejects active claims and inconsistent source/batch state. No expired listing is advertised as available for a new claim. Nonexpired reopening retains the existing protected donation-transition and eligibility refresh behavior.

## RPC and evidence contracts

New public entry points, authenticated only:

- `get_my_claim_coordination(p_claim uuid)` — observational participant state, actions, round/version, blockers and complete statement history.
- `get_my_donation_coordination(p_donation uuid)` — observational donor-owned direct-donation case contexts.
- `submit_claim_reconciliation_v2(p_claim uuid, p_handover_confirmed boolean, p_expected_round integer, p_expected_version bigint, p_request uuid)`.
- `resolve_my_claim_reconciliation(p_claim uuid, p_request uuid)` — explicit idempotent evaluation of already-submitted evidence, including an eligible Food Can-shaped MANUAL_REVIEW case.
- `review_my_claim_reconciliation(p_claim uuid, p_action text, p_expected_version bigint, p_request uuid)` — REQUEST, ACCEPT or DECLINE by authorized participants; acceptance must come from the counterpart.
- `get_my_coordination_receipt(p_request uuid)` — actor-scoped serialized receipt lookup.
- `confirm_my_route_depot_checkpoint(p_route uuid, p_confirmed boolean, p_request uuid)` — NGO-owned, truthful vehicle-at-registered-depot assertion; not route closure or goods return.

The original three-argument submit_claim_reconciliation remains a round-one compatibility adapter. It returns original evidence responses for old request IDs; it cannot submit to a later correction round. New RPCs reuse the existing protected resolution receipt table with distinct operation names; no new business table or administrator role was added. Request-ID reuse with a different operation/payload is rejected. A new resolve request after terminal resolution returns the authoritative terminal result without repeating custody effects.

Joint review adds round/version and pending-review metadata to the existing cases, and evidence_round to the existing evidence rows. Uniqueness becomes (case, actor, round), while request IDs remain globally unique for evidence. A trigger prohibits changing/deleting statement identity, value, round or timestamp; response may be filled once but not rewritten. Original receipts and historical rounds stay intact.

Review acceptance checks the expected version and source-context fingerprint. Only after mutual acceptance does a new round open; both participants must respond anew. Superseded testimony remains visible and audited. Actual collection events, source conflicts and incidents cannot be superseded by statements. If the source context changes after a round was accepted, submissions are blocked and a further mutual review can restart the round only with the same validated participants. No old/new-round evidence is combined.

Existing actionable claim/inbox/donor reader projections use a private current-round evidence view. Receipt/history reads remain unfiltered. Private helpers/view have no client execution/table privileges; public APIs keep explicit participant/owner checks and pinned search paths.

## Route and vehicle results

| State and final manifest | Result |
|---|---|
| Never started; every member safely released | Explicit CANCELLED + cancellation outcome NO_COLLECTION; binding closed; no depot assertion |
| Never started; safe released members plus unchanged valid planned members | Explicit cancellation allowed; released STALE tasks preserved, only still-valid planned tasks return to CONFIRMED; manifest archived through existing cancellation history where active associations are removed |
| Started; all collected | Existing depot-confirmed COMPLETED closure |
| Started; all safely released | Depot-confirmed ABANDONED + NO_COLLECTION |
| Started; collected plus safely released | Depot-confirmed ABANDONED + MIXED_OUTCOME |
| Remaining valid work | Keep open and subject to protected next-stop feasibility; no automatic cancellation |
| Unresolved custody/evidence | Terminal closure blocked by both read eligibility and direct mutation checks |

Reader flags and locked cancellation/closure use shared full-manifest classification, with explicit missing-record rejection. Historical cancellation no longer depends on today's listing/goods remaining AVAILABLE: a legitimate later re-claim does not invalidate the original safely released claim. Its newer claim/task remains untouched. Ordinary plan cancellation has an explicit UNSTARTED_PLAN_CANCELLED outcome, so Flutter does not describe it as the special all-released outcome.

The route reader retains legacy closure_outcome hints while adding closure_kind and separate collected/resolved-uncollected counts. Existing closure signatures and durable receipt replay are preserved. NO_COLLECTION closure records vehicle depot return/accountability, not goods return. It does not call the route CANCELLED or erase a start. Final outcome records are read from the protected closure receipt after terminal closure.

After a dispatched no-handover release, further pickup starts are blocked until a valid depot checkpoint establishes origin, unless a later collected stop already establishes the existing route origin. The checkpoint records the registered depot, current vehicle version and server time in the audit trail. Remaining feasibility uses that depot when the checkpoint is newer than the last collection; original route start/duration/horizon limits remain intact. Replaying a checkpoint request does not create a newer checkpoint, and a later release or depot/vehicle-version change can invalidate an older one. The booking remains held. A route ready for final closure needs the closure confirmation, not an additional resume checkpoint.

## Flutter behavior

Live donor details and NGO/hub participant flows show Awaiting Counterpart, disagreement/joint-review actions, exact custody blockers and resolved outcomes. Older injected repository/history test paths remain available without replacing unrelated historical-claim work. Resolve Matching Statements is explicit; opening or refreshing a panel only reads.

Actions reread protected state/version after confirmation. Saved requests are scoped to actor and claim/route, preserve exact parameters and request UUID, reject operation/payload replacement, and use serialized protected receipts before explicit retries. Only known coordination operations can be recovered from preferences. A committed request cannot be discarded as uncommitted; owner changes block sending and retain the original owner's pending request. Stale, uncommitted requests require explicit discard after a protected NOT_FOUND check; there is no silent replacement request. Concurrent local taps are serialized.

Confirmed actions refresh donation/claim/route detail; existing Home/My Donations refresh on return from detail. Existing route freshness, execution holds and mixed-closure request handling remain. No direct database table write or service key was added to Flutter.

## Executed validation

| Check | Final result |
|---|---|
| `flutter analyze --no-pub` | PASS — no issues, 5.3 seconds |
| Focused Flutter route/donor/coordination suite | PASS — 125 tests |
| `simplified_reconciliation_isolated_test.py --run-isolated` | PASS — 22 tests, 239.791 seconds, zero DEV connections |
| `unstarted_released_route_isolated_test.py --run-isolated` | PASS — 15 tests, 204.486 seconds, zero DEV connections |
| `unstarted_released_route_contract_test.py` | PASS — 6 tests |
| Existing `claim_scoped_reconciliation_static_test.py` | PASS — 5 tests |
| `git diff --check` | PASS |

PostgreSQL evidence: [coordination result](../../results/automatic-routing-local/20261104T140214Z-9cf850/coordination-result.json), [coordination cluster stop](../../results/automatic-routing-local/20261104T140214Z-9cf850/cluster-stop.json), [cancellation result](../../results/automatic-routing-local/20261104T140214Z-527d4d/safe-cancellation-result.json), [cancellation cluster stop](../../results/automatic-routing-local/20261104T140214Z-527d4d/cluster-stop.json). Both fresh loopback clusters stopped successfully with zero remote connections. Their directories contain exact SQL inputs, function preservation manifests and race evidence. Local adapters simulate Auth/Storage/cron; this is not hosted Supabase or live-device parity.

Logs: `.tmp/coordination-pg-final.log`, `.tmp/coordination-cancel-final.log`, `.tmp/coordination-flutter-final.log`, `.tmp/coordination-analyze.log`.

Exact Flutter test selection:

```text
flutter test --no-pub test/claim_coordination_test.dart test/unstarted_released_route_test.dart test/route_cards_test.dart test/route_details_presentation_test.dart test/route_execution_test.dart test/route_execution_widget_test.dart test/route_resolution_test.dart test/donor_status_refresh_test.dart test/donor_route_resolution_test.dart --reporter expanded
```

Both PostgreSQL commands used `.venv-stage8/Scripts/python.exe` and `--runtime .tmp/geolock-spatial-runtime-safe-cancel`. The runtime is private PostgreSQL 17.11/PostGIS 3.6.2/pgRouting 4.0.1, initialized fresh; it never accepts a remote DSN or existing service data directory. Existing synthetic fixture planning/validator helpers are used only within these isolated tests, not activated DEV workers or formal experiments.

Coverage includes direct/hub agreement both ways; existing matching MANUAL_REVIEW evidence; disagreement and accepted/declined/stale review; immutable history and old receipts; context changes/restart; ownership and private permissions; request conflicts/retries; source reclaims and expired listing/source windows; collection audit and incident blockers; missing leases; route cancellation/closure outcomes; checkpoint origin/version behavior; and concurrent resolution, checkpoint/dispatch, closure/start, expiry/cancellation and duplicate cancellation requests.

Diagnostic runs are not counted as passes: they exposed an expired-listing commit invariant, an outdated ordinary-cancellation test expectation, and a rejected mid-run input edit. Those issues were corrected before the final frozen runs above. Earlier PASS evidence for the previous smaller cancellation migration does not establish this revision.

## Canonical migration and compatibility risks

Only one cancellation/coordination migration exists in `supabase/migrations`: `20261104130000_unstarted_released_route_cancellation.sql`. The previous short-name duplicate does not exist. The canonical file was revised locally, not followed by a competing patch migration.

Tested canonical SHA256: `d80877ef1a0fc2a570ee87f5df0a664dba1ee580a30814614a0e9e9964663ab1`.

- Deployment history must be checked before treating this version as undeployed. If it has been applied in any target, do not replace its published history; prepare a new reviewed forward migration against that actual baseline.
- Source fingerprints and patch anchors deliberately abort on contract drift. This revision assumes the protected Stage A authority/reconciliation baseline through claim-scoped reconciliation, existing C1 fleet guards, and the existing private receipt tables. It preserves the independent released-history reader migration and does not deploy it implicitly.
- New columns, immutable evidence and round-aware readers require a coordinated backend/client rollout. Old clients can submit/replay round-one evidence but cannot safely participate in later rounds or use the new explicit resolve/checkpoint actions. Restrict later-round use to upgraded clients. No ambiguous RPC overload was introduced.
- Explicit vehicle assertions are accountable NGO statements, not independent GPS proof. Incorrect assertions cannot be detected from these records alone. Checkpoint/duration safeguards intentionally do not extend leases or reset route-start clocks.
- Genuine unresolved incidents, participant/source drift, missing associations, partial batch handovers or absence of mutual agreement remain blocked. No administrator-free algorithm can safely force a terminal custody outcome in those cases; no timeout release or unilateral override was added.
- PostgreSQL race tests exercise bounded schedules, not a proof of every interleaving. Full hosted RLS/Auth/PostgREST/client lifecycle verification remains a deployment prerequisite.

## Exact DEV deployment prerequisites and order — future approval required

1. Obtain explicit approval for deployment. This local approval does not authorize DEV mutations or resolution of Food Can.
2. Verify the intended DEV project is `rcgyuwiidqvrgbxswhqj`. Capture the migration ledger and a recoverable schema/data backup through the approved process. Confirm the canonical version is unapplied. Do not run the entire local migrations directory indiscriminately; it contains other unrelated pending work.
3. In explicit READ ONLY inspection transactions, verify transaction_read_only=on, deployed function definitions/owners/ACLs/search paths, enabled routing_task_authority and c1_route_vehicle_guard, protected evidence/receipt/history tables, constraints and private-table grants. End ROLLBACK. Compare the migration's exact baseline fingerprints: cancel `25d5d50b727abd9cf94fd0b9c479e612`, mixed close `1de1767851ac4a68e68e3c17f8e5d421`, authorized reader `167e9843e6e026df8844f441af77fded` (MD5 of prosrc after removing carriage returns). Inspect all other patched guard/helper anchors. Source drift requires review, not removal of guards.
4. Required historical baseline order: existing donation/claim/lease lifecycle and recovery migrations; C1 fleet; Stage A authority/publication/protected pickup/automatic departure; receipt, legacy interruption compatibility and donor readers; per-stop reconciliation; claim-scoped reconciliation. These are dependencies to verify, not instructions to redeploy their review artifacts. Reconcile independent released-claim-history reader changes before this package. No new worker or scheduler is needed.
5. Against that verified baseline, apply only the reviewed canonical migration in its single transaction as a clean postgres session at READ COMMITTED. Use schema-change lock/statement timeouts and the target's normal reviewed PostgREST schema-cache refresh procedure. Do not disable guards/RLS, invoke recovery or run record repair as part of installation. Migration-ledger management must match the reviewed deployment process.
6. Deploy the matching Flutter build after the new schema/RPCs are visible. Verify new function grants are authenticated-only, private helpers/view remain inaccessible, old initial-round receipt behavior remains valid, and the former internal route reader is not directly executable by clients. Confirm new readers do not write.
7. With separate approval and disposable DEV fixtures or normal owning-participant sessions, validate participant disagreements, round acceptance/version errors, explicit existing-evidence resolution, no-collection versus mixed/collected closure, truthful depot assertions, freshness/receipt recovery and foreign access. Use local/disposable tests for destructive or concurrent negatives. Do not cancel/resolve real goods simply as a smoke test.
8. Re-read Food Can and its actual source, collection/incident, claim/lease/task/route/case evidence. If still eligible and the participants separately authorize real resolution, use Resolve Matching Statements through the protected RPC/UI. Do not UPDATE its records, replay a historical receipt expecting new effects, or infer that migration installation releases it. Its started route and vehicle hold remain until every stop is final and the NGO truthfully confirms vehicle return for closure.

Stop here for deployment review. No DEV post-deployment verification or real-record mutation has been performed.
