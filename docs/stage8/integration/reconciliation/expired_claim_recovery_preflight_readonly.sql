-- SELECT ONLY; DEV rcgyuwiidqvrgbxswhqj. Run immediately before separately approved execution.
-- Also export three_claims_diagnostic_readonly.sql D01-D06 for full audit/routing evidence.
-- No application RPC is called. Catalog observations cannot establish lock-time safety.

-- P01: Protected function identity/security; require reviewed values, not just presence.
SELECT current_database(),session_user,current_user,statement_timestamp() AS database_time,
 p.oid::regprocedure AS signature,pg_get_userbyid(p.proowner) AS owner,p.prosecdef,p.proconfig,p.proacl,
 pg_get_function_arguments(p.oid) AS arguments,pg_get_function_result(p.oid) AS result,
 md5(replace(p.prosrc,E'\r\n',E'\n')) AS body_md5,pg_get_functiondef(p.oid) AS definition
FROM pg_proc p WHERE p.oid=to_regprocedure('public.recover_expired_claims(integer)');
-- Expected: postgres owner, SECURITY DEFINER, integer result, p_limit integer DEFAULT 100,
-- search_path=pg_catalog, public, extensions, pg_temp; ACL postgres/service_role EXECUTE only;
-- body_md5=5ff6d8719db9681aae6f444b89dfbaee. Verify actual session_user=postgres for SQL Editor.

-- P02: ENTIRE ACTIVE/ACTIVE queue, including future expiries (no LIMIT and no SKIP LOCKED).
SELECT c.claim_id,c.listing_id,le.lease_id,le.expires_at,
 le.expires_at<=statement_timestamp() AS currently_batch_eligible,
 c.claim_id IN ('b4bea793-9755-470a-95bb-6b02bc0c4443','dd1be70f-0e42-4b75-9124-cac3702d76f6') AS intended_target
FROM public.donation_claims c JOIN public.claim_leases le ON le.claim_id=c.claim_id
WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' ORDER BY le.expires_at,c.claim_id;
-- Any unrelated row blocks the exact-two guarded option, even if not yet expired.
-- Future rows can expire between a SELECT preflight and a later call using clock_timestamp().

-- P03: Conservative release assessment, reproducing the helper's data checks without calling it.
WITH targets(claim_id,task_id) AS (VALUES
 ('b4bea793-9755-470a-95bb-6b02bc0c4443'::uuid,'521ad842-5d79-4157-97f9-9fb1c73ca632'::uuid),
 ('dd1be70f-0e42-4b75-9124-cac3702d76f6'::uuid,'bbbf6b10-cb79-42ed-82cc-8b2246bf8bcb'::uuid)),
checks AS (
SELECT x.claim_id,x.task_id,c.listing_id,l.source_type,c.claim_status,le.lease_status,t.task_status,
 le.expires_at,l.listing_expires_at,l.listing_status,
 coalesce(c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' AND le.expires_at<=statement_timestamp(),false) AS expired_active_pair,
 coalesce(t.task_id=x.task_id AND t.claim_id=c.claim_id AND t.listing_id=c.listing_id
  AND t.ngo_user_id=c.ngo_user_id AND t.task_status='CONFIRMED',false) AS exact_task_ready,
 coalesce(l.listing_status='CLAIMED' AND (l.listing_expires_at IS NULL OR l.listing_expires_at>statement_timestamp()),false) AS listing_reopenable,
 NOT EXISTS(SELECT 1 FROM public.claim_reconciliation_cases rc WHERE (rc.claim_id=c.claim_id OR rc.listing_id=c.listing_id)
  AND rc.case_status IN ('OPEN','MANUAL_REVIEW')) AS no_unresolved_case,
 NOT EXISTS(SELECT 1 FROM public.donation_claims other WHERE other.listing_id=c.listing_id AND other.claim_id<>c.claim_id
  AND other.claim_status IN ('ACTIVE','RECONCILIATION_REQUIRED')) AS no_competing_owner,
 NOT EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id)
  AND NOT EXISTS(SELECT 1 FROM public.pickup_route_stops s WHERE s.task_id=t.task_id)
  AND NOT EXISTS(SELECT 1 FROM routing_private.items i WHERE i.task_id=t.task_id AND i.released_at IS NULL) AS no_route_reference,
 CASE WHEN l.source_type='DIRECT_DONATION' THEN EXISTS(SELECT 1 FROM public.donations d
  WHERE d.donation_id=l.donation_id AND d.donation_status='CLAIMED' AND d.collection_path='DIRECT_PICKUP')
 WHEN l.source_type='HUB_BATCH' THEN EXISTS(SELECT 1 FROM public.hub_batches b WHERE b.batch_id=l.batch_id
  AND b.batch_status='PUBLISHED' AND b.batch_donation_count>0
  AND b.batch_donation_count=(SELECT count(*) FROM public.hub_batch_members m WHERE m.batch_id=b.batch_id AND m.membership_status='ACTIVE')
  AND NOT EXISTS(SELECT 1 FROM public.hub_batch_members m LEFT JOIN public.donations d ON d.donation_id=m.donation_id
   WHERE m.batch_id=b.batch_id AND m.membership_status='ACTIVE' AND (d.donation_id IS NULL
    OR d.donation_status IS DISTINCT FROM 'CLAIMED' OR d.collection_path IS DISTINCT FROM 'HUB_COLLECTION'
    OR NOT EXISTS(SELECT 1 FROM public.hub_inventory hi WHERE hi.donation_id=m.donation_id
     AND hi.hub_id=b.hub_id AND hi.inventory_status='BATCHED'))))
 ELSE false END AS custody_ready
FROM targets x LEFT JOIN public.donation_claims c ON c.claim_id=x.claim_id
LEFT JOIN public.claim_leases le ON le.claim_id=c.claim_id
LEFT JOIN public.pickup_tasks t ON t.claim_id=c.claim_id
LEFT JOIN public.listings l ON l.listing_id=c.listing_id)
SELECT *,expired_active_pair AND exact_task_ready AND listing_reopenable AND no_unresolved_case
 AND no_competing_owner AND no_route_reference AND custody_ready AS conservative_release_candidate
