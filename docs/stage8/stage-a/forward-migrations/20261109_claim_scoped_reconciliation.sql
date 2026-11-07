-- GeoLock Hub forward migration: claim-scoped expiry reconciliation.
-- Depends on the 20261101-20261108 Stage 8 routing and reconciliation chain.
-- Local review artifact only; do not apply to DEV without approved preflight.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';

DO $preflight$
BEGIN
 IF current_user<>'postgres' OR session_user<>'postgres' THEN
  RAISE EXCEPTION 'POSTGRES_INSTALLER_REQUIRED';
 END IF;
 IF to_regclass('routing_private.items') IS NULL
  OR to_regclass('routing_private.deferred_stops') IS NULL
  OR to_regclass('routing_private.deferred_release_permits') IS NULL
  OR to_regclass('resolution_private.cases') IS NULL
  OR to_regprocedure('routing_private.lock_route(uuid,boolean)') IS NULL
  OR to_regprocedure('routing_private.check_remaining(uuid,uuid,timestamptz)') IS NULL
  OR to_regprocedure('public.recover_expired_claims(integer)') IS NULL
  OR to_regprocedure('public.defer_my_pickup_for_reconciliation(uuid,uuid)') IS NULL
  OR to_regprocedure('public.get_my_authorized_route(uuid)') IS NULL
  OR to_regprocedure('public.report_my_route_interruption(uuid,text,uuid)') IS NULL
  OR to_regprocedure('public.submit_claim_reconciliation(uuid,boolean,uuid)') IS NULL THEN
  RAISE EXCEPTION 'CLAIM_SCOPED_ROUTING_BASELINE_MISSING';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.pickup_tasks'::regclass
   AND tgname='routing_task_authority' AND tgenabled='O')
  OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid='routing_private.task_guard()'::regprocedure
   AND prosrc LIKE '%deferred_release_permits%') THEN
  RAISE EXCEPTION 'PICKUP_TASK_AUTHORITY_GUARD_MISSING';
 END IF;
END $preflight$;

-- Recovery first locks an authorized route when the task belongs to one, then
-- locks claim/lease/listing/task in the same scope as pickup operations. This
-- gives expiry, start and completion a single serialized winner.
CREATE FUNCTION routing_private.lock_route_for_recovery(p_route uuid)
RETURNS routing_private.bindings LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE b routing_private.bindings%rowtype; ids uuid[];
BEGIN
 IF current_setting('transaction_isolation')<>'read committed' THEN
  RAISE EXCEPTION 'READ_COMMITTED_REQUIRED';
 END IF;
 SELECT * INTO STRICT b FROM routing_private.bindings WHERE route_id=p_route;
 PERFORM 1 FROM public.ngo_profiles WHERE user_id=b.ngo_id FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ROUTE_NGO_REQUIRED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('routing-ngo:'||b.ngo_id::text,0));
 SELECT array_agg(task_id ORDER BY task_id) INTO ids
   FROM routing_private.items WHERE route_id=p_route;
 PERFORM routing_private.lock_sources(ids);
 PERFORM 1 FROM public.vehicles WHERE vehicle_id=b.vehicle_id FOR UPDATE;
 PERFORM 1 FROM public.pickup_routes WHERE route_id=p_route FOR UPDATE;
 PERFORM 1 FROM public.pickup_tasks WHERE task_id=ANY(ids) ORDER BY task_id FOR UPDATE;
 SELECT * INTO STRICT b FROM routing_private.bindings WHERE route_id=p_route FOR UPDATE;
 RETURN b;
END $$;
REVOKE ALL ON FUNCTION routing_private.lock_route_for_recovery(uuid)
 FROM PUBLIC,anon,authenticated,service_role,geolock_graph_worker,geolock_planner,
      geolock_validator,geolock_route_resolver;

