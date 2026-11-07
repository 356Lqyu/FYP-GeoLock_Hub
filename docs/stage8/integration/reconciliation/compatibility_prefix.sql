-- TEMPLATE for the separate generated proposal; not a standalone deployment.
-- No authorization to execute. DEV rcgyuwiidqvrgbxswhqj only.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';
DO $review$
BEGIN
 IF current_user<>'postgres' OR session_user<>'postgres' THEN RAISE EXCEPTION 'POSTGRES_SESSION_REQUIRED'; END IF;
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'READ_COMMITTED_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE oid=to_regprocedure('public.submit_claim_reconciliation(uuid,boolean,uuid)')
   AND proowner='postgres'::regrole AND prosecdef
   AND proconfig=ARRAY['search_path=pg_catalog, public, pg_temp']
   AND pg_get_function_result(oid)='jsonb'
   AND md5(replace(prosrc,E'\r\n',E'\n'))='__RECON_MD5__')
 THEN RAISE EXCEPTION 'RECONCILIATION_SOURCE_OR_SECURITY_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE oid=to_regprocedure('public.recover_expired_claims(integer)')
   AND proowner='postgres'::regrole AND prosecdef
   AND proconfig=ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
   AND md5(replace(prosrc,E'\r\n',E'\n'))='__RECOVERY_MD5__')
 THEN RAISE EXCEPTION 'RECOVERY_SOURCE_OR_SECURITY_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pickup_tasks'::regclass
   AND tgname='routing_task_authority' AND tgenabled='O'
   AND tgfoid=to_regprocedure('routing_private.task_guard()'))
 OR NOT EXISTS(SELECT 1 FROM pg_proc WHERE oid=to_regprocedure('routing_private.task_guard()')
   AND proowner='postgres'::regrole AND prosecdef
   AND md5(replace(prosrc,E'\r\n',E'\n'))='__GUARD_MD5__')
 THEN RAISE EXCEPTION 'REVIEWED_003_GUARD_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles r WHERE r.rolname IN
   ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')
   AND (has_table_privilege(r.oid,'routing_private.items','INSERT,UPDATE,DELETE')
     OR has_table_privilege(r.oid,'routing_private.legacy_inflight','INSERT,UPDATE,DELETE')))
 THEN RAISE EXCEPTION 'PRIVATE_PERMIT_TABLE_PRIVILEGES_REQUIRE_REVIEW'; END IF;
END $review$;

-- No caller-supplied NGO, task, route, case, actor, xid or success flag.
CREATE FUNCTION routing_private.reconciliation_participant(p_claim uuid) RETURNS boolean
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM public.donation_claims c
 JOIN public.listings l USING(listing_id)
 JOIN public.user_profiles u ON u.user_id=auth.uid()
 LEFT JOIN public.donations d ON d.donation_id=l.donation_id
 LEFT JOIN public.hub_batches b ON b.batch_id=l.batch_id
 LEFT JOIN public.community_hubs h ON h.hub_id=b.hub_id
 WHERE c.claim_id=p_claim AND (
  (u.role='NGO' AND u.user_id=c.ngo_user_id)
  OR (l.source_type='DIRECT_DONATION' AND u.role='DONOR' AND u.user_id=d.donor_user_id)
  OR (l.source_type='HUB_BATCH' AND u.role='HUB_ADMIN' AND u.user_id=h.admin_user_id)))
$$;

