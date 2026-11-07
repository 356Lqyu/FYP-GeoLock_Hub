# Shared listing lock: caller and dependency review

Local full-schema catalog captured 5 November 2026, after the existing reconciliation migration and before the candidate. No DEV catalog was queried. `original-reproduction/function-catalog.json` contains exact function definitions, metadata and normalized source hashes; `caller-catalog.json` and `caller-graph.json` retain the reviewed dependency closure.

The source scan found **29 functions in a conservative reverse-call closure**. PL/pgSQL calls are not comprehensively represented by pg_depend; this review uses actual prosrc plus checked migration definitions and trigger code. Overloads are conservatively linked by qualified name, so the graph can contain extra overload/self edges. This is a safety overapproximation, not a claim of 29 independent SQL execution paths. A new DEV preflight must repeat the scan and check for additional/dynamic callers before deployment.

## Direct callers of the helper

There are six direct caller names: `claim_listing`, six-argument `geolock_transition_listing_donations`, `cancel_claim`, `recover_expired_claims`, `routing_private.lock_sources`, and `routing_private.coord_decide`. The three-argument transition wrapper delegates to the six-argument version. All are represented below.

## Lock order by caller and wrapper

Rows describe explicit lock prefixes; FK checks and row modifications additionally acquire their ordinary PostgreSQL locks. Unqualified functions are in public. U = FOR UPDATE; NKU = FOR NO KEY UPDATE; S = FOR SHARE. Only the two marked listing acquisitions change. Locks already held more strongly are retained, not downgraded.

