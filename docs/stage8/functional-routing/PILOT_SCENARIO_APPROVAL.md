# First real Flutter pilot inputs — proposal only, no write approval

Observed27 October2026,11:13–11:18UTC (19:13–19:18MYT). Approved DEV project
rcgyuwiidqvrgbxswhqj confirmed by MCP URL; connection configured read_only=true;
actual SQL identitysupabase_read_only_user, databasepostgres, transaction_read_onlyon.
Every inspection transaction explicitly READ ONLY and ended ROLLBACK. No production,
planning RPC, snapshot, matrix generation, route, recovery or database write executed.

Evidence SQL/results: `results/pilot-scenario-review/20261027-readonly/`.
All rows inventoried:2NGOs,1vehicle,10donations,6listings,8tasks. Zero public routes,
managed bindings or active task assignments. Direct private observation/admission
functions were not callable by this read-only account and were NOT invoked or
granted; assessment combines actual source rows and inspected SQL definitions.

## Existing data: no immediately usable claimed/vehicle combination

| Input | Actual state | Decision |
|---|---|---|
| Rice100 |1000kg; taskCONFIRMED; claim/leaseACTIVE;349.66min remaining at11:13UTC; listing/donationCLAIMED; no listing expiry|Time-eligible then, but cannot fit20kg V1|
| STAGE3I-E2E donation |20kg; taskCONFIRMED; lease expired2026-10-25T01:37:43Z while status stillACTIVE; listingCLAIMED|Capacity fits, authority expired; do not reuse/recover automatically|
| Test40 |150kg; lease expired2026-10-25T01:37:48Z while statusACTIVE|Expired and exceeds V1 capacity|
| Test42 |50kg; donation/listingAVAILABLE; no listing expiry; recorded road eligibilityELIGIBLE|Needs a genuine >=50kg vehicle and fresh claim; none exists in DEV|
| test |60kg; donation/listingAVAILABLE; no listing expiry; recorded road eligibilityELIGIBLE|Needs a genuine >=60kg vehicle and fresh claim; none exists in DEV|
| Cloth |10kg but CANCELLED, no pickup node|Cannot claim or revive for this pilot|
| Test13/test32 |1kg/5kg; SUBMITTED HUB_COLLECTION; no listing|Would require normal hub receipt/batch/publication workflow; not a direct-pickup shortcut|

Existing claimed20kg donation ID3a012ba4-25cc-4054-897e-008e11da3e9e;
expired claimdd1be70f-0e42-4b75-9124-cac3702d76f6;
expired taskbbbf6b10-cb79-42ed-82cc-8b2246bf8bcb.
Do not extend its lease, reset states, recreate a claim or manually alter its weight.

Available50kg alternative: donation5ab67656-bd03-4e19-942f-59a2dd4e6f11,
listing2d06b504-d2dd-4121-8840-c8bf893f8a60, node5724643871.
Available60kg alternative: donation0c8f21b4-2e87-466c-bc29-dc15c78f4a04,
listing16e5b6a1-475d-4c5a-9460-d4834dd5640f, node2308277369.
Only choose an alternative if the operator actually has a matching vehicle and
authorizes its truthful registration. Do not inflate V1's recorded capacity.

## Recommended smallest direct-pickup setup — NOT YET APPROVED

Keep the existing NGO, vehicle, policy, graph and every existing donation/claim.
Create ONE genuinely available10kg donation through the donor Flutter workflow,
then have the current NGO claim it. Current donation_direct_min_kg=10, so10kg is
the smallest direct-donation weight; below10kg automatically takes the hub path.

| Field | Exact existing/proposed input |
|---|---|
| Existing NGO |test ngo;8e50bc66-7a8d-4791-bc6b-640682daa496|
| Existing depot |node1755847853;3.2175514451822,101.623839922249; active verified NGO/location generation1|
| Existing vehicle |V1/Lorry;e97b9c57-501b-40b7-83a9-0784d9d8e02b; version1;20kg;60min; active/available; matching depot; no hold|
| Existing donor account proposed |21d373a7-6551-4469-81d1-280198d4317e; DONOR role verified|
| Proposed title |FYP DEV pilot - Rice10kg|
| Proposed description |Controlled DEV pickup demonstration; factual description of the actual goods and agreed handover|
| Proposed item |Rice; quantity1; unitbag; unit_weight_kg10; total10kg; conditionGOOD only if true|
| Existing active category |Food;977fbf03-c3ae-4864-8307-ef2c98f7e7be|
| Proposed pickup |Reuse the existing test pickup location ONLY if the donor confirms it is the actual handover site:3.22284613426561,101.620313487947;1294 JalanE4/9,TamanEhsan|
| Expected pickup node |2308277456, from current approved snapshot; server must resolve it from the real coordinates; do not supply a forced client node|
| Photos |At least one actual compliant photo via existing upload flow; no fake image paths or metadata|
| New IDs/request IDs |Generated/preserved by existing app/RPCs at execution, not fabricated as pre-existing records|

