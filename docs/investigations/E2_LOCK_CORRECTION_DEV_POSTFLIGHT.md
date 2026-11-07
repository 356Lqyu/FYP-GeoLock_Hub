# E2 lock correction — DEV post-deployment verification

5 November 2026. **Catalog deployment verification: PASS. Overall postflight: PARTIAL**, because deployment history and current verified recovery documentation remain incomplete. No unexpected functional or permission difference was detected.

## Identity and read-only scope

The approved Supabase MCP connection reports https://rcgyuwiidqvrgbxswhqj.supabase.co, matching target project **rcgyuwiidqvrgbxswhqj**. Database postgres; current_user/session_user postgres; cluster main; PostgreSQL 17.11 on Linux. Identity timestamp: **2026-11-05 04:38:56.428210 UTC / 12:38:56.428210 MYT**. Individual catalog snapshots retain their timestamps in the evidence.

All verification SQL used explicit BEGIN READ ONLY and ROLLBACK, with transaction_read_only=on confirmed. Only catalog/privilege/identity SELECTs were executed. The migration, rollback and all mutation RPCs were not executed. No claims, donations or leases were created, no DEV benchmark was run, no permissions/data/functions changed, and no backup/restore, Flutter/worker change or push occurred.

## Executed-source artifact and observed functions

Local source: docs/investigations/e2-dev-compatible-lock/proposed_migration.sql.

Verified SHA256: **655976ab697031c3025e78ad967db4e7f6a755e091a21031de2d3a8e441fee8c**, matching the supplied expected checksum. The file was read only. The user reports manual SQL Editor execution; the database catalog proves the expected resulting function state, not independently which exact file bytes were pasted or the original COMMIT response/time.

| Function | Expected corrected MD5 | Actual normalized body MD5 | Result |
|---|---|---|---|
| public.claim_listing(uuid,uuid) | c8d324772b12c843fba231e7ea733914 | c8d324772b12c843fba231e7ea733914 | PASS |
| public.geolock_lock_listing_donations(uuid,text[]) | e97a3fd80673a827465f3eaa79b65903 | e97a3fd80673a827465f3eaa79b65903 | PASS |

Normalization is md5(replace(prosrc,chr(13),'')). Each actual body contains exactly one corrected listing statement:

```sql
select * into v_l from public.listings where listing_id=p_listing for no key update;
```

Neither body retains the original exact FOR UPDATE statement at that listing acquisition. Other intended donation/request/batch/inventory FOR UPDATE statements remain present and unchanged. Actual prosrc and pg_get_functiondef output are saved under reviewed_source_functions in e2-lock-dev-postflight-20261105/FUNCTION_CATALOG.json.

## Preflight comparison: bodies and metadata

Compared against docs/investigations/e2-lock-dev-preflight-20261105/:

- All **29 reviewed functions still exist**.
- Across all **288 captured non-extension function metadata records**, exactly two normalized source hashes changed: claim_listing and geolock_lock_listing_donations. No function appeared/disappeared.
- The other 27 reviewed bodies and all other captured function hashes are unchanged.
- All captured owners, definer modes, search-path/config arrays, raw ACLs and expanded ACL grants remain unchanged, including those of both corrected functions.
- Relevant role attributes/memberships and the separately queried effective execution permissions also remain unchanged.

Claim remains owner postgres / SECURITY DEFINER / search_path pg_catalog,public,extensions,pg_temp. Helper remains owner postgres / SECURITY INVOKER / search_path pg_catalog,public,pg_temp. Both return/type/security contracts are consistent with the reviewed definitions; the deployed body hashes match the locally validated correction.

### Protected function permissions

| Function | postgres EXECUTE | authenticated EXECUTE | service_role EXECUTE | anon EXECUTE |
|---|---|---|---|---|
| claim_listing(uuid,uuid) | Yes | Yes | Yes | No |
| cancel_claim(uuid,uuid) | Yes | Yes | Yes | No |
| submit_claim_reconciliation(uuid,boolean,uuid) | Yes | Yes | Yes | No |

All three retain ACL `{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}`. postgres execution is explicitly present in the ACL and ownership; effective authenticated/service_role/anon checks confirm the table above. PUBLIC execution has not been introduced. The helper retains owner-only `{postgres=X/postgres}`; anon, authenticated and service_role cannot directly execute it. No grant was changed by this inspection.

