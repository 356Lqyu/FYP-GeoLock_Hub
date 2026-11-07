-- LOCAL PROPOSAL ONLY. Depends on 20261101-20261107 route authority package.
-- Individual deferral never releases a claim, task, reservation, or assignment.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';

DO $guard$
BEGIN
 IF current_user<>'postgres' OR session_user<>'postgres' THEN RAISE EXCEPTION 'POSTGRES_INSTALLER_REQUIRED'; END IF;
 IF to_regclass('routing_private.items') IS NULL OR to_regclass('routing_private.bindings') IS NULL
  OR to_regclass('resolution_private.cases') IS NULL OR to_regprocedure('public.get_my_authorized_route(uuid)') IS NULL
  OR to_regprocedure('public.submit_claim_reconciliation(uuid,boolean,uuid)') IS NULL
  OR to_regprocedure('public.get_my_donation_route_resolution(uuid)') IS NULL
  OR to_regprocedure('routing_private.check_remaining(uuid,uuid,timestamptz)') IS NULL
  OR to_regprocedure('routing_private.task_guard()') IS NULL
  OR to_regprocedure('fleet_private.route_vehicle_guard()') IS NULL THEN
   RAISE EXCEPTION 'ROUTING_RECONCILIATION_BASELINE_MISSING';
 END IF;
 IF (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid='routing_private.check_remaining(uuid,uuid,timestamptz)'::regprocedure)<>'5dfaad95bb36f33dde8f0ce11c9af439'
  OR (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid='routing_private.task_guard()'::regprocedure)<>'ab3101347fdbd148116c634e6c6132ad'
  OR (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid='public.submit_claim_reconciliation(uuid,boolean,uuid)'::regprocedure)<>'8cd1c3c183bb1af41bebc9094556a905'
  OR (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid='public.get_my_authorized_route(uuid)'::regprocedure)<>'df7eb088b25c083673b223f164b7dcfd'
  OR (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid='fleet_private.route_vehicle_guard()'::regprocedure)<>'30c632aae8cd73948cb82009112527f2'
 THEN RAISE EXCEPTION 'ROUTING_RECONCILIATION_SOURCE_DRIFT'; END IF;
END $guard$;

