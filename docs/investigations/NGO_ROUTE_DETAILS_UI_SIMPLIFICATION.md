# NGO Route Details UI simplification

5 November 2026 (Asia/Kuala_Lumpur). Implemented locally in Flutter only. No DEV access/writes, migrations, worker changes, real-record/Food Can actions, production deployment or GitHub push. Existing unrelated work was preserved.

## Requirements findings from the originals

The original files were read directly, not inferred from the implementation addendum:

- [Original FYP report](<C:/Users/User/Downloads/RSW_LimQianYu_LowSusan_FullText.docx>), SHA256 `fc0db20769d2117907173b317a19824b8784a1ba46603407cda8d79d19ad5c5b`. Read the OOXML text, relevant algorithm/UI/security sections and the embedded images for Figure 4.13. They match the source recorded in the earlier requirements review.
- [Original supervisor reply](<C:/Users/User/Downloads/第6组_Lim Qian Yu与Low Susan_GeoLock Hub.pdf>), SHA256 `7b0d2b3a86239f85cbb1f76bd03b08c295cfa9132a04bd8a600c762258c9bb61`. Read its original PDF text, especially pages 5–6 and 14–15; page numbers below are the PDF's one-based pages.

| Question | Original report | Supervisor reply | Finding |
|---|---|---|---|
| Visible Route Diagnostics panel? | §4.4.6, **User Interface Specification**, Table 4.6 lists operational information/actions; no diagnostics panel is specified. Figure 4.13 depicts confirmed tasks, plan generation and a collection-plan overview, not a technical diagnostics panel. | §XI, **Stage 8: Implement routing**, pp.14–15 requires fixed inputs, metrics and independent validation, not a diagnostics widget. | No explicit requirement in either document. |
| Visible route/snapshot/candidate UUIDs, raw road nodes or raw technical fields? | §4.4.2, **Algorithm 9: Independent Plan Validation and Pre-Dispatch Authorisation**, binds authority to NGO/plan/snapshot/claims internally; §4.4.2.2 requires immutable snapshot references. Neither makes raw identifiers mandatory in the NGO display. §4.4.6/Table 4.6 calls for owned valid tasks/pickup node and route-plan information; an internal node identifier need not be its user-facing representation. | §IV, **Stage 1**, p.6 says operations must **save** donation/NGO/transaction/lease/request IDs, timestamps, reason codes and results, and support audit retrieval. Saving/retrieving evidence is different from printing it on every route page. | Keep identifiers/evidence internally; no explicit raw-UUID or raw-node panel requirement. |
| Literal ATTESTED label in NGO UI? | §4.4.2/Algorithm 9 requires independent verification and protected live authority checks. §4.7.1/Table 4.10 says validator failure must create no dispatch authority. The literal ATTESTED does not occur in the original report text. | Stage 8, p.15 says not to treat solver output as automatically valid and requires independent validation. The literal ATTESTED does not occur in the reply text. | Successful checking and safe failure handling are required; the implementation-specific token need not be shown. |
| Map for COMPLETED/CANCELLED/ABANDONED routes? | §4.4.6/Figure 4.13 illustrates a **Collection Plan** map with stops, distance/time/weight/cost and a Confirm Plan & Start action. It is a planning/operational mockup, not an explicit terminal-history map requirement. No instruction was found to retain maps for completed/cancelled/abandoned routes. | Stage 8, pp.14–15 specifies road matrices/constraints and reporting, not maps for closed-route histories. | Active route maps can remain; hiding terminal maps does not remove an explicit requirement. |

Relevant wording: §4.4.6/Table 4.6's **Route plan** row requires “Ordered stops, load, distance, duration, cost and unassigned reasons,” followed by protected pre-dispatch authorization. Its following paragraph requires the interface to display committed backend outputs and limits donor-address disclosure by role/state. This change preserves the existing route summary/stops/actions and does not invent cost data or claim that every broader FYP requirement is now satisfied. Cost/unassigned-plan reporting and research metrics were not removed or redesigned.

Algorithm 9 separates independently recomputed route feasibility from the subsequent protected current-state transaction. §4.4.2.1/Table 4.3 explicitly assigns capacity/duration checking to both the model and independent validator and live claim/lease checks to protected enforcement. Supervisor Stage 8 p.15 requires reporting total distance/duration, routes, unserved pickups, violations, timeouts, available optimality gaps and runtime. These backend/research duties remain intact; neither document equates them with normal NGO diagnostics display. These findings are an interpretation of the inspected requirements, not a claim of new supervisor approval.

