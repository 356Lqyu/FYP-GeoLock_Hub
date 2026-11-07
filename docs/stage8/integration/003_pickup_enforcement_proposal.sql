-- REVIEW ONLY. No DEV execution authorized. Requires 001 and 002.
-- Generated private legacy bodies are appended by build_legacy.py before COMMIT.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';
-- Drain old task writers BEFORE capturing the legacy in-flight set. Otherwise
-- an old start can commit between capture and trigger installation.
LOCK TABLE public.pickup_tasks IN SHARE ROW EXCLUSIVE MODE;
DO $pin$ BEGIN
 IF encode(sha256(convert_to(pg_get_functiondef('public.start_pickup(uuid)'::regprocedure),'UTF8')),'hex') IS DISTINCT FROM 'a87e59bd4c790bc593f76da42bff47e8864c2f27affffc623d6f7161a63a84a7'
 OR encode(sha256(convert_to(pg_get_functiondef('public.complete_pickup(uuid,boolean)'::regprocedure),'UTF8')),'hex') IS DISTINCT FROM 'de1f32f68ced1b9ffae70983cd7988c8e140509ef7aa9bf8c69a23dca512f4a0'
 THEN RAISE EXCEPTION 'CAPTURED_LIFECYCLE_SOURCE_DRIFT'; END IF;
END $pin$;
CREATE FUNCTION routing_private.lock_route(p_route uuid,p_active boolean DEFAULT true) RETURNS routing_private.bindings
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE b routing_private.bindings%rowtype; ids uuid[]; BEGIN
 SELECT * INTO STRICT b FROM routing_private.bindings WHERE route_id=p_route;
 PERFORM routing_private.actor_lock(b.ngo_id,p_active);
 SELECT array_agg(task_id ORDER BY task_id) INTO ids FROM routing_private.items WHERE route_id=p_route;
 PERFORM routing_private.lock_sources(ids);
 PERFORM 1 FROM public.vehicles WHERE vehicle_id=b.vehicle_id FOR UPDATE;
 PERFORM 1 FROM public.pickup_routes WHERE route_id=p_route FOR UPDATE;
 PERFORM 1 FROM public.pickup_tasks WHERE task_id=ANY(ids) ORDER BY task_id FOR UPDATE;
 SELECT * INTO STRICT b FROM routing_private.bindings WHERE route_id=p_route FOR UPDATE;
 RETURN b;
END $$;
CREATE FUNCTION routing_private.close_collected(p_route uuid) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM routing_private.items WHERE route_id=p_route)
 OR EXISTS(SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
 JOIN public.donation_claims c USING(claim_id) JOIN public.claim_leases le USING(claim_id)
 WHERE i.route_id=p_route AND (t.task_status<>'COLLECTED' OR c.claim_status<>'COMPLETED' OR le.lease_status<>'COMPLETED'))
 THEN RAISE EXCEPTION 'ROUTE_HAS_UNRESOLVED_TASKS'; END IF;
 DELETE FROM public.active_task_route_assignments WHERE route_id=p_route;
 UPDATE public.pickup_routes SET route_status='COMPLETED' WHERE route_id=p_route;
 UPDATE routing_private.items SET released_at=coalesce(released_at,clock_timestamp()) WHERE route_id=p_route;
 UPDATE routing_private.bindings SET closed_at=coalesce(closed_at,clock_timestamp()) WHERE route_id=p_route;
 INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,outcome,details)
 VALUES(auth.uid(),'NGO','ROUTE',p_route,'CLOSE_COLLECTED_ROUTE','SUCCESS',jsonb_build_object('assignments_cleared',true));
END $$;
CREATE FUNCTION public.close_my_collected_route(p_route uuid,p_depot_return_confirmed boolean) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE b routing_private.bindings%rowtype; BEGIN
 b:=routing_private.lock_route(p_route,false);
 IF p_depot_return_confirmed IS DISTINCT FROM true THEN RAISE EXCEPTION 'DEPOT_RETURN_CONFIRMATION_REQUIRED'; END IF;
 IF b.closed_at IS NOT NULL THEN
  IF (SELECT route_status FROM public.pickup_routes WHERE route_id=p_route)<>'COMPLETED' THEN RAISE EXCEPTION 'ROUTE_NOT_COMPLETED'; END IF;
  RETURN;
 END IF;
 PERFORM routing_private.close_collected(p_route);