CREATE OR REPLACE FUNCTION routing_private.release_expired_unstarted_stop(
 p_claim uuid,p_task uuid,p_ngo uuid,p_route uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE i routing_private.items%rowtype; r public.pickup_routes%rowtype;
        next_id uuid; req uuid:=gen_random_uuid();
BEGIN
 SELECT * INTO i FROM routing_private.items
 WHERE route_id=p_route AND task_id=p_task AND released_at IS NULL FOR UPDATE;
 IF NOT FOUND OR i.consumed_at IS NOT NULL OR i.collected_at IS NOT NULL THEN RETURN false; END IF;
 SELECT * INTO r FROM public.pickup_routes WHERE route_id=p_route;
 IF NOT FOUND OR r.route_status NOT IN('AUTHORISED','IN_PROGRESS') THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM resolution_private.cases c
   WHERE c.route_id=p_route AND c.status IN('AWAITING_EVIDENCE','MANUAL_REVIEW')) THEN
  RETURN false; -- retain the legacy whole-route hold until authorized resolution
 END IF;
 IF EXISTS(SELECT 1 FROM routing_private.deferred_stops d
   WHERE d.route_id=p_route AND d.task_id=p_task) THEN RETURN false; END IF;
 SELECT x.task_id INTO next_id FROM routing_private.items x
 JOIN public.pickup_tasks t USING(task_id)
 WHERE x.route_id=p_route AND x.released_at IS NULL AND x.collected_at IS NULL
  AND x.task_id<>p_task
  AND t.task_status<>'DISPATCHED'
  AND NOT EXISTS(SELECT 1 FROM routing_private.deferred_stops d
    WHERE d.route_id=x.route_id AND d.task_id=x.task_id AND d.status='DEFERRED')
 ORDER BY x.ordinal LIMIT 1;
 IF next_id IS NULL OR EXISTS(
   SELECT 1 FROM routing_private.items x
   JOIN public.pickup_tasks t USING(task_id)
   WHERE x.route_id=p_route AND x.task_id<>p_task
     AND x.released_at IS NULL AND t.task_status='DISPATCHED'
 ) OR EXISTS(
   SELECT 1 FROM routing_private.items x
   JOIN public.pickup_tasks t USING(task_id)
   JOIN public.donation_claims c USING(claim_id)
   JOIN public.claim_leases le USING(claim_id)
   WHERE x.route_id=p_route AND x.task_id<>p_task
     AND x.released_at IS NULL AND x.consumed_at IS NULL AND x.collected_at IS NULL
     AND t.task_status='PLANNED' AND c.claim_status='ACTIVE'
     AND le.lease_status='ACTIVE' AND le.expires_at<=clock_timestamp()
 ) THEN
  -- A different in-progress pickup makes check_remaining report
  -- PREVIOUS_PICKUP_UNRESOLVED; another expired, unstarted active stop also
  -- makes route feasibility fail on its lease. Neither is evidence that this
  -- PLANNED target was collected. Detach this claim independently; route start
  -- will revalidate feasibility after other dispatches finish; recovery
  -- handles each other expired stop, and check_remaining will revalidate
  -- the resulting route before any later pickup starts.
  INSERT INTO routing_private.deferred_stops(route_id,task_id,claim_id,ngo_id,request_id,reason)
  VALUES(p_route,p_task,p_claim,p_ngo,req,'LEASE_EXPIRED');
 ELSE
  -- Catch only the route-feasibility rejection. P0001 raised by the deferral
  -- insert, guards, or any later statement must abort rather than be treated
  -- as an ordinary infeasible route. The insert is inside this subtransaction
  -- so an expected feasibility rejection leaves no partial deferred-stop row.
  BEGIN
   INSERT INTO routing_private.deferred_stops(route_id,task_id,claim_id,ngo_id,request_id,reason)
   VALUES(p_route,p_task,p_claim,p_ngo,req,'LEASE_EXPIRED');
   PERFORM routing_private.check_remaining(p_route,next_id,clock_timestamp());
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
   IF SQLERRM NOT IN (
     'ROUTE_BINDING_DRIFT','DISPATCH_AUTHORITY_STALE',
     'WHOLE_ROUTE_INTERRUPTION_REQUIRES_RECONCILIATION',
     'BEFORE_AUTHORIZED_DEPARTURE','PREVIOUS_PICKUP_UNRESOLVED',
     'STOP_ORDER_REQUIRED','DISPATCH_SOURCE_STALE',
     'DISPATCH_WINDOW_OR_LEASE_EXPIRED','REMAINING_ROUTE_INFEASIBLE'
   ) THEN RAISE; END IF;
   RETURN false;
  END;
 END IF;
 INSERT INTO routing_private.deferred_release_permits(task_id,transaction_id)
 VALUES(p_task,pg_current_xact_id()) ON CONFLICT DO NOTHING;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION routing_private.release_expired_unstarted_stop(uuid,uuid,uuid,uuid)
 FROM PUBLIC,anon,authenticated,service_role,geolock_graph_worker,geolock_planner,
      geolock_validator,geolock_route_resolver;