The full comparison and individual permission rows are in COMPARISON.json and PRIVILEGES.json. The earlier local-baseline ACL mismatches are not post-deployment drift: the DEV-compatible candidate intentionally preserved actual DEV permissions, and those remain identical to preflight.

## Triggers, constraints, indexes and catalog-level atomic protection

The inspected index, constraint and listing-trigger catalogs are exactly equal to preflight, including trigger definitions/functions, security/configuration and ACLs. All 13 captured indexes remain valid/ready, and all 35 captured constraints remain validated.

- listings_pkey remains unique on listing_id. Direct-donation and batch listing unique indexes remain unchanged.
- **ux_active_claim** remains a valid/ready unique index on donation_claims(listing_id), filtered to ACTIVE or RECONCILIATION_REQUIRED. Duplicate active ownership remains structurally prohibited.
- claim_requests primary request UUID uniqueness, donation_claims request uniqueness, request/result FKs and claim/lease/task relationships remain unchanged. The pinned claim body retains actor/request advisory locking, digest/payload checks and stored-result replay.
- Lease primary/claim uniqueness, FK relationships and expiry/state checks remain unchanged. Claim creation/recovery/cancellation/reconciliation bodies retain their tested guards; recover_expired_claims source is unchanged.
- trg_listing_transition remains enabled BEFORE UPDATE, enforcing the reviewed status transitions. Its function hash remains c65f4b675734d8c28816066ea9f05603.
- zz_listing_eligibility_generation and trg_listing_road_eligibility remain enabled with the same event configurations and hashes 3c497b7081433cefc548ac8761347096 / 623342a706a4ca4e0a607fba4ffbf7e1.
- The corrected helper retains sorted source-donation/inventory locks, batch membership/custody validation and all other logic.

**Assessment: PASS at catalog level.** The deployed definitions and constraints preserve the previously validated atomic ownership/idempotency/lease design while incorporating the coordinated key-stable listing locks. This is **not live concurrency testing on DEV**. No claims or benchmarks were run here, and absence of every possible future lifecycle deadlock is not claimed. The prior fresh local 43-check/275-scenario candidate validation supplies runtime evidence for the matching code, with its documented local adapters and limits.

## Deployment history

The Supabase migration list remains empty and supabase_migrations.schema_migrations remains absent, exactly as in preflight. Provider auth/realtime/storage history tables are not application deployment records. No new durable E2 manual execution receipt was found in the reviewed workspace; the existing reconciliation receipt file is only a template. The user's statement of manual execution and this postflight are retained as operator assertion plus observed state, not substituted for the missing original execution receipt.

**Status: migration/version/execution receipt missing or not supplied.** No migration record was inserted, no ledger was created and no history was backfilled. A separately approved record should retain the actual operator/time, project, executed SQL SHA256, chosen version/history basis, execution result and this verification reference. Do not infer that the SQL failed merely because the ledger is absent: the corrected deployed bodies are positively verified.

## Recovery readiness

No current DEV backup with a successful compatible isolated restore is established in the reviewed documentation. Available backup verification records are historical and state restore validation NOT VERIFIED; the earlier incomplete/failed attempts do not fill that gap. No new successful restore/deployment receipt was found in the reviewed workspace. Provider-managed backups or operator-held artifacts outside these records are not assumed absent, but their availability/recoverability is unverified.

No backup, restore, capture or rollback operation occurred. The review-only rollback path remains docs/investigations/e2-dev-compatible-lock/rollback_patch.sql; it was not executed. It restores the original deadlock-prone bodies and is code rollback, not recovery of current business data. Current recovery operator, verified recovery point, isolated restore receipt and write-gap/service-reconciliation plan remain outstanding documentation requirements.

## Decision and evidence

**Function deployment and catalog preservation: PASS. Overall: PARTIAL** due to missing deployment history and unverified current recovery readiness. There is no observed reason in this catalog verification to rerun the migration or execute rollback. This report does not authorize additional live testing, metadata repair or deployment.

Added this report and e2-lock-dev-postflight-20261105/{IDENTITY_HISTORY.json,FUNCTION_CATALOG.json,SCHEMA_CATALOG.json,DEPENDENCIES.json,PRIVILEGES.json,COMPARISON.json,RECOVERY_REVIEW.json,READ_ONLY_QUERIES.sql,EVIDENCE_MANIFEST.json}. These separate read-only receipts contain the actual inspected metadata and SQL. Existing migration/rollback files, prior reports and benchmark evidence remain unchanged.