CREATE FUNCTION routing_private.lock_reconciliation_scope(p_claim uuid) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE ngo uuid; rid uuid; ids uuid[]; owner_after uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'READ_COMMITTED_REQUIRED'; END IF;
 SELECT ngo_user_id INTO ngo FROM public.donation_claims WHERE claim_id=p_claim;
 IF NOT FOUND THEN RAISE EXCEPTION 'CLAIM_NOT_FOUND'; END IF;
 IF NOT routing_private.reconciliation_participant(p_claim) THEN RAISE EXCEPTION 'RECONCILIATION_PARTICIPANT_ONLY'; END IF;
 -- Same prefix as actor_lock, but donor/hub participants are allowed ONLY
 -- through the unchanged reconciliation authorization and evidence checks.
 PERFORM 1 FROM public.ngo_profiles WHERE user_id=ngo FOR SHARE;
 PERFORM pg_advisory_xact_lock(hashtextextended('routing-ngo:'||ngo::text,0));
 SELECT ngo_user_id INTO owner_after FROM public.donation_claims WHERE claim_id=p_claim;
 IF owner_after IS DISTINCT FROM ngo THEN RAISE EXCEPTION 'RECONCILIATION_OWNER_CHANGED'; END IF;
 SELECT i.route_id INTO rid FROM routing_private.items i
 JOIN public.pickup_tasks t USING(task_id) WHERE t.claim_id=p_claim AND i.released_at IS NULL;
 IF rid IS NULL THEN
  PERFORM 1 FROM public.donation_claims WHERE claim_id=p_claim FOR UPDATE;
  RETURN;
 END IF;
 -- Exactly the managed route lock order: all claims, leases, listings,
 -- donations/inventory/hubs, then vehicle, route, tasks and binding.
 SELECT array_agg(task_id ORDER BY task_id) INTO ids FROM routing_private.items WHERE route_id=rid;
 PERFORM routing_private.lock_sources(ids);
 PERFORM 1 FROM public.vehicles WHERE vehicle_id=(SELECT vehicle_id FROM routing_private.bindings WHERE route_id=rid) FOR UPDATE;
 PERFORM 1 FROM public.pickup_routes WHERE route_id=rid FOR UPDATE;
 PERFORM 1 FROM public.pickup_tasks WHERE task_id=ANY(ids) ORDER BY task_id FOR UPDATE;
 PERFORM 1 FROM routing_private.bindings WHERE route_id=rid AND ngo_id=ngo FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'RECONCILIATION_ROUTE_BINDING_MISSING'; END IF;
END $$;

CREATE FUNCTION routing_private.permit_reconciled_collection(p_claim uuid) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE t public.pickup_tasks%rowtype; c public.donation_claims%rowtype;
 le public.claim_leases%rowtype; rc public.claim_reconciliation_cases%rowtype;
 counterpart uuid; lid uuid; rid uuid; expected_role text;
