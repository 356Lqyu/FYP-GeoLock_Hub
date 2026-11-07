-- STAGE A FORWARD REVIEW ARTIFACT. NOT DEPLOYED. DEV rcgyuwiidqvrgbxswhqj ONLY.
-- REVIEW PROPOSAL ONLY. Apply only after 001 and a reviewed rollback checkpoint.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';
CREATE FUNCTION routing_private.actor_lock(p_ngo uuid,p_active boolean DEFAULT true) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ BEGIN
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'READ_COMMITTED_REQUIRED'; END IF;
 IF auth.uid() IS DISTINCT FROM p_ngo THEN RAISE EXCEPTION 'NOT_ROUTE_OWNER'; END IF;
 PERFORM 1 FROM public.ngo_profiles WHERE user_id=p_ngo AND (NOT p_active OR active_flag) FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_NGO_REQUIRED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('routing-ngo:'||p_ngo::text,0));
END $$;
CREATE FUNCTION routing_private.lock_sources(p_tasks uuid[]) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ DECLARE lid uuid; BEGIN
 PERFORM 1 FROM public.donation_claims c JOIN public.pickup_tasks t USING(claim_id)
 WHERE t.task_id=ANY(p_tasks) ORDER BY c.claim_id FOR UPDATE OF c;
 PERFORM 1 FROM public.claim_leases le JOIN public.pickup_tasks t USING(claim_id)
 WHERE t.task_id=ANY(p_tasks) ORDER BY le.lease_id FOR UPDATE OF le;
 PERFORM 1 FROM public.listings l JOIN public.pickup_tasks t USING(listing_id)
 WHERE t.task_id=ANY(p_tasks) ORDER BY l.listing_id FOR UPDATE OF l;
 FOR lid IN SELECT DISTINCT listing_id FROM public.pickup_tasks WHERE task_id=ANY(p_tasks) ORDER BY listing_id LOOP
  PERFORM public.geolock_lock_listing_donations(lid,ARRAY['CLAIMED','PICKUP_IN_PROGRESS','COLLECTED']);
 END LOOP;
 PERFORM 1 FROM public.community_hubs h WHERE h.hub_id IN(SELECT b.hub_id FROM public.hub_batches b JOIN public.listings l USING(batch_id)
 JOIN public.pickup_tasks t USING(listing_id) WHERE t.task_id=ANY(p_tasks)) ORDER BY h.hub_id FOR SHARE;
END $$;
CREATE FUNCTION routing_private.task_window(p jsonb,p_cut timestamptz,p_policy jsonb) RETURNS jsonb
 LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
 SELECT jsonb_build_object('start',greatest(p_cut,(SELECT max((d->>'availability_start')::timestamptz) FROM jsonb_array_elements(p->'donations') d)),
 'end',least(p_cut+make_interval(secs=>((p_policy->>'horizon_minutes')::numeric*60)::double precision),
 (SELECT min((d->>'availability_end')::timestamptz) FROM jsonb_array_elements(p->'donations') d),
 (p->'listing'->>'listing_expires_at')::timestamptz),
 'service',CASE WHEN p->'listing'->>'source_type'='DIRECT_DONATION' THEN (p_policy->>'direct_service_minutes')::numeric ELSE (p_policy->>'hub_service_minutes')::numeric END)
