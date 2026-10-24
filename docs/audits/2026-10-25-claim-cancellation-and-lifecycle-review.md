# Claim cancellation fix and donation lifecycle review

Scope: SELECT-only catalog inspection of isolated DEV rcgyuwiidqvrgbxswhqj,
plus local SQL/Flutter source review. Shared project was not accessed.
Only the cancellation correction and its source tests are implemented locally.
No migration or stateful RPC was executed. Part B remains a proposal.

## Part A: confirmed cancellation defect and prepared fix

Flutter Cancel Claim calls cancel_claim(p_claim uuid,p_request uuid).
Source: frontend/geolock_hub_app/lib/donation_pages.dart:1240-1247.
The caller saves a per-user/per-claim request UUID in SharedPreferences before
calling the RPC and retains it when the RPC throws.

DEV cancel_claim's final audit INSERT includes:
    request_id,claim_id,lease_id,donation_id,listing_id,correlation_id,...
with corresponding values:
    ...,v_le.lease_id,v_l.donation_id,v_l.listing_id,p_request,...
Historical local source:
supabase/migrations/20261019_stage1_claim_recovery_and_reconciliation.sql:158-167.

Neither donation_id nor listing_id exists on deployed audit_events. This is a
direct RPC statement error, not an INSERT audit trigger. The audit table's only
user trigger prevents UPDATE/DELETE, preserving append-only history.

The deployed audit schema has:
event_id, actor_user_id, actor_role, entity_type, entity_id, event_type,
request_id, claim_id, lease_id, correlation_id, previous_state, requested_state,
resulting_state, reason_code, outcome, details, software_version,
configuration_version, occurred_at.
outcome permits SUCCESS, REJECTED, ERROR.
The convention is entity_type/entity_id for the subject, claim_id/lease_id for
claim references, and details JSON for extra donation/listing/task context.
Existing claim_listing and pickup RPCs already use this valid convention.

Prepared forward-only migration:
supabase/migrations/20261025_fix_cancel_claim_audit_columns.sql.
It replaces only cancel_claim(uuid,uuid), copied from the deployed definition.
The only body differences remove the two unsupported audit columns and their
positional values, and add donation_id to details. listing_id and task_id already
exist in that JSON and remain intact. Event type, subject, request/correlation IDs,
states, outcome, software/config versions and return value remain unchanged.
No audit column, table, policy, trigger, grant or historical row is changed.
CREATE OR REPLACE preserves the postgres owner and existing EXECUTE ACL:
postgres, authenticated and service_role; anon has no grant.

Ownership validation, fingerprint conflict handling, request-row FOR UPDATE,
cached-response replay and claim -> lease -> listing -> task locks are preserved.
A safe cancellation releases claim/lease, marks task STALE and reopens listing.
The newer listing trigger atomically bumps its eligibility generation and enqueues
refresh when reopened, so rediscovery waits for valid fresh eligibility.
Donation custody and hub inventory remain unchanged.

The original error happens after tentative state changes and saved response but
before the RPC returns. With no swallowing exception handler, the entire request
rolls back, including the request row/response, released state and requeue writes.
Existing audit history is untouched. Retrying with the same UUID is appropriate.

The fix preserves refusal after dispatch, route activity, expired leases, missing
tasks, inconsistent custody or other existing safety guards. It does not broaden
cancellation to planned/routed or in-progress pickups.

Local validation:
- Four focused cancel_claim audit contract checks passed.
- The full local SQL source-contract suite passed (29 checks at review time).
- Tests compare the entire body against the historical source with exactly the
  three audit substitutions, verify audit INSERT arity/schema, and preserve UUID,
  locks, guards and atomicity.
- PostgreSQL deployment/runtime tests have not been performed.

Adjacent confirmed defect (not changed by this narrow fix):
recover_expired_claims(integer) and submit_claim_reconciliation(uuid,boolean,uuid)
also INSERT audit_events.donation_id/listing_id. Recovery and reconciliation must
receive separate small audit-projection corrections before relying on those paths.
This is an existing defect, not introduced by the cancellation fix.

## Part B: current deployed state contracts

