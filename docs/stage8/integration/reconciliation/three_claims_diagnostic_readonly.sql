-- SELECT ONLY. Manually select DEV rcgyuwiidqvrgbxswhqj before executing.
-- No application RPC calls, locks, session changes or data corrections.
-- Export D01-D07 together. Results are observations, not a recovery authorization.

-- D01: Exact supplied claim/task mapping, UTC observation time and expiry.
WITH targets(claim_id,expected_task_id) AS (VALUES
 ('b4bea793-9755-470a-95bb-6b02bc0c4443'::uuid,'521ad842-5d79-4157-97f9-9fb1c73ca632'::uuid),
 ('dd1be70f-0e42-4b75-9124-cac3702d76f6'::uuid,'bbbf6b10-cb79-42ed-82cc-8b2246bf8bcb'::uuid),
 ('8161392c-e1e1-4723-a954-c80b6b61a8c7'::uuid,'270caa8b-5a6d-481c-b199-c9a47156dda2'::uuid))
SELECT statement_timestamp() AT TIME ZONE 'UTC' AS observed_at_utc,x.*,
 c.listing_id,c.ngo_user_id,c.claim_status,c.claimed_at,c.closed_at,c.close_reason,
 le.lease_id,le.lease_status,le.issued_at,le.expires_at,le.closed_at AS lease_closed_at,le.release_reason,
 le.expires_at<=statement_timestamp() AS expired_by_time,
 statement_timestamp()-le.expires_at AS elapsed_since_expiry,
 t.task_id,t.task_id=x.expected_task_id AS expected_task_matches,t.task_status,
 t.ngo_user_id AS task_ngo,t.ngo_user_id=c.ngo_user_id AS task_owner_matches_claim,
 l.source_type,l.listing_status,l.listing_version,l.listing_expires_at,
 l.listing_expires_at<=statement_timestamp() AS listing_expired_by_time,l.donation_id,l.batch_id
FROM targets x LEFT JOIN public.donation_claims c ON c.claim_id=x.claim_id
LEFT JOIN public.claim_leases le ON le.claim_id=c.claim_id
LEFT JOIN public.pickup_tasks t ON t.claim_id=c.claim_id
LEFT JOIN public.listings l ON l.listing_id=c.listing_id ORDER BY x.claim_id;

-- D02: ALL competing/historical claims and their owners, leases and tasks.
WITH targets AS (SELECT * FROM public.donation_claims WHERE claim_id IN
 ('b4bea793-9755-470a-95bb-6b02bc0c4443','dd1be70f-0e42-4b75-9124-cac3702d76f6','8161392c-e1e1-4723-a954-c80b6b61a8c7'))
SELECT old.claim_id AS inspected_claim,old.closed_at AS inspected_closed_at,c.listing_id,
 c.claim_id,c.ngo_user_id,c.claim_status,c.claimed_at,c.closed_at,c.close_reason,
 le.lease_status,le.expires_at,le.release_reason,t.task_id,t.task_status,
 c.claim_id<>old.claim_id AND c.claim_status='ACTIVE' AND c.claimed_at>=old.closed_at AS later_active_claim_candidate,
 (SELECT count(*) FROM public.donation_claims a WHERE a.listing_id=c.listing_id
  AND a.claim_status IN ('ACTIVE','RECONCILIATION_REQUIRED')) AS current_ownership_claim_count
FROM targets old JOIN public.donation_claims c ON c.listing_id=old.listing_id
LEFT JOIN public.claim_leases le ON le.claim_id=c.claim_id
LEFT JOIN public.pickup_tasks t ON t.claim_id=c.claim_id
ORDER BY old.claim_id,c.claimed_at,c.claim_id;
-- A different claim UUID can be a legitimate reclaim by the SAME NGO.
-- Later-active flag is a candidate only: require custody and chronological audit evidence below.

-- D03: Direct donation or ALL hub members (including inactive membership history).
WITH listings AS (SELECT DISTINCT l.* FROM public.listings l JOIN public.donation_claims c ON c.listing_id=l.listing_id
 WHERE c.claim_id IN ('b4bea793-9755-470a-95bb-6b02bc0c4443','dd1be70f-0e42-4b75-9124-cac3702d76f6','8161392c-e1e1-4723-a954-c80b6b61a8c7')),
sources AS (
 SELECT l.listing_id,l.source_type,l.batch_id,l.donation_id,NULL::text AS membership_status
 FROM listings l WHERE l.source_type='DIRECT_DONATION'
 UNION ALL SELECT l.listing_id,l.source_type,l.batch_id,m.donation_id,m.membership_status::text
 FROM listings l LEFT JOIN public.hub_batch_members m ON m.batch_id=l.batch_id WHERE l.source_type='HUB_BATCH')
SELECT s.*,d.donation_status,b.batch_status,hi.inventory_status,
 to_jsonb(d)->>'collection_path' AS collection_path,
 to_jsonb(d)->>'updated_at' AS donation_updated_at
FROM sources s LEFT JOIN public.donations d ON d.donation_id=s.donation_id
LEFT JOIN public.hub_batches b ON b.batch_id=s.batch_id
LEFT JOIN public.hub_inventory hi ON hi.donation_id=s.donation_id ORDER BY s.listing_id,s.donation_id;
-- Claim ownership is donation_claims.ngo_user_id; custody state alone does not establish ownership.

-- D04: Reconciliation for the whole listing, including earlier/later claims.
WITH listings AS (SELECT DISTINCT listing_id FROM public.donation_claims WHERE claim_id IN
 ('b4bea793-9755-470a-95bb-6b02bc0c4443','dd1be70f-0e42-4b75-9124-cac3702d76f6','8161392c-e1e1-4723-a954-c80b6b61a8c7'))