DO $patch_recovery$
DECLARE src text; old text; new text;
BEGIN
 SELECT prosrc INTO STRICT src FROM pg_proc
 WHERE oid='public.recover_expired_claims(integer)'::regprocedure;
 -- PostgreSQL preserves the source line endings supplied when the function was
 -- created. Normalize only CRLF to LF before exact, count-checked replacements;
 -- the resulting PL/pgSQL body is valid and stable regardless of client OS.
 src:=replace(src,chr(13)||chr(10),chr(10));
 old:='for update of c skip locked'
   || chr(10)
   || repeat(chr(32),4)
   || 'limit greatest(1,least(coalesce(p_limit,100),1000))';
 new:=$new$limit greatest(1,least(coalesce(p_limit,100),1000))$new$;
 IF position(old IN src)=0 OR (length(src)-length(replace(src,old,'')))/length(old)<>1 THEN RAISE EXCEPTION 'RECOVERY_CANDIDATE_LOCK_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,new);
 old:='select c.* into v_c from public.donation_claims c where c.claim_id=v_rec.claim_id;'
  || chr(10)
  || repeat(chr(32),4)
  || '-- Current row lock was obtained on claim above; follow V3 writer order.';
 new:=$new$-- Route execution locks route scope before claim/task rows. Lock the same
    -- scope before taking the claim lock so pickup and expiry cannot race.
    v_route_id:=NULL;
    SELECT i.route_id INTO v_route_id FROM routing_private.items i
      WHERE i.task_id=(SELECT t.task_id FROM public.pickup_tasks t WHERE t.claim_id=v_rec.claim_id)
        AND i.released_at IS NULL;
    IF v_route_id IS NOT NULL THEN
      v_binding:=routing_private.lock_route_for_recovery(v_route_id);
    END IF;
    SELECT c.* INTO v_c FROM public.donation_claims c
      WHERE c.claim_id=v_rec.claim_id FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN CONTINUE; END IF;$new$;
 IF position(old IN src)=0 OR (length(src)-length(replace(src,old,'')))/length(old)<>1 THEN RAISE EXCEPTION 'RECOVERY_ROUTE_LOCK_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,new);
 old:='or v_t.task_status<>''CONFIRMED'''
   || chr(10) || repeat(chr(32),6)
   || 'or exists(select 1 from public.active_task_route_assignments a where a.task_id=v_t.task_id)'
   || chr(10) || repeat(chr(32),6)
   || 'or exists(select 1 from public.pickup_route_stops s'
   || chr(10) || repeat(chr(32),8)
   || 'where s.task_id=v_t.task_id)';
 new:=$new$or v_t.task_status NOT IN ('CONFIRMED','PLANNED')
      or exists(select 1 from routing_private.items i where i.task_id=v_t.task_id
        and (i.consumed_at IS NOT NULL OR i.collected_at IS NOT NULL OR i.released_at IS NOT NULL))
      or (exists(select 1 from public.active_task_route_assignments a where a.task_id=v_t.task_id)
        and not exists(select 1 from routing_private.items i where i.task_id=v_t.task_id
          and i.released_at IS NULL))
      or exists(select 1 from resolution_private.cases rc
        join routing_private.items i on i.route_id=rc.route_id
        where i.task_id=v_t.task_id and rc.status IN ('AWAITING_EVIDENCE','MANUAL_REVIEW'))$new$;
 IF position(old IN src)=0 OR (length(src)-length(replace(src,old,'')))/length(old)<>1 THEN RAISE EXCEPTION 'RECOVERY_ROUTE_ACTIVITY_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,new);
 old:='v_uncertain:=v_uncertain'
   || chr(10) || repeat(chr(32),6)
   || 'or (v_l.listing_expires_at is not null and v_l.listing_expires_at<=clock_timestamp());'
   || chr(10) || repeat(chr(32),4)
   || 'if v_uncertain then';
 new:=$new$-- A route assignment is not custody evidence. A route member is released
    -- only after an unstarted stop is safely detached from its immutable plan.
    -- Listing expiry controls whether the released listing is reopened; it does
    -- not change the authoritative pickup/custody state.
    IF NOT v_uncertain AND EXISTS(SELECT 1 FROM routing_private.items i
      WHERE i.task_id=v_t.task_id AND i.released_at IS NULL) THEN
      IF NOT routing_private.release_expired_unstarted_stop(
        v_c.claim_id,v_t.task_id,v_c.ngo_user_id,v_route_id) THEN v_uncertain:=true; END IF;
    END IF;
    IF v_uncertain THEN$new$;
 IF position(old IN src)=0 OR (length(src)-length(replace(src,old,'')))/length(old)<>1 THEN RAISE EXCEPTION 'RECOVERY_SAFE_ROUTE_RELEASE_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,new);
 old:=$old$update public.pickup_tasks set task_status='STALE' where task_id=v_t.task_id;$old$;
 new:=$new$update public.pickup_tasks set task_status='STALE' where task_id=v_t.task_id;
      IF EXISTS(SELECT 1 FROM routing_private.deferred_release_permits p
        WHERE p.task_id=v_t.task_id AND p.transaction_id=pg_current_xact_id()) THEN
        DELETE FROM public.active_task_route_assignments WHERE task_id=v_t.task_id;
        UPDATE routing_private.items SET release_xid=pg_current_xact_id(),released_at=clock_timestamp()
          WHERE task_id=v_t.task_id AND released_at IS NULL AND consumed_at IS NULL;
        UPDATE routing_private.deferred_stops SET status='RESOLVED_UNCOLLECTED',resolved_at=clock_timestamp()
          WHERE task_id=v_t.task_id AND status='DEFERRED';
      END IF;$new$;
 IF position(old IN src)=0 OR (length(src)-length(replace(src,old,'')))/length(old)<>1 THEN RAISE EXCEPTION 'RECOVERY_ROUTE_RELEASE_FINALIZE_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,new);
 -- Listing status and donation status are coupled by the deferred lifecycle
 -- guard: AVAILABLE/BATCHED donations require an AVAILABLE listing. Preserve
 -- the original expiry timestamp; claim_listing and eligibility reads reject
 -- past expiries, so this does not make an expired listing claimable again.
 old:='if v_l.listing_status=''CLAIMED'' and (v_l.listing_expires_at is null or v_l.listing_expires_at>clock_timestamp()) then'
   || chr(10) || repeat(chr(32),8)
   || 'update public.listings set listing_status=''AVAILABLE'',listing_version=listing_version+1'
   || chr(10) || repeat(chr(32),10)
   || 'where listing_id=v_l.listing_id and listing_status=''CLAIMED'';'
   || chr(10) || repeat(chr(32),8)
   || 'perform public.geolock_transition_listing_donations(v_l.listing_id,''CLAIMED'','
   || chr(10) || repeat(chr(32),10)
   || 'case when v_l.source_type=''DIRECT_DONATION'' then ''AVAILABLE'' else ''BATCHED'' end,v_c.claim_id,NULL,''EXPIRED_SAFE_RELEASE'');'
   || chr(10) || repeat(chr(32),6) || 'else'
   || chr(10) || repeat(chr(32),8)
   || 'raise exception ''RECOVERY_LISTING_REOPEN_PRECONDITION_CHANGED'';'
   || chr(10) || repeat(chr(32),6) || 'end if;';
 new:=$new$if v_l.listing_status='CLAIMED' THEN
        update public.listings set listing_status='AVAILABLE',listing_version=listing_version+1
          where listing_id=v_l.listing_id and listing_status='CLAIMED';
        perform public.geolock_transition_listing_donations(v_l.listing_id,'CLAIMED',
          case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end,
          v_c.claim_id,NULL,'EXPIRED_SAFE_RELEASE');
      ELSE
        raise exception 'RECOVERY_LISTING_REOPEN_PRECONDITION_CHANGED';
      END IF;$new$;
 IF position(old IN src)=0 OR (length(src)-length(replace(src,old,'')))/length(old)<>1 THEN RAISE EXCEPTION 'RECOVERY_LISTING_EXPIRY_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,new);
 old:=$old$HANDOVER_OR_ROUTE_ACTIVITY_UNCERTAIN$old$;
 new:=$new$HANDOVER_OR_AUTHORITATIVE_STATE_UNCERTAIN$new$;
 IF position(old IN src)=0 OR (length(src)-length(replace(src,old,'')))/length(old)<>1 THEN
  RAISE EXCEPTION 'RECOVERY_REASON_SOURCE_DRIFT';
 END IF;
 src:=replace(src,old,new);
 -- These locals are added to the deployed recovery function body.
 IF position('v_route_id uuid' IN src)=0 THEN
  old:=$old$v_uncertain boolean; v_count integer:=0; v_did uuid; v_cfg text;$old$;
  new:=$new$v_uncertain boolean; v_count integer:=0; v_did uuid; v_cfg text; v_route_id uuid; v_binding routing_private.bindings%rowtype;$new$;
  IF position(old IN src)=0 OR (length(src)-length(replace(src,old,'')))/length(old)<>1 THEN
   RAISE EXCEPTION 'RECOVERY_LOCAL_DECLARATION_SOURCE_DRIFT';
  END IF;
  src:=replace(src,old,new);
 END IF;
 EXECUTE 'CREATE OR REPLACE FUNCTION public.recover_expired_claims(p_limit integer DEFAULT 100) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''pg_catalog'', ''public'', ''extensions'', ''pg_temp'' AS '||quote_literal(src);