This proposal is conditional on confirming the actual10kg goods, donor access and
pickup address. If those facts are not true, stop and select truthful inputs rather
than changing weights or coordinates solely to make a test pass.

All relevant existing node IDs were active in OSM-OPS-20261018; coverage active,
OPERATIONAL and approved. Cached NGO eligibility to the proposed existing pickup
wasELIGIBLE,1.246249984km within20km, with matching depot/pickup/snapshot IDs.
That historical row does not pre-authorize a NEW listing: normal claim eligibility
must be confirmed by the protected claim RPC after creation.

## Time and duration evidence — no new route generated

Existing full-size probe matrix:
`results/worker-readiness/20261027T083653Z-5f56bb/matrix-1.json`.
Frozen graph ID eab1f7ee-a8e0-4bed-a0e1-2c4bff024936, digest
5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a.
Depot1755847853 ↔ proposed pickup2308277456 has AVAILABLE arcs BOTH ways:
each1.24625km,2.6103minutes. Existing direct service10minutes gives
2.6103+10+2.6103=**15.2206minutes**, round-trip2.4925km, below V1's60min limit.
This is modeled time under the frozen speed profile, not live traffic or GPS proof.
No new path, matrix, candidate or route was generated for this inspection.

Current policy80db858b-93e8-4a0a-94e2-dbe14940f0a1 has horizon240min,
margin15min, mandatoryfalse. A new claim gets360min; require >255min remaining
lease and applicable listing validity at snapshot cutoff (claim age<105min).
New direct-listing creation currently sets listing_expires_atNULL; assert actual
post-create values before planning. Availability is derived by existing contract;
the create form does not grant arbitrary time-window overrides.

Important remaining scope limit: begin_my_routing_snapshot captures ALL this NGO's
CONFIRMED tasks, not just one selected task. The current worker forms matrix nodes
from all observations before admission exclusions. Thus current Rice1000 atnode
478516303 also enters the matrix, even when unserved; expired20/150kg observations
remain captured but are excluded from service eligibility. The reused diagnostic
3x3 matrix covers depot/2308277456/5735535080, not478516303. Complete current-snapshot
matrix availability and live end-to-end latency remain unverified until the approved
pilot. Do not silently repair/filter existing tasks or call the planner in this
read-only phase. Stop on ROUTE_UNAVAILABLE or source/lease failures.

## Exact write scope requiring separate approval

1. As the proposed donor, create one10kg donation via create_donation_with_images:
   actual Storage photo upload(s), one donation, one item, image metadata, one direct
   listing, normal request/audit/eligibility bookkeeping. Require AVAILABLE,
   DIRECT_PICKUP, expected coordinates/server node and10kg. No existing donation edit.
2. As the proposed NGO, claim only that returned listing through claim_listing:
   one new claim, one360min lease, oneCONFIRMED task; new listing/donationCLAIMED.
   Inspect returned IDs and current protected reads. No recovery/extension of old claims.
3. Generate through existing UI: snapshot, real matrix storage/sealing, candidate,
   independent validator attestation and normal durable journal/audit records.
   Under mandatoryfalse, expect new10kg served and oversized Rice1000 unserved
   if still admitted. Expired claims must not acquire new authority.
4. NGO explicit authorization: route/stops/binding/items/assignment and V1 reservation
   via authorize_my_routing_candidate. Only new10kg task becomesPLANNED.
5. Ordered start_pickup → complete_pickup with actual handover →
   close_my_collected_route with actual depot return. Preserve lifecycle receipts
   and audits; expected taskCONFIRMED→PLANNED→DISPATCHED→COLLECTED, claim/leaseCOMPLETED,
   routeAUTHORISED→IN_PROGRESS→COMPLETED. No vehicle capacity/duration edits.

No approval is assumed for any of these. Policy, frozen graph, permissions and
recovery scheduler are excluded from the proposed write scope.

## Flutter execution after approval

1. Donor: create the approved10kg donation using actual photo/location/items; record
   committed donation/listing IDs. If it becomes HUB_COLLECTION or the node differs,
   stop for review instead of overriding the result.
2. Sign in as test ngo, claim that listing normally. Open Pickup Routes; refresh.
3. Tick eligible V1; while the page is fresh (<30s), Generate route. Do not repeat
   taps/new request IDs after an unknown result. Observe served/unserved comparison.
4. Require candidate ID and validation_statusATTESTED. Choose a future departure
   (e.g. about5min ahead) within valid windows; Request database authorization.
   If page freshness expires and requires refresh, it clears the candidate; do not
   bypass the protection or treat a local validation label as authorization.
5. Open the returned database route. After the authorized departure, Start pickup,
   perform the real handover, Complete pickup, then confirm depot return and close.
   Refresh protected reads to verify statuses, vehicle release and audit evidence.

Verdict: **NO-GO with existing claimed data; conditional GO to request approval for
the new truthful10kg pilot setup.** Full live pilot success is not yet demonstrated.