BEGIN
 IF NOT routing_private.reconciliation_participant(p_claim) THEN RAISE EXCEPTION 'RECONCILIATION_PARTICIPANT_ONLY'; END IF;
 SELECT * INTO STRICT c FROM public.donation_claims WHERE claim_id=p_claim;
 SELECT * INTO STRICT le FROM public.claim_leases WHERE claim_id=p_claim;
 SELECT * INTO STRICT t FROM public.pickup_tasks WHERE claim_id=p_claim;
 SELECT * INTO STRICT rc FROM public.claim_reconciliation_cases
  WHERE claim_id=p_claim AND case_status IN ('OPEN','MANUAL_REVIEW');
 IF c.claim_status<>'RECONCILIATION_REQUIRED' OR le.lease_status<>'RECONCILIATION_REQUIRED'
 OR t.task_status NOT IN ('DISPATCHED','COLLECTED') OR rc.listing_id IS DISTINCT FROM c.listing_id
 THEN RAISE EXCEPTION 'RECONCILIATION_COLLECTION_STATE_MISMATCH'; END IF;
 SELECT CASE WHEN l.source_type='DIRECT_DONATION' THEN d.donor_user_id ELSE h.admin_user_id END,
        CASE WHEN l.source_type='DIRECT_DONATION' THEN 'DONOR' ELSE 'HUB_ADMIN' END,l.listing_id
 INTO counterpart,expected_role,lid FROM public.listings l
 LEFT JOIN public.donations d ON d.donation_id=l.donation_id
 LEFT JOIN public.hub_batches b ON b.batch_id=l.batch_id
 LEFT JOIN public.community_hubs h ON h.hub_id=b.hub_id WHERE l.listing_id=c.listing_id;
 IF counterpart IS NULL OR counterpart=c.ngo_user_id
 OR (SELECT count(*) FROM public.claim_reconciliation_evidence WHERE case_id=rc.case_id)<>2
 OR (SELECT count(DISTINCT e.actor_user_id) FROM public.claim_reconciliation_evidence e
     JOIN public.user_profiles u ON u.user_id=e.actor_user_id
     WHERE e.case_id=rc.case_id AND e.handover_confirmed IS TRUE
     AND ((e.actor_user_id=c.ngo_user_id AND u.role='NGO')
       OR (e.actor_user_id=counterpart AND u.role=expected_role)))<>2
 THEN RAISE EXCEPTION 'VALIDATED_TWO_PARTY_HANDOVER_REQUIRED'; END IF;
 -- This hook runs only AFTER the original mixed-batch/custody checks and
 -- donation/inventory collection, immediately before its task UPDATE.
 IF EXISTS(SELECT 1 FROM public.listings l WHERE l.listing_id=lid AND l.source_type='DIRECT_DONATION'
   AND NOT EXISTS(SELECT 1 FROM public.donations d WHERE d.donation_id=l.donation_id AND d.donation_status='COLLECTED'))
 OR EXISTS(SELECT 1 FROM public.listings l JOIN public.hub_batch_members m ON m.batch_id=l.batch_id
   JOIN public.donations d ON d.donation_id=m.donation_id WHERE l.listing_id=lid AND m.membership_status='ACTIVE'
   AND d.donation_status<>'COLLECTED')
 THEN RAISE EXCEPTION 'RECONCILIATION_CUSTODY_NOT_COLLECTED'; END IF;
 SELECT route_id INTO rid FROM routing_private.items WHERE task_id=t.task_id AND released_at IS NULL;
 IF rid IS NOT NULL THEN
  IF NOT EXISTS(SELECT 1 FROM routing_private.items i JOIN routing_private.bindings b USING(route_id)
    JOIN public.pickup_routes r USING(route_id)
    WHERE i.route_id=rid AND i.task_id=t.task_id AND b.ngo_id=c.ngo_user_id
    AND b.closed_at IS NULL AND b.started_at IS NOT NULL AND i.consumed_at IS NOT NULL AND i.dispatch_xid IS NOT NULL
    AND r.ngo_user_id=b.ngo_id AND r.vehicle_id=b.vehicle_id AND r.validation_reference=b.candidate_id::text
    AND r.route_status='IN_PROGRESS') THEN RAISE EXCEPTION 'RECONCILIATION_ROUTE_REQUIRES_REVIEW'; END IF;
  UPDATE routing_private.items SET complete_xid=pg_current_xact_id() WHERE route_id=rid AND task_id=t.task_id;
 ELSIF t.task_status='DISPATCHED' THEN
  UPDATE routing_private.legacy_inflight SET complete_xid=pg_current_xact_id() WHERE task_id=t.task_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'RECONCILIATION_TASK_NOT_CAPTURED_AT_CUTOVER'; END IF;
 END IF;
END $$;

CREATE FUNCTION routing_private.finish_reconciled_collection(p_claim uuid) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE tid uuid;
BEGIN
 IF NOT routing_private.reconciliation_participant(p_claim) THEN RAISE EXCEPTION 'RECONCILIATION_PARTICIPANT_ONLY'; END IF;
 SELECT t.task_id INTO tid FROM public.pickup_tasks t
 JOIN public.donation_claims c USING(claim_id) JOIN public.claim_leases le USING(claim_id)
 JOIN public.claim_reconciliation_cases rc USING(claim_id)
 WHERE t.claim_id=p_claim AND t.task_status='COLLECTED' AND c.claim_status='COMPLETED'
 AND le.lease_status='COMPLETED' AND rc.case_status='RESOLVED_COLLECTED';
 IF tid IS NULL THEN RAISE EXCEPTION 'RECONCILIATION_NOT_RESOLVED_COLLECTED'; END IF;
 UPDATE routing_private.items SET collected_at=coalesce(collected_at,clock_timestamp())
 WHERE task_id=tid AND released_at IS NULL AND complete_xid=pg_current_xact_id();
 IF EXISTS(SELECT 1 FROM routing_private.items WHERE task_id=tid AND released_at IS NULL AND collected_at IS NULL)
 THEN RAISE EXCEPTION 'RECONCILIATION_ROUTE_BOOKKEEPING_FAILED'; END IF;
 -- No assignment deletion, route closure, vehicle edit, release or dispatch.
END $$;

REVOKE ALL ON FUNCTION routing_private.reconciliation_participant(uuid),
 routing_private.lock_reconciliation_scope(uuid),routing_private.permit_reconciled_collection(uuid),
 routing_private.finish_reconciled_collection(uuid)
 FROM PUBLIC,anon,authenticated,service_role,geolock_graph_worker,geolock_planner,geolock_validator;