FROM checks ORDER BY claim_id;
-- Exactly two rows; every boolean true. This is stricter than recovery, not a promise of its outcome.

-- P04: Export immutable comparison evidence for the historical claim, its leases and task.
-- Re-run unchanged after recovery; each row hash and row count must match the exported baseline.
SELECT 'claim' AS object_type,c.claim_id::text AS id,md5(to_jsonb(c)::text) AS row_md5,to_jsonb(c) AS record
FROM public.donation_claims c WHERE c.claim_id='8161392c-e1e1-4723-a954-c80b6b61a8c7'
UNION ALL SELECT 'lease',le.lease_id::text,md5(to_jsonb(le)::text),to_jsonb(le)
FROM public.claim_leases le WHERE le.claim_id='8161392c-e1e1-4723-a954-c80b6b61a8c7'
UNION ALL SELECT 'task',t.task_id::text,md5(to_jsonb(t)::text),to_jsonb(t)
FROM public.pickup_tasks t WHERE t.claim_id='8161392c-e1e1-4723-a954-c80b6b61a8c7'
ORDER BY object_type,id;
-- Its shared listing/donation SHOULD change with recovery of the newer claim; do not require them unchanged.

-- P05: Route/vehicle holds relevant to either listing, including historical route evidence.
WITH tasks AS (SELECT t.* FROM public.pickup_tasks t WHERE t.listing_id IN
 (SELECT c.listing_id FROM public.donation_claims c WHERE c.claim_id IN
 ('b4bea793-9755-470a-95bb-6b02bc0c4443','dd1be70f-0e42-4b75-9124-cac3702d76f6'))),
routes AS (SELECT i.route_id FROM routing_private.items i JOIN tasks t ON t.task_id=i.task_id
 UNION SELECT a.route_id FROM public.active_task_route_assignments a JOIN tasks t ON t.task_id=a.task_id
 UNION SELECT s.route_id FROM public.pickup_route_stops s JOIN tasks t ON t.task_id=s.task_id)
SELECT r.route_id,r.route_status,r.vehicle_id,b.closed_at,b.started_at
FROM public.pickup_routes r LEFT JOIN routing_private.bindings b ON b.route_id=r.route_id
WHERE r.route_id IN (SELECT route_id FROM routes);
-- New nonterminal route or open binding: STOP, even though recovery does not explicitly inspect bindings.

-- P06: Scheduler inspection (only run if cron.job exists). Keep every matching job disabled.
SELECT jobid,jobname,schedule,active,username,database FROM cron.job
WHERE jobname='geolock-expired-claim-recovery' OR command ~* '\mrecover_expired_claims\M';
-- Also export three_claims_diagnostic_readonly.sql D06 as the pre-run audit-event baseline.