CREATE TABLE routing_private.deferred_stops(
 route_id uuid NOT NULL,
 task_id uuid NOT NULL,
 claim_id uuid NOT NULL,
 ngo_id uuid NOT NULL,
 request_id uuid NOT NULL,
 status text NOT NULL DEFAULT 'DEFERRED' CHECK(status IN('DEFERRED','RESOLVED_COLLECTED','RESOLVED_UNCOLLECTED')),
 reason text NOT NULL CHECK(reason IN('LEASE_EXPIRED','RECONCILIATION_REQUIRED')),
 deferred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 resolved_at timestamptz,
 PRIMARY KEY(route_id,task_id),
 UNIQUE(ngo_id,request_id),
 FOREIGN KEY(route_id,task_id) REFERENCES routing_private.items(route_id,task_id),
 FOREIGN KEY(claim_id) REFERENCES public.donation_claims(claim_id),
 FOREIGN KEY(ngo_id) REFERENCES public.ngo_profiles(user_id),
 CHECK((status='DEFERRED')=(resolved_at IS NULL))
);
CREATE TABLE routing_private.deferred_requests(
 ngo_id uuid NOT NULL REFERENCES public.ngo_profiles(user_id),
 request_id uuid NOT NULL,
 route_id uuid NOT NULL,
 task_id uuid NOT NULL,
 payload_digest text NOT NULL,
 result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(ngo_id,request_id)
);
CREATE TABLE routing_private.deferred_release_permits(
 task_id uuid NOT NULL REFERENCES public.pickup_tasks(task_id),
 transaction_id xid8 NOT NULL,
 PRIMARY KEY(task_id,transaction_id)
);
CREATE TABLE routing_private.deferred_events(
 event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 route_id uuid NOT NULL,
 task_id uuid NOT NULL,
 claim_id uuid NOT NULL,
 request_id uuid NOT NULL,
 status text NOT NULL CHECK(status IN('DEFERRED','RESOLVED_COLLECTED','RESOLVED_UNCOLLECTED')),
 actor_id uuid,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE routing_private.mixed_route_closures(
 route_id uuid PRIMARY KEY REFERENCES public.pickup_routes(route_id),
 ngo_id uuid NOT NULL REFERENCES public.ngo_profiles(user_id),
 request_id uuid NOT NULL,
 payload_digest text NOT NULL,
 transaction_id xid8 NOT NULL,
 result jsonb NOT NULL,
 accountability_confirmed boolean NOT NULL CHECK(accountability_confirmed),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(ngo_id,request_id)
);
REVOKE ALL ON routing_private.deferred_stops,routing_private.deferred_requests,
 routing_private.deferred_release_permits,routing_private.deferred_events,routing_private.mixed_route_closures
 FROM PUBLIC,anon,authenticated,service_role,geolock_graph_worker,geolock_planner,geolock_validator,geolock_route_resolver;

CREATE FUNCTION routing_private.reject_private_history_mutation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN RAISE EXCEPTION 'ROUTING_HISTORY_IMMUTABLE'; END $$;
CREATE TRIGGER deferred_request_immutable BEFORE UPDATE OR DELETE ON routing_private.deferred_requests
 FOR EACH ROW EXECUTE FUNCTION routing_private.reject_private_history_mutation();
CREATE TRIGGER deferred_event_immutable BEFORE UPDATE OR DELETE ON routing_private.deferred_events
 FOR EACH ROW EXECUTE FUNCTION routing_private.reject_private_history_mutation();
CREATE TRIGGER mixed_route_closure_immutable BEFORE UPDATE OR DELETE ON routing_private.mixed_route_closures
 FOR EACH ROW EXECUTE FUNCTION routing_private.reject_private_history_mutation();
CREATE FUNCTION routing_private.guard_deferred_transition() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'DEFERRED_PICKUP_HISTORY_IMMUTABLE'; END IF;
 IF ROW(NEW.route_id,NEW.task_id,NEW.claim_id,NEW.ngo_id,NEW.request_id,NEW.reason,NEW.deferred_at)
     IS DISTINCT FROM ROW(OLD.route_id,OLD.task_id,OLD.claim_id,OLD.ngo_id,OLD.request_id,OLD.reason,OLD.deferred_at)
  OR OLD.status<>'DEFERRED' OR NEW.status NOT IN('RESOLVED_COLLECTED','RESOLVED_UNCOLLECTED')
  OR NEW.resolved_at IS NULL THEN RAISE EXCEPTION 'INVALID_DEFERRED_PICKUP_TRANSITION'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER deferred_stop_transition BEFORE UPDATE OR DELETE ON routing_private.deferred_stops
 FOR EACH ROW EXECUTE FUNCTION routing_private.guard_deferred_transition();
CREATE FUNCTION routing_private.record_deferred_event() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF TG_OP='INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
  INSERT INTO routing_private.deferred_events(route_id,task_id,claim_id,request_id,status,actor_id)
  VALUES(NEW.route_id,NEW.task_id,NEW.claim_id,NEW.request_id,NEW.status,auth.uid());
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER deferred_stop_event AFTER INSERT OR UPDATE ON routing_private.deferred_stops
 FOR EACH ROW EXECUTE FUNCTION routing_private.record_deferred_event();

-- Patch the route feasibility function in place. Deferred items are omitted only
-- while still unstarted; original manifest and approved directed road matrix stay intact.
DO $patch_remaining$
DECLARE src text; old text; n integer;
BEGIN
 SELECT prosrc INTO STRICT src FROM pg_proc WHERE oid='routing_private.check_remaining(uuid,uuid,timestamptz)'::regprocedure;
 old:='SELECT task_id INTO first_id FROM routing_private.items WHERE route_id=p_route AND collected_at IS NULL ORDER BY ordinal LIMIT 1;';
 IF length(src)-length(replace(src,old,''))<>length(old) THEN RAISE EXCEPTION 'CHECK_REMAINING_NEXT_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,'SELECT task_id INTO first_id FROM routing_private.items x WHERE x.route_id=p_route AND x.released_at IS NULL AND x.collected_at IS NULL AND NOT EXISTS(SELECT 1 FROM routing_private.deferred_stops d WHERE d.route_id=x.route_id AND d.task_id=x.task_id AND d.status=''DEFERRED'') ORDER BY x.ordinal LIMIT 1;');
 old:='FOR i IN SELECT * FROM routing_private.items WHERE route_id=p_route AND collected_at IS NULL ORDER BY ordinal LOOP';
 IF length(src)-length(replace(src,old,''))<>length(old) THEN RAISE EXCEPTION 'CHECK_REMAINING_LOOP_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,'FOR i IN SELECT x.* FROM routing_private.items x WHERE x.route_id=p_route AND x.released_at IS NULL AND x.collected_at IS NULL AND NOT EXISTS(SELECT 1 FROM routing_private.deferred_stops d WHERE d.route_id=x.route_id AND d.task_id=x.task_id AND d.status=''DEFERRED'') ORDER BY x.ordinal LOOP');
 old:='WHERE x.route_id=p_route AND x.collected_at IS NULL AND le.expires_at<=finish';
 IF position(old IN src)=0 THEN RAISE EXCEPTION 'CHECK_REMAINING_LEASE_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,'WHERE x.route_id=p_route AND x.released_at IS NULL AND x.collected_at IS NULL AND NOT EXISTS(SELECT 1 FROM routing_private.deferred_stops d WHERE d.route_id=x.route_id AND d.task_id=x.task_id AND d.status=''DEFERRED'') AND le.expires_at<=finish');
 IF position('resolution_private.cases c WHERE c.route_id=p_route AND c.status IN (''AWAITING_EVIDENCE'',''MANUAL_REVIEW'')' IN src)>0 THEN RAISE EXCEPTION 'CHECK_REMAINING_ALREADY_FENCED'; END IF;
 old:='THEN RAISE EXCEPTION ''DISPATCH_AUTHORITY_STALE''; END IF;';
 IF position(old IN src)=0 THEN RAISE EXCEPTION 'CHECK_REMAINING_AUTHORITY_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,old||E'\n IF EXISTS(SELECT 1 FROM resolution_private.cases c WHERE c.route_id=p_route AND c.status IN (''AWAITING_EVIDENCE'',''MANUAL_REVIEW'')) THEN RAISE EXCEPTION ''WHOLE_ROUTE_INTERRUPTION_REQUIRES_RECONCILIATION''; END IF;');
 EXECUTE 'CREATE OR REPLACE FUNCTION routing_private.check_remaining(p_route uuid,p_next uuid,p_now timestamptz) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone=''UTC'' SET extra_float_digits=0 AS '||quote_literal(src);
END $patch_remaining$;

-- A release permit is single-transaction and minted only by the two-party
-- reconciliation RPC after it has accepted a deferred never-started outcome.
DO $patch_task_guard$
DECLARE src text; old text;
BEGIN
 SELECT prosrc INTO STRICT src FROM pg_proc WHERE oid='routing_private.task_guard()'::regprocedure;
 old:=$old$OR (NEW.task_status='STALE' AND EXISTS(SELECT 1 FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
        WHERE c.claim_id=OLD.claim_id AND c.claim_status='RECONCILIATION_REQUIRED' AND le.lease_status='RECONCILIATION_REQUIRED'))$old$;
 IF position(old IN src)=0 THEN RAISE EXCEPTION 'TASK_GUARD_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,'OR (NEW.task_status=''STALE'' AND (EXISTS(SELECT 1 FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id) WHERE c.claim_id=OLD.claim_id AND c.claim_status=''RECONCILIATION_REQUIRED'' AND le.lease_status=''RECONCILIATION_REQUIRED'') OR EXISTS(SELECT 1 FROM routing_private.deferred_release_permits p WHERE p.task_id=OLD.task_id AND p.transaction_id=pg_current_xact_id())))');
 EXECUTE 'CREATE OR REPLACE FUNCTION routing_private.task_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone=''UTC'' SET extra_float_digits=0 AS '||quote_literal(src);