$$;
CREATE FUNCTION routing_private.admissible(p jsonb,p_ngo uuid,p_cut timestamptz,p_policy jsonb) RETURNS boolean
 LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
 SELECT coalesce(
 p->'task'->>'ngo_user_id'=p_ngo::text AND p->'claim'->>'ngo_user_id'=p_ngo::text
 AND p->>'has_route_assignment'='false'
 AND p->'task'->>'task_status'='CONFIRMED' AND p->'claim'->>'claim_status'='ACTIVE'
 AND p->'lease'->>'lease_status'='ACTIVE' AND p->'listing'->>'listing_status'='CLAIMED'
 AND (p->'task'->>'created_at')::timestamptz<=p_cut AND (p->'lease'->>'issued_at')::timestamptz<=p_cut
 AND (p->'lease'->>'expires_at')::timestamptz>p_cut+make_interval(secs=>(((p_policy->>'horizon_minutes')::numeric+(p_policy->>'dispatch_margin_minutes')::numeric)*60)::double precision)
 AND ((p->'listing'->>'listing_expires_at') IS NULL OR (p->'listing'->>'listing_expires_at')::timestamptz>p_cut+make_interval(secs=>(((p_policy->>'horizon_minutes')::numeric+(p_policy->>'dispatch_margin_minutes')::numeric)*60)::double precision))
 AND p->'task'->>'pickup_road_node_id'=p->'listing'->>'pickup_road_node_id'
 AND (p->'task'->>'load_kg')::numeric=(p->'listing'->>'listing_weight_kg')::numeric
 AND jsonb_array_length(p->'donations')>0
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p->'donations') d WHERE d->>'donation_status' IS DISTINCT FROM 'CLAIMED')
 AND ((p->'listing'->>'source_type'='DIRECT_DONATION' AND jsonb_array_length(p->'donations')=1
  AND p->'donations'->0->>'collection_path'='DIRECT_PICKUP'
  AND p->'donations'->0->>'pickup_road_node_id'=p->'listing'->>'pickup_road_node_id')
 OR (p->'listing'->>'source_type'='HUB_BATCH' AND p->'batch'->>'batch_status'='PUBLISHED'
  AND (p->'batch'->>'batch_donation_count')::integer=jsonb_array_length(p->'donations')
  AND (p->'batch'->>'batch_weight_kg')::numeric=(p->'listing'->>'listing_weight_kg')::numeric
  AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p->'donations') d WHERE d->>'collection_path' IS DISTINCT FROM 'HUB_COLLECTION')
  AND (p->'hub'->>'active_flag')::boolean AND p->'hub'->>'road_node_id'=p->'listing'->>'pickup_road_node_id'
  AND jsonb_array_length(p->'inventory')=jsonb_array_length(p->'donations')
  AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p->'inventory') h WHERE h->>'inventory_status' IS DISTINCT FROM 'BATCHED'
    OR h->>'hub_id' IS DISTINCT FROM p->'batch'->>'hub_id')))
 AND (routing_private.task_window(p,p_cut,p_policy)->>'end')::timestamptz >=
     (routing_private.task_window(p,p_cut,p_policy)->>'start')::timestamptz + make_interval(secs=>((routing_private.task_window(p,p_cut,p_policy)->>'service')::numeric*60)::double precision)
 ,false)
$$;
CREATE FUNCTION routing_private.arc(p_matrix jsonb,p_from text,p_to text) RETURNS jsonb
 LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE i integer; j integer; BEGIN
 SELECT ordinality::integer-1 INTO i FROM jsonb_array_elements_text(p_matrix->'node_order') WITH ORDINALITY WHERE value=p_from;
 SELECT ordinality::integer-1 INTO j FROM jsonb_array_elements_text(p_matrix->'node_order') WITH ORDINALITY WHERE value=p_to;
 IF i IS NULL OR j IS NULL OR p_matrix->'arc_status'->i->>j IS DISTINCT FROM 'AVAILABLE' THEN RAISE EXCEPTION 'ROUTE_UNAVAILABLE'; END IF;
 RETURN jsonb_build_object('km',p_matrix->'distance_km'->i->j,'minutes',p_matrix->'travel_minutes'->i->j);
END $$;
CREATE FUNCTION routing_private.snapshot_task(p_body jsonb,p_task uuid) RETURNS jsonb LANGUAGE sql IMMUTABLE
 SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ SELECT o FROM jsonb_array_elements(p_body->'observations') o WHERE o->'task'->>'task_id'=p_task::text $$;
