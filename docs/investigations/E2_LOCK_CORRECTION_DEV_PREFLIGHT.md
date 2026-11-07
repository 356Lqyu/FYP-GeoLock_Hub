# E2 coordinated lock correction — read-only DEV preflight

**Decision: NO-GO. Not ready for deployment approval.**

Inspected 5 November 2026, 11:21–11:30 MYT (03:21–03:30 UTC). The approved Supabase MCP connection reports project URL `https://rcgyuwiidqvrgbxswhqj.supabase.co`. Database postgres, current/session role postgres, PostgreSQL 17.11 on Linux. Every SQL inspection used explicit BEGIN READ ONLY and ROLLBACK; transaction_read_only was confirmed on. No application RPC, migration, function replacement, database write, backup/restore operation, worker change, Flutter change or push occurred.

The target bodies and all 29 reviewed function sources match the validated pre-correction baseline. **Three function ACLs differ**, so the unchanged validated SQL would raise CALLER_SOURCE_OR_METADATA_DRIFT before replacing either function. Current backup/isolated-restore readiness and an unused final migration version are also unverified.

## Validated artifacts unchanged

Forward: `docs/investigations/e2-shared-lock-review/proposed_migration.sql`

SHA256: `d3b466db926b389155edc499d9cc53106f81ac6cd6addc1033e01b1531e4ce70`

Rollback: `docs/investigations/e2-shared-lock-review/rollback_patch.sql`

SHA256: `521f128b12ab7ce99ad9bdc8f8113d3ee67c8409cb214bdca759110c9d744ffd`

Both files were read/hashed only. The local 41-check/275-scenario pass remains valid for its recorded local baseline; it does not establish DEV grant parity. The old claim-only candidate remains FAILED / DO NOT DEPLOY.

## Actual target definitions and metadata

| Function | Expected original MD5 | Actual DEV MD5 | Assessment |
|---|---|---|---|
| public.claim_listing(uuid,uuid) | 2c1f60c876797c61b44b3cb43591bab8 | 2c1f60c876797c61b44b3cb43591bab8 | Body matches; ACL differs |
| public.geolock_lock_listing_donations(uuid,text[]) | 90816e7c6db3606dc8b6451a899d8036 | 90816e7c6db3606dc8b6451a899d8036 | Body and guarded metadata match |

MD5 is computed exactly as the candidate does: md5(replace(prosrc,chr(13),'')). Full actual definitions/prosrc are retained in `e2-lock-dev-preflight-20261105/DEV_FUNCTION_CATALOG.json` under reviewed_source_functions. Both retain the original listing FOR UPDATE acquisition, not the locally corrected hashes c8d324772b12c843fba231e7ea733914 / e97a3fd80673a827465f3eaa79b65903.

Both are owned by postgres. Claim is SECURITY DEFINER with search_path `pg_catalog, public, extensions, pg_temp`; helper is SECURITY INVOKER with search_path `pg_catalog, public, pg_temp`. These fields match the candidate expectations.

## All 29 reviewed functions

All 29 exist. All **29/29 body hashes, owners, definer modes and proconfig/search-path arrays match**. **26/29 match every guarded field**; three differ only in ACL. Expected/actual field values are in FUNCTION_COMPARISON.json and FUNCTION_COMPARISON.csv.

