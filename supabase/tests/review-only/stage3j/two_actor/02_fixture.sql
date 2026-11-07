-- SELECT ONLY. psycopg named parameter `listing` is a canonical UUID.
-- To use manually in SQL Editor, replace %(listing)s with a quoted approved
-- listing UUID in BOTH occurrences. Never use the retained Stage 3I listing.
WITH target AS (SELECT * FROM public.listings WHERE listing_id=%(listing)s::uuid)
SELECT jsonb_build_object(
 'listing',(SELECT jsonb_build_object('listing_id',listing_id,'donation_id',donation_id,
   'source_type',source_type,'listing_status',listing_status,'listing_version',listing_version,
   'listing_expires_at',listing_expires_at,'pickup_road_node_id',pickup_road_node_id,
   'listing_weight_kg',listing_weight_kg,
   'eligibility_generation',eligibility_generation) FROM target),
 'donation',(SELECT jsonb_build_object('donation_id',d.donation_id,'title',d.title,
   'donation_status',d.donation_status,'collection_path',d.collection_path)
   FROM public.donations d JOIN target l USING(donation_id)),
 'claims',(SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.claim_id),'[]'::jsonb)
   FROM public.donation_claims c JOIN target l USING(listing_id)),
 'leases',(SELECT coalesce(jsonb_agg(to_jsonb(le) ORDER BY le.lease_id),'[]'::jsonb)
   FROM public.claim_leases le JOIN public.donation_claims c USING(claim_id) JOIN target l USING(listing_id)),
 'tasks',(SELECT coalesce(jsonb_agg(jsonb_build_object('claim_id',t.claim_id,'task_id',t.task_id,
   'task_status',t.task_status,'ngo_user_id',t.ngo_user_id,'pickup_road_node_id',t.pickup_road_node_id,
   'load_kg',t.load_kg) ORDER BY t.task_id),'[]'::jsonb) FROM public.pickup_tasks t JOIN target l USING(listing_id)),
 'cases',(SELECT coalesce(jsonb_agg(to_jsonb(rc) ORDER BY rc.case_id),'[]'::jsonb)
   FROM public.claim_reconciliation_cases rc JOIN target l USING(listing_id)),
 'failures',(SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY f.failure_id),'[]'::jsonb)
   FROM public.operation_failure_events f JOIN target l USING(listing_id)),
 'route_count',(SELECT count(*) FROM public.pickup_tasks t JOIN target l USING(listing_id)
   WHERE EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id)
      OR EXISTS(SELECT 1 FROM public.pickup_route_stops s WHERE s.task_id=t.task_id)),
 'audits',(SELECT coalesce(jsonb_agg(jsonb_build_object('event_id',a.event_id,'event_type',a.event_type,
   'claim_id',a.claim_id,'lease_id',a.lease_id,'request_id',a.request_id,'outcome',a.outcome,
   'actor_user_id',a.actor_user_id,'actor_role',a.actor_role,'entity_type',a.entity_type,'entity_id',a.entity_id,
   'correlation_id',a.correlation_id,'software_version',a.software_version,
   'configuration_version',a.configuration_version,'details',a.details,'occurred_at',a.occurred_at,
   'previous_state',a.previous_state,'requested_state',a.requested_state,
   'resulting_state',a.resulting_state,'reason_code',a.reason_code) ORDER BY a.event_id),'[]'::jsonb)
   FROM public.audit_events a WHERE a.entity_id IN(SELECT listing_id FROM target UNION SELECT donation_id FROM target)
     OR a.claim_id IN(SELECT c.claim_id FROM public.donation_claims c JOIN target l USING(listing_id))),
 'photo_count',(SELECT count(*) FROM public.donation_images i JOIN target l USING(donation_id)),
 'item_count',(SELECT count(*) FROM public.donation_items i JOIN target l USING(donation_id)),
 'refresh_enqueued',EXISTS(SELECT 1 FROM public.listing_eligibility_refresh_jobs r JOIN target l USING(listing_id)
   WHERE r.eligibility_generation=l.eligibility_generation AND r.expected_road_node_id=l.pickup_road_node_id
   AND EXISTS(SELECT 1 FROM public.road_network_coverage c WHERE c.network_snapshot_id=r.expected_snapshot_id
     AND c.active_flag AND c.dataset_kind='OPERATIONAL' AND c.approved_at IS NOT NULL)),
 'current_refresh_completed',EXISTS(SELECT 1 FROM public.listing_eligibility_refresh_jobs r JOIN target l USING(listing_id)
   WHERE r.eligibility_generation=l.eligibility_generation AND r.job_status='COMPLETED'
   AND r.expected_road_node_id=l.pickup_road_node_id
   AND EXISTS(SELECT 1 FROM public.road_network_coverage c WHERE c.network_snapshot_id=r.expected_snapshot_id
     AND c.active_flag AND c.dataset_kind='OPERATIONAL' AND c.approved_at IS NOT NULL)));
