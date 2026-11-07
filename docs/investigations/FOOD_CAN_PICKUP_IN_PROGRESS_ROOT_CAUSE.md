# Food Can — pickup status investigation

Investigated 2026-11-04 (MYT). Investigation only; no Food Can implementation or DEV mutation.

## Finding

Food Can is **not released**. One case-insensitive, trimmed exact title match was found: donation `53448e5f-85bd-482f-8904-e1237a70769e`. Its persisted donation status is PICKUP_IN_PROGRESS. Both participants submitted no-handover statements, but the task had already been dispatched. The protected reconciliation function therefore moved the case to MANUAL_REVIEW, not RESOLVED_RELEASED. The current label reflects the database; it is not a verified stale-cache or historical-route projection defect.

## Read-only verification boundary

Before SQL, Supabase get_project_url returned `https://rcgyuwiidqvrgbxswhqj.supabase.co`, matching the configured GeoLock Hub DEV project. Each SQL call explicitly began READ ONLY, returned transaction_read_only=on and ended with ROLLBACK. The correlated record/audit inspection used REPEATABLE READ READ ONLY. Only catalog/record SELECTs ran. No user impersonation or application RPC invocation was used to inspect status. Credentials, addresses and participant identities were not retrieved into this report.

Actual deployed definitions were inspected for get_my_donation_dashboard_v2(), get_my_donation_detail(uuid), submit_claim_reconciliation(uuid,boolean,uuid), and discover_eligible_listing_cards(). The previously inspected route/start/completion/recovery and protected resolution definitions provide the related lifecycle contract.

## Verified records

All times below are UTC; add eight hours for MYT.

| Field | Persisted value |
|---|---|
| Donation ID | `53448e5f-85bd-482f-8904-e1237a70769e` |
| Donation state / path | PICKUP_IN_PROGRESS / DIRECT_PICKUP |
| Created | 2026-10-30 11:16:25.780341 |
| Updated | 2026-11-02 16:59:11.476961 |
| Listing | `737d15f7-02bc-47a0-9140-8c1b5ffa9bcf`, CLAIMED, version 6, no listing expiry |
| Current claim | `36ba7908-a7ab-42fc-839b-9e6fed5971a9`, RECONCILIATION_REQUIRED, closed_at NULL, close_reason NULL |
| Current lease | RECONCILIATION_REQUIRED, expired 2026-11-02 22:20:13.801888, release_reason NULL |
| Current task | `76c074ff-b60e-4ac3-8f5f-d522fab3af88`, DISPATCHED |
| Route | `5dff9b93-1ca2-476e-a6fb-a2f790a81d92`, IN_PROGRESS |
| Route started_at | 2026-11-02 16:59:11.468977 |
| Item consumed_at | 2026-11-02 16:59:11.466188 |
| Collection / item release / binding closure | All NULL |
| Claim reconciliation case | `3708432b-88a1-4b16-ae13-2b89da1d3cdd` |
| Case status / reason | MANUAL_REVIEW / NO_HANDOVER_CONFIRMED_AFTER_PICKUP_STARTED |
| Opened / resolved | 2026-11-02 22:21:00.219203 / NULL |
| NGO statement | handover_confirmed=false at 2026-11-03 06:02:07.251040 |
| Actual donor statement | handover_confirmed=false at 2026-11-03 06:02:39.170527 |
| Deferred-stop record | None for this dispatched item |
| Whole-route resolution case | None for this route |

Two older claims exist, both unrelated to the current pickup start: `fa7b05b4-4faf-403d-ad39-17959104a285` and `7699cecb-310c-4263-9fdd-d608931f601a`. Both were cancelled before pickup on Nov 1, with RELEASED claims/leases, NGO_CANCELLED_BEFORE_PICKUP reasons and STALE tasks; neither belongs to a route. They do not release the later Nov 2 claim and do not control the current donation status.

The audit records the current claim being accepted at Nov 2 16:20:13, the donation moving CLAIMED → PICKUP_IN_PROGRESS with PICKUP_STARTED at 16:59:11, and a successful START_PICKUP event. Recovery later moved its claim to RECONCILIATION_REQUIRED. The first no-handover statement returned SECOND_PARTY_CONFIRMATION_REQUIRED. The second returned NO_HANDOVER_AFTER_PICKUP_STARTED_REQUIRES_REVIEW. Later submissions were rejected as EVIDENCE_ALREADY_SUBMITTED; no successful release transition followed. Thus pickup start is positively recorded, while collection is not recorded. Matching no-handover statements do not erase that dispatch/accountability history.

## Exact reconciliation semantics

Deployed submit_claim_reconciliation first locks the authoritative claim scope and verifies the caller is the NGO or actual donor/hub counterpart. A new statement requires claim/lease RECONCILIATION_REQUIRED, a CLAIMED listing and an OPEN/MANUAL_REVIEW case. Requests are bound to actor, claim, case, value and request ID; a second different request from an actor who already supplied evidence is rejected.