SELECT rc.*,e.actor_user_id,e.handover_confirmed,e.request_id,
 to_jsonb(e)->>'created_at' AS evidence_created_at,to_jsonb(e)->'response' AS recorded_response
FROM public.claim_reconciliation_cases rc LEFT JOIN public.claim_reconciliation_evidence e ON e.case_id=rc.case_id
WHERE rc.listing_id IN (SELECT listing_id FROM listings)
 OR rc.claim_id IN (SELECT c.claim_id FROM public.donation_claims c JOIN listings l ON l.listing_id=c.listing_id)
ORDER BY rc.claim_id,rc.case_id,e.actor_user_id;

-- D05: Routing references for ALL tasks belonging to the listings, not just supplied task IDs.
WITH listings AS (SELECT DISTINCT listing_id FROM public.donation_claims WHERE claim_id IN
 ('b4bea793-9755-470a-95bb-6b02bc0c4443','dd1be70f-0e42-4b75-9124-cac3702d76f6','8161392c-e1e1-4723-a954-c80b6b61a8c7'))
SELECT t.task_id,t.claim_id,t.task_status,
 (SELECT coalesce(jsonb_agg(to_jsonb(i)),'[]'::jsonb) FROM routing_private.items i WHERE i.task_id=t.task_id) AS routing_items,
 (SELECT coalesce(jsonb_agg(to_jsonb(a)),'[]'::jsonb) FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id) AS assignments,
 (SELECT coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) FROM public.pickup_route_stops s WHERE s.task_id=t.task_id) AS stops,
 (SELECT coalesce(jsonb_agg(to_jsonb(z)),'[]'::jsonb) FROM routing_private.legacy_inflight z WHERE z.task_id=t.task_id) AS legacy_capture,
 (SELECT coalesce(jsonb_agg(to_jsonb(h)),'[]'::jsonb) FROM routing_private.cancelled_stop_history h WHERE h.task_id=t.task_id) AS archived_stops,
 (SELECT coalesce(jsonb_agg(jsonb_build_object('route',to_jsonb(r),'binding',to_jsonb(b))),'[]'::jsonb)
  FROM public.pickup_routes r LEFT JOIN routing_private.bindings b ON b.route_id=r.route_id
  WHERE r.route_id IN (SELECT i.route_id FROM routing_private.items i WHERE i.task_id=t.task_id
   UNION SELECT a.route_id FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id
   UNION SELECT s.route_id FROM public.pickup_route_stops s WHERE s.task_id=t.task_id
   UNION SELECT h.route_id FROM routing_private.cancelled_stop_history h WHERE h.task_id=t.task_id)) AS routes_and_holds
FROM public.pickup_tasks t WHERE t.listing_id IN (SELECT listing_id FROM listings) ORDER BY t.claim_id,t.task_id;

-- D06: Audit timeline: claim/lease/listing/task/source/batch/route IDs plus details references.
-- Deliberately no LIMIT: preserve the full history for these three listings.
WITH listings AS (SELECT DISTINCT l.* FROM public.listings l JOIN public.donation_claims c ON c.listing_id=l.listing_id
 WHERE c.claim_id IN ('b4bea793-9755-470a-95bb-6b02bc0c4443','dd1be70f-0e42-4b75-9124-cac3702d76f6','8161392c-e1e1-4723-a954-c80b6b61a8c7')),
claims AS (SELECT c.* FROM public.donation_claims c JOIN listings l ON l.listing_id=c.listing_id),
tasks AS (SELECT t.* FROM public.pickup_tasks t JOIN listings l ON l.listing_id=t.listing_id),
ids(id) AS (
 SELECT listing_id FROM listings UNION SELECT donation_id FROM listings UNION SELECT batch_id FROM listings
 UNION SELECT m.donation_id FROM public.hub_batch_members m JOIN listings l ON l.batch_id=m.batch_id
 UNION SELECT claim_id FROM claims UNION SELECT le.lease_id FROM public.claim_leases le JOIN claims c ON c.claim_id=le.claim_id
 UNION SELECT task_id FROM tasks UNION SELECT i.route_id FROM routing_private.items i JOIN tasks t ON t.task_id=i.task_id
 UNION SELECT s.route_id FROM public.pickup_route_stops s JOIN tasks t ON t.task_id=s.task_id
 UNION SELECT a.route_id FROM public.active_task_route_assignments a JOIN tasks t ON t.task_id=a.task_id)
SELECT a.* FROM public.audit_events a WHERE a.entity_id IN (SELECT id FROM ids)
 OR a.claim_id IN (SELECT claim_id FROM claims)
 OR EXISTS (SELECT 1 FROM jsonb_each_text(coalesce(to_jsonb(a)->'details','{}'::jsonb)) d
  WHERE d.key IN ('claim_id','listing_id','task_id','donation_id','batch_id','route_id','lease_id')
  AND d.value IN (SELECT id::text FROM ids))
ORDER BY to_jsonb(a)->>'created_at',to_jsonb(a)->>'event_id';

-- D07: Recovery scheduler inspection ONLY if cron.job exists (otherwise skip).
SELECT jobid,jobname,schedule,active,username,database FROM cron.job
WHERE command ~* '\mrecover_expired_claims\M' ORDER BY jobid;
-- A paused schedule or SKIP LOCKED/backlog may explain overdue ACTIVE rows;
-- expiry does not itself update status. This query does not establish why a run was missed.
