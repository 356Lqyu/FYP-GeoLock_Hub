# Stage C.0 — Offline DEV Parity Review Preparation

**Status: PREPARED — no database access or query execution.** This report and the companion SQL were prepared by repository inspection only. No Supabase connection, database connection, migration execution, or data write occurred. The SQL is an inspection aid and is not authorization to connect or run it.

## 1. Prepared deliverables

- [Read-only inspection SQL](DEV_PARITY_READ_ONLY.sql) — psql script enclosed in `BEGIN READ ONLY` / `ROLLBACK`. It inspects versions, migration ledger versions, selected function definitions and fingerprints, function privileges, relevant tables/constraints/triggers/RLS, policy values and road-network summary counts. It does not read user or donation records or invoke application RPCs.
- This report — baseline matrix, order/dependency plan, interpretation rules and proposed Stage C.1 scope.

The SQL has not been parsed or run against a database. It assumes the known repository schema names exist; absent objects, insufficient catalog visibility, or unsupported SQL/client behavior must be reported UNKNOWN and must not be worked around by changing database state.

## 2. Exact proposed artifact fingerprints

| Forward artifact | Repository SHA-256 | Expected precondition / result |
|---|---|---|
| Stage A `20261101_routing_authority.sql` | `fbe81acd7811e884536ed5bf125fb6b0b5eb71e6bd314872378e68b2da0ec94f` | Requires current lifecycle fingerprints, policy values, private helper ACL, and matching Stage C.1 `fleet_private` fingerprint; refuses existing `routing_private`. |
| Stage A `20261102_routing_publication.sql` | `96bc7763a30b7a641d6dc768dda4e255e12d4b9de2a5e52e8979cb0e26d1682f` | Requires Stage A authority objects and guards the original assignment function; replaces routing publication interface. |
| Stage A `20261103_routing_pickup_and_reconciliation.sql` | `6541f0a002ea56ad77c023e33ad1500ab2273cc821f87fa43d38e633bd6724ea` | Requires Stage A 001/002, lifecycle and policy fingerprints; locks `pickup_tasks` during legacy-writer cutover and installs protected pickup/reconciliation controls. |
| Stage B.2 `20261104_spatial_endpoint_validation.sql` | `7a4c71ab4ea967f894c33ab405ef8c9df5de87957e62e99433ca22268b5ecec5` | Requires October 20 helper source hashes, owner/security/config/result contracts, PostGIS/pgRouting and supported `pgr_dijkstraCost` overload, exactly one approved active operational 500 m snapshot, and 20 km / 360 min / 10 kg policy. |
| Stage B.4.3 Candidate 2 `20261105_b43_claim_and_donation_lock_no_key_update.sql` | `35f1d816b22b2a55150d6dd5d5666b2d7532e2abd80560669da1037a63139b16` | Requires the original or exact Candidate 2 bodies and expected owner/security/config/signatures for `claim_listing` and `geolock_lock_listing_donations`; captures and compares ACLs transaction-locally. |

Stage A hashes are from [the Stage A package manifest](../stage-a/package-manifest.json); Stage B.2 hash is from its local applied-artifact record; Candidate 2 hash is from [the B.4.3 diff evidence](../../../results/stage-b4-3/migration-diff-check.json). These hashes identify repository artifacts only. None establishes DEV migration history or deployed source.

## 3. Function fingerprint and contract matrix

`pg_proc.prosrc` MD5 below uses the same CRLF-to-LF normalization as the forward guards. For Stage A replacements without a pinned post-install body MD5, inspect full definitions against the exact forward artifact; do not call an unpinned value a mismatch solely because the source hash changed.