## ATTESTED trace and meaning

1. `backend/routing/worker_service/validator.py`, `Validator.validate`, rereads the candidate/snapshot/matrix through the scoped `read_routing_work_item` RPC and checks binding/age. It calls `integration/worker.py:validate_work_item`, which rebuilds inputs and calls `phase_b/validation.py:validate_plan` without trusting an optimizer success flag.
2. A valid, feasible result produces a report containing candidate/snapshot/matrix digests, input hashes and validator build. `attest_routing_candidate` in `docs/stage8/stage-a/forward-migrations/20261101_routing_authority.sql` is callable by the validator role, verifies matching digests and true valid/feasible report fields, and records `routing_private.validations`. It does not grant route authority or perform physical handover.
3. `worker_service/orchestrator.py:RoutingWorker.plan` requires the returned attestation to match the exact candidate digest, then returns `validation_status='ATTESTED'` for an advisory candidate. `plan_and_authorize` separately requires that state before requesting the existing NGO authorization RPC.
4. `20261104_routing_automatic_departure.sql:get_my_authorized_route` (later retained in the pre-deferral reader chain) projects `validation_status` using the existence of a validation row whose candidate digest matches. The later pre-deferral → pre-coordination → current wrapper chain preserves this metadata while adding lifecycle/action flags. The actual authorization transaction separately checks owner, live source/fleet/lease state, attestation, locks, schedules and route bindings.
5. Flutter `NgoRoutingRepository.detail` retrieves that JSON and checks owner/route/contract; `NgoRouteDetailPage.received` retains it while applying existing private-stop redaction. Previously Route Details interpolated validation_status into the main summary and technical panel. Those visual uses are removed. `ProposedRouteView` now translates it into a plain-language check result without exposing the token or presenting an advisory proposal as authorized.

**Interpretation:** ATTESTED is the application's recorded successful trusted-validation attestation, bound to an exact candidate. It is not an arbitrary client assertion: its intended writer is the separate validator role after independent checks. At the reader level, however, it reports the existence of that stored attestation; reading the label does not rerun validation. PostgreSQL checks the trusted report/digest contract rather than rerunning the Python solver/validator. It is therefore neither mathematical proof nor independent proof of current feasibility, current ownership, authorization or actual collection. A privileged validator remains part of the trust boundary.

Route status (AUTHORISED/IN_PROGRESS/COMPLETED/CANCELLED/ABANDONED) describes the route lifecycle. `authorization_confirmed` and protected per-stop flags represent currently confirmed authority/actions; leases, vehicle versions or custody can change after a plan was attested. ATTESTED can remain in historical evidence after closure. Hiding its text cannot disable or bypass any of these backend checks. The `authorized` predicate, fresh reads, controller state machine, RPC payloads, receipts and backend validation were not changed.

This is a source trace, not a new deployed-DEV fingerprint certification. No live Supabase inspection was necessary or performed for this UI change.

## Exact code changes

All paths below are relative to `C:\Users\User\Downloads\FYP-GeoLock_Hub`.

| Changed file | Change |
|---|---|
| `frontend/geolock_hub_app/lib/routing/ngo_routes_page.dart` | Removes the Route Diagnostics expansion and its heading helper; removes validation_status from the normal summary; uses readable lifecycle labels; constructs the map only for AUTHORISED/IN_PROGRESS; retains historical stop outcomes/text; removes raw task-ID title fallback and raw source/task-state tokens from ordinary stop text; hides irrelevant pickup/closure/checkpoint/cancel controls on terminal routes while retaining receipt-recovery information and existing handlers/eligibility checks for active routes. |
| `frontend/geolock_hub_app/lib/routing/route_display_formatters.dart` | Adds presentation-only `routeStatusLabel`, without modifying values used by authorization or routing. Unknown status displays Status unavailable. |
| `frontend/geolock_hub_app/lib/routing/proposed_route_view.dart` | Replaces the raw validation token with Route checks passed / checks not confirmed wording. The explicit advisory/not-authorized warning remains. |
| `frontend/geolock_hub_app/test/route_details_map_visibility_test.dart` | Ten new focused tests: all five requested statuses, DRAFT/missing status, and active-to-each-terminal refresh transitions. |
| `frontend/geolock_hub_app/test/route_details_presentation_test.dart` | Updates summary expectation, asserts diagnostics/ATTESTED/raw identifiers absent, and retains immutable raw input/ordered-stop/formatting/action-gate assertions. |
| `frontend/geolock_hub_app/test/proposed_route_view_test.dart` | Asserts friendly check wording and absence of ATTESTED while preserving advisory semantics. |
| `docs/investigations/NGO_ROUTE_DETAILS_UI_SIMPLIFICATION.md` | Requirements, ATTESTED trace and implementation/test report. |