CREATE FUNCTION public.authorize_my_routing_candidate(p_request uuid,p_candidate uuid,p_depart_at timestamptz) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE ngo uuid:=fleet_private.require_ngo(); c routing_private.candidates%rowtype; s routing_private.snapshots%rowtype;
 m routing_private.matrices%rowtype; v public.vehicles%rowtype; original jsonb; r jsonb; stop jsonb; obs jsonb; cur jsonb; win jsonb; a jsonb;
 ids uuid[]; served uuid[]:=ARRAY[]::uuid[]; vehicles uuid[]:=ARRAY[]::uuid[]; routes uuid[]:=ARRAY[]::uuid[];
 rid uuid; vid uuid; tid uuid; node text; last_node text; load numeric; km numeric; cursor_us numeric; arr numeric; start_us numeric; end_us numeric;
 nominal_cursor_us numeric; nominal_arr numeric; nominal_start_us numeric; nominal_end_us numeric; retimed_stops jsonb;
 request_hash text; prior routing_private.requests%rowtype; policy jsonb; ord integer; cutoff_end timestamptz;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pickup_tasks'::regclass AND tgname='routing_task_authority' AND tgenabled='O')
 THEN RAISE EXCEPTION 'DISPATCH_CUTOVER_REQUIRED_BEFORE_AUTHORIZATION'; END IF;
 IF p_request IS NULL OR p_depart_at IS NULL THEN RAISE EXCEPTION 'REQUEST_AND_DEPARTURE_REQUIRED'; END IF;
 PERFORM routing_private.actor_lock(ngo);
 request_hash:=routing_private.hash(jsonb_build_array('AUTHORIZE',p_candidate,p_depart_at));
 SELECT * INTO prior FROM routing_private.requests WHERE ngo_id=ngo AND request_id=p_request;
 IF FOUND THEN IF prior.payload_digest IS DISTINCT FROM request_hash THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF; RETURN prior.result; END IF;
 SELECT * INTO STRICT c FROM routing_private.candidates WHERE candidate_id=p_candidate;
 SELECT * INTO STRICT s FROM routing_private.snapshots WHERE snapshot_id=c.snapshot_id;
 IF s.ngo_id<>ngo THEN RAISE EXCEPTION 'NOT_SNAPSHOT_OWNER'; END IF;
 SELECT * INTO STRICT m FROM routing_private.matrices WHERE matrix_id=s.matrix_id;
 IF NOT EXISTS(SELECT 1 FROM routing_private.validations WHERE candidate_id=c.candidate_id AND candidate_digest=c.digest)
 OR c.body->'plan'->>'method' IS DISTINCT FROM 'proposed' OR c.body->'plan'->>'feasible' IS DISTINCT FROM 'true'
 OR c.body->'plan'->>'dispatch_authority_issued' IS DISTINCT FROM 'false'
 OR NOT coalesce(jsonb_array_length(c.body->'plan'->'routes') BETWEEN 1 AND 20,false)
 THEN RAISE EXCEPTION 'VALIDATED_FEASIBLE_PLAN_REQUIRED'; END IF;
 IF routing_private.ngo_observation(ngo) IS DISTINCT FROM s.body->'ngo' THEN RAISE EXCEPTION 'PLAN_STALE_NGO'; END IF;
 policy:=s.body->'policy'; cutoff_end:=s.cutoff+make_interval(secs=>((policy->>'horizon_minutes')::numeric*60)::double precision);
 IF p_depart_at<clock_timestamp() OR p_depart_at>cutoff_end THEN RAISE EXCEPTION 'INVALID_DEPARTURE'; END IF;
 SELECT array_agg((o->'task'->>'task_id')::uuid) INTO ids FROM jsonb_array_elements(s.body->'observations') o;
 PERFORM routing_private.lock_sources(ids);
 -- Canonical vehicle ordering prevents multi-vehicle publication deadlocks.
 PERFORM 1 FROM public.vehicles WHERE vehicle_id IN(SELECT (x->>'vehicle_id')::uuid FROM jsonb_array_elements(c.body->'plan'->'routes') x) ORDER BY vehicle_id FOR UPDATE;
 FOR r IN SELECT value FROM jsonb_array_elements(c.body->'plan'->'routes') LOOP
  vid:=(r->>'vehicle_id')::uuid;
  IF vid=ANY(vehicles) THEN RAISE EXCEPTION 'DUPLICATE_VEHICLE'; END IF; vehicles:=array_append(vehicles,vid);
  SELECT * INTO STRICT v FROM public.vehicles WHERE vehicle_id=vid;
  SELECT x INTO original FROM jsonb_array_elements(s.body->'vehicles') x WHERE x->>'vehicle_id'=vid::text;
  IF original IS NULL OR original->>'vehicle_version' IS DISTINCT FROM v.vehicle_version::text OR v.ngo_user_id<>ngo
  OR NOT v.active_flag OR NOT v.available_for_planning OR fleet_private.vehicle_has_hold(vid)
  OR v.depot_road_node_id IS DISTINCT FROM fleet_private.require_depot(ngo) THEN RAISE EXCEPTION 'PLAN_STALE_VEHICLE'; END IF;
  IF r->>'ngo_id' IS DISTINCT FROM ngo::text OR r->>'start_node_id' IS DISTINCT FROM v.depot_road_node_id
   OR r->>'end_node_id' IS DISTINCT FROM v.depot_road_node_id OR (r->>'departure_us')::numeric IS DISTINCT FROM 0::numeric
   OR NOT coalesce(jsonb_array_length(r->'stops') BETWEEN 1 AND 100,false) THEN RAISE EXCEPTION 'INVALID_ROUTE_DEPOT_OR_STOPS'; END IF;
  rid:=gen_random_uuid(); load:=0; km:=0; cursor_us:=0; nominal_cursor_us:=0; retimed_stops:='[]'::jsonb; last_node:=v.depot_road_node_id; ord:=0;
  INSERT INTO public.pickup_routes(route_id,ngo_user_id,vehicle_id,route_status,matrix_id,authorised_at,validation_reference)
  VALUES(rid,ngo,vid,'DRAFT',m.matrix_id::text,clock_timestamp(),c.candidate_id::text);
  INSERT INTO routing_private.bindings(route_id,candidate_id,ngo_id,vehicle_id,vehicle_version,plan,departure_at)
  VALUES(rid,c.candidate_id,ngo,vid,v.vehicle_version,r,p_depart_at);
  FOR stop IN SELECT value FROM jsonb_array_elements(r->'stops') LOOP
   ord:=ord+1; tid:=(stop->>'task_id')::uuid;
   IF tid=ANY(served) THEN RAISE EXCEPTION 'DUPLICATE_TASK'; END IF; served:=array_append(served,tid);
   obs:=routing_private.snapshot_task(s.body,tid);
   IF obs IS NULL OR NOT routing_private.admissible(obs,ngo,s.cutoff,policy) THEN RAISE EXCEPTION 'UNAUTHORIZED_TASK'; END IF;
   PERFORM 1 FROM public.pickup_tasks WHERE task_id=tid FOR UPDATE;
   cur:=routing_private.observe_task(tid);
   IF routing_private.task_digest(cur) IS DISTINCT FROM routing_private.task_digest(obs)
    OR cur->'task'->>'task_status' IS DISTINCT FROM 'CONFIRMED'
    OR EXISTS(SELECT 1 FROM public.active_task_route_assignments WHERE task_id=tid) THEN RAISE EXCEPTION 'PLAN_STALE_TASK'; END IF;
   node:=obs->'task'->>'pickup_road_node_id'; win:=routing_private.task_window(obs,s.cutoff,policy);
   IF stop->>'road_node_id' IS DISTINCT FROM node THEN RAISE EXCEPTION 'UNAUTHORIZED_PICKUP_NODE'; END IF;
   a:=routing_private.arc(m.body,last_node,node);
   -- Solver offsets use a nominal zero departure at the snapshot cutoff.
   -- Validate those offsets first, then replay the same ordered route against
   -- the actual departure. Shifting nominal waits would count the delay twice.
   nominal_arr:=nominal_cursor_us+(a->>'minutes')::numeric*60000000;
   nominal_start_us:=greatest(nominal_arr,extract(epoch FROM ((win->>'start')::timestamptz-s.cutoff))*1000000);
   nominal_end_us:=nominal_start_us+(win->>'service')::numeric*60000000;
   arr:=cursor_us+(a->>'minutes')::numeric*60000000;
   start_us:=greatest(arr,extract(epoch FROM ((win->>'start')::timestamptz-p_depart_at))*1000000);
   end_us:=start_us+(win->>'service')::numeric*60000000;
   IF (stop->>'arrival_us')::numeric IS DISTINCT FROM nominal_arr OR (stop->>'service_start_us')::numeric IS DISTINCT FROM nominal_start_us
    OR (stop->>'departure_us')::numeric IS DISTINCT FROM nominal_end_us
    OR s.cutoff+make_interval(secs=>(nominal_end_us/1000000)::double precision)>(win->>'end')::timestamptz
    OR p_depart_at+make_interval(secs=>(end_us/1000000)::double precision)>(win->>'end')::timestamptz THEN RAISE EXCEPTION 'ROUTE_SCHEDULE_INVALID'; END IF;
   retimed_stops:=retimed_stops||jsonb_build_array(stop||jsonb_build_object('arrival_us',arr,'service_start_us',start_us,'departure_us',end_us));
   load:=load+(obs->'task'->>'load_kg')::numeric; km:=km+(a->>'km')::numeric;
   IF load>v.payload_capacity_kg OR (stop->>'cumulative_load_kg')::numeric IS DISTINCT FROM load THEN RAISE EXCEPTION 'CAPACITY_VIOLATION'; END IF;
   INSERT INTO routing_private.items(route_id,task_id,ordinal,observation_digest,planned_xid) VALUES(rid,tid,ord,routing_private.task_digest(obs),pg_current_xact_id());
   INSERT INTO public.active_task_route_assignments(task_id,route_id) VALUES(tid,rid);
   INSERT INTO public.pickup_route_stops(route_id,ngo_user_id,stop_order,task_id,planned_arrival)
    VALUES(rid,ngo,ord,tid,p_depart_at+make_interval(secs=>(arr/1000000)::double precision));
   UPDATE public.pickup_tasks SET task_status='PLANNED' WHERE task_id=tid;
   cursor_us:=end_us; nominal_cursor_us:=nominal_end_us; last_node:=node;
  END LOOP;
  a:=routing_private.arc(m.body,last_node,v.depot_road_node_id); cursor_us:=cursor_us+(a->>'minutes')::numeric*60000000; km:=km+(a->>'km')::numeric;
  nominal_cursor_us:=nominal_cursor_us+(a->>'minutes')::numeric*60000000;
  IF (r->>'return_us')::numeric IS DISTINCT FROM nominal_cursor_us OR nominal_cursor_us>v.max_route_duration_min*60000000 OR cursor_us>v.max_route_duration_min*60000000
   OR p_depart_at+make_interval(secs=>(cursor_us/1000000)::double precision)>cutoff_end THEN RAISE EXCEPTION 'ROUTE_DURATION_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM routing_private.items i WHERE route_id=rid AND
    (routing_private.snapshot_task(s.body,i.task_id)->'lease'->>'expires_at')::timestamptz<=p_depart_at+make_interval(secs=>(cursor_us/1000000+(policy->>'dispatch_margin_minutes')::numeric*60)::double precision)) THEN RAISE EXCEPTION 'LEASE_TOO_SHORT'; END IF;
  UPDATE public.pickup_routes SET route_status='AUTHORISED',total_distance_km=km,total_duration_min=cursor_us/60000000 WHERE route_id=rid;
  UPDATE routing_private.bindings SET plan=r||jsonb_build_object('stops',retimed_stops,'return_us',cursor_us) WHERE route_id=rid;
  routes:=array_append(routes,rid);
 END LOOP;
 IF (policy->>'mandatory')::boolean AND EXISTS(SELECT 1 FROM jsonb_array_elements(s.body->'observations') o WHERE routing_private.admissible(o,ngo,s.cutoff,policy) AND NOT((o->'task'->>'task_id')::uuid=ANY(served))) THEN RAISE EXCEPTION 'MANDATORY_TASK_UNSERVED'; END IF;
 -- Claimed unserved IDs must equal the exact admitted-task complement.
 IF (SELECT coalesce(array_agg(x ORDER BY x),ARRAY[]::text[]) FROM jsonb_array_elements_text(c.body->'plan'->'unserved_tasks') x)
 IS DISTINCT FROM (SELECT coalesce(array_agg(o->'task'->>'task_id' ORDER BY o->'task'->>'task_id'),ARRAY[]::text[]) FROM jsonb_array_elements(s.body->'observations') o
 WHERE routing_private.admissible(o,ngo,s.cutoff,policy) AND NOT((o->'task'->>'task_id')::uuid=ANY(served))) THEN RAISE EXCEPTION 'UNSERVED_TASK_MISMATCH'; END IF;
 INSERT INTO routing_private.requests VALUES(ngo,p_request,'AUTHORIZE',request_hash,jsonb_build_object('route_ids',routes,'candidate_id',p_candidate));
 INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,outcome,details)
 VALUES(ngo,'NGO','ROUTING',p_candidate,'AUTHORIZE_ROUTING','SUCCESS',jsonb_build_object('routes',routes,'candidate_digest',c.digest));
 RETURN jsonb_build_object('route_ids',routes,'candidate_id',p_candidate);