| Function | Actual DEV normalized MD5 | Full guarded comparison |
|---|---|---|
| public.authorize_my_routing_candidate(uuid,uuid,timestamp with time zone) | e383a34bfadba383cf71ac07b0854a47 | Match |
| public.cancel_claim(uuid,uuid) | f24c46b0c39e945df6d2e2bfb3862573 | ACL mismatch |
| public.cancel_my_unstarted_route(uuid) | a54faa6575a55a38679749b1383f6840 | Match |
| public.claim_listing(uuid,uuid) | 2c1f60c876797c61b44b3cb43591bab8 | ACL mismatch |
| public.close_my_collected_route(uuid,boolean) | 2863ee5cf179708c023be71bb2320684 | Match |
| public.close_my_resolved_route(uuid,boolean,uuid) | 401117567094d3f9b6c17d28b8604ec1 | Match |
| public.complete_pickup(uuid,boolean) | 26f0cd8cebe783c65b45e05649693860 | Match |
| public.confirm_my_route_depot_checkpoint(uuid,boolean,uuid) | f5fd65220bf370955729286ac3f07f11 | Match |
| public.defer_my_pickup_for_reconciliation(uuid,uuid) | 749b753b6647c44457751bd628ac3637 | Match |
| public.finalize_route_resolution(uuid,bigint,uuid) | 3650767a5a9bc4928b58193321367ed8 | Match |
| public.geolock_lock_listing_donations(uuid,text[]) | 90816e7c6db3606dc8b6451a899d8036 | Match |
| public.geolock_transition_listing_donations(uuid,text,text) | 8a050031901f6796ed74210e4d5cbfec | Match |
| public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text) | 67f27a85fb9129c9017bb0e9178f8ba1 | Match |
| public.recover_expired_claims(integer) | 05fe46d8b76085f71c87fcc5f6520775 | Match |
| public.report_my_route_interruption(uuid,text,uuid) | e245085411815961f3c5bab3320b8973 | Match |
| resolution_private.lock_case(uuid) | bd6ff3d99c3804f5233212796e290925 | Match |
| public.resolve_my_claim_reconciliation(uuid,uuid) | c9c5f1636788022bf43b416de5db074e | Match |
| public.review_my_claim_reconciliation(uuid,text,bigint,uuid) | 66cec993efe030f8499e6963e428d02a | Match |
| routing_private.coord_decide(uuid,uuid) | 69fcdab19e8d9bcac672e6456cf534ff | Match |
| routing_private.legacy_complete_pickup(uuid,boolean) | ae1b885377292281da17951cb18afd55 | Match |
| routing_private.legacy_start_pickup(uuid) | e89b650c83713b04e8310f4c372f10f4 | Match |
| routing_private.lock_reconciliation_scope(uuid) | 618ea50c0c300e98098cfa62333a8608 | Match |
| routing_private.lock_route(uuid,boolean) | ebc10b61666e492afd7bbbd23f0e7448 | Match |
| routing_private.lock_route_for_recovery(uuid) | 20d815e7357e243757e1dc8b7d066a4e | Match |
| routing_private.lock_sources(uuid[]) | 52dc6262f3f85bd3c67a787401cf71aa | Match |
| public.start_pickup(uuid) | cb306433867538804b67aa1a242867b4 | Match |
| public.submit_claim_reconciliation(uuid,boolean,uuid) | de0e779f604cf9fc5459ca58b6f86ee0 | ACL mismatch |
| public.submit_claim_reconciliation_v2(uuid,boolean,integer,bigint,uuid) | 07be1bb35ed84b21f9acda69b7c35b16 | Match |
| public.submit_route_resolution_evidence(uuid,uuid,text,bigint,uuid) | 7122f77ea8ed84d28bc08fbf77192d40 | Match |

## Permission differences: deployment blocker

Every grant below is EXECUTE, grantor postgres, without grant option. These are privilege-set differences, not just ACL array order.

| Function | Validated expectation | Actual DEV |
|---|---|---|
| claim_listing | PUBLIC, postgres, authenticated | postgres, authenticated, service_role |
| cancel_claim | postgres, authenticated | postgres, authenticated, service_role |
| submit_claim_reconciliation (legacy wrapper) | postgres, authenticated | postgres, authenticated, service_role |

Effective checks confirm anon cannot execute these three functions; authenticated and service_role can. The helper remains unavailable to anon/authenticated/service_role directly. Relevant role attributes/memberships and execution checks are saved in DEV_PRIVILEGES.json. These differences do not establish an authorization bypass: the matching bodies retain their actor/ownership checks.

**Do not grant PUBLIC access or revoke DEV grants simply to satisfy the local guard.** Review the provenance/intended policy of the DEV ACLs. A separately authorized DEV-compatible candidate could preserve approved DEV grants and adjust its metadata expectations, then undergo local validation against that exact ACL baseline with a new checksum. This task does neither. The current forward SQL would safely abort before replacement; the rollback has the same baseline-ACL assumptions and must not be presumed DEV-compatible either.

