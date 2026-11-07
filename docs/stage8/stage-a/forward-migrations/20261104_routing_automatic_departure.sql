-- LOCAL REVIEW ONLY. Separate explicit DEV deployment approval required.
-- Forward-only A004: explicit NULL = AUTO_NOW; explicit timestamps unchanged.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='120s';
DO $guard$
BEGIN
 IF session_user<>'postgres' OR current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'REVIEWED_INSTALLER_AND_ISOLATION_REQUIRED'; END IF;
 IF (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid='public.authorize_my_routing_candidate(uuid,uuid,timestamptz)'::regprocedure) IS DISTINCT FROM '1c3c880e27da261a9a95a95730640196' THEN RAISE EXCEPTION 'AUTHORIZATION_BASELINE_DRIFT_OR_ALREADY_APPLIED'; END IF;
 IF (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid='public.get_my_authorized_route(uuid)'::regprocedure) IS DISTINCT FROM '5e6583e6092daf191eeca066f0b06ebe' THEN RAISE EXCEPTION 'OWNED_ROUTE_READER_BASELINE_DRIFT'; END IF;
 IF EXISTS(SELECT 1 FROM pg_proc WHERE oid IN ('public.authorize_my_routing_candidate(uuid,uuid,timestamptz)'::regprocedure,'public.get_my_authorized_route(uuid)'::regprocedure) AND (NOT prosecdef OR proowner<>'postgres'::regrole)) THEN RAISE EXCEPTION 'ROUTING_FUNCTION_SECURITY_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pickup_tasks'::regclass AND tgname='routing_task_authority' AND tgenabled='O') THEN RAISE EXCEPTION 'A003_REQUIRED'; END IF;
END $guard$;
CREATE OR REPLACE FUNCTION public.authorize_my_routing_candidate(p_request uuid,p_candidate uuid,p_depart_at timestamptz) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE ngo uuid:=fleet_private.require_ngo(); c routing_private.candidates%rowtype; s routing_private.snapshots%rowtype;
 m routing_private.matrices%rowtype; v public.vehicles%rowtype; original jsonb; r jsonb; stop jsonb; obs jsonb; cur jsonb; win jsonb; a jsonb;
 ids uuid[]; served uuid[]:=ARRAY[]::uuid[]; vehicles uuid[]:=ARRAY[]::uuid[]; routes uuid[]:=ARRAY[]::uuid[];
 rid uuid; vid uuid; tid uuid; node text; last_node text; load numeric; km numeric; cursor_us numeric; arr numeric; start_us numeric; end_us numeric;
 nominal_cursor_us numeric; nominal_arr numeric; nominal_start_us numeric; nominal_end_us numeric; retimed_stops jsonb;
 request_hash text; prior routing_private.requests%rowtype; policy jsonb; ord integer; cutoff_end timestamptz; automatic_departure boolean := p_depart_at IS NULL; receipt jsonb;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pickup_tasks'::regclass AND tgname='routing_task_authority' AND tgenabled='O')
 THEN RAISE EXCEPTION 'DISPATCH_CUTOVER_REQUIRED_BEFORE_AUTHORIZATION'; END IF;
 IF p_request IS NULL THEN RAISE EXCEPTION 'REQUEST_AND_DEPARTURE_REQUIRED'; END IF;
 PERFORM routing_private.actor_lock(ngo);
 request_hash:=CASE WHEN automatic_departure THEN routing_private.hash(jsonb_build_array('AUTHORIZE_AUTO_NOW',p_candidate)) ELSE routing_private.hash(jsonb_build_array('AUTHORIZE',p_candidate,p_depart_at)) END;
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
 IF NOT automatic_departure AND (p_depart_at<clock_timestamp() OR p_depart_at>cutoff_end) THEN RAISE EXCEPTION 'INVALID_DEPARTURE'; END IF;
 SELECT array_agg((o->'task'->>'task_id')::uuid) INTO ids FROM jsonb_array_elements(s.body->'observations') o;
 PERFORM routing_private.lock_sources(ids);
 -- Canonical vehicle ordering prevents multi-vehicle publication deadlocks.
 PERFORM 1 FROM public.vehicles WHERE vehicle_id IN(SELECT (x->>'vehicle_id')::uuid FROM jsonb_array_elements(c.body->'plan'->'routes') x) ORDER BY vehicle_id FOR UPDATE;
 IF automatic_departure THEN
  p_depart_at:=clock_timestamp();
  IF p_depart_at>cutoff_end THEN RAISE EXCEPTION 'INVALID_DEPARTURE'; END IF;
 END IF;
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
 receipt:=jsonb_build_object('route_ids',routes,'candidate_id',p_candidate);
 IF automatic_departure THEN receipt:=receipt||jsonb_build_object('snapshot_id',s.snapshot_id,'departure_mode','AUTO_NOW','planned_departure_at',p_depart_at); END IF;
 INSERT INTO routing_private.requests VALUES(ngo,p_request,'AUTHORIZE',request_hash,receipt);
 INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,outcome,details)
 VALUES(ngo,'NGO','ROUTING',p_candidate,'AUTHORIZE_ROUTING','SUCCESS',jsonb_build_object('routes',routes,'candidate_digest',c.digest));
 RETURN receipt;