END $patch_task_guard$;

-- Extend the existing participant reconciliation only at its already guarded
-- no-handover branch. Dispatched custody remains manual review.
DO $patch_claim_reconciliation$
DECLARE src text; old text; addendum text;
BEGIN
 SELECT prosrc INTO STRICT src FROM pg_proc WHERE oid='public.submit_claim_reconciliation(uuid,boolean,uuid)'::regprocedure;
 old:=$old$and not exists(select 1 from public.active_task_route_assignments a where a.task_id=v_t.task_id)
       and not exists(
      select 1 from public.pickup_route_stops s join public.pickup_routes r using(route_id)
      where s.task_id=v_t.task_id and r.route_status not in ('CANCELLED','STALE')) then$old$;
 IF position(old IN src)=0 THEN RAISE EXCEPTION 'CLAIM_RECONCILIATION_RELEASE_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,$new$and (
        (not exists(select 1 from public.active_task_route_assignments a where a.task_id=v_t.task_id)
         and not exists(select 1 from public.pickup_route_stops s join public.pickup_routes r using(route_id) where s.task_id=v_t.task_id and r.route_status not in ('CANCELLED','STALE')))
        or exists(select 1 from routing_private.deferred_stops ds join routing_private.items di on di.route_id=ds.route_id and di.task_id=ds.task_id where ds.claim_id=p_claim and ds.status='DEFERRED' and di.consumed_at IS NULL AND v_t.task_status IN ('CONFIRMED','PLANNED'))
      ) then$new$);
 old:=$old$if v_t.task_status='CONFIRMED'
       and v_l.listing_status='CLAIMED'$old$;
 IF position(old IN src)=0 THEN RAISE EXCEPTION 'CLAIM_RECONCILIATION_UNSTARTED_STATUS_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,$new$if (v_t.task_status='CONFIRMED' OR (v_t.task_status='PLANNED' AND EXISTS(SELECT 1 FROM routing_private.deferred_stops ds JOIN routing_private.items di USING(route_id,task_id) WHERE ds.claim_id=p_claim AND ds.status='DEFERRED' AND di.consumed_at IS NULL)))
       and v_l.listing_status='CLAIMED'$new$);
 old:='update public.pickup_tasks set task_status=''STALE'' where task_id=v_t.task_id;';
 IF position(old IN src)=0 THEN RAISE EXCEPTION 'CLAIM_RECONCILIATION_TASK_RELEASE_SOURCE_DRIFT'; END IF;
 addendum:='IF EXISTS(SELECT 1 FROM routing_private.deferred_stops ds JOIN routing_private.items di USING(route_id,task_id) WHERE ds.claim_id=p_claim AND ds.status=''DEFERRED'' AND di.consumed_at IS NULL) THEN INSERT INTO routing_private.deferred_release_permits(task_id,transaction_id) VALUES(v_t.task_id,pg_current_xact_id()) ON CONFLICT DO NOTHING; END IF; '||old||' IF EXISTS(SELECT 1 FROM routing_private.deferred_release_permits p WHERE p.task_id=v_t.task_id AND p.transaction_id=pg_current_xact_id()) THEN DELETE FROM public.active_task_route_assignments WHERE task_id=v_t.task_id; UPDATE routing_private.items SET release_xid=pg_current_xact_id(),released_at=clock_timestamp() WHERE task_id=v_t.task_id AND released_at IS NULL AND consumed_at IS NULL; UPDATE routing_private.deferred_stops SET status=''RESOLVED_UNCOLLECTED'',resolved_at=clock_timestamp() WHERE task_id=v_t.task_id AND status=''DEFERRED''; END IF;';
 src:=replace(src,old,addendum);
 EXECUTE 'CREATE OR REPLACE FUNCTION public.submit_claim_reconciliation(p_claim uuid,p_handover_confirmed boolean,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''pg_catalog'', ''public'', ''pg_temp'' AS '||quote_literal(src);
END $patch_claim_reconciliation$;

CREATE FUNCTION routing_private.mark_deferred_collection() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF NEW.collected_at IS NOT NULL AND OLD.collected_at IS NULL THEN
  UPDATE routing_private.deferred_stops SET status='RESOLVED_COLLECTED',resolved_at=clock_timestamp()
   WHERE route_id=NEW.route_id AND task_id=NEW.task_id AND status='DEFERRED';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER routing_mark_deferred_collection AFTER UPDATE OF collected_at ON routing_private.items
 FOR EACH ROW EXECUTE FUNCTION routing_private.mark_deferred_collection();
REVOKE ALL ON FUNCTION routing_private.reject_private_history_mutation(),
 routing_private.guard_deferred_transition(),routing_private.record_deferred_event(),
 routing_private.mark_deferred_collection()
 FROM PUBLIC,anon,authenticated,service_role,geolock_graph_worker,geolock_planner,geolock_validator,geolock_route_resolver;