## Caller and dependency review

Discovery covered **288 non-extension stored functions** across non-system namespaces. Conservative qualified/unqualified reverse-call scanning found the same **28 function names / 29 overload signatures** in the helper closure. No new stored-function caller or missing reviewed caller was found. The direct names remain claim_listing, six-argument geolock_transition_listing_donations, cancel_claim, recover_expired_claims, routing_private.lock_sources and routing_private.coord_decide.

All closure bodies match, so the detailed existing CALLER_LOCK_REVIEW.md lock-order analysis applies. Transition wrappers, legacy/managed pickup, authorization/cancellation/closure, recovery and reconciliation remain included transitively. No newly introduced stored-function caller requires further business-logic review from this discovery.

Static pg_depend checks returned no recorded dependents for the four queried claim/helper/transition signatures. PL/pgSQL string bodies are not fully tracked there, so this is not treated as proof of no callers. No referencing view or explicit dynamic-reference candidate was found. Opaque constructed names, external SQL and arbitrary administrator sessions cannot be exhaustively certified by a source scan. Catalog sources/edges and additional checks are retained in DEV_FUNCTION_CATALOG.json and DEV_ADDITIONAL_DEPENDENCIES.json.

A final read-only recheck of the **29 closure plus three listing-trigger functions** found no source/owner/definer/ACL/config changes during inspection. This is a point-in-time result, not a reservation against future DDL.

## Listing keys, FKs and triggers

All relevant inspected constraints are validated, and all 13 inspected indexes across listings/claims/requests/leases/tasks are valid/ready. Listing unique keys are listing_id (primary), donation_id for DIRECT_DONATION and batch_id for HUB_BATCH. Neither listing_status nor listing_version is a unique key. The unique active-claim index remains on listing_id for ACTIVE/RECONCILIATION_REQUIRED claims; request UUID uniqueness and claim/lease/task constraints remain present.

Five FK relationships reference listings(listing_id): claim_requests, donation_claims, claim_reconciliation_cases, listing_eligibility_refresh_jobs (ON DELETE CASCADE) and ngo_listing_road_eligibility. None references status/version. Exact definitions are in DEV_SCHEMA_CATALOG.json. No constraint validation or schema operation was executed.

The non-internal listing triggers match the candidate's reviewed operational set, all enabled, zero arguments, empty UPDATE-column vector and no WHEN qualifier:

| Trigger | Actual row/event type | Function MD5 | Guard result |
|---|---|---|---|
| trg_listing_transition | BEFORE UPDATE (19) | c65f4b675734d8c28816066ea9f05603 | Match |
| zz_listing_eligibility_generation | BEFORE INSERT OR UPDATE (23) | 3c497b7081433cefc548ac8761347096 | Match |
| trg_listing_road_eligibility | AFTER INSERT OR UPDATE (21) | 623342a706a4ca4e0a607fba4ffbf7e1 | Match |

All three functions are owned by postgres. Transition is SECURITY INVOKER/search_path public,pg_temp; generation is SECURITY DEFINER/search_path pg_catalog,public,extensions,pg_temp; after-trigger is SECURITY DEFINER/search_path pg_catalog,public,pg_temp. Operational dependency bodies/configurations match the reviewed definitions and operational trigger ACLs are owner-only.

An additional ACL distinction exists for enforce_listing_transition(): the minimal local fixture used NULL/default PUBLIC execution; DEV explicitly grants postgres/anon/authenticated/service_role. Body, owner, security mode and path match. The current candidate does not compare that trigger-function ACL, so it does not cause the current guard failure, but it must remain visible in any DEV-aligned baseline review.

These structural checks support the two key-stable lock changes. The current decisive guarded incompatibility is the three ACL mismatches. The migration was not executed to reach this conclusion.

## Migration/version history: unresolved