| Function(s) | Explicit acquisition order / delegation |
|---|---|
| `claim_listing(uuid,uuid)` | NGO S → actor/request advisory → request insert (listing and NGO FK key-share) → own request U → listing **U→NKU** → helper source set → new claim/lease/task rows → transition → request result/audits. Different actor/request advisory keys do not serialize all contenders. |
| `geolock_lock_listing_donations(uuid,text[])` | listing **U→NKU** → direct donation U, or batch U → donations U in donation UUID order → inventory U in the same donation order. Complete source membership/status validation remains unchanged. |
| `geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)` | helper → read listing/context claim+lease → ordered donation updates → append donation-status audits. No new explicit listing upgrade. |
| `geolock_transition_listing_donations(uuid,text,text)` | delegates to six-argument transition with explicit absent claim/request context; no guessed historical ownership. |
| `cancel_claim(uuid,uuid)` | cancellation request insert/lock U → claim U → lease U → listing U → task U → helper → conditional source/claim/lease/task/listing updates → transition/audit. Strong listing lock is taken before helper/donation locks and remains held. |
| `recover_expired_claims(integer)` | route recovery lock prefix if managed → claim U SKIP LOCKED → lease U → listing U → task U → helper → guarded release or unresolved reconciliation → transition/audit. Eligibility/custody/expiry policy unchanged. |
| `routing_private.lock_sources(uuid[])` | all claims U in claim order → all leases U in lease order → all listings U in listing order → helper for each distinct listing in order → hubs S. |
| `routing_private.lock_route(uuid,boolean)` | actor/NGO routing lock → lock_sources → vehicle U → route U → tasks U in order → binding U. |
| `routing_private.lock_route_for_recovery(uuid)` | NGO S → NGO routing advisory → lock_sources → vehicle U → route U → tasks U → binding U; routed recovery shares managed-route order. |
| `routing_private.lock_reconciliation_scope(uuid)` | participant authorization → NGO S → NGO routing advisory → bare claim U if unmanaged; otherwise lock_sources → vehicle U → route U → ordered tasks U → binding U. |
| `resolution_private.lock_case(uuid)` | NGO S → routing advisory → lock_sources → vehicle U → route U → tasks U → binding U → resolution case U. |
| `routing_private.coord_decide(uuid,uuid)` | reconciliation case U → claim U → lease U → listing U → task U → votes/blocker → helper → protected matching resolution and audit. Public entry points acquire their scope prefix first. |
| `routing_private.legacy_start_pickup(uuid)` | claim U → lease U → listing U → task transition → donation transition/helper/audit. |
| `routing_private.legacy_complete_pickup(uuid,boolean)` | claim U → lease U → listing U → task/source transition/helper/audit. Legacy eligibility remains unchanged. |
| `start_pickup(uuid)` | managed lock_route + protected consumption, or authorized legacy_start_pickup delegation. |
| `complete_pickup(uuid,boolean)` | managed lock_route + protected completion, or authorized legacy_complete_pickup delegation. |
| `authorize_my_routing_candidate(uuid,uuid,timestamptz)` | NGO actor prefix → lock_sources for candidate tasks → ordered vehicles U → candidate/source rechecks → task U/assignment/binding creation. |
| `cancel_my_unstarted_route(uuid)` | lock_route → safe unstarted lifecycle checks/closure; source locks inherited. |
| `close_my_collected_route(uuid,boolean)` | lock_route → collected-source/vehicle guards → closure. |
| `close_my_resolved_route(uuid,boolean,uuid)` | receipt/advisory → lock_route → unresolved-custody and depot/outcome guards → closure/receipt. |
| `confirm_my_route_depot_checkpoint(uuid,boolean,uuid)` | receipt → lock_route → physical depot confirmation and remaining-route checkpoint guards. |
| `defer_my_pickup_for_reconciliation(uuid,uuid)` | receipt/request advisory → lock_route → protected deferred stop/claim-scoped evidence changes. |
| `report_my_route_interruption(uuid,text,uuid)` | lock_route → interruption case U → reconciliation/vehicle accounting/audit. |
| `finalize_route_resolution(uuid,bigint,uuid)` | operator/receipt checks → lock_case → immutable manifest/evidence/custody checks → transition/helper for safe no-handover stops → source/claim/lease/listing outcomes and receipt. |
| `submit_route_resolution_evidence(uuid,uuid,text,bigint,uuid)` | participant checks → lock_reconciliation_scope → case U, or submit_claim_reconciliation delegation for the compatible claim path. |
| `submit_claim_reconciliation(uuid,boolean,uuid)` | compatible wrapper delegates to v2 with protected current evidence-round/version. |
| `submit_claim_reconciliation_v2(uuid,boolean,integer,bigint,uuid)` | participant/receipt → lock_reconciliation_scope → case U/version checks → append evidence → coord_decide → response/audit/receipt. |
| `resolve_my_claim_reconciliation(uuid,uuid)` | participant/receipt → lock_reconciliation_scope → coord_decide → receipt. |
| `review_my_claim_reconciliation(uuid,text,bigint,uuid)` | participant/receipt → lock_reconciliation_scope → case U/version checks → append review/evidence-round operations/receipt. |

This table accounts for all 29 catalog entries (the transition overload row contributes two functions). Exact per-function edges and full sources remain in the JSON rather than being inferred solely from names.

## Keys, FK locks, transitions and audits

The helper reads/locks listings and never changes their keys. Reviewed caller listing updates change `listing_status` and `listing_version`; no reviewed caller rewrites listing ID, donation ID, batch ID or source type. The primary key and source-specific donation/batch unique indexes are retained. Neither updated column is a unique key. `enforce_listing_transition` only validates/returns NEW and does not rewrite keys. Candidate guards reject unique-key drift or unexpected listing trigger count/source. Catalog evidence is also captured by the focused suite in `dependency_catalog.json`.

`claim_requests.listing_id` and `donation_claims.listing_id` reference listings; request insertion takes FK key-share before the explicit listing acquisition. Claim/lease/task inserts also check their existing FK parents; the lease refers to its claim and the claim request/result relationship is preserved. NGO profile S locks are compatible with FK key-share. No FK/index/trigger is disabled or replaced by this correction.