END $patch_recovery$;

-- A protected participant may defer the affected unstarted claim while another
-- stop is dispatched. The target stop still must be unconsumed and uncollected.
DO $patch_defer$
DECLARE src text; old text;
BEGIN
 SELECT prosrc INTO STRICT src FROM pg_proc
 WHERE oid='public.defer_my_pickup_for_reconciliation(uuid,uuid)'::regprocedure;
 src:=replace(src,chr(13)||chr(10),chr(10));
 old:=$old$OR EXISTS(SELECT 1 FROM routing_private.items x JOIN public.pickup_tasks q USING(task_id) WHERE x.route_id=i.route_id AND q.task_status='DISPATCHED')$old$;
 IF position(old IN src)=0 OR (length(src)-length(replace(src,old,'')))/length(old)<>1 THEN RAISE EXCEPTION 'DEFER_OTHER_DISPATCH_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,'');
 EXECUTE 'CREATE OR REPLACE FUNCTION public.defer_my_pickup_for_reconciliation(p_claim uuid,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone=''UTC'' SET extra_float_digits=0 AS '||quote_literal(src);
 SELECT prosrc INTO STRICT src FROM pg_proc
 WHERE oid='public.get_my_authorized_route(uuid)'::regprocedure;
 src:=replace(src,chr(13)||chr(10),chr(10));
 old:=$old$AND NOT EXISTS(SELECT 1 FROM routing_private.items x JOIN public.pickup_tasks q USING(task_id) WHERE x.route_id=p_route AND q.task_status='DISPATCHED')$old$;
 IF position(old IN src)=0 OR (length(src)-length(replace(src,old,'')))/length(old)<>1 THEN RAISE EXCEPTION 'ROUTE_READ_DEFER_GUARD_SOURCE_DRIFT'; END IF;
 src:=replace(src,old,'');
 EXECUTE 'CREATE OR REPLACE FUNCTION public.get_my_authorized_route(p_route uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone=''UTC'' SET extra_float_digits=0 AS '||quote_literal(src);
