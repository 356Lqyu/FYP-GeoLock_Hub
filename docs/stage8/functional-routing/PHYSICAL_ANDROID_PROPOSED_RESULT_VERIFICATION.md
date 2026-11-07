# Physical Android Proposed result verification

27 October 2026. **PASS for the physical Android saved-result interface.**
The user reported the observations below after testing the verified Proposed-only
APK on their physical phone. Codex did not independently view screenshots or a
screen recording. Separate fresh DEV checks used a READ ONLY transaction and
ROLLBACK; local presentation calculations used the actual saved snapshot/plan.
No current eligible-task weights or locations were substituted.

## Physical UI observations reported by the user

- Planner ACTIVE; authenticated saved Proposed result loaded successfully.
- CANDIDATE_READY and ATTESTED displayed; only Proposed results visible.
- Vehicle V2; distance 7.21 km; duration 33.55 minutes; assigned load 110 kg.
- Two ordered pickup locations; Google Maps tiles, numbered markers 1 and 2,
  and the blue depot marker all visible.
- Road geometry unavailable message displayed correctly. This is a markers-only
  map, with no claim of exact road geometry or live Google travel costs.

These later user observations supersede the implementation-time limitation that
phone map rendering and authenticated saved-result retrieval were not yet tested.

## Immutable candidate and source

- Candidate: a00bc45c-33f9-4193-8cb6-f313d92e4b5c.
- Snapshot: f597018e-e068-486f-a99b-4e194a2c57dc.
- Request: d184df24-3e54-4935-80a9-5efe9392f1ab.
- Snapshot cutoff: 2026-10-27T12:40:15.988752Z (20:40:15.988752 MYT).
- Candidate digest and stored attestation digest both:
  f27336b441ecc1e180102ca85bea9078864f8f01cfba0a04b00d6bf097e5c23e.
- Candidate plan equals the previously captured plan. No replacement or new
  candidate, snapshot, attestation or routing record was created by this check.

## Weight discrepancy resolved

| Assigned stop | Snapshot task weight | Snapshot listing/donation weight | Candidate cumulative load |
|---|---:|---:|---:|
| 1 — task daa38fdb-ce05-4ca2-aca2-b808cfeb5216 | 50 kg | 50 kg | 50 kg |
| 2 — task 9f03a7ec-d399-4fed-a949-971928713ffd | 60 kg | 60 kg | 110 kg |

The summary sums the assigned snapshot task weights: **50 + 60 = 110 kg**.
Stop 2 adds 110 - 50 = 60 kg. Its 110 kg cumulative load is not an individual
donation weight. An earlier description of 50 + 110 = 160 kg does not describe
this snapshot; the available description alone does not identify a separate test.
The two other observations in the snapshot are not assigned route stops and were
not included in the route-load calculation.

## Snapshot coordinate binding

| Marker | Road node | Latitude | Longitude |
|---|---|---:|---:|
| Blue NGO depot — start/return | 1755847853 | 3.2175514451822 | 101.623839922249 |
| Pickup 1 | 5724643871 | 3.21012303406445 | 101.612223945558 |
| Pickup 2 | 2308277369 | 3.2163744 | 101.6166429 |

The presentation depot equals the saved snapshot NGO depot. Candidate start/end
nodes and the saved vehicle depot node all match it. Each pickup marker matches
the ordered candidate node and its snapshot task/listing node. Latitude/longitude
equal the snapshot listing and corresponding authorized donation coordinates.
Direct-donation location IDs also match the snapshot donation IDs. Flutter uses
these presentation coordinates directly for marker positions; current profile or
eligible-task coordinates are not used as replacements.

## FYP evidence verdict and limits

**Retain this candidate as successful controlled DEV planning and physical Android
saved-result/UI evidence.** Preserve the exact snapshot, matrix, candidate,
attestation, solver settings and all four research-method outputs. Describe it as
an independently attested feasible incumbent. The stored timeout flag is true,
secondary_optimal is false and no secondary optimality gap is established; do not
claim globally optimal operating cost or omit the time-limit qualification.

This does not demonstrate database authorization, dispatch, physical handover,
completed pickup or depot return. At the fresh read-only check there were four
snapshots, one candidate, one validation, zero routes and zero active assignments.
Displaying an old ATTESTED receipt does not establish current dispatch eligibility.
No comparative experimental superiority follows from this one UI demonstration.

## Evidence files

- results/proposed-only-routing/physical-android-ui-verification.json records the
  user-reported physical device observations and their evidence scope.
- physical-android-snapshot-inspection.json and .sql preserve the actual immutable
  DEV facts and read-only query.
- physical-android-weight-marker-verification.json records exact arithmetic,
  coordinate checks, digest agreement and scope limitations.
- physical-android-evidence-checksums.json provides SHA-256 integrity checks for
  these four evidence files. Those file hashes are distinct from database digests.

No route generation, DEV business writes, dispatch authorization, pickup action,
recovery, graph probe or service restart was performed during this verification.