CREATE FUNCTION public.defer_my_pickup_for_reconciliation(p_claim uuid,p_request uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE ngo uuid:=auth.uid(); b routing_private.bindings%rowtype; i routing_private.items%rowtype;
 t public.pickup_tasks%rowtype; c public.donation_claims%rowtype; le public.claim_leases%rowtype;
 payload jsonb; digest text; prior routing_private.deferred_requests%rowtype; result jsonb; why text;
BEGIN
 IF ngo IS NULL OR p_request IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_AND_REQUEST_REQUIRED'; END IF;
 payload:=jsonb_build_object('claim_id',p_claim); digest:=routing_private.hash(payload);
 PERFORM pg_advisory_xact_lock(hashtextextended('defer-pickup:'||ngo::text||':'||p_request::text,0));
 SELECT * INTO prior FROM routing_private.deferred_requests WHERE ngo_id=ngo AND request_id=p_request;
 IF FOUND THEN
  IF prior.payload_digest<>digest OR prior.route_id IS DISTINCT FROM (SELECT route_id FROM routing_private.items WHERE task_id=(SELECT task_id FROM public.pickup_tasks WHERE claim_id=p_claim)) THEN RAISE EXCEPTION 'REQUEST_PAYLOAD_CONFLICT'; END IF;
  RETURN prior.result;
 END IF;
 SELECT x.* INTO STRICT i FROM routing_private.items x JOIN public.pickup_tasks q USING(task_id) WHERE q.claim_id=p_claim AND x.released_at IS NULL;
 b:=routing_private.lock_route(i.route_id);
 SELECT * INTO STRICT t FROM public.pickup_tasks WHERE task_id=i.task_id;
 SELECT * INTO STRICT c FROM public.donation_claims WHERE claim_id=p_claim;
 SELECT * INTO STRICT le FROM public.claim_leases WHERE claim_id=p_claim;
 IF b.ngo_id IS DISTINCT FROM ngo OR t.ngo_user_id IS DISTINCT FROM ngo OR c.ngo_user_id IS DISTINCT FROM ngo
  OR b.closed_at IS NOT NULL
  OR (SELECT route_status FROM public.pickup_routes WHERE route_id=i.route_id) NOT IN('AUTHORISED','IN_PROGRESS')
  THEN RAISE EXCEPTION 'OWNED_STARTED_ROUTE_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM resolution_private.cases rc WHERE rc.route_id=i.route_id AND rc.status IN('AWAITING_EVIDENCE','MANUAL_REVIEW'))
  THEN RAISE EXCEPTION 'WHOLE_ROUTE_INTERRUPTION_REQUIRES_RECONCILIATION'; END IF;
 IF t.task_status NOT IN('PLANNED','CONFIRMED') OR i.consumed_at IS NOT NULL OR i.collected_at IS NOT NULL
  OR NOT EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.route_id=i.route_id AND a.task_id=i.task_id)
  OR EXISTS(SELECT 1 FROM routing_private.items x JOIN public.pickup_tasks q USING(task_id) WHERE x.route_id=i.route_id AND q.task_status='DISPATCHED')
  THEN RAISE EXCEPTION 'PICKUP_CUSTODY_REQUIRES_RECONCILIATION'; END IF;
 IF c.claim_status<>'RECONCILIATION_REQUIRED' OR le.lease_status<>'RECONCILIATION_REQUIRED'
  OR NOT EXISTS(SELECT 1 FROM public.claim_reconciliation_cases rc WHERE rc.claim_id=p_claim AND rc.case_status IN('OPEN','MANUAL_REVIEW'))
  THEN RAISE EXCEPTION 'CLAIM_RECONCILIATION_NOT_READY'; END IF;
 IF le.expires_at<=clock_timestamp() THEN why:='LEASE_EXPIRED'; ELSE why:='RECONCILIATION_REQUIRED'; END IF;
 INSERT INTO routing_private.deferred_stops(route_id,task_id,claim_id,ngo_id,request_id,reason)
 VALUES(i.route_id,i.task_id,p_claim,ngo,p_request,why);
 result:=jsonb_build_object('route_id',i.route_id,'task_id',i.task_id,'claim_id',p_claim,'status','DEFERRED','request_id',p_request);
 INSERT INTO routing_private.deferred_requests VALUES(ngo,p_request,i.route_id,i.task_id,digest,result,clock_timestamp());
 INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,request_id,claim_id,lease_id,outcome,details)
 VALUES(ngo,'NGO','ROUTE',i.route_id,'DEFER_PICKUP_RECONCILIATION',p_request,p_claim,le.lease_id,'SUCCESS',jsonb_build_object('task_id',i.task_id,'claim_id',p_claim,'reason',why,'released',false,'reassigned',false));
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.defer_my_pickup_for_reconciliation(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.defer_my_pickup_for_reconciliation(uuid,uuid) TO authenticated;

-- Preserve the old protected route read as a private implementation detail and
-- expose backend-selected next stop plus per-stop reconciliation state.
ALTER FUNCTION public.get_my_authorized_route(uuid) RENAME TO get_my_authorized_route_pre_deferral;
CREATE FUNCTION public.get_my_authorized_route(p_route uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE v jsonb; ngo uuid:=auth.uid(); next_id uuid; ok boolean:=false; blocked text; stops jsonb; mixed_ready boolean:=false;
BEGIN
 v:=public.get_my_authorized_route_pre_deferral(p_route);
 IF v->>'ngo_id' IS DISTINCT FROM ngo::text OR v->>'route_id' IS DISTINCT FROM p_route::text THEN RAISE EXCEPTION 'OWNED_MANAGED_ROUTE_NOT_FOUND'; END IF;
 SELECT x.task_id INTO next_id FROM routing_private.items x JOIN public.pickup_tasks t USING(task_id)
 WHERE x.route_id=p_route AND x.collected_at IS NULL AND x.released_at IS NULL
  AND t.task_status<>'DISPATCHED' AND NOT EXISTS(SELECT 1 FROM routing_private.deferred_stops d WHERE d.route_id=x.route_id AND d.task_id=x.task_id AND d.status='DEFERRED')
 ORDER BY x.ordinal LIMIT 1;
 IF next_id IS NOT NULL AND v->'authorization_confirmed'='true'::jsonb THEN
  BEGIN PERFORM routing_private.check_remaining(p_route,next_id,clock_timestamp()); ok:=true;
  EXCEPTION WHEN OTHERS THEN blocked:=SQLERRM; ok:=false; END;
 END IF;
 SELECT coalesce(jsonb_agg(
   s.value || jsonb_build_object(
    'needs_reconciliation',CASE WHEN d.task_id IS NOT NULL THEN d.status='DEFERRED' ELSE c.claim_status='RECONCILIATION_REQUIRED' OR le.lease_status='RECONCILIATION_REQUIRED' END,
    'lease_expired_pending_recovery',d.task_id IS NULL AND c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' AND le.expires_at<=clock_timestamp() AND NOT EXISTS(SELECT 1 FROM public.claim_reconciliation_cases rc WHERE rc.claim_id=t.claim_id AND rc.case_status IN('OPEN','MANUAL_REVIEW')),
    'deferred_for_reconciliation',COALESCE(d.status='DEFERRED',false),
    'deferred_status',d.status,
    'deferred_request_id',d.request_id,
    'can_defer',v->'authorization_confirmed'='true'::jsonb AND d.task_id IS NULL AND t.task_status IN('PLANNED','CONFIRMED') AND i.consumed_at IS NULL AND i.collected_at IS NULL AND c.claim_status='RECONCILIATION_REQUIRED' AND le.lease_status='RECONCILIATION_REQUIRED' AND EXISTS(SELECT 1 FROM public.claim_reconciliation_cases rc WHERE rc.claim_id=t.claim_id AND rc.case_status IN('OPEN','MANUAL_REVIEW')) AND (SELECT route_status FROM public.pickup_routes WHERE route_id=p_route) IN('AUTHORISED','IN_PROGRESS') AND NOT EXISTS(SELECT 1 FROM routing_private.items x JOIN public.pickup_tasks q USING(task_id) WHERE x.route_id=p_route AND q.task_status='DISPATCHED') AND NOT EXISTS(SELECT 1 FROM resolution_private.cases rc WHERE rc.route_id=p_route AND rc.status IN('AWAITING_EVIDENCE','MANUAL_REVIEW')),
    'can_start',v->'authorization_confirmed'='true'::jsonb AND ok AND s.value->>'task_id'=next_id::text AND i.consumed_at IS NULL AND t.task_status IN('PLANNED','CONFIRMED'),
    'can_complete',s.value->>'can_complete'='true'
   ) ORDER BY (s.value->>'stop_order')::integer),'[]') INTO stops
 FROM jsonb_array_elements(v->'stops') s(value)
 JOIN public.pickup_tasks t ON t.task_id=(s.value->>'task_id')::uuid
 JOIN routing_private.items i ON i.task_id=t.task_id AND i.route_id=p_route
 JOIN public.donation_claims c ON c.claim_id=t.claim_id JOIN public.claim_leases le ON le.claim_id=t.claim_id
 LEFT JOIN routing_private.deferred_stops d ON d.route_id=p_route AND d.task_id=t.task_id;
 SELECT EXISTS(SELECT 1 FROM routing_private.deferred_stops d WHERE d.route_id=p_route AND d.status='RESOLVED_UNCOLLECTED')
  AND NOT EXISTS(SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) JOIN public.donation_claims c USING(claim_id) JOIN public.claim_leases le USING(claim_id)
   LEFT JOIN routing_private.deferred_stops d ON d.route_id=i.route_id AND d.task_id=i.task_id WHERE i.route_id=p_route
   AND NOT ((i.collected_at IS NOT NULL AND t.task_status='COLLECTED' AND c.claim_status='COMPLETED' AND le.lease_status='COMPLETED')
    OR (d.status='RESOLVED_UNCOLLECTED' AND i.released_at IS NOT NULL AND t.task_status='STALE' AND c.claim_status='RELEASED' AND le.lease_status='RELEASED')))
  AND NOT EXISTS(SELECT 1 FROM public.active_task_route_assignments a JOIN public.pickup_tasks at USING(task_id) JOIN routing_private.items ai USING(route_id,task_id) WHERE a.route_id=p_route AND NOT(at.task_status='COLLECTED' AND ai.collected_at IS NOT NULL))
  AND NOT EXISTS(SELECT 1 FROM resolution_private.cases rc WHERE rc.route_id=p_route AND rc.status IN('AWAITING_EVIDENCE','MANUAL_REVIEW'))
 INTO mixed_ready;
 v:=v||jsonb_build_object('stops',stops,'next_executable_task_id',next_id,'dispatch_block_reason',CASE WHEN ok THEN NULL WHEN blocked IS NOT NULL THEN to_jsonb(blocked) ELSE v->'dispatch_block_reason' END,
  'can_close',(v->'authorization_confirmed'='true'::jsonb) AND (coalesce((v->>'can_close')::boolean,false) OR mixed_ready),
  'can_cancel',coalesce((v->>'can_cancel')::boolean,false) AND NOT EXISTS(SELECT 1 FROM routing_private.deferred_stops d WHERE d.route_id=p_route),
  'closure_outcome',CASE WHEN mixed_ready THEN 'ABANDONED' WHEN coalesce((v->>'can_close')::boolean,false) THEN 'COMPLETED' ELSE NULL END,
  'awaiting_individual_reconciliation',next_id IS NULL AND EXISTS(SELECT 1 FROM routing_private.deferred_stops d WHERE d.route_id=p_route AND d.status='DEFERRED') AND NOT EXISTS(SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) WHERE i.route_id=p_route AND i.released_at IS NULL AND i.collected_at IS NULL AND t.task_status<>'DISPATCHED' AND NOT EXISTS(SELECT 1 FROM routing_private.deferred_stops d WHERE d.route_id=i.route_id AND d.task_id=i.task_id AND d.status='DEFERRED')),
  'has_resolved_uncollected',EXISTS(SELECT 1 FROM routing_private.deferred_stops d WHERE d.route_id=p_route AND d.status='RESOLVED_UNCOLLECTED'));
 RETURN v;
