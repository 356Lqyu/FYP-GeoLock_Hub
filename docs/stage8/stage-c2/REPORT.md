# GeoLock Hub — Stage C.2 Read-Only Compatibility and Security Investigation

**Connection identity verification: COMPLETE. Compatibility investigation: NOT RESUMED in this task.**

## Stage C.2 connection identity verification addendum

The registered Codex MCP configuration at [config.toml](C:/Users/User/.codex/config.toml) contains `[mcp_servers.supabase]` with URL `https://mcp.supabase.com/mcp?project_ref=rcgyuwiidqvrgbxswhqj&read_only=true&features=database,debugging`. The active tool namespace is `mcp__supabase`, matching the registered server name `supabase`. This reliably traces the active MCP connection to the authorized project-scoped endpoint. No other Supabase project was selected or accessed.

A safety-only read-only SQL probe confirmed database `postgres`, role/session role `supabase_read_only_user`, and `transaction_read_only=on`. The role is not superuser, has no database CREATE, role creation, database creation, replication, or schema CREATE capability, and has no INSERT, UPDATE, DELETE, TRUNCATE or TRIGGER privilege on application/private tables. It does have `BYPASSRLS`. The only non-system relation with any effective write privilege is `cron.job_run_details`, with DELETE only. Because the session is transaction-read-only and the registered MCP endpoint has `read_only=true`, this is a restricted connection rather than an unrestricted write path; nevertheless, its SQL ACL is not globally zero-write.

**Connection-safety gate: SATISFIED for identity and enforced read-only access.** The project ref is established from the registered project-scoped endpoint, not inferred from PostgreSQL properties or database contents. The database probe inspected role and privilege metadata only. No Stage C.2 compatibility/security investigation was resumed in this task.

## Connection-safety result

**CONFIRMED — authorized project endpoint and enforced read-only session.** The raw SQL MCP capability is scoped to the registered endpoint above; its configuration has `read_only=true`, and PostgreSQL reports `transaction_read_only=on`. The role has no write privileges on application/private tables. Its one narrow DELETE grant on `cron.job_run_details` means its catalog ACLs are not globally zero-write, but the read-only MCP setting and read-only transaction prevent a write path through this session. The role also has `BYPASSRLS`, so inspection remains limited to catalog/privilege metadata as authorized.

## Findings

All items below are **NOT VERIFIED in Stage C.2**. Stage C.1 evidence is not treated as fresh Stage C.2 confirmation.

| Requested investigation | Result | Reason |
|---|---|---|
| `routing_private` inventory, signatures, owners, security modes, search paths, marker, and Stage A baseline comparison | NOT VERIFIED | No further catalog queries were run. |
| Whether Stage A first-install guard fails or an upgrade migration is required | NOT VERIFIED | Requires the authorized target’s current schema and function metadata. |
| Exact `assign_task_to_route` definition differences and routing/transaction impact | NOT VERIFIED | Prior Stage C.1 recorded a definition-hash mismatch, but did not perform the requested exact comparison. |
| Anonymous pickup EXECUTE, function source, authentication/ownership/route checks, and mutation ordering | NOT VERIFIED | No fresh privilege or source inspection was run. |
| Migration API and ledger visibility cause; alternative history evidence | NOT VERIFIED | No fresh checks or deployment-document review were performed under this blocked Stage C.2 connection. |
| RLS policy visibility cause | NOT VERIFIED | No fresh policy catalog checks were run. |
| `fleet_private` marker and fingerprint confirmation without invoking restricted functions | NOT VERIFIED | No additional catalog inspection was run. |

## Prior Stage C.1 context (not revalidated)

The Stage C.1 result reported a read-only Supabase role and `transaction_read_only=on`, an empty migration API inventory, an absent `supabase_migrations.schema_migrations` relation, a `fleet_private` marker matching the expected v2 marker, an existing unmarked `routing_private` schema, an `assign_task_to_route` fingerprint mismatch, original rather than corrected fingerprints for the spatial and Candidate 2 functions, and anonymous EXECUTE on the two pickup functions. These remain prior-session observations only and are not promoted to Stage C.2 findings.

## Next checkpoint

The connection-safety gate is now satisfied. The Stage C.2 compatibility and security investigation was not resumed in this task, as instructed. It can continue under the prior Stage C.2 approval using this verified endpoint and the existing read-only restrictions. No correction or deployment is recommended from this connection-only verification.

No database changes, migrations, privilege changes, application RPCs, personal-record reads, Flutter changes, Stage B.3 changes, or Chapter 5 experiments were performed. Database access in this task was limited to the connection identity/read-only probe and effective privilege metadata checks.