END $$;
CREATE FUNCTION public.cancel_my_unstarted_route(p_route uuid) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE b routing_private.bindings%rowtype; i record; BEGIN
 b:=routing_private.lock_route(p_route,false);
 IF b.closed_at IS NOT NULL THEN
  IF (SELECT route_status FROM public.pickup_routes WHERE route_id=p_route)<>'CANCELLED' THEN RAISE EXCEPTION 'ROUTE_NOT_CANCELLED'; END IF;
  RETURN;
 END IF;
 IF b.started_at IS NOT NULL OR EXISTS(SELECT 1 FROM routing_private.items WHERE route_id=p_route AND consumed_at IS NOT NULL)
 THEN RAISE EXCEPTION 'STARTED_ROUTE_REQUIRES_RECONCILIATION'; END IF;
 FOR i IN SELECT x.*,t.task_status FROM routing_private.items x JOIN public.pickup_tasks t USING(task_id) WHERE x.route_id=p_route LOOP
  IF i.task_status<>'PLANNED' OR routing_private.task_digest(routing_private.observe_task(i.task_id)) IS DISTINCT FROM i.observation_digest
  THEN RAISE EXCEPTION 'STALE_ROUTE_REQUIRES_RECONCILIATION'; END IF;
 END LOOP;
 -- Preserve evidence outside the active planning relation. Existing recovery
 -- treats ANY public stop as execution uncertainty, even a cancelled plan.
 INSERT INTO routing_private.cancelled_stop_history(route_id,task_id,ngo_id,stop_order,original_stop)
 SELECT route_id,task_id,ngo_user_id,stop_order,to_jsonb(s) FROM public.pickup_route_stops s WHERE route_id=p_route;
 DELETE FROM public.pickup_route_stops WHERE route_id=p_route;
 DELETE FROM public.active_task_route_assignments WHERE route_id=p_route;
 UPDATE routing_private.items SET release_xid=pg_current_xact_id(),released_at=clock_timestamp() WHERE route_id=p_route;
 UPDATE public.pickup_tasks SET task_status='CONFIRMED' WHERE task_id IN(SELECT task_id FROM routing_private.items WHERE route_id=p_route);
 UPDATE public.pickup_routes SET route_status='CANCELLED' WHERE route_id=p_route;
 UPDATE routing_private.bindings SET closed_at=clock_timestamp() WHERE route_id=p_route;
 INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,outcome,details)
 VALUES(auth.uid(),'NGO','ROUTE',p_route,'CANCEL_UNSTARTED_ROUTE','SUCCESS',jsonb_build_object('stops_archived',true,'tasks_retained',true));
END $$;
CREATE FUNCTION routing_private.task_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE i routing_private.items%rowtype; BEGIN
 IF NEW.task_status=OLD.task_status THEN RETURN NEW; END IF;
 SELECT * INTO i FROM routing_private.items WHERE task_id=OLD.task_id AND (released_at IS NULL OR release_xid=pg_current_xact_id()) ORDER BY released_at NULLS FIRST,ordinal LIMIT 1;
 IF NEW.task_status='DISPATCHED' THEN
  IF i.dispatch_xid IS DISTINCT FROM pg_current_xact_id() OR i.consumed_at IS NULL THEN RAISE EXCEPTION 'DATABASE_DISPATCH_AUTHORIZATION_REQUIRED'; END IF;
 ELSIF NEW.task_status='COLLECTED' THEN
  IF i.complete_xid IS DISTINCT FROM pg_current_xact_id() AND NOT EXISTS(SELECT 1 FROM routing_private.legacy_inflight WHERE task_id=OLD.task_id AND complete_xid=pg_current_xact_id())
  THEN RAISE EXCEPTION 'PROTECTED_COMPLETION_REQUIRED'; END IF;
 ELSIF i.task_id IS NOT NULL THEN
  IF NOT ((OLD.task_status='CONFIRMED' AND NEW.task_status='PLANNED' AND i.planned_xid=pg_current_xact_id())
    OR (OLD.task_status='PLANNED' AND NEW.task_status='CONFIRMED' AND i.release_xid=pg_current_xact_id())
    OR (NEW.task_status='STALE' AND EXISTS(SELECT 1 FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
        WHERE c.claim_id=OLD.claim_id AND c.claim_status='RECONCILIATION_REQUIRED' AND le.lease_status='RECONCILIATION_REQUIRED')))
  THEN RAISE EXCEPTION 'RESERVED_TASK_REQUIRES_RECONCILIATION'; END IF;
 END IF;
 RETURN NEW;