END $$;
REVOKE ALL ON FUNCTION public.get_my_authorized_route_pre_deferral(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_my_authorized_route_pre_deferral(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_my_authorized_route(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_my_authorized_route(uuid) TO authenticated;

CREATE FUNCTION public.close_my_resolved_route(p_route uuid,p_depot_return_confirmed boolean,p_request uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE ngo uuid:=auth.uid(); b routing_private.bindings%rowtype; payload jsonb; digest text; prior routing_private.mixed_route_closures%rowtype; result jsonb; n integer;
BEGIN
 IF ngo IS NULL OR p_request IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_AND_REQUEST_REQUIRED'; END IF;
 payload:=jsonb_build_object('route_id',p_route,'depot_return_confirmed',p_depot_return_confirmed); digest:=routing_private.hash(payload);
 PERFORM pg_advisory_xact_lock(hashtextextended('mixed-route-close:'||ngo::text||':'||p_request::text,0));
 SELECT * INTO prior FROM routing_private.mixed_route_closures WHERE ngo_id=ngo AND request_id=p_request;
 IF FOUND THEN IF prior.route_id<>p_route OR prior.payload_digest<>digest THEN RAISE EXCEPTION 'REQUEST_PAYLOAD_CONFLICT'; END IF; RETURN prior.result; END IF;
 b:=routing_private.lock_route(p_route,false);
 IF b.ngo_id IS DISTINCT FROM ngo OR b.closed_at IS NOT NULL OR (SELECT route_status FROM public.pickup_routes WHERE route_id=p_route) NOT IN('AUTHORISED','IN_PROGRESS') THEN RAISE EXCEPTION 'OWNED_ACTIVE_ROUTE_REQUIRED'; END IF;
 IF p_depot_return_confirmed IS DISTINCT FROM true THEN RAISE EXCEPTION 'DEPOT_RETURN_CONFIRMATION_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM resolution_private.cases c WHERE c.route_id=p_route AND c.status IN('AWAITING_EVIDENCE','MANUAL_REVIEW')) THEN RAISE EXCEPTION 'WHOLE_ROUTE_INTERRUPTION_REQUIRES_RECONCILIATION'; END IF;
 IF NOT EXISTS(SELECT 1 FROM routing_private.deferred_stops d WHERE d.route_id=p_route AND d.status='RESOLVED_UNCOLLECTED') THEN RAISE EXCEPTION 'MIXED_OUTCOME_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) JOIN public.donation_claims c USING(claim_id) JOIN public.claim_leases le USING(claim_id)
   LEFT JOIN routing_private.deferred_stops d ON d.route_id=i.route_id AND d.task_id=i.task_id
   WHERE i.route_id=p_route AND NOT ((i.collected_at IS NOT NULL AND t.task_status='COLLECTED' AND c.claim_status='COMPLETED' AND le.lease_status='COMPLETED')
    OR (d.status='RESOLVED_UNCOLLECTED' AND i.released_at IS NOT NULL AND t.task_status='STALE' AND c.claim_status='RELEASED' AND le.lease_status='RELEASED')))
  THEN RAISE EXCEPTION 'ROUTE_HAS_UNRESOLVED_TASKS'; END IF;
 IF EXISTS(SELECT 1 FROM public.active_task_route_assignments a JOIN public.pickup_tasks t USING(task_id) JOIN routing_private.items i USING(route_id,task_id) WHERE a.route_id=p_route AND NOT(t.task_status='COLLECTED' AND i.collected_at IS NOT NULL)) THEN RAISE EXCEPTION 'ROUTE_ASSIGNMENT_REMAINS'; END IF;
 SELECT count(*) INTO n FROM routing_private.items WHERE route_id=p_route;
 result:=jsonb_build_object('route_id',p_route,'route_status','ABANDONED','outcome','MIXED_OUTCOME','final_pickup_count',n,'request_id',p_request);
 INSERT INTO routing_private.mixed_route_closures(route_id,ngo_id,request_id,payload_digest,transaction_id,result,accountability_confirmed)
 VALUES(p_route,ngo,p_request,digest,pg_current_xact_id(),result,true);
 DELETE FROM public.active_task_route_assignments WHERE route_id=p_route;
 UPDATE routing_private.items SET release_xid=pg_current_xact_id(),released_at=coalesce(released_at,clock_timestamp()) WHERE route_id=p_route;
 UPDATE public.pickup_routes SET route_status='ABANDONED' WHERE route_id=p_route;
 UPDATE routing_private.bindings SET closed_at=clock_timestamp() WHERE route_id=p_route;
 INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,request_id,outcome,details)
 VALUES(ngo,'NGO','ROUTE',p_route,'CLOSE_MIXED_OUTCOME_ROUTE',p_request,'SUCCESS',jsonb_build_object('final_pickup_count',n,'resolved_uncollected_count',(SELECT count(*) FROM routing_private.deferred_stops WHERE route_id=p_route AND status='RESOLVED_UNCOLLECTED'),'depot_return_confirmed',true,'vehicle_accountability_confirmed',true,'meaning','At least one independently resolved uncollected pickup; every pickup has a valid final outcome.'));
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.close_my_resolved_route(uuid,boolean,uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.close_my_resolved_route(uuid,boolean,uuid) TO authenticated;

CREATE FUNCTION public.get_my_mixed_route_close_receipt(p_request uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE ngo uuid:=auth.uid(); r routing_private.mixed_route_closures%rowtype;
BEGIN
 IF ngo IS NULL OR p_request IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_AND_REQUEST_REQUIRED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('mixed-route-close:'||ngo::text||':'||p_request::text,0));
 SELECT * INTO r FROM routing_private.mixed_route_closures WHERE ngo_id=ngo AND request_id=p_request;
 IF NOT FOUND THEN RETURN jsonb_build_object('found',false,'request_id',p_request); END IF;
 RETURN jsonb_build_object('found',true,'request_id',p_request,'route_id',r.route_id,'result',r.result);
END $$;
REVOKE ALL ON FUNCTION public.get_my_mixed_route_close_receipt(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_my_mixed_route_close_receipt(uuid) TO authenticated;

-- Linearizable, participant-scoped receipts let the client check the durable
-- request before replaying the same idempotency key after a lost response.
CREATE FUNCTION public.get_my_deferred_pickup_receipt(p_request uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE ngo uuid:=auth.uid(); r routing_private.deferred_requests%rowtype;
BEGIN
 IF ngo IS NULL OR p_request IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_AND_REQUEST_REQUIRED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('defer-pickup:'||ngo::text||':'||p_request::text,0));
 SELECT * INTO r FROM routing_private.deferred_requests WHERE ngo_id=ngo AND request_id=p_request;
 IF NOT FOUND THEN RETURN jsonb_build_object('found',false,'request_id',p_request); END IF;
 RETURN jsonb_build_object('found',true,'request_id',p_request,'route_id',r.route_id,'task_id',r.task_id,'result',r.result);
END $$;
REVOKE ALL ON FUNCTION public.get_my_deferred_pickup_receipt(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_my_deferred_pickup_receipt(uuid) TO authenticated;

-- Donor-scoped read binding a direct donation to its claim, route task and
-- claim-level reconciliation case. Hub batches are deliberately excluded:
-- their authorized counterpart is the hub administrator handled by the
-- existing get_my_reconciliation_cases / submit_claim_reconciliation path.
CREATE FUNCTION public.get_my_donation_claim_reconciliation(p_donation uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE actor uuid:=auth.uid(); result jsonb;
BEGIN
 IF actor IS NULL OR NOT EXISTS(
  SELECT 1 FROM public.donations d JOIN public.user_profiles u ON u.user_id=d.donor_user_id
  JOIN public.donor_profiles dp ON dp.user_id=d.donor_user_id
  WHERE d.donation_id=p_donation AND d.donor_user_id=actor AND u.role='DONOR')
 THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='DONATION_NOT_FOUND_OR_FORBIDDEN'; END IF;

 WITH history AS MATERIALIZED (
  SELECT c.claim_id,c.ngo_user_id,c.claim_status,l.listing_id,l.listing_status,l.source_type,
   d.donation_id,d.title,le.lease_status,le.expires_at,t.task_id,t.task_status,
   i.route_id,rc.case_id,rc.case_status,rc.opened_at,rc.resolved_at,
   (c.listing_id=l.listing_id AND l.donation_id=p_donation AND l.source_type='DIRECT_DONATION'
    AND d.donor_user_id=actor AND t.claim_id=c.claim_id AND t.listing_id=l.listing_id
    AND le.claim_id=c.claim_id AND (rc.case_id IS NULL OR
     (rc.claim_id=c.claim_id AND rc.listing_id=l.listing_id AND rc.donation_id=p_donation AND rc.source_type='DIRECT_DONATION'))) IS TRUE AS binding_valid
  FROM public.donations d
  JOIN public.listings l ON l.donation_id=d.donation_id AND l.source_type='DIRECT_DONATION'
  JOIN public.donation_claims c ON c.listing_id=l.listing_id
  JOIN public.pickup_tasks t ON t.claim_id=c.claim_id
  LEFT JOIN public.claim_leases le ON le.claim_id=c.claim_id
  LEFT JOIN routing_private.items i ON i.task_id=t.task_id AND i.released_at IS NULL
  LEFT JOIN public.claim_reconciliation_cases rc ON rc.claim_id=c.claim_id
  WHERE d.donation_id=p_donation AND d.donor_user_id=actor
 ), scoped AS (
  SELECT count(*) AS total,count(*) FILTER(WHERE case_status IN('OPEN','MANUAL_REVIEW')) AS open_count,
   coalesce(bool_and(binding_valid),true) AS all_valid FROM history
 ), decorated AS (
  SELECT h.*,de.handover_confirmed AS donor_handover,de.submitted_at AS donor_submitted_at,
   de.response AS donor_response,ne.handover_confirmed AS ngo_handover,ne.submitted_at AS ngo_submitted_at,
   ne.response AS ngo_response,
   CASE
    WHEN s.total>20 THEN 'HISTORY_TRUNCATED'
    WHEN NOT s.all_valid THEN 'ASSOCIATION_CONFLICT'
    WHEN s.open_count>1 THEN 'MULTIPLE_OPEN_CLAIM_CASES'
    WHEN case_status IN('RESOLVED_COLLECTED','RESOLVED_RELEASED') THEN 'RESOLVED_READ_ONLY'
    WHEN case_id IS NULL AND claim_status='ACTIVE' AND lease_status='ACTIVE' AND expires_at<=clock_timestamp() THEN 'WAITING_FOR_EXPIRY_RECOVERY'
    WHEN case_id IS NULL THEN 'NO_OPEN_RECONCILIATION'
    WHEN case_status<>'OPEN' THEN 'MANUAL_REVIEW_OR_TERMINAL'
    WHEN claim_status<>'RECONCILIATION_REQUIRED' OR lease_status<>'RECONCILIATION_REQUIRED'
     OR listing_status<>'CLAIMED' OR task_status NOT IN('CONFIRMED','PLANNED','DISPATCHED','COLLECTED') THEN 'PICKUP_STATE_REQUIRES_REVIEW'
    WHEN de.request_id IS NOT NULL THEN 'DONOR_EVIDENCE_ALREADY_RECORDED'
    ELSE NULL END AS blocker
  FROM history h CROSS JOIN scoped s
  LEFT JOIN LATERAL (SELECT e.request_id,e.handover_confirmed,e.submitted_at,e.response FROM public.claim_reconciliation_evidence e
   WHERE e.case_id=h.case_id AND e.actor_user_id=actor ORDER BY e.submitted_at DESC LIMIT 1) de ON true
  LEFT JOIN LATERAL (SELECT e.handover_confirmed,e.submitted_at,e.response FROM public.claim_reconciliation_evidence e
   WHERE e.case_id=h.case_id AND e.actor_user_id=h.ngo_user_id ORDER BY e.submitted_at DESC LIMIT 1) ne ON true
 )
 SELECT jsonb_build_object('contract','geolock.donor-claim-reconciliation.v1','donation_id',p_donation,
  'title',(SELECT title FROM public.donations WHERE donation_id=p_donation),'server_now',statement_timestamp(),
  'history_truncated',s.total>20,'association_conflict',NOT s.all_valid OR s.open_count>1,
  'contexts',coalesce((SELECT jsonb_agg(jsonb_build_object(
   'donation_id',x.donation_id,'claim_id',x.claim_id,'listing_id',x.listing_id,'task_id',x.task_id,'route_id',x.route_id,
   'case_id',x.case_id,'case_status',x.case_status,'opened_at',x.opened_at,'resolved_at',x.resolved_at,
   'claim_status',x.claim_status,'lease_status',x.lease_status,'lease_expires_at',x.expires_at,
   'task_status',x.task_status,'source_type',x.source_type,'can_submit_evidence',x.blocker IS NULL,
   'blocking_reason',x.blocker,
   'donor_evidence',jsonb_build_object('handover_confirmed',x.donor_handover,'submitted_at',x.donor_submitted_at,'response',x.donor_response),
   'ngo_evidence',jsonb_build_object('handover_confirmed',x.ngo_handover,'submitted_at',x.ngo_submitted_at,'response',x.ngo_response),
   'allowed_assertions',CASE WHEN x.blocker IS NULL THEN jsonb_build_array('COLLECTED','NOT_COLLECTED') ELSE '[]'::jsonb END
  ) ORDER BY x.opened_at DESC NULLS LAST,x.claim_id) FROM decorated x),'[]'::jsonb))
 INTO result FROM scoped s;
 RETURN result;
END $$;
ALTER FUNCTION public.get_my_donation_claim_reconciliation(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_my_donation_claim_reconciliation(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_my_donation_claim_reconciliation(uuid) TO authenticated;

-- A participant can read only their own claim evidence receipt.
CREATE FUNCTION public.get_my_claim_reconciliation_receipt(p_request uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE actor uuid:=auth.uid(); r record;
BEGIN
 IF actor IS NULL OR p_request IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_AND_REQUEST_REQUIRED'; END IF;
 SELECT e.request_id,e.case_id,e.actor_user_id,e.handover_confirmed,e.response,cl.claim_id,l.source_type
 INTO r FROM public.claim_reconciliation_evidence e JOIN public.claim_reconciliation_cases c USING(case_id)
 JOIN public.donation_claims cl ON cl.claim_id=c.claim_id JOIN public.listings l ON l.listing_id=cl.listing_id
 LEFT JOIN public.donations d ON d.donation_id=l.donation_id
 LEFT JOIN public.hub_batches hb ON hb.batch_id=l.batch_id LEFT JOIN public.community_hubs h USING(hub_id)
 JOIN public.user_profiles u ON u.user_id=actor
 WHERE e.request_id=p_request AND e.actor_user_id=actor AND
  ((u.role='NGO' AND cl.ngo_user_id=actor) OR
   (l.source_type='DIRECT_DONATION' AND u.role='DONOR' AND d.donor_user_id=actor) OR
   (l.source_type='HUB_BATCH' AND u.role='HUB_ADMIN' AND h.admin_user_id=actor));
 IF NOT FOUND THEN RETURN jsonb_build_object('found',false,'request_id',p_request); END IF;
 RETURN jsonb_build_object('found',true,'request_id',r.request_id,'case_id',r.case_id,'claim_id',r.claim_id,
  'handover_confirmed',r.handover_confirmed,'result',r.response);
END $$;
ALTER FUNCTION public.get_my_claim_reconciliation_receipt(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_my_claim_reconciliation_receipt(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.get_my_claim_reconciliation_receipt(uuid) TO authenticated;

-- Permit the separate mixed-outcome route finalizer while preserving the
-- whole-route interruption finalizer as an independent authorized path.
DO $patch_route_guard$
DECLARE src text; old text;
BEGIN
 SELECT prosrc INTO STRICT src FROM pg_proc WHERE oid='fleet_private.route_vehicle_guard()'::regprocedure;
 old:='IF NEW.route_status=''ABANDONED'' AND NOT EXISTS(SELECT 1 FROM resolution_private.finalizations f JOIN resolution_private.cases c USING(case_id) WHERE f.route_id=NEW.route_id AND f.transaction_id=pg_current_xact_id() AND c.status=''RESOLVED'') THEN RAISE EXCEPTION ''RESOLUTION_FINALIZER_REQUIRED''; END IF;';
 IF position(old IN src)=0 THEN RAISE EXCEPTION 'ROUTE_GUARD_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,'IF NEW.route_status=''ABANDONED'' AND NOT (EXISTS(SELECT 1 FROM resolution_private.finalizations f JOIN resolution_private.cases c USING(case_id) WHERE f.route_id=NEW.route_id AND f.transaction_id=pg_current_xact_id() AND c.status=''RESOLVED'') OR EXISTS(SELECT 1 FROM routing_private.mixed_route_closures m WHERE m.route_id=NEW.route_id AND m.transaction_id=pg_current_xact_id() AND m.accountability_confirmed)) THEN RAISE EXCEPTION ''RESOLUTION_FINALIZER_REQUIRED''; END IF;');
 EXECUTE 'CREATE OR REPLACE FUNCTION fleet_private.route_vehicle_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS '||quote_literal(src);
END $patch_route_guard$;

COMMIT;
