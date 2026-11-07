# DEV ACL correction proposal — review only

**Status: prepared, not applied. Explicit approval to execute is still required.**

Target: isolated DEV `rcgyuwiidqvrgbxswhqj` only. The original shared project `mffccmlimmbrgasgfnnq` was not accessed and is excluded from every proposed action.

The baseline was captured on **21 October 2026 at 13:46:09 UTC / 21:46:09 Malaysia time** through the project-scoped Supabase MCP. Its URL has `read_only=true&features=database%2Cdocs`. The database reported `supabase_read_only_user`, with transaction and default transaction read-only both enabled. The database exposes no project-ref setting; scope is established by the configured endpoint. Future execution requires independent operator verification of the DEV endpoint; the SQL attestation guard is not independent identity proof.

Reference: [Stage 1–4 seven-day gap analysis](../../2026-10-21-stage1-4-seven-day-gap-analysis.md), sections E and H. Deployed catalogs take precedence over historical SQL proposals. No application code, historical migration, deployed object, grant or row was modified during preparation.

## Proposed change

1. Remove the eight recorded privileges — SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN — from `anon` and `authenticated` on the **29 public tables that currently grant them**. The other seven public tables already deny client access and receive no permission statement.
2. Remove USAGE, SELECT and UPDATE from those roles on the only public sequence, `road_network_edges_edge_id_seq`.
3. Remove only those roles' schema-specific future TABLES and SEQUENCES default grants in `public`, separately for object creators `postgres` and `supabase_admin`.

This is 60 explicit existing-object REVOKE statements and eight default-privilege REVOKE statements. There is no schema-wide wildcard revoke and no CASCADE. Every changed grant was explicit and had no grant option.

`postgres`, `service_role`, owners, RLS settings, all function definitions/configuration/ACLs, all function default privileges, role memberships, schema privileges, Storage tables/sequences/policies/triggers, and application data are preserved. The 30 Flutter RPCs with anonymous EXECUTE retain it in this first correction; [the separate review list](ANONYMOUS_RPC_REVIEW.md) also includes other anonymously executable helpers.

Direct client table/sequence access will intentionally be denied, including direct authenticated SELECT on image metadata. The inspected Flutter paths obtain public data through RPCs and use the Storage API for binary objects. This does not establish that every external consumer has the same dependencies.

## Findings and exact evidence

- [ACL inventory](ACL_INVENTORY.md): all 36 public tables, one public sequence and all six applicable schema default ACL rows.
- [RPC inventory](RPC_INVENTORY.md): exact deployed signature, owner, SECURITY DEFINER, configuration and effective EXECUTE for all 36 Flutter-called RPCs, plus source call sites.
- [Dependency review](DEPENDENCY_REVIEW.md): triggers, helpers, Storage, sequences, tests, external-consumer uncertainty and historical restore sources.
- [Raw deployed snapshot](captured/deployed-security-snapshot.json): original ACL text plus exploded grantor/grantee/privilege/grant-option entries, effective privileges, all 72 non-extension public functions and bodies, roles/memberships, policies, schemas and triggers.
- [Storage trigger definitions](captured/storage-trigger-functions.json) and [column/sequence dependencies](captured/column-and-sequence-dependencies.json).
- [Source fingerprints](captured/source-files-sha256.json): 60 inspected source files, without local env files or credentials.
- [Exact permission statements](captured/proposed-permission-statements.json): a compact review of the statements embedded in the guarded scripts.

`anon` and `authenticated` are not superusers, owners or BYPASSRLS roles. Neither has another reachable/inherited role. No PUBLIC relation/sequence grants or public column ACLs were present. All existing effective client access therefore comes from the explicit grants being removed. No global default ACL rows were present for either creator. Built-in table and sequence defaults grant the owner only; future access will not survive through PUBLIC or another inherited role. Future function defaults, including built-in PUBLIC EXECUTE, are deliberately outside this correction.

All 36 Flutter RPC names resolve to one signature each; each is owned by `postgres`, uses SECURITY DEFINER, has an explicit search path and grants authenticated/service_role EXECUTE. `postgres` is not a superuser but has BYPASSRLS and owns every public table/sequence. An explicit search path is not a complete authorization review; several paths include public/extensions. No client CREATE privilege was found in public/extensions/storage.