END $$;
-- Existing in-flight tasks can finish; they cannot obtain a new start permit.
INSERT INTO routing_private.legacy_inflight(task_id) SELECT task_id FROM public.pickup_tasks WHERE task_status='DISPATCHED';
CREATE TRIGGER routing_task_authority BEFORE UPDATE OF task_status ON public.pickup_tasks
 FOR EACH ROW EXECUTE FUNCTION routing_private.task_guard();
CREATE FUNCTION routing_private.check_remaining(p_route uuid,p_next uuid,p_now timestamptz) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE b routing_private.bindings%rowtype; s routing_private.snapshots%rowtype; m jsonb; pol jsonb; win jsonb; obs jsonb;
 v public.vehicles%rowtype; i record; node text; at_time timestamptz; finish timestamptz; origin timestamptz; first_id uuid;
BEGIN
 SELECT * INTO STRICT b FROM routing_private.bindings WHERE route_id=p_route;
 SELECT sn.* INTO STRICT s FROM routing_private.candidates c JOIN routing_private.snapshots sn USING(snapshot_id) WHERE c.candidate_id=b.candidate_id;
 SELECT body INTO STRICT m FROM routing_private.matrices WHERE matrix_id=s.matrix_id;
 IF NOT EXISTS(SELECT 1 FROM public.pickup_routes r WHERE r.route_id=p_route AND r.ngo_user_id=b.ngo_id AND r.vehicle_id=b.vehicle_id
 AND r.matrix_id=s.matrix_id::text AND r.validation_reference=b.candidate_id::text)
 OR (SELECT count(*) FROM public.pickup_route_stops WHERE route_id=p_route)<>(SELECT count(*) FROM routing_private.items WHERE route_id=p_route)
 OR EXISTS(SELECT 1 FROM routing_private.items x WHERE x.route_id=p_route AND NOT EXISTS(SELECT 1 FROM public.pickup_route_stops z
 WHERE z.route_id=p_route AND z.task_id=x.task_id AND z.stop_order=x.ordinal AND z.ngo_user_id=b.ngo_id))
 THEN RAISE EXCEPTION 'ROUTE_BINDING_DRIFT'; END IF;
 pol:=s.body->'policy'; SELECT * INTO STRICT v FROM public.vehicles WHERE vehicle_id=b.vehicle_id;
 IF b.closed_at IS NOT NULL OR v.vehicle_version<>b.vehicle_version OR NOT v.active_flag OR NOT v.available_for_planning
 OR v.depot_road_node_id IS DISTINCT FROM fleet_private.require_depot(b.ngo_id)
 OR routing_private.ngo_observation(b.ngo_id) IS DISTINCT FROM s.body->'ngo'
 OR (SELECT route_status FROM public.pickup_routes WHERE route_id=p_route) NOT IN ('AUTHORISED','IN_PROGRESS')
 THEN RAISE EXCEPTION 'DISPATCH_AUTHORITY_STALE'; END IF;
 IF p_now<b.departure_at THEN RAISE EXCEPTION 'BEFORE_AUTHORIZED_DEPARTURE'; END IF;
 IF EXISTS(SELECT 1 FROM routing_private.items x JOIN public.pickup_tasks t USING(task_id) WHERE x.route_id=p_route AND t.task_status='DISPATCHED') THEN RAISE EXCEPTION 'PREVIOUS_PICKUP_UNRESOLVED'; END IF;
 SELECT task_id INTO first_id FROM routing_private.items WHERE route_id=p_route AND collected_at IS NULL ORDER BY ordinal LIMIT 1;
 IF first_id IS DISTINCT FROM p_next THEN RAISE EXCEPTION 'STOP_ORDER_REQUIRED'; END IF;
 node:=v.depot_road_node_id;
 SELECT t.pickup_road_node_id INTO node FROM routing_private.items x JOIN public.pickup_tasks t USING(task_id)
 WHERE x.route_id=p_route AND x.collected_at IS NOT NULL ORDER BY ordinal DESC LIMIT 1;
 node:=coalesce(node,v.depot_road_node_id); at_time:=p_now; origin:=coalesce(b.started_at,p_now);
 FOR i IN SELECT * FROM routing_private.items WHERE route_id=p_route AND collected_at IS NULL ORDER BY ordinal LOOP
  obs:=routing_private.observe_task(i.task_id);
  IF routing_private.task_digest(obs) IS DISTINCT FROM i.observation_digest
  OR NOT EXISTS(SELECT 1 FROM public.active_task_route_assignments WHERE task_id=i.task_id AND route_id=p_route)
  THEN RAISE EXCEPTION 'DISPATCH_SOURCE_STALE'; END IF;
  win:=routing_private.task_window(obs,s.cutoff,pol);
  at_time:=at_time+make_interval(secs=>((routing_private.arc(m,node,obs->'task'->>'pickup_road_node_id')->>'minutes')::numeric*60)::double precision);
  at_time:=greatest(at_time,(win->>'start')::timestamptz)+make_interval(secs=>((win->>'service')::numeric*60)::double precision);
  IF at_time>(win->>'end')::timestamptz OR (obs->'lease'->>'expires_at')::timestamptz<=at_time THEN RAISE EXCEPTION 'DISPATCH_WINDOW_OR_LEASE_EXPIRED'; END IF;
  node:=obs->'task'->>'pickup_road_node_id';
 END LOOP;
 finish:=at_time+make_interval(secs=>((routing_private.arc(m,node,v.depot_road_node_id)->>'minutes')::numeric*60)::double precision);
 IF finish>origin+make_interval(secs=>(v.max_route_duration_min*60)::double precision)
 OR finish>s.cutoff+make_interval(secs=>((pol->>'horizon_minutes')::numeric*60)::double precision)
 OR EXISTS(SELECT 1 FROM routing_private.items x JOIN public.pickup_tasks t USING(task_id) JOIN public.claim_leases le USING(claim_id)
 WHERE x.route_id=p_route AND x.collected_at IS NULL AND le.expires_at<=finish+make_interval(secs=>((pol->>'dispatch_margin_minutes')::numeric*60)::double precision))
 THEN RAISE EXCEPTION 'REMAINING_ROUTE_INFEASIBLE'; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.start_pickup(p_claim uuid) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE tid uuid; rid uuid; b routing_private.bindings%rowtype; BEGIN
 SELECT t.task_id,i.route_id INTO tid,rid FROM public.pickup_tasks t JOIN routing_private.items i USING(task_id)
 WHERE t.claim_id=p_claim AND i.released_at IS NULL;
 IF rid IS NULL THEN RAISE EXCEPTION 'DATABASE_DISPATCH_AUTHORIZATION_REQUIRED'; END IF;
 b:=routing_private.lock_route(rid);
 PERFORM routing_private.check_remaining(rid,tid,clock_timestamp());
 UPDATE routing_private.items SET dispatch_xid=pg_current_xact_id(),consumed_at=clock_timestamp() WHERE route_id=rid AND task_id=tid AND consumed_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'DISPATCH_ALREADY_CONSUMED'; END IF;
 UPDATE routing_private.bindings SET started_at=coalesce(started_at,clock_timestamp()) WHERE route_id=rid;
 UPDATE public.pickup_routes SET route_status='IN_PROGRESS' WHERE route_id=rid;
 PERFORM routing_private.legacy_start_pickup(p_claim);