| Function(s) | Pre-migration expected | Reviewed post-migration state / contract |
|---|---|---|
| `public.claim_listing(uuid,uuid)` | `2c1f60c876797c61b44b3cb43591bab8`; `jsonb`; owner `postgres`; SECURITY DEFINER; `search_path=pg_catalog, public, extensions, pg_temp` | Candidate 2 `c8d324772b12c843fba231e7ea733914`; same contract. The approved body changes only the listing lock mode. |
| `public.geolock_lock_listing_donations(uuid,text[])` | `90816e7c6db3606dc8b6451a899d8036`; `boolean`; owner `postgres`; invoker; `search_path=pg_catalog, public, pg_temp` | Candidate 2 `e97a3fd80673a827465f3eaa79b65903`; same contract and owner-only ACL expected by local evidence. |
| `public.start_pickup(uuid)` | `e89b650c83713b04e8310f4c372f10f4`; `void`; owner `postgres`; SECURITY DEFINER; `search_path=public, extensions, pg_temp` | Replaced by Stage A 003 with routing-authorized pickup body. The forward artifact does not pin a post-install `prosrc` MD5; compare full definition, ACL and trigger dependencies to artifact. |
| `public.complete_pickup(uuid,boolean)` | `ae1b885377292281da17951cb18afd55`; `void`; owner `postgres`; SECURITY DEFINER; `search_path=public, extensions, pg_temp` | Replaced by Stage A 003 with route/task authorization and collection control; compare full definition and ACL. |
| `public.submit_claim_reconciliation(uuid,boolean,uuid)` | `246a33d552da2ac4e229fa79c357d194`; `jsonb`; owner `postgres`; SECURITY DEFINER; `search_path=pg_catalog, public, pg_temp` | Replaced compatibly by Stage A 003; guards preserve the intended recovery/helper dependencies. Compare full definition and ACL. |
| `public.recover_expired_claims(integer)` | `89e01f42d5ec23bfcbcdc47c1f4fd4e5`; `integer`; owner `postgres`; SECURITY DEFINER; `search_path=pg_catalog, public, extensions, pg_temp` | Preserved by Stage A; expected source body remains. |
| `public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)` | `67f27a85fb9129c9017bb0e9178f8ba1`; `boolean`; owner `postgres`; invoker; private execution | Preserved by Stage A and must remain non-executable to public/authenticated/service/worker roles named by its guard. |
| `public.geolock_resolve_road_node(double precision,double precision)` | `9701683fdcfeb2486c887860c6470262`; table result `(node_id text, snap_distance_m double precision, snapshot_id text)`; owner `postgres`; SECURITY DEFINER; STABLE; `search_path=public, extensions, pg_temp` | Stage B.2 result `3e2ae3b624e0276110b5029231671df0`; same signature/security/result/config. |
| `public.geolock_road_costs(bigint[],bigint[],double precision,double precision,double precision)` | `828217e0b8faeeb3d32fa726b3e06a2a`; table result `(source_node bigint, target_node bigint, road_km double precision)`; owner `postgres`; SECURITY DEFINER; VOLATILE; same search path | Stage B.2 result `53bac7e143510f560006bb641024c1a3`; same contract. |
| `public.assign_task_to_route(uuid,uuid,integer)` | Stage A 001 precondition SHA-256 of `pg_get_functiondef`: `0341fd334439b319b0bc78b8910ce2de5e2f51b5803ab4a53d0e0e89b50e11cf`; Stage A 002 guards source MD5 `047f2b5d6a4483b8cef8e3b91c9dc299` | Stage A 002 replaces direct assignment with validated publication; do not expect the precondition hash after 002. Compare to 002 body and execute ACL. |

Stage A 001 also guards `coordination_config` (`claim_lease_minutes=360`, `donation_direct_min_kg=10`, `geofence_radius_m=20000`), the C.1 schema fingerprint, and absence of an existing Stage A routing schema. Other public routing functions created by the forward package must be checked against the exact reviewed artifact and their effective privileges; they do not all have pinned post-install body MD5s. The SQL includes their key public interfaces in the privilege listing.

## 4. Migration-order dependency matrix

| Proposed order | Required before step | Ordering constraints and parity gates |
|---|---|---|
| Historical migration chain through `20261031_claim_audit_and_failure_capture.sql` | Actual recorded history and source/package match | Verify contiguous applied history, source fingerprints and required schema objects. Stage A's authoritative source SHA-256 is `4c11ca6325856406e607b35b451c41fa461e620bf584543a053d2d16f0c222c8`. Must include the 20261020 road schema/helpers and 20261031 lifecycle version expected by the later guards. |
| Stage A 001–003 (`20261101`–`20261103`) | Historical chain; Stage C.1 `fleet_private` schema and matching `geolock-stage8-c1-v2` installation fingerprint; expected roles/objects absent; expected current function bodies/config | `20261102` requires 001; `20261103` requires 001/002 and explicitly locks `pickup_tasks` before its cutover snapshot. Stage A forward files are not auto-discovered under `supabase/migrations`. Current repository notes that these are un-deployed review artifacts. |
| Stage B.2 (`20261104_spatial_endpoint_validation.sql`) | Historical October 20 spatial helpers/schema; required extensions and overload; one approved operational snapshot and unchanged policy | Changes only two spatial helper definitions. No direct function-hash dependency on Candidate 2 or Stage A routing functions. The proposed chronological sequence places B.2 after Stage A. Its migration itself was locally tested after the historical package, not after Stage A. |
| Stage B.4.3 Candidate 2 (`20261105...sql`) | Current `claim_listing`/helper source or exact Candidate 2 replay body, expected owner/security/config/argument/result metadata | Candidate 2 must come after Stage A because Stage A 001/003 source guards require the original `claim_listing` hash. Stage A does not replace the claim/helper functions; B.2 does not replace them either. The B.4.3 regression package included Stage A 001–003 but its applied manifest does **not** include B.2 20261104. Therefore the complete ordered Stage A + B.2 + Candidate 2 composition is **NOT VERIFIED** by the reviewed B.4.3 composed-run artifact. |

