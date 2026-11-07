# Stage C.3 — Manual Read-Only Prerequisite Inspection

**DEV project reference:** `rcgyuwiidqvrgbxswhqj`  
**Execution:** User-run manually in the Supabase Dashboard SQL Editor. Codex will not connect to Supabase or execute SQL.

## Scope and safety

This package prepares the read-only evidence needed before a separate Stage A 003 upgrade design. It does not approve or execute a migration. Run only the currently supplied numbered query, paste its actual result, and wait for comparison before requesting the next query. Queries are prepared incrementally to avoid unreviewed or excessive catalog scans.

Query 1 is a catalog-only `SELECT` over `pg_proc` and role metadata exposed through function ACLs. It resolves the exact 28 function signatures declared or replaced by reviewed Stage A 001/002 and reports their actual source-body MD5, identity arguments, result type, owner, SECURITY DEFINER flag, volatility, configuration, and ACL. It invokes no functions and reads no application tables or records. Its output is one row per expected signature (28 rows); absent signatures are reported rather than silently omitted. The complete 28-row result has now been compared against the reviewed SQL; all 28 function definitions and reported metadata/ACLs match, as recorded in `RESULTS.md`.

The expected phase distinction is important: `public.assign_task_to_route(uuid,uuid,integer)` is expected at its **post-002** fail-closed body, not at the pre-001 definition. The other 27 entries are expected 001/002 definitions, subject to phase-aware comparison against the migration source. A matching body hash alone does not prove full schema or deployment compatibility.

## Incremental inspection sequence

Query 2 was manually executed by the user. Its complete 11-row JSON has now been compared against reviewed Stage A 001 definitions. All 11 table definitions, including 75 columns, 21 indexes, 35 validated constraints, and eight application triggers, match. The earlier report of 19 indexes was a recount error; see the reconciliation in `RESULTS.md`.

Query 3 was manually executed and its scoped PASS is recorded in `RESULTS.md`: no table-level INSERT/UPDATE/DELETE/TRUNCATE privilege was found for the six inspected roles on `routing_private.items` or `routing_private.legacy_inflight`. This does not cover other roles or column privileges.

Query 4 was manually executed; the scoped ACL and role-membership results are recorded in `RESULTS.md`. The direct `service_role` grant matches the later migration's documented preserved reconciliation grant set; this does not establish global privilege isolation.

Query 5 was manually executed by the user and its ten zero counts are recorded in `RESULTS.md`. They establish only the inspected point-in-time aggregate conditions, not future cutover safety or deployment authorization.

Query 6 was manually executed by the user and returned seven catalog objects across `auth`, `realtime`, and `storage`. These are Supabase internal component migration objects, not evidence that GeoLock Hub Stage A migrations were applied. Application migration history remains UNKNOWN. No further query against those internal tables is prepared.

Only the next approved query will be presented for manual execution; later queries will not be executed by Codex.

## Result handling

Classify each inspected requirement as **PASS**, **MISMATCH**, or **UNKNOWN**. Missing objects are not privilege mismatches; null `has_*_privilege` results for absent objects mean the object is absent. Do not infer application behavior, historical migration application, or safe upgradeability from catalog presence alone. Preserve user-reported output and truncation limits in `RESULTS.md`.