END $$;
CREATE OR REPLACE FUNCTION public.complete_pickup(p_claim uuid,p_handover_confirmed boolean) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE tid uuid; rid uuid; b routing_private.bindings%rowtype; BEGIN
 SELECT t.task_id,i.route_id INTO tid,rid FROM public.pickup_tasks t LEFT JOIN routing_private.items i ON i.task_id=t.task_id AND i.released_at IS NULL WHERE t.claim_id=p_claim;
 IF rid IS NULL THEN
  PERFORM routing_private.actor_lock(auth.uid(),false);
  UPDATE routing_private.legacy_inflight SET complete_xid=pg_current_xact_id() WHERE task_id=tid;
  IF NOT FOUND THEN RAISE EXCEPTION 'NO_AUTHORIZED_OR_LEGACY_INFLIGHT_TASK'; END IF;
  PERFORM routing_private.legacy_complete_pickup(p_claim,p_handover_confirmed); RETURN;
 END IF;
 b:=routing_private.lock_route(rid,false);
 UPDATE routing_private.items SET complete_xid=pg_current_xact_id() WHERE route_id=rid AND task_id=tid AND consumed_at IS NOT NULL AND collected_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'PICKUP_NOT_STARTED'; END IF;
 PERFORM routing_private.legacy_complete_pickup(p_claim,p_handover_confirmed);
 UPDATE routing_private.items SET collected_at=clock_timestamp() WHERE route_id=rid AND task_id=tid;
 -- Collection is not depot return. Keep reservations until protected closure.
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA routing_private FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.start_pickup(uuid),public.complete_pickup(uuid,boolean),public.close_my_collected_route(uuid,boolean),public.cancel_my_unstarted_route(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.start_pickup(uuid),public.complete_pickup(uuid,boolean),public.close_my_collected_route(uuid,boolean),public.cancel_my_unstarted_route(uuid) TO authenticated;
-- Minimal authenticated Flutter reads. These expose only the caller's tasks
-- and managed routes; a public route-status string alone is never a permit.
CREATE FUNCTION public.get_my_routing_overview() RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE ngo uuid:=auth.uid(); pol routing_private.policies%rowtype; cut timestamptz:=statement_timestamp(); BEGIN
 IF ngo IS NULL OR NOT EXISTS(SELECT 1 FROM public.ngo_profiles n JOIN public.user_profiles u ON u.user_id=n.user_id AND u.role=n.role WHERE n.user_id=ngo AND n.role='NGO') THEN RAISE EXCEPTION 'NGO_PROFILE_REQUIRED'; END IF;
 SELECT * INTO pol FROM routing_private.policies ORDER BY created_at DESC,policy_id LIMIT 1;
 RETURN jsonb_build_object('contract','geolock.ngo-routing.v1','ngo_id',ngo,'server_now',cut,'policy_id',pol.policy_id,
 'authorization_enforced',EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pickup_tasks'::regclass AND tgname='routing_task_authority' AND tgenabled='O'),
 'eligible_tasks',(SELECT coalesce(jsonb_agg(jsonb_build_object('task_id',t.task_id,'claim_id',t.claim_id,'load_kg',t.load_kg,
 'pickup_road_node_id',t.pickup_road_node_id,'task_status',t.task_status,'source_type',l.source_type,'title',d.title) ORDER BY t.created_at,t.task_id),'[]')
 FROM public.pickup_tasks t JOIN public.listings l USING(listing_id) LEFT JOIN public.donations d ON d.donation_id=l.donation_id
 WHERE t.ngo_user_id=ngo AND pol.policy_id IS NOT NULL AND routing_private.admissible(routing_private.observe_task(t.task_id),ngo,cut,pol.body)),
 'routes',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]') FROM
 (SELECT r.route_id,r.route_status,r.vehicle_id,r.total_distance_km,r.total_duration_min,b.created_at FROM routing_private.bindings b
 JOIN public.pickup_routes r USING(route_id) WHERE b.ngo_id=ngo AND r.ngo_user_id=ngo ORDER BY b.created_at DESC LIMIT 30) x));