- One statement alone returns AWAITING_COUNTERPART; it does not release the donation.
- Opposing statements produce MANUAL_REVIEW with PARTY_EVIDENCE_CONFLICT.
- Two true statements can complete collection only with compatible dispatched/collected task and donation states; conflicting task/source state remains reviewable.
- Two false statements can release only an eligible unstarted task: CONFIRMED, or a protected deferred PLANNED item whose consumed_at is NULL. Source goods must still be CLAIMED/BATCHED as required, the listing must be valid, and route/assignment uncertainty must be absent or explicitly covered by that safe deferral.
- For that permitted branch, the function releases claim/lease with RECONCILED_NO_HANDOVER, makes the task STALE, resolves the deferred stop as uncollected, reopens the listing, and calls geolock_transition_listing_donations to move CLAIMED goods to AVAILABLE for direct donations (BATCHED for hub inventory). It resolves the case as RESOLVED_RELEASED/BOTH_PARTIES_CONFIRMED_NO_HANDOVER atomically.
- A DISPATCHED task fails the false/false release branch. It produces MANUAL_REVIEW/NO_HANDOVER_CONFIRMED_AFTER_PICKUP_STARTED instead. Deferral is for an unconsumed unstarted item; it cannot be used to undo this dispatched task.

Food Can follows the last branch. Both required participants responded; the remaining blocker is the started-task custody/accountability contract, not an unanswered counterpart. The persisted state intentionally retains uncertainty until an authorized protected resolution occurs. Do not change the donation to AVAILABLE, re-submit evidence with fresh request IDs, or apply the unstarted-route cancellation branch to this case.

## Flutter and RPC mapping

| Surface | Status source and display |
|---|---|
| Donor Home | dashboard_pages.dart:274 calls get_my_donation_dashboard_v2; DonationSummaryCard at :2236 calls donationStatusLabel with donation_status |
| My Donations | dashboard_pages.dart:514 calls the same dashboard RPC; uses the same summary card and status mapper. Its “Picked Up” filter groups PICKUP_IN_PROGRESS and COLLECTED (:536), but does not change the state |
| Older donor list page | donation_pages.dart:3379 calls the dashboard; :3425 uses donationStatusLabel(donation_status) |
| Donation Details | donation_pages.dart:3576 calls get_my_donation_detail; :3903 maps its status through donationStatusLabel |
| Current-state mapper | donation_status.dart:25 maps PICKUP_IN_PROGRESS exactly to “Pickup in Progress”; persisted donation state precedes listing/inventory values |
| Status timeline | status_timeline.dart:207 uses the same wording for workflow states; recorded events come from get_authorized_audit_events and pending milestones use the current donation status (:310 onward) |
| Route card | routing/route_card_view.dart uses the separate route stop can_complete flag for lowercase “Pickup in progress”; it is not the donor donation badge |

The deployed dashboard SELECT returns d.donation_status directly; detail returns both status and donation_status from d.donation_status. Neither synthesizes it from historical tasks, released claims, routes or vehicle bindings. Detail's dashboard merge supplies photo/inventory/reservation fields and does not overwrite its donation status. The audit timeline shows past events; it does not override the current badge. Donor Home, My Donations and Details should therefore agree after fresh reads. No live screenshot/session comparison was performed.

The Home/list/detail screens hold in-memory Futures, not a persistent authoritative status cache. Home reloads on shell refresh signals, pull refresh and return from details. My Donations reloads on shell signal, pull refresh and returning from details. Detail reloads on manual refresh and after a confirmed donor reconciliation receipt via DonorPickupOutcomeNotice.onConfirmed → _refreshAfterConfirmedDonationAction → _load (donation_pages.dart:3553, :3973, :4102 onward). The reconciliation panel also refreshes its own protected state. There is no continuous cross-device realtime refresh in these inspected donor flows, so an idle screen can be stale. Here a fresh read still returns PICKUP_IN_PROGRESS, so refresh cannot release this case.

## Discovery and interaction with the unstarted route

Deployed discover_eligible_listing_cards requires listing_status=AVAILABLE and, for a direct donation, donation_status=AVAILABLE, in addition to NGO/road eligibility. Food Can fails both state prerequisites. Any cached road eligibility cannot make it discoverable through this protected query while these states remain.

Food Can does **not** belong to `24c9a21a-a5fd-4ff4-8fb4-e04779b292e9`. That route never recorded a pickup and its two claims resolved released. Food Can belongs to the different started route above. Its open vehicle binding is an accountability hold; it is not the SQL source of the donor badge. The donation remains in pickup because its own started claim failed the protected release branch. Cancelling the other route will not change Food Can.

## Recommended next step and tests

No incorrect current-state projection or release transition was verified. Keep the existing protection. The smallest useful presentation improvement would explicitly explain “Reconciliation requires manual review — pickup was started; both parties reported no handover,” while retaining the authoritative donation state. That Food Can/UI change is not implemented here. Separately review the authorized operational/manual resolution path for a dispatched no-handover claim, including vehicle accountability; creation of new legacy whole-route cases is retired, so do not assume the legacy finalizer is a currently available escape hatch. Any new resolution contract needs separate approval and tests.

Required regressions: one false statement awaits counterpart; false/false unstarted deferred releases; false/false dispatched remains MANUAL_REVIEW; contradictory statements remain protected; duplicate requests preserve receipts and reject replacement evidence; no donation discovery during pending custody; donor Home/list/detail all project persisted state; protected reconciliation refresh rereads detail; foreign donor/NGO cannot submit; route cancellation never alters unrelated Food Can claim/task/donation or its started vehicle hold.

This investigation executed read-only record/catalog queries. No Food Can fixes, route mutations, recovery, reconciliation, worker activation, formal E2/E4 experiments or deployment ran against DEV.
