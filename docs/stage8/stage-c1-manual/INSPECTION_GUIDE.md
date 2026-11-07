# Stage C.1 Manual DEV Parity Inspection Guide

**Scope:** manual, read-only catalog and policy inspection of DEV project ref `rcgyuwiidqvrgbxswhqj`, performed by the user in Supabase Dashboard SQL Editor. No connection will be made by Codex. Run one numbered query at a time and paste its actual result here before requesting the next query.

## Safety and workflow

1. Confirm the Dashboard is connected to DEV project `rcgyuwiidqvrgbxswhqj` before running Query 1. Do not run these queries against another project.
2. Paste one numbered query from [READ_ONLY_QUERIES.sql](READ_ONLY_QUERIES.sql) into SQL Editor and run it manually.
3. Paste the complete result/error into this conversation. Do not paste credentials, keys, tokens, user rows, donation rows, or personally identifying data.
4. I will compare only that result to the local expectations, record PASS / MISMATCH / UNKNOWN in [RESULTS.md](RESULTS.md), and then provide the next query. No later query is assumed to pass.
5. If a query errors because an object is absent or inaccessible, report the error; do not create an object, change privileges, or retry using a more privileged connection. Query 4 should be run only if Query 3 confirms the function exists.

Every SQL statement in the query file is a `SELECT` over catalog metadata or policy/configuration/aggregate road metadata. No application coordination RPCs or personal application records are selected. Query 4 invokes the reviewed `fleet_private.installation_fingerprint()` function only after its presence is confirmed; repository source marks it `LANGUAGE sql STABLE SECURITY DEFINER` and its body reads catalog metadata only. If you prefer not to execute that function, skip Query 4 and the fingerprint result remains UNKNOWN.

## Classification

- **PASS:** actual result matches the relevant reviewed precondition or postcondition, including the expected migration phase.
- **MISMATCH:** actual result contradicts the reviewed contract or fingerprint. Record it; do not repair or deploy.
- **UNKNOWN:** not run, missing/inaccessible object, incomplete output, ambiguous migration phase, or no pinned post-migration fingerprint available for a needed comparison.

The earlier reported possible findings (existing `routing_private`, assignment-function drift, missing B.2/B.4.3 changes, anonymous pickup EXECUTE, and unavailable migration history) are hypotheses only. They remain UNKNOWN until their query results are supplied.

## Query sequence

1. PostgreSQL and extension versions.
2. Migration-ledger presence/columns, then migration history only if available.
3. Stage C.1 `fleet_private` schema, seal comment and fingerprint-function presence.
4. Computed C.1 installation fingerprint (conditional on Query 3).
5. `routing_private` schema, functions, owner/security/config/ACL and key objects.
6. `assign_task_to_route` phase/function fingerprint and compatibility.
7. Stage A migration prerequisite source fingerprints and coordination policy.
8. Stage B.2 helper fingerprints and road-snapshot prerequisites.
9. Stage B.4.3 Candidate 2 claim/helper fingerprints.
10. Effective function EXECUTE privileges for relevant roles.
11. Relevant RLS flags, constraints, policies, and triggers. If a dashboard row cap truncates Query 11a, use Query 11a-2 for all `routing_private` constraints and Query 11a-3 to isolate its UNIQUE constraints; neither repeats public-schema rows. If Query 11b's broad trigger inventory is truncated, use Query 11b-2, which filters internal triggers and includes `public.pickup_tasks` plus the Stage A routing tables to verify `routing_task_authority`.
12. Coordination configuration and aggregate road-network metadata.

Queries 2b and 4 are conditional: run 2b only after 2a confirms the migration ledger relation and required columns; run 4 only after Query 3 confirms `fleet_private.installation_fingerprint()` exists. Stop on a mismatch that makes later interpretation unsafe; record remaining checks UNKNOWN rather than changing the database.

## Expected local comparison anchors

- Historical chain source through 20261031: SHA-256 `4c11ca6325856406e607b35b451c41fa461e620bf584543a053d2d16f0c222c8` for the Stage A authoritative `20261031` source input.
- Stage C.1 is a separate prerequisite: Stage A 001 requires a matching `fleet_private` installation seal, not just historical migrations.
- Stage A forward files are 20261101, 20261102, 20261103. Stage A 002 depends on 001; 003 depends on 001 and 002.
- Stage B.2 20261104 expected helper source hashes: pre `geolock_resolve_road_node` `9701683fdcfeb2486c887860c6470262`, pre `geolock_road_costs` `828217e0b8faeeb3d32fa726b3e06a2a`; reviewed post hashes `3e2ae3b624e0276110b5029231671df0` and `53bac7e143510f560006bb641024c1a3`.
- Stage B.4.3 Candidate 2 expected pre hashes: `claim_listing` `2c1f60c876797c61b44b3cb43591bab8`, helper `90816e7c6db3606dc8b6451a899d8036`; Candidate 2 post hashes `c8d324772b12c843fba231e7ea733914` and `e97a3fd80673a827465f3eaa79b65903`.
- Stage B.4.3 regression composition did not include Stage B.2, so the full Stage A + B.2 + Candidate 2 sequence remains locally unverified as one composed package.

See [Stage C.0 report](../stage-c0/REPORT.md) for the full artifact SHA-256 values, function contracts, ordering dependencies and limitations.