END $$;
CREATE FUNCTION public.get_my_authorized_route(p_route uuid) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE ngo uuid:=auth.uid(); b routing_private.bindings%rowtype; r public.pickup_routes%rowtype;
 next_id uuid; ready boolean:=false; authorized boolean; blocked text; rows jsonb; can_close boolean; can_cancel boolean;
BEGIN
 SELECT * INTO b FROM routing_private.bindings WHERE route_id=p_route AND ngo_id=ngo;
 IF NOT FOUND OR ngo IS NULL THEN RAISE EXCEPTION 'OWNED_MANAGED_ROUTE_NOT_FOUND'; END IF;
 SELECT * INTO STRICT r FROM public.pickup_routes WHERE route_id=p_route;
 authorized:=b.closed_at IS NULL AND r.ngo_user_id=ngo AND r.vehicle_id=b.vehicle_id AND r.validation_reference=b.candidate_id::text
 AND r.route_status IN ('AUTHORISED','IN_PROGRESS') AND EXISTS(SELECT 1 FROM routing_private.candidates c JOIN routing_private.validations v USING(candidate_id)
 JOIN routing_private.snapshots s USING(snapshot_id) WHERE c.candidate_id=b.candidate_id AND v.candidate_digest=c.digest AND r.matrix_id=s.matrix_id::text);
 SELECT task_id INTO next_id FROM routing_private.items WHERE route_id=p_route AND collected_at IS NULL ORDER BY ordinal LIMIT 1;
 IF authorized AND next_id IS NOT NULL THEN
  BEGIN PERFORM routing_private.check_remaining(p_route,next_id,clock_timestamp()); ready:=true;
  EXCEPTION WHEN OTHERS THEN blocked:=SQLERRM; ready:=false; END;
 END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('stop_order',i.ordinal,'task_id',i.task_id,'claim_id',t.claim_id,'task_status',t.task_status,
 'source_type',l.source_type,'title',d.title,'pickup_address',d.pickup_address,'pickup_latitude',l.pickup_latitude,'pickup_longitude',l.pickup_longitude,
 'pickup_road_node_id',t.pickup_road_node_id,'load_kg',t.load_kg,'planned_arrival',ps.planned_arrival,
 'can_start',authorized AND ready AND i.task_id=next_id AND i.consumed_at IS NULL AND t.task_status='PLANNED',
 'can_complete',authorized AND i.consumed_at IS NOT NULL AND i.collected_at IS NULL AND t.task_status='DISPATCHED'
 AND c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' AND le.expires_at>clock_timestamp()) ORDER BY i.ordinal),'[]') INTO rows
 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) JOIN public.listings l USING(listing_id)
 JOIN public.donation_claims c ON c.claim_id=t.claim_id JOIN public.claim_leases le ON le.claim_id=t.claim_id
 LEFT JOIN public.donations d ON d.donation_id=l.donation_id LEFT JOIN public.pickup_route_stops ps ON ps.route_id=i.route_id AND ps.task_id=i.task_id WHERE i.route_id=p_route;
 can_close:=authorized AND EXISTS(SELECT 1 FROM routing_private.items WHERE route_id=p_route) AND NOT EXISTS(
 SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) JOIN public.donation_claims c USING(claim_id) JOIN public.claim_leases le USING(claim_id)
 WHERE i.route_id=p_route AND (i.collected_at IS NULL OR t.task_status<>'COLLECTED' OR c.claim_status<>'COMPLETED' OR le.lease_status<>'COMPLETED'));
 can_cancel:=authorized AND b.started_at IS NULL AND NOT EXISTS(SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
 WHERE i.route_id=p_route AND (i.consumed_at IS NOT NULL OR t.task_status<>'PLANNED' OR routing_private.task_digest(routing_private.observe_task(t.task_id)) IS DISTINCT FROM i.observation_digest));
 RETURN jsonb_build_object('contract','geolock.ngo-routing.v1','ngo_id',ngo,'route_id',p_route,'server_now',clock_timestamp(),
 'route_status',r.route_status,'vehicle_id',b.vehicle_id,'depot_road_node_id',b.plan->>'start_node_id','departure_at',b.departure_at,
 'total_distance_km',r.total_distance_km,'total_duration_min',r.total_duration_min,'authorization_confirmed',authorized,
 'dispatch_block_reason',blocked,'can_close',can_close,'can_cancel',can_cancel,'stops',rows);