| Record | Allowed persisted states |
| --- | --- |
| donations.donation_status | SUBMITTED, READY_FOR_PICKUP, HUB_ASSIGNED, AT_HUB, BATCHED, PICKUP_IN_PROGRESS, COLLECTED, CANCELLED |
| listings.listing_status | AVAILABLE, CLAIMED, CLOSED, CANCELLED |
| donation_claims.claim_status | ACTIVE, RELEASED, EXPIRED, COMPLETED, CANCELLED, RECONCILIATION_REQUIRED |
| claim_leases.lease_status | ACTIVE, EXPIRED, RELEASED, COMPLETED, RECONCILIATION_REQUIRED |
| pickup_tasks.task_status | CONFIRMED, PLANNED, DISPATCHED, COLLECTED, CANCELLED, STALE |
| hub_inventory.inventory_status | STORED, BATCHED, COLLECTED, RECONCILIATION_REQUIRED |
| hub_batches.batch_status | DRAFT, PUBLISHED, CLAIMED, COLLECTED, CANCELLED |

The live direct threshold is 10 kg inclusive and the claim lease is 360 minutes.
Creation temporarily inserts SUBMITTED while items are being inserted; guard_donation_items
allows items only before collection_path/total_weight have been finalized. Direct
donations commit READY_FOR_PICKUP plus an AVAILABLE listing. Smaller donations
commit SUBMITTED with no direct listing; reserve_hub_capacity assigns a hub,
receipt changes donation to AT_HUB and inventory to STORED, and batch publication
changes members/inventory to BATCHED, batch to PUBLISHED and inserts one AVAILABLE
batch listing.

claim_listing creates an ACTIVE claim/lease and a CONFIRMED pickup task, then sets
the listing to CLAIMED. It does not change donation status or hub_batches status.
The permitted hub batch CLAIMED enum is not used by this claim path.
A unique partial index permits only one ACTIVE/RECONCILIATION_REQUIRED claim per
listing; another permits only one ACTIVE batch membership per donation.

start_pickup (the sole direct writer found for DISPATCHED/PICKUP_IN_PROGRESS)
validates holder, active unexpired lease and CLAIMED listing; changes CONFIRMED
or PLANNED task to DISPATCHED; and changes direct READY_FOR_PICKUP or active batch
members BATCHED to PICKUP_IN_PROGRESS. Thus claiming already does NOT start pickup.
complete_pickup requires explicit handover confirmation and a DISPATCHED task,
sets donation(s) COLLECTED, closes listing, completes claim/lease and marks task
COLLECTED. For batches it also marks inventory and batch COLLECTED.

The donation transition trigger permits SUBMITTED->READY_FOR_PICKUP only for a
direct donation >=10 kg; SUBMITTED->HUB_ASSIGNED only for a hub donation <10 kg;
HUB_ASSIGNED->AT_HUB->BATCHED; READY_FOR_PICKUP/BATCHED->PICKUP_IN_PROGRESS;
and PICKUP_IN_PROGRESS->COLLECTED, plus allowed donor cancellation paths.
AVAILABLE and CLAIMED are currently invalid donation_status values.

## Recommended user-facing workflow (not implemented)

Keep the existing custody/claim records as authoritative and expose one derived
workflow_status from protected read RPCs. Do not add a second persisted claim flag
on each donation. The requested user-facing sequences can then be:

Direct: AVAILABLE -> CLAIMED -> PICKUP_IN_PROGRESS -> COLLECTED.
Hub: AVAILABLE -> HUB_ASSIGNED -> AT_HUB -> BATCHED -> CLAIMED ->
PICKUP_IN_PROGRESS -> COLLECTED.

| User-facing stage | Authoritative condition |
| --- | --- |
| AVAILABLE, direct | READY_FOR_PICKUP without an effective claim |
| AVAILABLE, hub | SUBMITTED and awaiting hub selection; no NGO listing exists yet |
| HUB_ASSIGNED / AT_HUB / BATCHED | Existing custody states, before later pickup progress |
| CLAIMED | Direct or active-member batch listing CLAIMED, with matching effective claim; pickup not started |
| PICKUP_IN_PROGRESS | start_pickup dispatch plus the donation's PICKUP_IN_PROGRESS custody state |
| COLLECTED | Confirmed handover and matching completed custody/claim state |
| CANCELLED / attention | Preserve cancellation, expired reservation, stale/expired lease and reconciliation states separately |