END $patch_defer$;

-- New whole-route participant reports are retired. Reads, evidence submission,
-- immutable records and restricted finalization remain for existing legacy cases.
DO $legacy_report_guard$
DECLARE src text; old text; new text;
BEGIN
 SELECT prosrc INTO STRICT src FROM pg_proc
 WHERE oid='public.report_my_route_interruption(uuid,text,uuid)'::regprocedure;
 src:=replace(src,chr(13)||chr(10),chr(10));
 old:=$old$IF NOT FOUND THEN$old$;
 new:=$new$IF NOT FOUND THEN RAISE EXCEPTION 'NEW_ROUTE_INTERRUPTION_REPORTS_RETIRED'; END IF;
 IF false THEN$new$;
 IF position(old IN src)=0 OR (length(src)-length(replace(src,old,'')))/length(old)<>1 THEN
  RAISE EXCEPTION 'LEGACY_ROUTE_REPORT_SOURCE_DRIFT';
 END IF;
 src:=replace(src,old,new);
 EXECUTE 'CREATE OR REPLACE FUNCTION public.report_my_route_interruption(p_route uuid,p_reason text,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS '||quote_literal(src);
END $legacy_report_guard$;

REVOKE ALL ON FUNCTION routing_private.release_expired_unstarted_stop(uuid,uuid,uuid,uuid)
 FROM PUBLIC,anon,authenticated,service_role,geolock_graph_worker,geolock_planner,
      geolock_validator,geolock_route_resolver;
COMMENT ON FUNCTION public.recover_expired_claims(integer) IS
 'Claim-scoped lease recovery. Unstarted managed stops are detached only when route feasibility and custody guards pass; uncertain custody stays reconciliation-required.';
COMMENT ON FUNCTION public.submit_claim_reconciliation(uuid,boolean,uuid) IS
 'Individual claim custody statements. Insufficient or conflicting evidence remains held; never auto-releases a dispatched claim.';
COMMIT;