END $$;
REVOKE ALL ON FUNCTION public.get_my_routing_overview(),public.get_my_authorized_route(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_my_routing_overview(),public.get_my_authorized_route(uuid) TO authenticated;
-- LEGACY_BODIES_AND_COMMIT
CREATE OR REPLACE FUNCTION routing_private.legacy_start_pickup(p_claim uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
 SET timezone TO 'UTC'
 SET extra_float_digits TO '0'
AS $function$
declare v_actor uuid:=auth.uid();v_c public.donation_claims%rowtype;
 v_l public.listings%rowtype;v_lease public.claim_leases%rowtype;
begin
 select * into v_c from public.donation_claims where claim_id=p_claim for update;
 if not found or v_c.ngo_user_id is distinct from v_actor or v_c.claim_status<>'ACTIVE'
 then raise exception 'NOT_ACTIVE_CLAIM_HOLDER'; end if;
 select * into v_lease from public.claim_leases where claim_id=p_claim for update;
 if not found or v_lease.lease_status<>'ACTIVE' or v_lease.expires_at<=clock_timestamp()
 then raise exception 'STALE_OR_EXPIRED_LEASE'; end if;
 select * into v_l from public.listings where listing_id=v_c.listing_id for update;
 if v_l.listing_status<>'CLAIMED' then raise exception 'LISTING_NOT_CLAIMED'; end if;
 update public.pickup_tasks set task_status='DISPATCHED'
 where claim_id=p_claim and task_status in ('CONFIRMED','PLANNED');
 if not found then raise exception 'PICKUP_TASK_NOT_DISPATCHABLE'; end if;
 perform public.geolock_transition_listing_donations(v_l.listing_id,'CLAIMED','PICKUP_IN_PROGRESS');
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 claim_id,lease_id,requested_state,resulting_state,outcome)
 values(v_actor,'NGO','CLAIM',p_claim,'START_PICKUP',p_claim,v_lease.lease_id,
 'PICKUP_IN_PROGRESS','PICKUP_IN_PROGRESS','SUCCESS');
end $function$
;

CREATE OR REPLACE FUNCTION routing_private.legacy_complete_pickup(p_claim uuid, p_handover_confirmed boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
 SET timezone TO 'UTC'
 SET extra_float_digits TO '0'
AS $function$
declare v_actor uuid:=auth.uid();v_c public.donation_claims%rowtype;
 v_l public.listings%rowtype;v_lease public.claim_leases%rowtype;
begin
 select * into v_c from public.donation_claims where claim_id=p_claim for update;
 if not found or v_c.ngo_user_id is distinct from v_actor or v_c.claim_status<>'ACTIVE'
 then raise exception 'NOT_ACTIVE_CLAIM_HOLDER'; end if;
 select * into v_lease from public.claim_leases where claim_id=p_claim for update;
 if not found or v_lease.lease_status<>'ACTIVE' or v_lease.expires_at<=clock_timestamp()
 then raise exception 'STALE_OR_EXPIRED_LEASE'; end if;
 if p_handover_confirmed is distinct from true then raise exception 'HANDOVER_NOT_CONFIRMED'; end if;
 select * into v_l from public.listings where listing_id=v_c.listing_id for update;
 if v_l.listing_status<>'CLAIMED' then raise exception 'LISTING_NOT_CLAIMED'; end if;
 update public.pickup_tasks set task_status='COLLECTED'
 where claim_id=p_claim and task_status='DISPATCHED';
 if not found then raise exception 'PICKUP_NOT_STARTED'; end if;
 perform public.geolock_transition_listing_donations(v_l.listing_id,'PICKUP_IN_PROGRESS','COLLECTED');
 if v_l.source_type='HUB_BATCH' then
  update public.hub_inventory set inventory_status='COLLECTED'
  where donation_id in(select donation_id from public.hub_batch_members
    where batch_id=v_l.batch_id and membership_status='ACTIVE');
  update public.hub_batches set batch_status='COLLECTED' where batch_id=v_l.batch_id;
 end if;
 update public.listings set listing_status='CLOSED',listing_version=listing_version+1
 where listing_id=v_l.listing_id;
 update public.donation_claims set claim_status='COMPLETED',closed_at=clock_timestamp()
 where claim_id=p_claim;
 update public.claim_leases set lease_status='COMPLETED',closed_at=clock_timestamp()
 where claim_id=p_claim;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 claim_id,lease_id,requested_state,resulting_state,outcome)
 values(v_actor,'NGO','CLAIM',p_claim,'COMPLETE_PICKUP',p_claim,v_lease.lease_id,
 'COLLECTED','COLLECTED','SUCCESS');
end $function$
;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA routing_private FROM PUBLIC,anon,authenticated,service_role;
COMMIT;