Evaluate terminal/custody progress before generic listing CLAIMED, because the
listing remains CLAIMED while pickup is in progress. Never label a reconciliating
or expired-but-unrecovered claim AVAILABLE solely because the lease clock elapsed.
Async eligibility pending/failed status remains separate from donation workflow:
an AVAILABLE listing can still be hidden from NGOs until refresh is complete.

For member donations derive CLAIMED from their active batch membership and its one
listing/current claim. Keep inventory BATCHED until actual collection; claiming
must neither release capacity nor mark goods collected. The batch can remain
PUBLISHED internally while its listing is CLAIMED; existing photo authorization,
claim checks and publication guards depend on that distinction. At Start Pickup
and handover validate all active members, lock them in stable UUID order and ensure
the whole expected set progresses atomically. Preserve the unique membership/claim
indexes and existing batch composition/weight rules. Combined batch weight must
not reclassify the original <10 kg member donations as DIRECT_PICKUP.

Cancellation before pickup returns the direct workflow to AVAILABLE or member
workflow to BATCHED, retaining the released claim as history and opening a new
eligibility generation. A subsequent claim is a new claim, not a revived released
one. Safe lease expiry follows the same outcome; uncertain/dispatch/route activity
must stay in reconciliation rather than automatically republish. The currently
broken recovery/reconciliation audits noted above are prerequisites to validating
these paths.

## Affected components and design conflicts

For the recommended derived workflow:
- Backend protected read RPCs: get_my_donation_dashboard_v2, get_my_donations,
  get_my_donation_detail and claim/batch/detail read RPCs must return a consistent
  derived workflow_status and relevant claim/task metadata.
- The donor dashboard/detail currently joins ONLY direct listings. It must also
  resolve active hub_batch_members -> batch listing -> current claim/task, without
  joining every historical released claim or duplicating donor rows.
- Flutter donation_status.dart currently checks listing CLAIMED before
  PICKUP_IN_PROGRESS, so it can mask pickup progress. dashboard_pages.dart filters
  also overlap At Hub/Claimed/Picked Up and use custody state alone in some paths.
- status_timeline.dart labels SUBMITTED/READY_FOR_PICKUP using old terminology.
  pendingDonationMilestones omits CLAIMED from both paths. donation_pages.dart has
  additional raw status checks, static READY_FOR_PICKUP/PUBLISHED detail progress
  and button guards. Change presentation and derived state consumers consistently,
  keeping action authorization on the backend.
- Timelines must use recorded audit/claim/pickup events, including release/reclaim
  cycles, rather than invent CLAIMED timestamps from the current state. Preserve
  old audit records and translate legacy names for display.
- Tests must cover >=10 kg boundary, before/after claim, explicit Start Pickup,
  batch member synchronization, safe cancellation/expiry, reconciliation, and
  async refresh hidden states.

If AVAILABLE and CLAIMED must instead be persisted in donations.donation_status,
that is a larger coordinated forward migration, NOT a label edit. It must update
constraints/defaults, item insertion staging, transition guards, existing rows,
creation, claim, pickup, cancellation, recovery/reconciliation, hub reservation,
discovery, image authorization and read RPCs in one compatible plan.
Live functions depending on SUBMITTED/READY_FOR_PICKUP include:
can_read_geolock_donation_image, cancel_claim, cancel_donation, claim_listing,
create_and_validate_donation, discover_eligible_listing_cards,
discover_eligible_listings, enforce_donation_transition, geolock_backfill_road_nodes,
get_eligible_hubs, get_eligible_listing_constituents, guard_donation_items,
recover_expired_claims, reserve_hub_capacity, start_pickup, submit_claim_reconciliation.
Persisting duplicate CLAIMED states also requires atomic rollback/synchronization
for every member on release/recovery and would conflict with today's
READY_FOR_PICKUP/BATCHED cancellation checks. The derived workflow is the smaller,
safer way to deliver the requested user-facing behavior.

No Part B SQL or Flutter implementation has been made.