Stage A 001 has a separate Stage C.1 prerequisite not listed as a dated forward migration in the user's proposed four-part sequence. It requires a verified existing C.1 `fleet_private` installation and exact fingerprint; this must be treated as an explicit prerequisite, not inferred from the 20261031 chain. Stage A's `build_package.py` generates forward artifacts and the README explicitly says those are not applied migration history. Stage B.2 likewise remains outside automatic migration discovery. Deployment history must therefore be established from the target ledger plus approved release records, not filenames.

## 5. Inspection checklist and classification rules

Checklist before interpreting any fingerprint:

1. Confirm the connection was separately authorized, target identity/project ref approved, session is read-only, and no credentials or user rows are captured in output.
2. Record PostgreSQL and installed extension versions/schema locations; compare pgRouting overload signatures to B.2's accepted overload.
3. Inspect migration ledger presence and ordered versions. Supplement with approved deployment records because forward artifacts may not appear in the standard ledger.
4. Compare relevant function signatures, result types, `prosrc` hashes, owner, `prosecdef`, volatility, `proconfig`, ACL/effective EXECUTE privileges and full definitions where the forward artifacts lack post-install hashes.
5. Inspect required tables, constraints, validated state, trigger definitions/enabled state, RLS flags and policy roles/expressions for listing/donation/claim/lease/task/route/hub/inventory/road-network and `routing_private` objects.
6. Check only non-personal policy and road metadata: exact singleton coordination values, active approved road-snapshot count/snap distance and aggregate active node/edge counts. Do not read account, donor, NGO, claim, address, or pickup records.
7. Compare the target state to each step's **precondition** if unapplied or reviewed **postcondition** if applied. Stop on an unknown intermediate state; do not run migration scripts to resolve it.

Classification:

- **PASS:** all required catalog/data-policy observations for the relevant phase are visible and exactly match the reviewed pre- or postcondition, including ownership/security/ACLs and artifact fingerprints.
- **MISMATCH:** a required observation contradicts the reviewed condition, a source/ACL/trigger/policy differs, an artifact hash differs, or migration history/order conflicts. Do not attempt repair in C.1.
- **UNKNOWN:** missing/inaccessible catalogs, missing ledger without corroborating release record, unpinned post-migration definition without an artifact comparison, unclear partial application, different platform behavior, or any ambiguity in target identity. UNKNOWN is not PASS and blocks deployment consideration.

## 6. Questions requiring explicit approval before Stage C.1

No query in the companion script should be run until the user explicitly approves the connection. Before execution, obtain explicit approval for:

1. The exact target project/ref, host/region, and approved read-only credential/session identity (never provide or print the secret).
2. Whether reading `pg_get_functiondef`, effective role privileges, RLS policy expressions, migration ledger versions, coordination policy values and aggregate road-network counts is within the approved inspection scope.
3. Whether output may be saved locally, its location, and whether identifiers/project refs should be redacted before reporting.
4. Whether Stage C.1 is limited to catalog-only queries when one or more target objects are absent, or should stop immediately at the first missing prerequisite.
5. A separate later checkpoint if any MISMATCH/UNKNOWN requires expanded inspection, DEV writes, migration packaging, execution, or deployment. None is implied by this approval.

## 7. Proposed Stage C.1 execution plan (not executed)

1. After explicit approval, establish target identity using the approved read-only connection and verify `transaction_read_only=on`; stop if identity or read-only status is wrong.
2. Run the companion script once, capture sanitized raw output and client/server errors, and record tool/client version and timestamp. Do not retry with elevated privileges or broader queries without approval.
3. Compare results against the matrix above and the exact local artifact hashes; classify each item PASS/MISMATCH/UNKNOWN with evidence path and query section.
4. Check migration chain and the C.1 prerequisite separately. If Stage A is partially installed or its expected fingerprint differs, stop; do not execute or repair any artifact.
5. Produce a parity-only report. No deployment readiness/authorization is inferred from parity success; any migration execution requires a separate approval and deployment review.

## 8. Current readiness and stop condition

**NOT VERIFIED:** actual DEV migration history, deployed functions/ACLs/RLS/triggers, C.1 fingerprint, target PostgreSQL/extensions, and deployed road/config state. These require the later explicitly approved read-only inspection.

**C.0 preparation is complete.** The companion script and report are new files under this Stage C.0 directory. No existing source, migration, Stage B.3 artifact, evidence, or database was modified. Stop here and wait for explicit approval before any DEV connection.