No repository RPC, execution controller, coordination transport, SQL, worker or audit definition changed. There is no hidden removal of metadata: raw route/snapshot/candidate IDs, validation field and stop data remain in the protected response/repository for authorized internal investigation. Tests compare the original fixture JSON after rendering to verify that display changes do not rewrite it. Existing separate Route support and backend audit/receipt access remain available; the normal Route Details page no longer renders its technical dump.

### Map lifecycle and history

| Route status | Map widget | Text/history |
|---|---|---|
| AUTHORISED | Constructed when depot coordinates are present | Summary, ordered stops, permitted actions/blockers |
| IN_PROGRESS | Constructed when depot coordinates are present | Current/collected/unresolved outcomes and permitted actions/blockers |
| COMPLETED | Not constructed | Completed pickup history, vehicle and totals |
| CANCELLED | Not constructed | Historical stops and resolved/no-start outcomes |
| ABANDONED | Not constructed | Individual collected/resolved-uncollected outcomes and closure explanation |
| Missing/unrecognized/DRAFT | Not constructed | Existing readable information; no invented map eligibility |

This is conditional widget construction, not Offstage/Opacity/a collapsed section. A hidden route never creates `ProposedRouteMap`, its number-icon initialization or native `GoogleMap`; refreshing an active route to terminal removes/disposes that subtree. The map implementation is already marker-only: it has no Directions request, route-polyline fetch or routing-worker call. Normal protected route and claim reads remain necessary for text, privacy, outcomes and receipt recovery; they are not removed. Tests assert exact RPC calls and zero map-builder invocations for hidden routes, including fixtures that still contain coordinates.

Current private-location expiry/redaction and refresh timers are retained. Existing raw dispatch reasons continue through `routingDispatchMessage` for user-facing blockers. Start/complete/defer/close/cancel confirmations and protected checks remain unchanged; terminal presentation only suppresses actions that are no longer relevant. Reconciliation and saved receipt recovery are preserved. No new permission or unilateral custody transition was introduced.

## Validation

Executed from `frontend/geolock_hub_app`:

```text
flutter test --no-pub test/route_details_map_visibility_test.dart test/route_details_presentation_test.dart test/proposed_route_view_test.dart test/route_execution_widget_test.dart test/unstarted_released_route_test.dart test/claim_coordination_test.dart
```

**PASS: 51 tests**, covering the ten new status/transition cases plus existing formatting, address privacy at lease expiry, authority-gated completion, start/next-stop execution, uncertain receipts, reconciliation/deferral, cancellation, depot checkpoint and no-collection closure behaviors. The initial run exposed an obsolete old summary expectation; that was corrected before this passing run.

`flutter analyze --no-pub`: **PASS, no issues, 4.5 seconds**. An initial test-only missing-braces info was fixed; the ten new map cases were then rerun independently and all ten passed. These are the same ten cases included in the 51, not 61 distinct tests.

Scoped whitespace checks pass. Existing unrelated repository-wide whitespace findings were left untouched. Logs:

- `.tmp/route-details-simplification-tests.log` — final 51-case run.
- `.tmp/route-details-map-final.log` — ten map cases after the test lint correction.
- `.tmp/route-details-simplification-analyze.log` — final clean analysis.

Tests use injected offline map builders and synthetic RPC responses; no real Google Maps tiles, phone, routing worker or database is contacted. The widget-absence and builder-count checks verify construction/teardown behavior without claiming a new native-device acceptance run. No APK was built or installed; the visible change requires a later Flutter build/run under the user's normal process.