END $$;
-- Existing callers cannot reserve unvalidated tasks using the old entry point.
CREATE OR REPLACE FUNCTION public.assign_task_to_route(p_route uuid,p_task uuid,p_stop_order integer) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ BEGIN RAISE EXCEPTION 'VALIDATED_ROUTE_PUBLICATION_REQUIRED'; END $$;
REVOKE ALL ON FUNCTION public.assign_task_to_route(uuid,uuid,integer) FROM PUBLIC,anon,authenticated,service_role;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON public.pickup_routes,public.pickup_route_stops,public.active_task_route_assignments,public.pickup_tasks FROM PUBLIC,anon,authenticated;
DO $acl$ DECLARE t text; cols text; BEGIN
 FOREACH t IN ARRAY ARRAY['pickup_routes','pickup_route_stops','active_task_route_assignments','pickup_tasks'] LOOP
  SELECT string_agg(quote_ident(attname),',') INTO cols FROM pg_attribute WHERE attrelid=('public.'||t)::regclass AND attnum>0 AND NOT attisdropped;
  EXECUTE format('REVOKE INSERT (%s),UPDATE (%s),REFERENCES (%s) ON public.%I FROM PUBLIC,anon,authenticated',cols,cols,cols,t);
 END LOOP;
END $acl$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA routing_private FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.authorize_my_routing_candidate(uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.authorize_my_routing_candidate(uuid,uuid,timestamptz) TO authenticated;
COMMIT;
