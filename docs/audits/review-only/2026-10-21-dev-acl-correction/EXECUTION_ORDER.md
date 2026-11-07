# Precise future execution order

**Review only. None of the forward/rollback statements below has been run. Do not apply until the user explicitly approves execution of this package.** The MCP remains read-only.

## Prerequisites before approval

1. Verify the external project connection is only `rcgyuwiidqvrgbxswhqj`. The database's project_ref setting is NULL, so it cannot attest its own project identity. Match the DEV Dashboard/project ref and direct/pooler endpoint and username without logging credentials. Never try the shared endpoint.
2. Establish a supported, separately authorized Supabase administration path that runs the admin-default statements as `supabase_admin`. The current catalog proves postgres cannot SET ROLE to it. Ordinary SQL Editor/CLI postgres access and a service_role JWT are insufficient. If no such path is available, stop before applying either part and resolve it with Supabase administration/support.
3. Review the exact 68 permission statements, snapshot, dependency exceptions and test plan. Verify required consumers use the retained roles/RPCs. Schedule a DEV DDL/object-creation freeze. Resolve unrelated baseline failures before using them as ACL acceptance criteria.
4. Keep captured files immutable for this approval. The generator is offline tooling for review, not an execution runner. Do not regenerate a new baseline after an unexpected change and silently continue under the old approval.

## SQL execution sequence after explicit approval

Use `psql -X -v ON_ERROR_STOP=1` or an equivalent tool that stops on the first error, shows every result set and preserves one session across its attestation SET commands and the selected transaction file. Do not paste all SQL files at once. The MCP will not execute write files, and its protections must not be disabled as a workaround.

1. As a read-capable DEV role, run `00_capture_snapshot.sql`, `00b_capture_storage_triggers.sql` and `00d_capture_column_dependencies.sql`. Save their outputs beside the approved snapshot under a fresh operator-selected evidence directory. Run `01_preflight_verify_snapshot.sql`; every security-section comparison must be true. Admin capability remains false for postgres and must be handled by the separate path, not “fixed” by this package.
2. As **current_user postgres** on the verified DEV connection, set these session attestations only after approval:

```sql
SET geolock.reviewed_project_ref = 'rcgyuwiidqvrgbxswhqj';
SET geolock.acl_approval = 'APPLY_DEV_ACL_PACKAGE';
```

   Run **`10_forward_postgres.sql` alone**. Its order is BEGIN → transaction-local settings → role/DEV/approval/read-only guard → full baseline guard → 60 existing-object REVOKEs → four postgres-default REVOKEs → full expected intermediate-state guard → COMMIT. No function or Storage privilege statements exist in this file. Both guards must succeed or the transaction aborts.
3. Run `11_verify_after_postgres.sql`. All 12 sections must match. Existing table/sequence client privileges are now absent; supabase_admin defaults are still unchanged. Keep DDL frozen. If checks fail, stop for investigation; do not start the next transaction.
4. Through the established authorized administration path, ensure **current_user supabase_admin**, verify the same DEV target, and set the same two session attestations. Run **`20_forward_supabase_admin_defaults.sql` alone**. Its order is BEGIN → local settings → identity/approval guard → exact intermediate-state guard → four narrowly scoped admin-default REVOKEs → final-state guard → COMMIT.
5. Run **`30_postchange_verify.sql`** in a read-capable DEV session, saving all five result sets. Require every section comparison true; all client table/sequence privileges false; all service_role values true; zero excessive future table/sequence grant rows; zero column ACL rows. Function grants/settings/definitions and Storage/policies/triggers/roles must match the baseline exactly.
6. Run only the separately authorized DEV synthetic regression checks in `TEST_CHECKLIST.md`. Save actual JWT role names, expected/actual outcomes, synthetic fixture IDs and sanitized error details. Do not log JWTs, connection strings or donor addresses. Re-run catalog verification after functional tests if schema/security changes occurred; do not expect data-changing tests themselves to change the security manifest.
7. Record both completed transactions and evidence outside historical migrations using the project's approved deployment process. The current files remain review-only; moving approved forward files into a tracked future migration location is a later authorized action. Do not replay the historical migration directory or grant restore files.
8. Resume DDL only when both creator defaults are corrected and final checks pass. Ordinary application activity can resume after acceptance; no frontend rebuild or function-body deployment is proposed.

Custom GUCs are deliberate operator attestations, not authentication, authorization escalation or project-identity proof. Identical schemas across projects could pass a catalog fingerprint; correct external endpoint selection remains mandatory. SQL guards additionally reject a contradictory database project_ref if one becomes available.

SET LOCAL settings expire at COMMIT/ROLLBACK; the two session attestations remain for that session. Close the dedicated connection after finishing. Do not reuse it for another project.

## Failure and partial application

- A guard, REVOKE, timeout or permission error aborts its transaction. Issue ROLLBACK in an interactive aborted session, or close the stop-on-error connection. Do not continue to COMMIT or remove assertions.
- If transaction 10 failed before commit: it left no committed ACL change. Transaction 20 is not eligible to run.
- If 10 committed but 20 failed/not run: existing access/postgres defaults are corrected, admin defaults remain broad. Maintain the freeze; choose either completing the separately approved admin step or a separately approved rollback of 10. This is a documented intermediate state, not completed hardening.
- If 20 committed: final-state verification is required before acceptance. Any unexpected security/catalog difference requires recapture and a new review, not an automatic “repair”.
- There is no automatic cross-session rollback, CASCADE, table lock escalation or owner/membership change. Coordinate concurrent DDL externally. Statement/lock timeouts are 60 s / 5 s per transaction; tune only through another review if necessary.

## Exact rollback, only after a separate decision

Rollback recreates the broad client privileges captured before hardening. It restores explicit privileges per object/grantee/grantor and the original no-grant-option state, not GRANT ALL. It does not rewind data, function definitions, policies or unrelated grants.

If **both forward transactions committed**:

1. As authorized `supabase_admin` on verified DEV, set `geolock.reviewed_project_ref` to the DEV ref and `geolock.acl_approval` to `RESTORE_CAPTURED_DEV_ACLS`. Run `90_rollback_supabase_admin_defaults.sql`. It requires the exact final state, restores the four changed admin default entries and checks the intermediate state.
2. As `postgres` on verified DEV, set the same rollback attestations and run `91_rollback_postgres.sql`. It requires the intermediate state, restores only the captured grants on 29 tables/one sequence and postgres defaults, then checks baseline equality.
3. Run `92_verify_restored_snapshot.sql`. Every section must match. ACL item ordering may differ, but privileges, grantors and grant options must be identical.

If **only transaction 10 committed**, skip 90 and run 91 after its guard confirms the intermediate state.

If **neither committed**, do not run rollback files.

These restoration scripts are valid only while the captured object/security inventory remains otherwise unchanged. New tables/sequences, role memberships, function/policy changes or grant drift make the guards abort. Default restoration is not retroactive to objects created during the hardened window. Inventory such objects and prepare a new exact rollback proposal; do not add blanket grants, bypass checks or run a generator against the changed DB under the old approval.