END $$;
CREATE OR REPLACE FUNCTION public.get_my_authorized_route(p_route uuid) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE ngo uuid:=auth.uid(); b routing_private.bindings%rowtype; r public.pickup_routes%rowtype;
 next_id uuid; ready boolean:=false; authorized boolean; blocked text; rows jsonb; can_close boolean; can_cancel boolean; snap routing_private.snapshots%rowtype;
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
 SELECT sn.* INTO STRICT snap FROM routing_private.candidates c JOIN routing_private.snapshots sn USING(snapshot_id) WHERE c.candidate_id=b.candidate_id;
 SELECT coalesce(jsonb_agg(jsonb_build_object('stop_order',i.ordinal,'task_id',i.task_id,'claim_id',t.claim_id,'task_status',t.task_status,
 'source_type',l.source_type,'title',d.title,'pickup_address',d.pickup_address,'pickup_latitude',(routing_private.snapshot_task(snap.body,t.task_id)->'listing'->>'pickup_latitude')::double precision,'pickup_longitude',(routing_private.snapshot_task(snap.body,t.task_id)->'listing'->>'pickup_longitude')::double precision,
 'pickup_road_node_id',routing_private.snapshot_task(snap.body,t.task_id)->'task'->>'pickup_road_node_id','load_kg',routing_private.snapshot_task(snap.body,t.task_id)->'task'->'load_kg','planned_arrival',ps.planned_arrival,'actual_started_at',i.consumed_at,
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
 'candidate_id',b.candidate_id,'snapshot_id',snap.snapshot_id,'actual_started_at',b.started_at,
 'depot',jsonb_build_object('road_node_id',snap.body->'ngo'->>'road_node_id','latitude',snap.body->'ngo'->'latitude','longitude',snap.body->'ngo'->'longitude'),
 'vehicle_label',(SELECT x->>'vehicle_label' FROM jsonb_array_elements(snap.body->'vehicles') x WHERE x->>'vehicle_id'=b.vehicle_id::text),
 'total_load_kg',(SELECT coalesce(sum((routing_private.snapshot_task(snap.body,(x->>'task_id')::uuid)->'task'->>'load_kg')::numeric),0) FROM jsonb_array_elements(b.plan->'stops') x),
 'pickup_count',jsonb_array_length(b.plan->'stops'),
 'pickup_location_count',(SELECT count(DISTINCT x->>'location_id') FROM jsonb_array_elements(b.plan->'stops') x),
 'validation_status',CASE WHEN EXISTS(SELECT 1 FROM routing_private.candidates c JOIN routing_private.validations v USING(candidate_id) WHERE c.candidate_id=b.candidate_id AND v.candidate_digest=c.digest) THEN 'ATTESTED' ELSE 'NOT_CONFIRMED' END,
 'route_status',r.route_status,'vehicle_id',b.vehicle_id,'depot_road_node_id',b.plan->>'start_node_id','departure_at',b.departure_at,
 'total_distance_km',r.total_distance_km,'total_duration_min',r.total_duration_min,'authorization_confirmed',authorized,
 'dispatch_block_reason',blocked,'can_close',can_close,'can_cancel',can_cancel,'stops',rows);
END $$;

-- Owner-scoped read only; NOT_FOUND is not proof that an in-flight write rolled back.
CREATE FUNCTION public.get_my_routing_authorization_receipt(p_request uuid) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' AS $$
DECLARE ngo uuid:=fleet_private.require_ngo(); prior routing_private.requests%rowtype;
BEGIN
 IF p_request IS NULL THEN RAISE EXCEPTION 'REQUEST_REQUIRED'; END IF;
 SELECT * INTO prior FROM routing_private.requests WHERE ngo_id=ngo AND request_id=p_request AND operation='AUTHORIZE';
 IF NOT FOUND THEN RETURN jsonb_build_object('contract','geolock.routing-auto-now.v1','ngo_id',ngo,'request_id',p_request,'outcome','NOT_FOUND'); END IF;
 RETURN jsonb_build_object('contract','geolock.routing-auto-now.v1','ngo_id',ngo,'request_id',p_request,'outcome','FOUND','result',prior.result);
END $$;
REVOKE ALL ON FUNCTION public.get_my_routing_authorization_receipt(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_my_routing_authorization_receipt(uuid) TO authenticated;
COMMIT;
