# Stage 3I Phase 1: fixture creation and baseline verification

PASS. One dedicated DEV donation and claim were created by the USER through the
existing Flutter workflows. Assistant database access was SELECT-only through DEV
rcgyuwiidqvrgbxswhqj/read_only=true. No shared project access or Phase 2 action.

## Preflight

2026-10-22 20:23:02 UTC: job 3 inactive, 12 historical succeeded executions, no
unfinished run. Jobs 1/2 active. No nonterminal claim, overdue ACTIVE/ACTIVE pair,
unresolved reconciliation case or open client transaction was returned. No previous
STAGE3I-E2E fixture existed. Recovery fingerprint 5ff6d8719db9681aae6f444b89dfbaee;
postgres owner; SECURITY DEFINER; approved search_path and exact postgres/service_role
EXECUTE ACL; anon/authenticated EXECUTE false. Configuration: 360-minute lease and
10kg direct threshold. See phase1_precreation_preflight.json.

## User application actions

Donor: Donations -> Create donation; exact title below; description identifying
disposable DEV fixture; one active-category Rice item, quantity 1, unit weight
20kg; one benign test photo; normal location picker; Submit Donation. No dates,
SQL fixture insertion or validation bypass. Donor creation success was reported
by the user and verified with SELECT before proceeding to NGO action.

NGO: dedicated DEV NGO login -> Discover -> exact fixture -> Claim listing ->
My Claims / Active. User confirmed claim success and Active visibility. No pickup,
route, cancellation, completion or manual recovery was performed as part of this
supervision. Normal authenticated/idempotent RPCs and real eligibility stayed in use.

## Identifiers and baseline

| Field | Value |
|---|---|
| Title | STAGE3I-E2E-30bc928b-2843-4b9c-a5d4-298b76a8c514 |
| Donation | 3a012ba4-25cc-4054-897e-008e11da3e9e |
| Listing | 95d6cd51-866b-4eec-8a36-36dc24296aec |
| Claim | 8161392c-e1e1-4723-a954-c80b6b61a8c7 |
| Lease | 11b7d48e-a459-4b47-b1db-b43f98d0d474 |
| Pickup task | 270caa8b-5a6d-481c-b199-c9a47156dda2 |
| Claim request/idempotency ID | 38aba660-edee-4cab-b1eb-ee75692607c4 |
| Donor account | 21d373a7-6551-4469-81d1-280198d4317e |
| NGO account | 743cf8c1-12db-4c7d-8768-e584bae29c0e |
| Listing version | 2 |
| Listing eligibility generation | 1 |
| Separate claim generation | Not present in deployed claim/lease schema; do not invent one |
| Baseline captured UTC | 2026-10-22 20:33:50.214027+00 |
| Lease issued UTC | 2026-10-22 20:33:13.441725+00 |
| Lease expires UTC | 2026-10-23 02:33:13.441725+00 |
| Lease expires MYT (UTC+8) | 2026-10-23 10:33:13.441725 |
| Lease duration | Exactly 21600 seconds / 360 minutes |

At baseline: claim ACTIVE and lease ACTIVE, close timestamps/reasons NULL; task
CONFIRMED with 20kg load and expected pickup road node; donation CLAIMED,
DIRECT_PICKUP, 20kg; listing CLAIMED, DIRECT_DONATION, NULL listing_expires_at,
no batch. One 20kg item and one donor-owned primary image, unchanged from creation.
The lease is NOT expired; expiry-readiness preflight false is expected in Phase 1.

One real eligibility job (job_id 10), generation 1, completed successfully at
2026-10-22 20:32:13.416868 UTC, attempt 1, no error. NGO active/location verified;
cached result ELIGIBLE on snapshot OSM-OPS-20261018, 0.154229998588562km road
distance against 20000m radius. No road graph, NGO location or eligibility override
was made by the assistant.

Audits present, all SUCCESS:

- CREATE_DONATION, event 721f6d06-1250-455c-b873-91f79078316e, donor -> AVAILABLE.
- DONATION_PHOTOS_ATTACHED, event 089ccb7f-2fce-4921-b7e8-9380a13f7d9a, photo_count 1.
- DONATION_STATUS_CHANGED, event 10e73c1c-9d88-4247-a4a0-049499038380,
  NGO AVAILABLE -> CLAIMED with exact test claim and lease IDs.
- CLAIM_ATTEMPT, event 11f33058-1753-4879-af19-6696831e9a7a,
  NGO AVAILABLE -> CLAIMED with exact request/claim/lease IDs.

Zero recovery, pickup or handover audit events for the test claim. No route
assignment, route stop, reconciliation case, inventory or batch membership exists.
These records establish no recorded custody/pickup progress; physical custody
cannot be independently proven from database records.

## Scope comparison and deviations

Exactly this one nonterminal claim exists; no unrelated active/overdue claim or
unresolved case was found. Four older claims remain RELEASED/RELEASED with STALE
tasks. The 13-table snapshot with original empty-manifest audit scope, excluding
the newly created fixture, matches precreation hash
1a635cad67b4c3f1f1790599b475796e.

Populated target-manifest baseline hash is 070bb28ff5737477d6d91ec9e36feb02.
Do NOT compare it directly with the empty-manifest hash: NULL target exclusions in
the latter omit NULL-claim/entity audit rows, while a populated target includes
unrelated historical donor audits. Aligning the filters reproduces the original
hash. This is a comparison-scope difference, not evidence of an unrelated mutation.
No SQL template was changed during Phase 1. Future comparisons must reuse the exact
populated target IDs and scope. Items/photos and auth/profile/cache data are outside
that 13-table hash; target item/photo metadata was separately captured.

No deviation from normal fixture creation, photos, real eligibility, lifecycle or
lease policy was observed. The requested standalone claim generation does not exist;
listing version/generation and stable claim/request identity are recorded instead.

## Stopped state and Phase 2 recommendation

Job 3 remains INACTIVE, limit 1 every minute, configured timeouts 5s/50s, exactly
12 historical runs. Jobs 1/2 remain active. Recovery source remains approved.
No cron activation, recovery call, timestamp manipulation, SQL fixture insertion,
migration, cleanup or deployed object/grant change was performed by the assistant.

Leave the fixture untouched. CONDITIONAL GO for a Phase 2 READINESS REVIEW only
after server time reaches 2026-10-23 02:33:13.441725 UTC and the user explicitly
approves Phase 2. Natural expiry will not automatically recover it while cron is
paused. No reminder/monitor/cron was scheduled by this task.

Phase 2 must recheck source/security/cron, all candidates, custody/cases, jobs 1/2,
snapshots and exact expiry before separately approved activation. Phase 1 evidence
will be older than the activation script's 3-minute freshness guard; obtain a fresh
manifest then. phase1_target_manifest.json intentionally has operator/stop_at NULL
and maintenance_confirmed=false, so it cannot authorize activation.

## Files created by this phase

Under C:/Users/User/Downloads/FYP-GeoLock_Hub/supabase/tests/review-only/stage3i/:

- phase1_precreation_preflight.json
- phase1_donation_created.json
- phase1_claim_baseline.json
- phase1_target_manifest.json (inert Phase-1-only IDs/evidence)
- phase1_fixture_report.md

Existing SQL, manifests, source code and migrations were not modified. Baseline
JSON is administrative evidence containing account/location data: keep it local,
do not publish it, and do not include credentials or signed photo URLs.