NKU still conflicts with another NKU or U listing acquisition and serializes the competing decision/update. It permits parent-key-stable FK checks to coexist. Ordinary primary-key-changing updates/deletion still require incompatible key locks; this patch does not authorize them. The unique active-claim constraint remains the final database invariant, with all request digest/UUID and authorization logic unchanged.

Donation/batch/inventory locks remain U and retain their existing acquisition order. Published batch membership stays immutable. Transition triggers, task dispatch/completion/deferred-release permit guards, evidence rounds/version/participant checks and custody blockers are unchanged. Audit inserts retain actor FK checks. `resolution_private.audit_provenance` enriches provenance via reads; it does not introduce a hidden listing U acquisition in a new claim. Audit append-only and ordinary-user failure-receipt permissions remain unchanged.

## Why two changes are justified, and limits

The claim-only candidate retained a later helper U upgrade. With both acquisitions NKU, the reviewed new-claim call chain no longer requests that incompatible upgrade. Transition calls the same corrected helper again, preserving the lock mode. Other reviewed callers either inherit an already-held listing U lock or keep their established lock prefixes; weakening the helper's redundant acquisition does not reorder or release their stronger locks. No additional shared function change was identified as necessary during this review.

This does not prove absence of every lifecycle deadlock. Multi-listing operations, route/claim/case ordering, profile administration, arbitrary trusted SQL or new callers can form other graphs. Existing stronger U locks in cancellation/recovery/routing are deliberately unchanged; they can block FK insertion but are not automatically defects. The focused races and custody checks test relevant interactions, not exhaustive scheduling. No automatic retries mask errors. A future failure requiring a third function change triggers a new scope decision.

The review-only forward and rollback scripts fingerprint the source/owner/ACL/security/configuration of all 29 reviewed functions and verify exact replacement counts and full pg_proc metadata preservation for the two changed functions. They do not automatically discover all newly added DEV callers; that catalog comparison is a mandatory separate preflight. No assumption about current deployed source is made from this local review.

## Operational async-eligibility trigger configuration

The initial minimal-fixture trigger-count guard correctly rejected the operational custody fixture. The final guard accepts exactly two reviewed sets: the transition trigger alone, or that trigger plus `zz_listing_eligibility_generation` and `trg_listing_road_eligibility`. It checks trigger names, row/event timing, enabled state, absence of extra attributes/conditions/arguments and function identity, plus source fingerprints/owner/security-definer state for the operational trigger functions. Unknown/partially installed configurations still fail. No trigger was removed, disabled or rewritten to pass a test.

The operational definitions come from `supabase/migrations/20261024_async_listing_eligibility_refresh.sql`. `geolock_prepare_listing_eligibility()` runs before insert/update: on a claim's AVAILABLE→CLAIMED transition it retains generation/node and does not refresh. `geolock_listing_eligibility_trigger()` runs afterward and immediately returns when the generation did not change. Therefore this claim update introduces no additional listing lock upgrade or queue operation.

On legitimate reopening or re-noding, the before trigger checks coverage FOR SHARE/resolves the node and advances generation; the after trigger deletes the old eligibility cache and queues a new generation. It explicitly avoids locking old queue rows to preserve queue/listing order. These callers already hold their existing listing U prefix. Neither trigger changes listing ID, source donation/batch identity or another listing key. Their bodies are unchanged. This additional dependency review expands the guard's exact known schema configurations, not the two-function business correction.

The older custody fixture also deliberately doubles blank lines during CRLF transport testing. Its adapter restores reviewed formatting only when every nonblank source line is byte-identical; any substantive difference fails. Its claim-function explicit authenticated grant is aligned with the primary fixture, while retaining existing PUBLIC execution and unchanged body-level authorization. This is fixture setup, not a grant change made by the SQL candidate. Exact prior mismatch evidence is retained in the numbered failed attempts.