## Execution constraint

**The full package is not ready for execution through an ordinary postgres connection.** The deployed role graph shows that `postgres` is neither a member of nor able to SET ROLE `supabase_admin`. The latter is a managed superuser. Its four default-privilege corrections require a separately authorized Supabase administration path that actually runs as `supabase_admin`. Do not grant new membership, change ownership, disable MCP read-only protections or use a client/service JWT as a substitute.

Resolve and review that administration path **before approving execution**. The two forward transactions cannot be atomic across separate sessions. After the first commits, existing client grants and postgres defaults are corrected, but supabase_admin defaults remain broad until the second commits. Freeze schema/object creation across this window. Do not report the full correction complete unless both transactions and final checks pass.

## Files and execution order

All files live here rather than in `supabase/migrations/`, preventing accidental migration discovery. The forward scripts contain no rollback operations; restoration is separate and requires a new decision.

| Order | File | Purpose / execution role |
|---|---|---|
| 1 | `00_capture_snapshot.sql`, `00b_capture_storage_triggers.sql`, `00d_capture_column_dependencies.sql` | Read-only recapture before any future approval/application |
| 2 | `01_preflight_verify_snapshot.sql` | Read-only exact baseline comparison and admin-role capability check |
| 3 | `10_forward_postgres.sql` | Future guarded transaction as postgres: existing object grants plus postgres defaults |
| 4 | `11_verify_after_postgres.sql` | Read-only exact intermediate-state comparison |
| 5 | `20_forward_supabase_admin_defaults.sql` | Future guarded transaction as supabase_admin: its defaults only |
| 6 | `30_postchange_verify.sql` | Read-only final baseline-preservation and effective-privilege checks |
| recovery | `90_rollback_supabase_admin_defaults.sql`, then `91_rollback_postgres.sql` | Separately approved exact restoration, in reverse order |
| recovery verification | `92_verify_restored_snapshot.sql` | Read-only semantic equality with the captured baseline |

[The execution runbook](EXECUTION_ORDER.md) gives the precise order, guard settings, stop conditions and partial-application/rollback branches. Do not execute forward or rollback files during review.

## Validation and approval gates

Completed during preparation:

- SELECT-only preflight returned **true for all 12 security sections** against the exact captured baseline.
- All five post-check queries were parsed/executed as harmless reads against the unchanged database. As expected, only relation/default ACL comparisons differ from the proposed future state; ten protected sections match. Current output still shows 470 client privilege facts and 44 excessive default-grant facts. These are **pre-application observations, not successful post-deployment checks**.
- Offline replay of the actual generated permission statements matches both proposed intermediate/final states. Replaying both restoration files returns the exact captured semantic grants, grantors and grant options; untouched security sections are equal throughout.
- No full PostgreSQL DDL/PLpgSQL parser is installed locally. Forward/rollback transactions were inspected and modeled offline, **not submitted, even in a rolled-back transaction**. This is not a runtime demonstration of the application after revocation.

Evidence: [read-only validation](captured/read-only-validation.json), [post-query validation before applying](captured/postquery-preapply-validation.json), [offline validation](captured/offline-validation.json).

Before execution approval, require: resolved supabase_admin execution path; fresh matching snapshot; no concurrent DDL; review/acceptance of intentional direct-access denial; confirmation from teammates/external consumers that they do not require the removed client privileges; and baseline RPC/Storage behavior established with DEV synthetic fixtures. Stateful baseline tests need separate authorization and were not run here.

After separately approved execution, acceptance requires all final catalog checks passing, authenticated RPC behavior and Storage regressions matching the baseline, service_role verification still working, and client direct-access negatives passing. [The test checklist](TEST_CHECKLIST.md) specifies these checks. Unknown baseline failures must be distinguished from ACL regressions; automatic full historical test suites are not approval gates for unrelated requirements.

Rollback restores the excessive original grants and therefore needs its own security decision. It uses explicit captured privileges, not GRANT ALL, and restores only changed entries. ACL array order may differ while grant semantics are identical. New objects or other security changes after capture trigger the guards and require a new reviewed snapshot/rollback; do not bypass the guard or regenerate against the changed database without review.