Supabase list_migrations returned an empty list. Independently, to_regclass('supabase_migrations.schema_migrations') returned NULL. History-table discovery found provider-component histories in auth/realtime/storage, not an application deployment ledger; component history cannot establish application version usage.

The validated coordinated SQL has **no assigned final deployment version and records no ledger entry**. The local identifier 20261105120000 belongs to the failed claim-only review proposal, not an approved coordinated release. No final coordinated receipt/version assignment was established in the local records reviewed. An absent ledger does not prove that no manual migration was published or applied; the matching current reconciliation functions already demonstrate deployed state without that ledger.

An unused intended version is therefore **NOT VERIFIED**. Reconcile manual deployment history, select/confirm a fresh coordinated version and agree its receipt/ledger-recording procedure before approval. Do not create/repair a ledger or rewrite a possibly published version during this read-only task.

## Backup and recovery: deployment blocker

Only existing status/verification JSON and documentation were read. No backup capture, pg_dump/pg_restore, archive re-verification, restore, retention action or permission change was performed. Private metadata initially inaccessible in the restricted shell was read through a read-only filesystem escalation; dump/role/password contents were not needed.

Available records show:

- 26 October/pre-freeze exports: archive checks passed; restore validation and external-service recovery NOT VERIFIED.
- 27 October pre-automatic-departure and 29 October pre-route-resolution: VERIFIED LOGICAL EXPORT / RESTORABILITY NOT VERIFIED. The later scoped archive review is not a full restore.
- Three 1 November attempts: INCOMPLETE or FAILED / NOT A VERIFIED BACKUP.
- Manual pre-reconciliation archive review: HOLD FOR INSTALLATION, restore readiness NOT VERIFIED and global roles not supplied for that artifact.
- No current post-coordination/pre-E2 DEV backup with a successful isolated restore receipt was established. Hosted backup/PITR availability is not proven by SQL catalogs or available tools; it is neither assumed absent nor treated as verified.

Sanitized evidence is in BACKUP_METADATA_REVIEW.json. BACKUP_AND_RECOVERY.md and SIMPLIFIED_RECONCILIATION_RECOVERY_PREPARATION.md provide procedures, not successful restore evidence. The pre-simplified capture mode intentionally expects the older/absent coordination baseline and is not a reviewed current-baseline capture unchanged.

The prior operator record identifies the project owner/user as self-declared recovery/deployment operator. Reconfirm the current executor, approval reference, protected backup location, recovery point and acceptable write gap. Separately approved current capture, compatible isolated restore and comparison receipts remain required. Synthetic E2 fixtures and successful code rollback are not restoration of current DEV.

Even complete schema/ACL parity would not remove this recovery blocker.

## Required next decisions; no action executed

1. Review the three ACL mismatches and trigger ACL distinction. Separately authorize any DEV-compatible guard revision and local revalidation; preserve the validated artifact and do not widen grants to make it pass.
2. Establish the final unused version and manual history/receipt procedure without repairing history in this task.
3. Separately approve current-baseline backup preparation/capture and compatible isolated restore validation, naming the operator and write-gap/cutover plan.
4. Repeat read-only preflight against the finalized candidate and recovery receipts. Only then request deployment approval. No deployment command is recommended for the currently incompatible script.

**NO-GO.** Local correctness remains LOCAL PASS, while current DEV approval is blocked by ACL incompatibility, unresolved version/history and unverified current recovery. No deployment was authorized or performed.

## Evidence added

This report and docs/investigations/e2-lock-dev-preflight-20261105/: IDENTITY_AND_HISTORY.json; DEV_FUNCTION_CATALOG.json; FUNCTION_COMPARISON.json/.csv; DEV_SCHEMA_CATALOG.json; DEV_ADDITIONAL_DEPENDENCIES.json; DEV_PRIVILEGES.json; FINAL_CATALOG_RECHECK.json; BACKUP_METADATA_REVIEW.json; READ_ONLY_QUERIES.sql; IDENTITY_AND_FINAL_RECHECK.sql; EVIDENCE_MANIFEST.json. No validated migration, rollback or historical experiment result was modified.
