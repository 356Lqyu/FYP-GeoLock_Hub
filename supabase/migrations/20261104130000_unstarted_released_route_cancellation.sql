-- Canonical LOCAL ONLY coordination/lifecycle migration. Never deployed here.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';
DO $$ BEGIN
 IF current_user<>'postgres' OR session_user<>'postgres' OR current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'POSTGRES_READ_COMMITTED_REQUIRED'; END IF;
 IF (SELECT md5(replace(prosrc,chr(13),'')) FROM pg_proc WHERE oid='public.cancel_my_unstarted_route(uuid)'::regprocedure) IS DISTINCT FROM '25d5d50b727abd9cf94fd0b9c479e612'
 OR (SELECT md5(replace(prosrc,chr(13),'')) FROM pg_proc WHERE oid='public.close_my_resolved_route(uuid,boolean,uuid)'::regprocedure) IS DISTINCT FROM '1de1767851ac4a68e68e3c17f8e5d421'
 OR (SELECT md5(replace(prosrc,chr(13),'')) FROM pg_proc WHERE oid='public.get_my_authorized_route(uuid)'::regprocedure) IS DISTINCT FROM '167e9843e6e026df8844f441af77fded'
 THEN RAISE EXCEPTION 'SAFE_CANCELLATION_SOURCE_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pickup_tasks'::regclass AND tgname='routing_task_authority' AND tgenabled='O') THEN RAISE EXCEPTION 'PICKUP_TASK_AUTHORITY_GUARD_MISSING'; END IF;
END $$;

-- Every function whose body is patched is pinned, not just the three core APIs.
DO $source_contracts$ DECLARE f record; actual text; BEGIN
 FOR f IN SELECT * FROM (VALUES
  ('public.close_my_collected_route(uuid,boolean)','5f83aea95b8c8971ea3bfcbcb8b3c18a'),
  ('public.enforce_donation_transition()','50f7c982be9c6cce75174e09f73649ae'),
  ('public.geolock_assert_donation_lifecycle(uuid)','3e7df59a90533e0708c51767889d930e'),
  ('public.get_my_authorized_route_pre_deferral(uuid)','df7eb088b25c083673b223f164b7dcfd'),
  ('public.get_my_claim_cards_v2()','44da3209586085a93e76204e37288f13'),
  ('public.get_my_donation_claim_reconciliation(uuid)','b23b62f1d1fad22a9eabc907157ea7d1'),
  ('public.get_my_reconciliation_cases()','ef135eb954b7052703b4c1df5315b312'),
  ('routing_private.check_remaining(uuid,uuid,timestamptz)','fefd041705ec87001a10135923ac7acc'),
  ('routing_private.permit_reconciled_collection(uuid)','c5bbed4368a64f83ed837d6195b02050'),
  ('routing_private.task_guard()','4012fed7dad4a6f7767d39bed3de70e6'),
  ('public.get_claimed_listing_detail(uuid)','b15fb1c6260eee67a4eb73766effcf15'),
  ('public.begin_my_routing_snapshot(uuid,uuid,uuid[])','dca3ee04e8fbf991c4ef0993930ec185')
 ) expected(signature,fingerprint) LOOP
  SELECT md5(replace(prosrc,chr(13),'')) INTO actual FROM pg_proc WHERE oid=to_regprocedure(f.signature);
  IF actual IS DISTINCT FROM f.fingerprint THEN RAISE EXCEPTION 'COORDINATION_SOURCE_DRIFT:%',f.signature; END IF;
 END LOOP;
 IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
  AND p.proname IN('get_my_reconciliation_cases','get_my_donation_claim_reconciliation','get_my_claim_cards_v2'))<>3
 THEN RAISE EXCEPTION 'COORDINATION_READER_SET_DRIFT'; END IF;
END $source_contracts$;

-- Authorization is evaluated from live rows, never a historical route/snapshot.
CREATE FUNCTION routing_private.coord_location_allowed(p_claim uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id)
 JOIN public.listings l USING(listing_id) JOIN public.ngo_profiles n ON n.user_id=c.ngo_user_id
 WHERE c.claim_id=p_claim AND c.ngo_user_id=auth.uid() AND n.active_flag
 AND c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' AND le.expires_at>statement_timestamp()
 AND l.listing_status='CLAIMED' AND (l.listing_expires_at IS NULL OR l.listing_expires_at>statement_timestamp()))
$$;

-- Stored snapshot evidence/digest remains unchanged. Clients only consume its ID;
-- a replay may no longer disclose observations whose pickup authority has ended.
CREATE FUNCTION routing_private.coord_snapshot_for_client(p_snapshot jsonb) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT p_snapshot || jsonb_build_object('client_projection',true,'body',
  (p_snapshot->'body') || jsonb_build_object('observations',coalesce((
   SELECT jsonb_agg(o.value ORDER BY o.ordinality) FROM jsonb_array_elements(p_snapshot->'body'->'observations') WITH ORDINALITY o
   JOIN public.pickup_tasks t ON t.task_id=(o.value->'task'->>'task_id')::uuid
   WHERE t.ngo_user_id=auth.uid() AND t.task_status IN('CONFIRMED','PLANNED','DISPATCHED')
   AND t.claim_id=(o.value->'claim'->>'claim_id')::uuid
   AND routing_private.coord_location_allowed(t.claim_id)), '[]'::jsonb)))
$$;

DO $privacy_patches$ DECLARE src text; f record; anchor text; BEGIN
 SELECT replace(prosrc,chr(13),'') INTO src FROM pg_proc WHERE oid='public.get_my_authorized_route_pre_deferral(uuid)'::regprocedure;
 FOR f IN SELECT * FROM (VALUES
  ('d.pickup_address'),
  ('(routing_private.snapshot_task(snap.body,t.task_id)->''listing''->>''pickup_latitude'')::double precision'),
  ('(routing_private.snapshot_task(snap.body,t.task_id)->''listing''->>''pickup_longitude'')::double precision'),
  ('routing_private.snapshot_task(snap.body,t.task_id)->''task''->>''pickup_road_node_id''')
 ) a(expression) LOOP
  anchor:=f.expression;
  IF (length(src)-length(replace(src,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'ROUTE_LOCATION_ANCHOR_DRIFT'; END IF;
 src:=replace(src,anchor,'CASE WHEN authorized AND routing_private.coord_location_allowed(t.claim_id) THEN '||anchor||' ELSE NULL END');
 END LOOP;
 EXECUTE 'CREATE OR REPLACE FUNCTION public.get_my_authorized_route_pre_deferral(p_route uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone=''UTC'' SET extra_float_digits=0 AS '||quote_literal(src);
 SELECT replace(prosrc,chr(13),'') INTO src FROM pg_proc WHERE oid='public.begin_my_routing_snapshot(uuid,uuid,uuid[])'::regprocedure;
 FOR f IN SELECT * FROM (VALUES
  ('RETURN to_jsonb(old);','RETURN routing_private.coord_snapshot_for_client(to_jsonb(old));'),
  ('RETURN (SELECT to_jsonb(s) FROM routing_private.snapshots s WHERE snapshot_id=id);','RETURN (SELECT routing_private.coord_snapshot_for_client(to_jsonb(s)) FROM routing_private.snapshots s WHERE snapshot_id=id);')
 ) a(anchor,replacement) LOOP
  IF (length(src)-length(replace(src,f.anchor,'')))/length(f.anchor)<>1 THEN RAISE EXCEPTION 'SNAPSHOT_LOCATION_ANCHOR_DRIFT'; END IF;
  src:=replace(src,f.anchor,f.replacement);
 END LOOP;
 EXECUTE 'CREATE OR REPLACE FUNCTION public.begin_my_routing_snapshot(p_request uuid,p_policy uuid,p_vehicle_ids uuid[] DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone=''UTC'' SET extra_float_digits=0 AS '||quote_literal(src);
END $privacy_patches$;

-- Small existing-reader replacement from the pending history proposal. The full
-- optional history migration is not a prerequisite and must not overwrite this fix.
CREATE OR REPLACE FUNCTION public.get_claimed_listing_detail(p_claim uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE v jsonb; BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
 SELECT jsonb_build_object('claim_id',c.claim_id,'claim_status',c.claim_status,
  'listing_id',l.listing_id,'listing_status',l.listing_status,'source_type',l.source_type,
  'pickup_address',CASE WHEN routing_private.coord_location_allowed(c.claim_id) THEN CASE WHEN l.source_type='DIRECT_DONATION' THEN d.pickup_address ELSE h.address_text END ELSE NULL END,
  'latitude',CASE WHEN routing_private.coord_location_allowed(c.claim_id) THEN l.pickup_latitude ELSE NULL END,
  'longitude',CASE WHEN routing_private.coord_location_allowed(c.claim_id) THEN l.pickup_longitude ELSE NULL END,
  'listing_weight_kg',l.listing_weight_kg,'lease_status',le.lease_status,'lease_expires_at',le.expires_at,
  'donation_ids',coalesce((SELECT jsonb_agg(m.donation_id) FROM public.hub_batch_members m WHERE m.batch_id=l.batch_id AND m.membership_status='ACTIVE'),
   CASE WHEN d.donation_id IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(d.donation_id) END)) INTO v
 FROM public.donation_claims c JOIN public.listings l USING(listing_id)
 LEFT JOIN public.donations d ON d.donation_id=l.donation_id LEFT JOIN public.hub_batches b ON b.batch_id=l.batch_id
 LEFT JOIN public.community_hubs h ON h.hub_id=b.hub_id LEFT JOIN public.claim_leases le USING(claim_id)
 WHERE c.claim_id=p_claim AND c.ngo_user_id=auth.uid();
 IF v IS NULL THEN RAISE EXCEPTION 'CLAIM_NOT_FOUND_OR_FORBIDDEN'; END IF; RETURN v;
END $$;

ALTER TABLE public.claim_reconciliation_cases ADD COLUMN evidence_round integer NOT NULL DEFAULT 1 CHECK(evidence_round>0),
 ADD COLUMN evidence_version bigint NOT NULL DEFAULT 1 CHECK(evidence_version>0), ADD COLUMN review_requested_by uuid,
 ADD COLUMN review_context text;
ALTER TABLE public.claim_reconciliation_evidence ADD COLUMN evidence_round integer NOT NULL DEFAULT 1 CHECK(evidence_round>0);
ALTER TABLE public.claim_reconciliation_evidence DROP CONSTRAINT claim_reconciliation_one_response_per_actor;
ALTER TABLE public.claim_reconciliation_evidence ADD CONSTRAINT claim_reconciliation_one_response_per_round UNIQUE(case_id,actor_user_id,evidence_round);

CREATE FUNCTION routing_private.coord_immutable_evidence() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$ BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'CLAIM_EVIDENCE_IMMUTABLE'; END IF;
 IF (to_jsonb(NEW)-'response') IS DISTINCT FROM (to_jsonb(OLD)-'response') OR (OLD.response IS NOT NULL AND NEW.response IS DISTINCT FROM OLD.response)
 THEN RAISE EXCEPTION 'CLAIM_EVIDENCE_IMMUTABLE'; END IF; RETURN NEW;
END $$;
CREATE TRIGGER coordination_evidence_immutable BEFORE UPDATE OR DELETE ON public.claim_reconciliation_evidence FOR EACH ROW EXECUTE FUNCTION routing_private.coord_immutable_evidence();

CREATE FUNCTION routing_private.coord_counterpart(p_claim uuid) RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT CASE WHEN l.source_type='DIRECT_DONATION' THEN d.donor_user_id ELSE h.admin_user_id END
 FROM public.donation_claims c JOIN public.listings l USING(listing_id) LEFT JOIN public.donations d USING(donation_id)
 LEFT JOIN public.hub_batches hb USING(batch_id) LEFT JOIN public.community_hubs h USING(hub_id) WHERE c.claim_id=p_claim
$$;
CREATE FUNCTION routing_private.coord_votes(p_claim uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT jsonb_build_object('count',count(e.request_id),'yes',count(*) FILTER(WHERE e.handover_confirmed),
 'valid',count(*) FILTER(WHERE (e.actor_user_id=c.ngo_user_id AND u.role='NGO') OR
   (e.actor_user_id=routing_private.coord_counterpart(p_claim) AND u.role=CASE WHEN rc.source_type='DIRECT_DONATION' THEN 'DONOR' ELSE 'HUB_ADMIN' END)))
 FROM public.claim_reconciliation_cases rc JOIN public.donation_claims c USING(claim_id)
 LEFT JOIN public.claim_reconciliation_evidence e ON e.case_id=rc.case_id AND e.evidence_round=rc.evidence_round
 LEFT JOIN public.user_profiles u ON u.user_id=e.actor_user_id WHERE rc.claim_id=p_claim
$$;
CREATE FUNCTION routing_private.coord_context(p_claim uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT routing_private.task_digest(routing_private.observe_task(t.task_id)) FROM public.pickup_tasks t WHERE t.claim_id=p_claim
$$;

CREATE FUNCTION routing_private.coord_can_review(p_claim uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM public.claim_reconciliation_cases rc JOIN public.donation_claims c USING(claim_id)
 WHERE rc.claim_id=p_claim AND rc.resolved_at IS NULL AND rc.case_status IN('OPEN','MANUAL_REVIEW') AND rc.review_requested_by IS NULL
 AND ((routing_private.coord_votes(p_claim)->>'count'='2' AND routing_private.coord_votes(p_claim)->>'valid'='2')
 OR (rc.evidence_round>1 AND rc.review_context IS DISTINCT FROM routing_private.coord_context(p_claim)
 AND EXISTS(SELECT 1 FROM public.claim_reconciliation_evidence e WHERE e.case_id=rc.case_id AND e.evidence_round=rc.evidence_round-1 AND e.actor_user_id=c.ngo_user_id)
 AND EXISTS(SELECT 1 FROM public.claim_reconciliation_evidence e WHERE e.case_id=rc.case_id AND e.evidence_round=rc.evidence_round-1 AND e.actor_user_id=routing_private.coord_counterpart(p_claim)))))
$$;
CREATE FUNCTION routing_private.coord_listing_window_valid(p_listing uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM public.listings l WHERE l.listing_id=p_listing AND (l.listing_expires_at IS NULL OR l.listing_expires_at>statement_timestamp())
 AND NOT EXISTS(SELECT 1 FROM public.donations d WHERE (d.donation_id=l.donation_id OR EXISTS(SELECT 1 FROM public.hub_batch_members m WHERE m.batch_id=l.batch_id AND m.donation_id=d.donation_id AND m.membership_status='ACTIVE')) AND d.availability_end<=statement_timestamp()))
$$;

-- Pure eligibility check. Mutation repeats it after the established scope locks.
CREATE FUNCTION routing_private.coord_blocker(p_claim uuid,p_handover boolean) RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE c public.donation_claims%rowtype; le public.claim_leases%rowtype; l public.listings%rowtype; t public.pickup_tasks%rowtype;
 rc public.claim_reconciliation_cases%rowtype; i routing_private.items%rowtype; b routing_private.bindings%rowtype; obs jsonb; v jsonb;
BEGIN
 SELECT * INTO c FROM public.donation_claims WHERE claim_id=p_claim; SELECT * INTO le FROM public.claim_leases WHERE claim_id=p_claim;
 SELECT * INTO l FROM public.listings WHERE listing_id=c.listing_id; SELECT * INTO t FROM public.pickup_tasks WHERE claim_id=p_claim;
 SELECT * INTO rc FROM public.claim_reconciliation_cases WHERE claim_id=p_claim;
 IF c.claim_id IS NULL OR le.lease_id IS NULL OR l.listing_id IS NULL OR t.task_id IS NULL OR rc.case_id IS NULL THEN RETURN 'AUTHORITATIVE_ASSOCIATION_MISSING'; END IF;
 IF c.claim_status<>'RECONCILIATION_REQUIRED' OR le.lease_status<>'RECONCILIATION_REQUIRED' OR l.listing_status<>'CLAIMED'
 OR rc.case_status NOT IN('OPEN','MANUAL_REVIEW') OR rc.listing_id IS DISTINCT FROM c.listing_id OR rc.source_type IS DISTINCT FROM l.source_type OR rc.donation_id IS DISTINCT FROM l.donation_id OR t.ngo_user_id IS DISTINCT FROM c.ngo_user_id OR rc.resolved_at IS NOT NULL THEN RETURN 'RECONCILIATION_STATE_MISMATCH'; END IF;
 IF routing_private.coord_counterpart(p_claim) IS NULL OR routing_private.coord_counterpart(p_claim)=c.ngo_user_id THEN RETURN 'PARTICIPANT_CONFLICT'; END IF;
 IF rc.review_requested_by IS NOT NULL THEN RETURN 'JOINT_REVIEW_ACCEPTANCE_PENDING'; END IF;
 IF rc.evidence_round>1 AND rc.review_context IS DISTINCT FROM routing_private.coord_context(p_claim) THEN RETURN 'REVIEW_CONTEXT_CHANGED'; END IF;
 v:=routing_private.coord_votes(p_claim);
 IF (v->>'count')::int<>2 OR (v->>'valid')::int<>2 THEN RETURN 'AWAITING_COUNTERPART'; END IF;
 IF (v->>'yes')::int NOT IN(0,2) THEN RETURN 'PARTY_EVIDENCE_CONFLICT'; END IF;
 IF ((v->>'yes')::int=2) IS DISTINCT FROM p_handover THEN RETURN 'PARTY_EVIDENCE_CONFLICT'; END IF;
 SELECT * INTO i FROM routing_private.items WHERE task_id=t.task_id AND released_at IS NULL;
 IF i.task_id IS NOT NULL THEN
  SELECT * INTO b FROM routing_private.bindings WHERE route_id=i.route_id;
  IF b.closed_at IS NOT NULL OR b.ngo_id IS DISTINCT FROM c.ngo_user_id OR NOT EXISTS(SELECT 1 FROM public.pickup_routes r
   WHERE r.route_id=i.route_id AND r.ngo_user_id=b.ngo_id AND r.vehicle_id=b.vehicle_id AND r.validation_reference=b.candidate_id::text AND r.route_status IN('AUTHORISED','IN_PROGRESS'))
  OR NOT EXISTS(SELECT 1 FROM public.active_task_route_assignments WHERE route_id=i.route_id AND task_id=t.task_id)
  OR NOT EXISTS(SELECT 1 FROM public.pickup_route_stops WHERE route_id=i.route_id AND task_id=t.task_id AND stop_order=i.ordinal)
  THEN RETURN 'ROUTE_BINDING_DRIFT'; END IF;
  IF EXISTS(SELECT 1 FROM resolution_private.cases WHERE route_id=i.route_id AND status IN('AWAITING_EVIDENCE','MANUAL_REVIEW'))
   OR EXISTS(SELECT 1 FROM resolution_private.incidents inc JOIN resolution_private.cases r USING(case_id) WHERE r.route_id=i.route_id)
   OR EXISTS(SELECT 1 FROM resolution_private.evidence e JOIN resolution_private.cases r USING(case_id) WHERE r.route_id=i.route_id AND e.task_id=t.task_id AND e.assertion='HANDOVER_TO_NGO_CONFIRMED' AND NOT p_handover)
  THEN RETURN 'UNRESOLVED_CUSTODY_OR_INCIDENT'; END IF;
 END IF;
 obs:=routing_private.observe_task(t.task_id);
 IF obs IS NULL OR coalesce(jsonb_array_length(obs->'donations'),0)=0 THEN RETURN 'SOURCE_SET_MISSING'; END IF;
 IF l.source_type='HUB_BATCH' AND (NOT EXISTS(SELECT 1 FROM public.hub_batch_members WHERE batch_id=l.batch_id AND membership_status='ACTIVE')
  OR EXISTS(SELECT 1 FROM public.hub_batch_members m LEFT JOIN public.hub_inventory hi USING(donation_id) WHERE m.batch_id=l.batch_id AND m.membership_status='ACTIVE' AND hi.inventory_status IS DISTINCT FROM CASE WHEN t.task_status='COLLECTED' THEN 'COLLECTED' ELSE 'BATCHED' END)) THEN RETURN 'BATCH_CUSTODY_CONFLICT'; END IF;
 IF p_handover THEN
  IF t.task_status NOT IN('DISPATCHED','COLLECTED') OR EXISTS(SELECT 1 FROM jsonb_array_elements(obs->'donations') d WHERE d->>'donation_status' NOT IN('PICKUP_IN_PROGRESS','COLLECTED'))
   OR (SELECT count(DISTINCT d->>'donation_status') FROM jsonb_array_elements(obs->'donations') d)<>1 THEN RETURN 'HANDOVER_SOURCE_STATE_CONFLICT'; END IF;
 ELSE
  IF t.task_status NOT IN('CONFIRMED','PLANNED','DISPATCHED') OR i.collected_at IS NOT NULL
   OR EXISTS(SELECT 1 FROM public.audit_events WHERE claim_id=p_claim AND outcome='SUCCESS' AND (event_type='COMPLETE_PICKUP' OR resulting_state IN('COLLECTED','COMPLETED')))
   OR EXISTS(SELECT 1 FROM jsonb_array_elements(obs->'donations') d WHERE d->>'donation_status' IS DISTINCT FROM CASE WHEN t.task_status='DISPATCHED' THEN 'PICKUP_IN_PROGRESS' ELSE 'CLAIMED' END)
  THEN RETURN 'RECORDED_COLLECTION_OR_SOURCE_CONFLICT'; END IF;
  IF t.task_status IN('PLANNED','DISPATCHED') AND (i.task_id IS NULL OR (t.task_status='DISPATCHED' AND (i.consumed_at IS NULL OR b.started_at IS NULL OR i.dispatch_xid IS NULL))) THEN RETURN 'MANAGED_DISPATCH_EVIDENCE_REQUIRED'; END IF;
  IF le.expires_at>statement_timestamp() THEN RETURN 'LEASE_NOT_EXPIRED'; END IF;
 END IF;
 RETURN NULL;
END $$;

CREATE FUNCTION routing_private.coord_release_allowed(p_donation uuid,p_target text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM routing_private.deferred_release_permits p JOIN public.pickup_tasks t USING(task_id)
 JOIN public.listings l USING(listing_id) JOIN public.donations d ON d.donation_id=p_donation
 WHERE p.transaction_id=pg_current_xact_id() AND routing_private.reconciliation_participant(t.claim_id)
 AND ((l.source_type='DIRECT_DONATION' AND l.donation_id=d.donation_id AND p_target='AVAILABLE') OR
 (l.source_type='HUB_BATCH' AND p_target='BATCHED' AND EXISTS(SELECT 1 FROM public.hub_batch_members m WHERE m.batch_id=l.batch_id AND m.donation_id=d.donation_id AND m.membership_status='ACTIVE')))
 AND routing_private.coord_votes(t.claim_id)->>'count'='2' AND routing_private.coord_votes(t.claim_id)->>'valid'='2' AND routing_private.coord_votes(t.claim_id)->>'yes'='0')
$$;

DO $patch_guards$ DECLARE src text; anchor text; BEGIN
 SELECT prosrc INTO src FROM pg_proc WHERE oid='public.enforce_donation_transition()'::regprocedure;
 anchor:='resolution_private.release_allowed(old.donation_id,new.donation_status)';
 IF (length(src)-length(replace(src,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'DONATION_RELEASE_GUARD_DRIFT'; END IF;
 src:=replace(src,anchor,'(resolution_private.release_allowed(old.donation_id,new.donation_status) OR routing_private.coord_release_allowed(old.donation_id,new.donation_status))');
 EXECUTE 'CREATE OR REPLACE FUNCTION public.enforce_donation_transition() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS '||quote_literal(src);
 -- Collection permit considers exactly the mutually accepted current round.
 SELECT prosrc INTO src FROM pg_proc WHERE oid='routing_private.permit_reconciled_collection(uuid)'::regprocedure;
 anchor:='WHERE case_id=rc.case_id)';
 IF (length(src)-length(replace(src,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'COLLECTION_CASE_ROUND_ANCHOR_DRIFT'; END IF;
 src:=replace(src,'WHERE case_id=rc.case_id)','WHERE case_id=rc.case_id AND evidence_round=rc.evidence_round)');
 anchor:='WHERE e.case_id=rc.case_id AND e.handover_confirmed IS TRUE';
 IF (length(src)-length(replace(src,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'COLLECTION_VOTE_ROUND_ANCHOR_DRIFT'; END IF;
 src:=replace(src,'WHERE e.case_id=rc.case_id AND e.handover_confirmed IS TRUE','WHERE e.case_id=rc.case_id AND e.evidence_round=rc.evidence_round AND e.handover_confirmed IS TRUE');
 EXECUTE 'CREATE OR REPLACE FUNCTION routing_private.permit_reconciled_collection(p_claim uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone=''UTC'' SET extra_float_digits=0 AS '||quote_literal(src);
END $patch_guards$;

DO $task_release_guard$ DECLARE src text; old text:=$old$EXISTS(SELECT 1 FROM public.donation_claims c JOIN public.claim_leases le USING(claim_id) WHERE c.claim_id=OLD.claim_id AND c.claim_status='RECONCILIATION_REQUIRED' AND le.lease_status='RECONCILIATION_REQUIRED')$old$; BEGIN
 SELECT replace(prosrc,chr(13),'') INTO src FROM pg_proc WHERE oid='routing_private.task_guard()'::regprocedure;
 IF (length(src)-length(replace(src,old,'')))/length(old)<>1 THEN RAISE EXCEPTION 'TASK_RELEASE_GUARD_DRIFT'; END IF;
 src:=replace(src,old,'EXISTS(SELECT 1 FROM resolution_private.permits p WHERE p.task_id=OLD.task_id AND p.transaction_id=pg_current_xact_id())');
 EXECUTE 'CREATE OR REPLACE FUNCTION routing_private.task_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone=''UTC'' SET extra_float_digits=0 AS '||quote_literal(src);
END $task_release_guard$;


CREATE FUNCTION routing_private.coord_decide(p_claim uuid,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE c public.donation_claims%rowtype; le public.claim_leases%rowtype; l public.listings%rowtype; t public.pickup_tasks%rowtype;
 rc public.claim_reconciliation_cases%rowtype; i routing_private.items%rowtype; v jsonb; blocked text; yes boolean; expected text; reason text; did uuid;
BEGIN
 SELECT * INTO STRICT rc FROM public.claim_reconciliation_cases WHERE claim_id=p_claim FOR UPDATE;
 IF rc.resolved_at IS NOT NULL THEN RETURN jsonb_build_object('outcome','SUCCESS','claim_id',p_claim,'case_id',rc.case_id,'case_status',rc.case_status); END IF;
 SELECT * INTO STRICT c FROM public.donation_claims WHERE claim_id=p_claim FOR UPDATE;
 SELECT * INTO STRICT le FROM public.claim_leases WHERE claim_id=p_claim FOR UPDATE;
 SELECT * INTO STRICT l FROM public.listings WHERE listing_id=c.listing_id FOR UPDATE;
 SELECT * INTO STRICT t FROM public.pickup_tasks WHERE claim_id=p_claim FOR UPDATE;
 v:=routing_private.coord_votes(p_claim); yes:=(v->>'yes')::int=2;
 blocked:=routing_private.coord_blocker(p_claim,yes);
 IF blocked IS NOT NULL THEN
  IF blocked<>'AWAITING_COUNTERPART' THEN UPDATE public.claim_reconciliation_cases SET case_status='MANUAL_REVIEW',resolution_reason=blocked WHERE case_id=rc.case_id; END IF;
  RETURN jsonb_build_object('outcome',CASE WHEN blocked='AWAITING_COUNTERPART' THEN 'AWAITING_COUNTERPART' ELSE 'RECONCILIATION_REQUIRED' END,'reason_code',blocked,'claim_id',p_claim,'case_id',rc.case_id);
 END IF;
 IF NOT public.geolock_lock_listing_donations(l.listing_id,ARRAY['CLAIMED','PICKUP_IN_PROGRESS','COLLECTED']) THEN RAISE EXCEPTION 'SOURCE_LOCK_CONFLICT'; END IF;
 SELECT * INTO i FROM routing_private.items WHERE task_id=t.task_id AND released_at IS NULL;
 IF yes THEN
  -- Preserve the existing participant collection permit/finish contract.
  IF l.source_type='DIRECT_DONATION' THEN
   UPDATE public.donations SET donation_status='COLLECTED' WHERE donation_id=l.donation_id AND donation_status='PICKUP_IN_PROGRESS';
  ELSE
   UPDATE public.donations SET donation_status='COLLECTED' WHERE donation_id IN(SELECT donation_id FROM public.hub_batch_members WHERE batch_id=l.batch_id AND membership_status='ACTIVE') AND donation_status='PICKUP_IN_PROGRESS';
   UPDATE public.hub_inventory SET inventory_status='COLLECTED' WHERE donation_id IN(SELECT donation_id FROM public.hub_batch_members WHERE batch_id=l.batch_id AND membership_status='ACTIVE');
   UPDATE public.hub_batches SET batch_status='COLLECTED' WHERE batch_id=l.batch_id;
  END IF;
  PERFORM routing_private.permit_reconciled_collection(p_claim);
  UPDATE public.pickup_tasks SET task_status='COLLECTED' WHERE task_id=t.task_id;
  UPDATE public.donation_claims SET claim_status='COMPLETED',closed_at=clock_timestamp(),close_reason='RECONCILED_HANDOVER_CONFIRMED' WHERE claim_id=p_claim;
  UPDATE public.claim_leases SET lease_status='COMPLETED',closed_at=clock_timestamp() WHERE claim_id=p_claim;
  UPDATE public.listings SET listing_status='CLOSED',listing_version=listing_version+1 WHERE listing_id=l.listing_id;
  UPDATE public.claim_reconciliation_cases SET case_status='RESOLVED_COLLECTED',resolved_at=clock_timestamp(),resolution_reason='BOTH_PARTIES_CONFIRMED_HANDOVER' WHERE case_id=rc.case_id;
  PERFORM routing_private.finish_reconciled_collection(p_claim);
 ELSE
  reason:=CASE WHEN t.task_status='DISPATCHED' THEN 'RECONCILED_STARTED_NO_HANDOVER' ELSE 'RECONCILED_NO_HANDOVER' END;
  IF i.task_id IS NOT NULL THEN
   INSERT INTO routing_private.deferred_stops(route_id,task_id,claim_id,ngo_id,request_id,reason)
   VALUES(i.route_id,i.task_id,p_claim,c.ngo_user_id,p_request,'RECONCILIATION_REQUIRED') ON CONFLICT(route_id,task_id) DO NOTHING;
  END IF;
  INSERT INTO routing_private.deferred_release_permits(task_id,transaction_id) VALUES(t.task_id,pg_current_xact_id()) ON CONFLICT DO NOTHING;
  expected:=CASE WHEN t.task_status='DISPATCHED' THEN 'PICKUP_IN_PROGRESS' ELSE 'CLAIMED' END;
  -- The guard checks the same validated permit/evidence while all source rows
  -- are still in their pre-transition states; batch members are locked together.
  PERFORM public.geolock_transition_listing_donations(l.listing_id,expected,CASE WHEN l.source_type='DIRECT_DONATION' THEN 'AVAILABLE' ELSE 'BATCHED' END,p_claim,p_request,reason);
  UPDATE public.pickup_tasks SET task_status='STALE' WHERE task_id=t.task_id;
  UPDATE public.donation_claims SET claim_status='RELEASED',closed_at=clock_timestamp(),close_reason=reason WHERE claim_id=p_claim;
  UPDATE public.claim_leases SET lease_status='RELEASED',closed_at=clock_timestamp(),release_reason=reason WHERE claim_id=p_claim;
  DELETE FROM public.active_task_route_assignments WHERE task_id=t.task_id AND (i.route_id IS NULL OR route_id=i.route_id);
  UPDATE routing_private.items SET release_xid=pg_current_xact_id(),released_at=clock_timestamp() WHERE route_id=i.route_id AND task_id=t.task_id;
  UPDATE routing_private.deferred_stops SET status='RESOLVED_UNCOLLECTED',resolved_at=clock_timestamp() WHERE route_id=i.route_id AND task_id=t.task_id AND status='DEFERRED';
  UPDATE public.listings SET listing_status=CASE WHEN routing_private.coord_listing_window_valid(l.listing_id) THEN 'AVAILABLE' ELSE 'CLOSED' END,listing_version=listing_version+1 WHERE listing_id=l.listing_id;
  UPDATE public.claim_reconciliation_cases SET case_status='RESOLVED_RELEASED',resolved_at=clock_timestamp(),resolution_reason='BOTH_PARTIES_CONFIRMED_NO_HANDOVER' WHERE case_id=rc.case_id;
 END IF;
 INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,claim_id,lease_id,outcome,reason_code,details)
 VALUES(auth.uid(),(SELECT role FROM public.user_profiles WHERE user_id=auth.uid()),'CLAIM',p_claim,'RECONCILIATION_RESOLVED',p_claim,le.lease_id,'SUCCESS',coalesce(reason,'RECONCILED_HANDOVER_CONFIRMED'),jsonb_build_object('case_id',rc.case_id,'evidence_round',rc.evidence_round,'pickup_started',t.task_status='DISPATCHED','handover_confirmed',yes));
 RETURN jsonb_build_object('outcome','SUCCESS','claim_id',p_claim,'case_id',rc.case_id,'claim_status',CASE WHEN yes THEN 'COMPLETED' ELSE 'RELEASED' END,'reason_code',coalesce(reason,'RECONCILED_HANDOVER_CONFIRMED'));
END $$;

CREATE FUNCTION public.submit_claim_reconciliation_v2(p_claim uuid,p_handover_confirmed boolean,p_expected_round integer,p_expected_version bigint,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE rc public.claim_reconciliation_cases%rowtype; prior jsonb; result jsonb; payload jsonb:=jsonb_build_object('claim',p_claim,'handover',p_handover_confirmed,'round',p_expected_round,'version',p_expected_version); actor text:='user:'||auth.uid();
BEGIN
 IF NOT routing_private.reconciliation_participant(p_claim) THEN RAISE EXCEPTION 'RECONCILIATION_PARTICIPANT_ONLY'; END IF;
 prior:=resolution_private.receipt(actor,p_request,'CLAIM_SUBMIT_V2',payload); IF prior IS NOT NULL THEN RETURN prior; END IF;
 PERFORM routing_private.lock_reconciliation_scope(p_claim);
 SELECT * INTO STRICT rc FROM public.claim_reconciliation_cases WHERE claim_id=p_claim FOR UPDATE;
 IF rc.evidence_round IS DISTINCT FROM p_expected_round OR rc.evidence_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'CASE_VERSION_STALE'; END IF;
 IF rc.resolved_at IS NOT NULL OR rc.review_requested_by IS NOT NULL OR p_handover_confirmed IS NULL THEN RAISE EXCEPTION 'CASE_NOT_ACCEPTING_EVIDENCE'; END IF;
 IF rc.evidence_round>1 AND rc.review_context IS DISTINCT FROM routing_private.coord_context(p_claim) THEN RAISE EXCEPTION 'REVIEW_CONTEXT_CHANGED'; END IF;
 INSERT INTO public.claim_reconciliation_evidence(request_id,case_id,actor_user_id,handover_confirmed,evidence_round) VALUES(p_request,rc.case_id,auth.uid(),p_handover_confirmed,rc.evidence_round);
 result:=routing_private.coord_decide(p_claim,p_request);
 UPDATE public.claim_reconciliation_evidence SET response=result WHERE request_id=p_request;
 UPDATE public.claim_reconciliation_cases SET evidence_version=evidence_version+1 WHERE case_id=rc.case_id;
 INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,claim_id,request_id,outcome,details)
 VALUES(auth.uid(),(SELECT role FROM public.user_profiles WHERE user_id=auth.uid()),'CLAIM',p_claim,'CLAIM_RECONCILIATION_EVIDENCE',p_claim,p_request,'SUCCESS',jsonb_build_object('handover_confirmed',p_handover_confirmed,'evidence_round',rc.evidence_round));
 RETURN resolution_private.save_receipt(actor,p_request,'CLAIM_SUBMIT_V2',payload,result);
END $$;
-- Compatibility: round-one callers retain the original evidence receipt. They
-- cannot accidentally contribute to a later jointly accepted correction round.
CREATE OR REPLACE FUNCTION public.submit_claim_reconciliation(p_claim uuid,p_handover_confirmed boolean,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE e public.claim_reconciliation_evidence%rowtype; rc public.claim_reconciliation_cases%rowtype;
BEGIN
 IF NOT routing_private.reconciliation_participant(p_claim) THEN RAISE EXCEPTION 'RECONCILIATION_PARTICIPANT_ONLY'; END IF;
 SELECT * INTO e FROM public.claim_reconciliation_evidence WHERE request_id=p_request;
 IF FOUND THEN
  IF e.actor_user_id IS DISTINCT FROM auth.uid() OR e.handover_confirmed IS DISTINCT FROM p_handover_confirmed OR NOT EXISTS(SELECT 1 FROM public.claim_reconciliation_cases WHERE case_id=e.case_id AND claim_id=p_claim) THEN RAISE EXCEPTION 'REQUEST_PAYLOAD_CONFLICT'; END IF;
  RETURN e.response;
 END IF;
 SELECT * INTO STRICT rc FROM public.claim_reconciliation_cases WHERE claim_id=p_claim;
 IF rc.evidence_round<>1 THEN RAISE EXCEPTION 'ROUND_AWARE_CLIENT_REQUIRED'; END IF;
 RETURN public.submit_claim_reconciliation_v2(p_claim,p_handover_confirmed,1,rc.evidence_version,p_request);
END $$;

CREATE FUNCTION public.resolve_my_claim_reconciliation(p_claim uuid,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor text:='user:'||auth.uid(); payload jsonb:=jsonb_build_object('claim',p_claim); prior jsonb; result jsonb;
BEGIN
 IF NOT routing_private.reconciliation_participant(p_claim) THEN RAISE EXCEPTION 'RECONCILIATION_PARTICIPANT_ONLY'; END IF;
 prior:=resolution_private.receipt(actor,p_request,'CLAIM_RESOLVE',payload); IF prior IS NOT NULL THEN RETURN prior; END IF;
 PERFORM routing_private.lock_reconciliation_scope(p_claim);
 result:=routing_private.coord_decide(p_claim,p_request);
 RETURN resolution_private.save_receipt(actor,p_request,'CLAIM_RESOLVE',payload,result);
END $$;

CREATE FUNCTION public.review_my_claim_reconciliation(p_claim uuid,p_action text,p_expected_version bigint,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor text:='user:'||auth.uid(); payload jsonb:=jsonb_build_object('claim',p_claim,'action',p_action,'version',p_expected_version); prior jsonb; result jsonb; rc public.claim_reconciliation_cases%rowtype; v jsonb;
BEGIN
 IF NOT routing_private.reconciliation_participant(p_claim) THEN RAISE EXCEPTION 'RECONCILIATION_PARTICIPANT_ONLY'; END IF;
 prior:=resolution_private.receipt(actor,p_request,'CLAIM_REVIEW',payload); IF prior IS NOT NULL THEN RETURN prior; END IF;
 PERFORM routing_private.lock_reconciliation_scope(p_claim);
 SELECT * INTO STRICT rc FROM public.claim_reconciliation_cases WHERE claim_id=p_claim FOR UPDATE;
 IF rc.resolved_at IS NOT NULL OR rc.case_status NOT IN('OPEN','MANUAL_REVIEW') THEN RAISE EXCEPTION 'TERMINAL_EVIDENCE_IMMUTABLE'; END IF;
 IF rc.evidence_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'CASE_VERSION_STALE'; END IF;
 IF p_action='REQUEST' THEN
  v:=routing_private.coord_votes(p_claim);
  IF NOT routing_private.coord_can_review(p_claim) THEN RAISE EXCEPTION 'TWO_STATEMENTS_OR_CHANGED_REVIEW_CONTEXT_REQUIRED'; END IF;
  UPDATE public.claim_reconciliation_cases SET review_requested_by=auth.uid(),review_context=routing_private.coord_context(p_claim),evidence_version=evidence_version+1 WHERE case_id=rc.case_id;
 ELSIF p_action IN('ACCEPT','DECLINE') THEN
  IF rc.review_requested_by IS NULL OR rc.review_requested_by=auth.uid() THEN RAISE EXCEPTION 'COUNTERPART_ACCEPTANCE_REQUIRED'; END IF;
  IF p_action='ACCEPT' AND rc.review_context IS DISTINCT FROM routing_private.coord_context(p_claim) THEN RAISE EXCEPTION 'REVIEW_CONTEXT_CHANGED'; END IF;
  UPDATE public.claim_reconciliation_cases SET review_requested_by=NULL,evidence_version=evidence_version+1,
   evidence_round=evidence_round+CASE WHEN p_action='ACCEPT' THEN 1 ELSE 0 END,
   case_status=CASE WHEN p_action='ACCEPT' THEN 'OPEN' ELSE case_status END,
   resolution_reason=CASE WHEN p_action='ACCEPT' THEN 'JOINT_REVIEW_IN_PROGRESS' ELSE resolution_reason END WHERE case_id=rc.case_id;
 ELSE RAISE EXCEPTION 'INVALID_REVIEW_ACTION'; END IF;
 result:=jsonb_build_object('outcome','SUCCESS','claim_id',p_claim,'action',p_action);
 INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,request_id,claim_id,outcome,details)
 VALUES(auth.uid(),(SELECT role FROM public.user_profiles WHERE user_id=auth.uid()),'CLAIM',p_claim,'CLAIM_JOINT_REVIEW_'||p_action,p_request,p_claim,'SUCCESS',jsonb_build_object('prior_round',rc.evidence_round,'prior_version',rc.evidence_version));
 RETURN resolution_private.save_receipt(actor,p_request,'CLAIM_REVIEW',payload,result);
END $$;

CREATE FUNCTION public.get_my_coordination_receipt(p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE r resolution_private.requests%rowtype; actor text:=resolution_private.actor_key(); BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('route-resolution-request:'||actor||':'||p_request,0));
 SELECT * INTO r FROM resolution_private.requests WHERE actor_key=actor AND request_id=p_request AND operation IN('CLAIM_SUBMIT_V2','CLAIM_RESOLVE','CLAIM_REVIEW','VEHICLE_CHECKPOINT');
 RETURN jsonb_build_object('found',FOUND,'request_id',p_request,'result',r.result);
END $$;
CREATE FUNCTION public.get_my_claim_coordination(p_claim uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE rc public.claim_reconciliation_cases%rowtype; v jsonb; mine boolean; n int; blocked text;
BEGIN
 IF NOT routing_private.reconciliation_participant(p_claim) THEN RAISE EXCEPTION 'RECONCILIATION_PARTICIPANT_ONLY'; END IF;
 SELECT * INTO STRICT rc FROM public.claim_reconciliation_cases WHERE claim_id=p_claim;
 v:=routing_private.coord_votes(p_claim); n:=(v->>'count')::int;
 blocked:=routing_private.coord_blocker(p_claim,(v->>'yes')::int=2);
 mine:=EXISTS(SELECT 1 FROM public.claim_reconciliation_evidence WHERE case_id=rc.case_id AND evidence_round=rc.evidence_round AND actor_user_id=auth.uid());
 RETURN jsonb_build_object('contract','geolock.claim-coordination.v2','claim_id',p_claim,'case_id',rc.case_id,'case_status',rc.case_status,
 'evidence_round',rc.evidence_round,'evidence_version',rc.evidence_version,'blocker',CASE WHEN rc.resolved_at IS NULL THEN blocked ELSE NULL END,
 'can_submit',rc.resolved_at IS NULL AND rc.review_requested_by IS NULL AND NOT mine AND (rc.evidence_round=1 OR rc.review_context IS NOT DISTINCT FROM routing_private.coord_context(p_claim)),
 'can_resolve',rc.resolved_at IS NULL AND blocked IS NULL,
 'can_request_review',routing_private.coord_can_review(p_claim),
 'can_accept_review',rc.resolved_at IS NULL AND rc.review_requested_by IS NOT NULL AND rc.review_requested_by<>auth.uid(),
 'review_waiting',rc.review_requested_by=auth.uid(),
 'statements',(SELECT coalesce(jsonb_agg(jsonb_build_object('round',e.evidence_round,'participant',CASE WHEN e.actor_user_id=c.ngo_user_id THEN 'NGO' ELSE 'Source' END,'handover_confirmed',e.handover_confirmed,'submitted_at',e.submitted_at) ORDER BY e.evidence_round,e.submitted_at),'[]') FROM public.claim_reconciliation_evidence e JOIN public.donation_claims c ON c.claim_id=p_claim WHERE e.case_id=rc.case_id));
END $$;

CREATE FUNCTION routing_private.has_recorded_pickup(p_route uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM routing_private.bindings WHERE route_id=p_route AND started_at IS NOT NULL) OR EXISTS(SELECT 1 FROM routing_private.items WHERE route_id=p_route AND (consumed_at IS NOT NULL OR collected_at IS NOT NULL))
$$;
CREATE FUNCTION routing_private.coord_safe_released(p_route uuid,p_task uuid) RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE x record; v jsonb; BEGIN
 SELECT t.claim_id,t.task_status,c.claim_status,c.close_reason,c.closed_at,c.ngo_user_id,le.lease_id,le.lease_status,le.release_reason,le.expires_at,le.closed_at lease_closed_at,
 i.released_at,i.collected_at,ds.status deferred_status,ds.claim_id deferred_claim,ds.ngo_id,b.ngo_id owner_id
 INTO x FROM routing_private.items i JOIN routing_private.bindings b USING(route_id) LEFT JOIN public.pickup_tasks t USING(task_id)
 LEFT JOIN public.donation_claims c USING(claim_id) LEFT JOIN public.claim_leases le USING(claim_id)
 LEFT JOIN routing_private.deferred_stops ds USING(route_id,task_id) WHERE i.route_id=p_route AND i.task_id=p_task;
 IF NOT FOUND OR x.claim_id IS NULL OR x.lease_id IS NULL OR x.task_status IS DISTINCT FROM 'STALE' OR x.claim_status IS DISTINCT FROM 'RELEASED'
 OR x.lease_status IS DISTINCT FROM 'RELEASED' OR x.released_at IS NULL OR x.collected_at IS NOT NULL OR x.closed_at IS NULL OR x.lease_closed_at IS NULL
 OR EXISTS(SELECT 1 FROM public.active_task_route_assignments WHERE task_id=p_task) OR x.ngo_user_id IS DISTINCT FROM x.owner_id OR x.deferred_status IS DISTINCT FROM 'RESOLVED_UNCOLLECTED' OR x.deferred_claim IS DISTINCT FROM x.claim_id OR x.ngo_id IS DISTINCT FROM x.owner_id
 OR EXISTS(SELECT 1 FROM public.claim_reconciliation_cases WHERE claim_id=x.claim_id AND case_status IN('OPEN','MANUAL_REVIEW'))
 OR EXISTS(SELECT 1 FROM public.audit_events WHERE claim_id=x.claim_id AND outcome='SUCCESS' AND (event_type='COMPLETE_PICKUP' OR resulting_state IN('COLLECTED','COMPLETED'))) THEN RETURN false; END IF;
 IF x.close_reason='EXPIRED_SAFE_RELEASE' AND x.release_reason=x.close_reason THEN
  RETURN x.expires_at<=x.lease_closed_at AND NOT EXISTS(SELECT 1 FROM public.claim_reconciliation_cases WHERE claim_id=x.claim_id)
   AND EXISTS(SELECT 1 FROM public.audit_events WHERE claim_id=x.claim_id AND lease_id=x.lease_id AND event_type='LEASE_RECOVERY' AND reason_code='EXPIRED_SAFE_RELEASE' AND resulting_state='RELEASED' AND outcome='SUCCESS');
 END IF;
 v:=routing_private.coord_votes(x.claim_id);
 RETURN x.close_reason IN('RECONCILED_NO_HANDOVER','RECONCILED_STARTED_NO_HANDOVER') AND x.release_reason=x.close_reason
  AND v->>'count'='2' AND v->>'valid'='2' AND v->>'yes'='0'
  AND EXISTS(SELECT 1 FROM public.claim_reconciliation_cases WHERE claim_id=x.claim_id AND case_status='RESOLVED_RELEASED' AND resolved_at IS NOT NULL AND resolution_reason='BOTH_PARTIES_CONFIRMED_NO_HANDOVER');
END $$;
CREATE FUNCTION routing_private.coord_route_kind(p_route uuid) RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE x record; n int:=0; collected int:=0; BEGIN
 IF EXISTS(SELECT 1 FROM resolution_private.cases WHERE route_id=p_route AND status IN('AWAITING_EVIDENCE','MANUAL_REVIEW'))
 OR EXISTS(SELECT 1 FROM resolution_private.incidents i JOIN resolution_private.cases c USING(case_id) WHERE c.route_id=p_route) THEN RETURN NULL; END IF;
 FOR x IN SELECT i.*,t.task_status,t.claim_id,c.claim_status,le.lease_status FROM routing_private.items i LEFT JOIN public.pickup_tasks t USING(task_id) LEFT JOIN public.donation_claims c USING(claim_id) LEFT JOIN public.claim_leases le USING(claim_id) WHERE route_id=p_route LOOP
  n:=n+1;
  IF NOT EXISTS(SELECT 1 FROM public.pickup_route_stops s JOIN routing_private.bindings b USING(route_id) WHERE s.route_id=p_route AND s.task_id=x.task_id AND s.stop_order=x.ordinal AND s.ngo_user_id=b.ngo_id) THEN RETURN NULL; END IF;
  IF EXISTS(SELECT 1 FROM public.claim_reconciliation_cases WHERE claim_id=x.claim_id AND case_status IN('OPEN','MANUAL_REVIEW')) THEN RETURN NULL; END IF;
  IF x.collected_at IS NOT NULL AND x.task_status='COLLECTED' AND x.claim_status='COMPLETED' AND x.lease_status='COMPLETED' THEN collected:=collected+1;
  ELSIF routing_private.coord_safe_released(p_route,x.task_id) IS DISTINCT FROM true THEN RETURN NULL; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE (a.route_id=p_route AND NOT EXISTS(SELECT 1 FROM routing_private.items i WHERE i.route_id=p_route AND i.task_id=a.task_id)) OR (a.route_id<>p_route AND a.task_id IN(SELECT task_id FROM routing_private.items WHERE route_id=p_route))) THEN RETURN NULL; END IF;
 IF n=0 OR n<>(SELECT count(*) FROM public.pickup_route_stops WHERE route_id=p_route) THEN RETURN NULL; END IF;
 IF collected=n THEN RETURN 'COLLECTED'; ELSIF collected=0 THEN RETURN 'NO_COLLECTION'; ELSE RETURN 'MIXED_OUTCOME'; END IF;
END $$;
CREATE FUNCTION routing_private.coord_can_cancel(p_route uuid) RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE b routing_private.bindings%rowtype; x record; n int:=0; BEGIN
 SELECT * INTO b FROM routing_private.bindings WHERE route_id=p_route AND ngo_id=auth.uid();
 IF NOT FOUND OR b.closed_at IS NOT NULL OR routing_private.has_recorded_pickup(p_route)
 OR NOT EXISTS(SELECT 1 FROM public.pickup_routes WHERE route_id=p_route AND route_status='AUTHORISED' AND ngo_user_id=b.ngo_id)
 OR EXISTS(SELECT 1 FROM resolution_private.cases WHERE route_id=p_route AND status IN('AWAITING_EVIDENCE','MANUAL_REVIEW'))
 OR EXISTS(SELECT 1 FROM resolution_private.incidents i JOIN resolution_private.cases c USING(case_id) WHERE c.route_id=p_route) THEN RETURN false; END IF;
 FOR x IN SELECT i.*,t.task_status,t.claim_id,c.claim_status,le.lease_status,le.expires_at FROM routing_private.items i LEFT JOIN public.pickup_tasks t USING(task_id) LEFT JOIN public.donation_claims c USING(claim_id) LEFT JOIN public.claim_leases le USING(claim_id) WHERE route_id=p_route LOOP
  n:=n+1;
  IF EXISTS(SELECT 1 FROM public.audit_events WHERE claim_id=x.claim_id AND event_type='START_PICKUP' AND outcome='SUCCESS') THEN RETURN false; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.pickup_route_stops WHERE route_id=p_route AND task_id=x.task_id AND stop_order=x.ordinal AND ngo_user_id=b.ngo_id) THEN RETURN false; END IF;
  IF x.released_at IS NOT NULL THEN
   IF routing_private.coord_safe_released(p_route,x.task_id) IS DISTINCT FROM true OR EXISTS(SELECT 1 FROM public.active_task_route_assignments WHERE task_id=x.task_id) THEN RETURN false; END IF;
  ELSE
   IF x.task_status IS DISTINCT FROM 'PLANNED' OR x.claim_status IS DISTINCT FROM 'ACTIVE' OR x.lease_status IS DISTINCT FROM 'ACTIVE' OR x.expires_at IS NULL OR x.expires_at<=statement_timestamp()
   OR routing_private.task_digest(routing_private.observe_task(x.task_id)) IS DISTINCT FROM x.observation_digest THEN RETURN false; END IF;
  END IF;
 END LOOP;
 RETURN n>0 AND n=(SELECT count(*) FROM public.pickup_route_stops WHERE route_id=p_route);
END $$;
CREATE FUNCTION routing_private.can_cancel_released_unstarted(p_route uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT routing_private.coord_can_cancel(p_route) AND NOT EXISTS(SELECT 1 FROM routing_private.items WHERE route_id=p_route AND released_at IS NULL)
$$;
CREATE OR REPLACE FUNCTION public.cancel_my_unstarted_route(p_route uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE b routing_private.bindings%rowtype; all_released boolean; BEGIN
 b:=routing_private.lock_route(p_route,false);
 IF b.closed_at IS NOT NULL THEN IF (SELECT route_status FROM public.pickup_routes WHERE route_id=p_route)<>'CANCELLED' THEN RAISE EXCEPTION 'ROUTE_NOT_CANCELLED'; END IF; RETURN; END IF;
 IF NOT routing_private.coord_can_cancel(p_route) THEN RAISE EXCEPTION 'UNSTARTED_ROUTE_NOT_SAFELY_CANCELLABLE'; END IF;
 all_released:=routing_private.can_cancel_released_unstarted(p_route);
 IF NOT all_released THEN
  INSERT INTO routing_private.cancelled_stop_history(route_id,task_id,ngo_id,stop_order,original_stop) SELECT route_id,task_id,ngo_user_id,stop_order,to_jsonb(s) FROM public.pickup_route_stops s WHERE route_id=p_route;
  DELETE FROM public.pickup_route_stops WHERE route_id=p_route;
  DELETE FROM public.active_task_route_assignments WHERE route_id=p_route;
  UPDATE routing_private.items SET release_xid=pg_current_xact_id() WHERE route_id=p_route AND released_at IS NULL;
  UPDATE public.pickup_tasks SET task_status='CONFIRMED' WHERE task_id IN(SELECT task_id FROM routing_private.items WHERE route_id=p_route AND released_at IS NULL);
  UPDATE routing_private.items SET released_at=clock_timestamp() WHERE route_id=p_route AND released_at IS NULL;
 END IF;
 UPDATE public.pickup_routes SET route_status='CANCELLED' WHERE route_id=p_route;
 UPDATE routing_private.bindings SET closed_at=clock_timestamp() WHERE route_id=p_route;
 INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,reason_code,outcome,details)
 VALUES(auth.uid(),'NGO','ROUTE',p_route,'CANCEL_UNSTARTED_ROUTE',CASE WHEN all_released THEN 'ALL_MEMBERS_RELEASED_NO_COLLECTION' ELSE 'UNSTARTED_SAFE_CANCELLATION' END,'SUCCESS',jsonb_build_object('cancellation_outcome',CASE WHEN all_released THEN 'NO_COLLECTION' ELSE 'UNSTARTED_PLAN_CANCELLED' END,'terminal_tasks_preserved',true,'depot_return_required',false));
END $$;

CREATE FUNCTION routing_private.coord_checkpoint(p_route uuid) RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT max(a.occurred_at) FROM public.audit_events a JOIN routing_private.bindings b ON b.route_id=a.entity_id JOIN public.vehicles v ON v.vehicle_id=b.vehicle_id
 WHERE a.entity_type='ROUTE' AND a.entity_id=p_route AND a.event_type='VEHICLE_AT_DEPOT_CHECKPOINT' AND a.outcome='SUCCESS'
 AND a.actor_user_id=b.ngo_id AND a.details->>'depot'=v.depot_road_node_id AND a.details->>'vehicle_version'=v.vehicle_version::text
$$;
CREATE FUNCTION routing_private.coord_checkpoint_required(p_route uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT coalesce((SELECT max(released_at) FROM routing_private.items WHERE route_id=p_route AND consumed_at IS NOT NULL AND collected_at IS NULL),'-infinity')
 > greatest(coalesce(routing_private.coord_checkpoint(p_route),'-infinity'),coalesce((SELECT max(collected_at) FROM routing_private.items WHERE route_id=p_route),'-infinity'))
$$;
CREATE FUNCTION public.confirm_my_route_depot_checkpoint(p_route uuid,p_confirmed boolean,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE b routing_private.bindings%rowtype; actor text:='user:'||auth.uid(); payload jsonb:=jsonb_build_object('route',p_route,'confirmed',p_confirmed); prior jsonb; result jsonb;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM routing_private.bindings WHERE route_id=p_route AND ngo_id=auth.uid()) THEN RAISE EXCEPTION 'NOT_ROUTE_OWNER'; END IF;
 prior:=resolution_private.receipt(actor,p_request,'VEHICLE_CHECKPOINT',payload); IF prior IS NOT NULL THEN RETURN prior; END IF;
 b:=routing_private.lock_route(p_route,false);
 IF p_confirmed IS DISTINCT FROM true OR NOT routing_private.coord_checkpoint_required(p_route) OR b.closed_at IS NOT NULL OR b.started_at IS NULL OR EXISTS(SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) WHERE i.route_id=p_route AND t.task_status='DISPATCHED') THEN RAISE EXCEPTION 'VEHICLE_CHECKPOINT_NOT_AUTHORIZED'; END IF;
 INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,request_id,outcome,details)
 SELECT auth.uid(),'NGO','ROUTE',p_route,'VEHICLE_AT_DEPOT_CHECKPOINT',p_request,'SUCCESS',jsonb_build_object('depot',v.depot_road_node_id,'vehicle_version',v.vehicle_version,'vehicle_accountability_confirmed',true) FROM public.vehicles v WHERE v.vehicle_id=b.vehicle_id AND v.depot_road_node_id=fleet_private.require_depot(b.ngo_id);
 IF NOT FOUND THEN RAISE EXCEPTION 'VEHICLE_DEPOT_STALE'; END IF;
 result:=jsonb_build_object('outcome','SUCCESS','route_id',p_route,'checkpoint_confirmed',true);
 RETURN resolution_private.save_receipt(actor,p_request,'VEHICLE_CHECKPOINT',payload,result);
END $$;
DO $patch_remaining$ DECLARE src text; anchor text; BEGIN
 SELECT prosrc INTO src FROM pg_proc WHERE oid='routing_private.check_remaining(uuid,uuid,timestamptz)'::regprocedure;
 anchor:='SELECT * INTO STRICT b FROM routing_private.bindings WHERE route_id=p_route;';
 IF (length(src)-length(replace(src,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'CHECKPOINT_BINDING_SOURCE_DRIFT'; END IF;
 src:=replace(src,anchor,anchor||' IF routing_private.coord_checkpoint_required(p_route) THEN RAISE EXCEPTION ''VEHICLE_AT_DEPOT_CHECKPOINT_REQUIRED''; END IF;');
 anchor:='node:=coalesce(node,v.depot_road_node_id);';
 IF (length(src)-length(replace(src,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'CHECKPOINT_ORIGIN_SOURCE_DRIFT'; END IF;
 src:=replace(src,anchor,anchor||' IF routing_private.coord_checkpoint(p_route)>coalesce((SELECT max(collected_at) FROM routing_private.items WHERE route_id=p_route),''-infinity'') THEN node:=v.depot_road_node_id; END IF;');
 EXECUTE 'CREATE OR REPLACE FUNCTION routing_private.check_remaining(p_route uuid,p_next uuid,p_now timestamptz) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone=''UTC'' SET extra_float_digits=0 AS '||quote_literal(src);
END $patch_remaining$;

ALTER FUNCTION public.get_my_authorized_route(uuid) RENAME TO get_my_authorized_route_pre_coordination;
REVOKE ALL ON FUNCTION public.get_my_authorized_route_pre_coordination(uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.get_my_authorized_route(p_route uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE v jsonb; kind text; open boolean; BEGIN
 v:=public.get_my_authorized_route_pre_coordination(p_route); kind:=routing_private.coord_route_kind(p_route); open:=coalesce((v->>'authorization_confirmed')::boolean,false);
 RETURN v||jsonb_build_object('can_cancel',open AND routing_private.coord_can_cancel(p_route),
 'no_collection_cancellation_eligible',open AND routing_private.can_cancel_released_unstarted(p_route),
 'can_close',open AND routing_private.has_recorded_pickup(p_route) AND kind IS NOT NULL,
 'closure_outcome',CASE WHEN kind IN('MIXED_OUTCOME','NO_COLLECTION') AND routing_private.has_recorded_pickup(p_route) THEN 'ABANDONED' WHEN kind='COLLECTED' THEN 'COMPLETED' ELSE NULL END,
 'collected_pickup_count',(SELECT count(*) FROM routing_private.items WHERE route_id=p_route AND collected_at IS NOT NULL),
 'resolved_uncollected_count',(SELECT count(*) FROM routing_private.deferred_stops WHERE route_id=p_route AND status='RESOLVED_UNCOLLECTED'),
 'closure_kind',coalesce((SELECT m.result->>'outcome' FROM routing_private.mixed_route_closures m WHERE m.route_id=p_route),kind),
 'vehicle_checkpoint_required',open AND routing_private.coord_checkpoint_required(p_route),
 'can_confirm_depot_checkpoint',open AND routing_private.coord_checkpoint_required(p_route) AND NOT EXISTS(SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) WHERE i.route_id=p_route AND t.task_status='DISPATCHED'),
 'cancellation_outcome',(SELECT a.details->>'cancellation_outcome' FROM public.audit_events a WHERE a.entity_id=p_route AND a.entity_type='ROUTE' AND a.event_type='CANCEL_UNSTARTED_ROUTE' AND a.outcome='SUCCESS' ORDER BY occurred_at DESC LIMIT 1));
END $$;
-- Reuse the existing closure receipt and vehicle guard; never count released
-- historical stops as collected goods.
DO $patch_close$ DECLARE src text; anchor text; BEGIN
 SELECT replace(prosrc,chr(13),'') INTO src FROM pg_proc WHERE oid='public.close_my_resolved_route(uuid,boolean,uuid)'::regprocedure;
 anchor:=' IF p_depot_return_confirmed IS DISTINCT FROM true';
 IF (length(src)-length(replace(src,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'MIXED_CLOSURE_ANCHOR_DRIFT'; END IF;
 src:=replace(src,anchor,' IF NOT routing_private.has_recorded_pickup(p_route) OR routing_private.coord_route_kind(p_route) NOT IN(''NO_COLLECTION'',''MIXED_OUTCOME'') OR routing_private.coord_route_kind(p_route) IS NULL THEN RAISE EXCEPTION ''ROUTE_FINAL_OUTCOME_NOT_AUTHORIZED''; END IF;'||anchor);
 IF (length(src)-length(replace(src,'''outcome'',''MIXED_OUTCOME''','')))/length('''outcome'',''MIXED_OUTCOME''')<>1 THEN RAISE EXCEPTION 'MIXED_CLOSURE_ANCHOR_DRIFT'; END IF;
 src:=replace(src,'''outcome'',''MIXED_OUTCOME''','''outcome'',routing_private.coord_route_kind(p_route)');
 IF (length(src)-length(replace(src,'''final_pickup_count'',n,','')))/length('''final_pickup_count'',n,')<>2 THEN RAISE EXCEPTION 'MIXED_CLOSURE_ANCHOR_DRIFT'; END IF;
 src:=replace(src,'''final_pickup_count'',n,','''final_pickup_count'',n,''collected_pickup_count'',(SELECT count(*) FROM routing_private.items WHERE route_id=p_route AND collected_at IS NOT NULL),');
 IF (length(src)-length(replace(src,'''depot_return_confirmed'',true,','')))/length('''depot_return_confirmed'',true,')<>1 THEN RAISE EXCEPTION 'MIXED_CLOSURE_ANCHOR_DRIFT'; END IF;
 src:=replace(src,'''depot_return_confirmed'',true,','''vehicle_depot_return_confirmed'',true,''closure_kind'',result->>''outcome'',');
 EXECUTE 'CREATE OR REPLACE FUNCTION public.close_my_resolved_route(p_route uuid,p_depot_return_confirmed boolean,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone=''UTC'' SET extra_float_digits=0 AS '||quote_literal(src);
END $patch_close$;

DO $collected_guard$ DECLARE src text; anchor text:=' PERFORM routing_private.close_collected(p_route);'; BEGIN
 SELECT prosrc INTO src FROM pg_proc WHERE oid='public.close_my_collected_route(uuid,boolean)'::regprocedure;
 IF (length(src)-length(replace(src,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'COLLECTED_CLOSURE_SOURCE_DRIFT'; END IF;
 src:=replace(src,anchor,' IF routing_private.coord_route_kind(p_route) IS DISTINCT FROM ''COLLECTED'' OR NOT routing_private.has_recorded_pickup(p_route) THEN RAISE EXCEPTION ''ROUTE_FINAL_OUTCOME_NOT_AUTHORIZED''; END IF;'||anchor);
 EXECUTE 'CREATE OR REPLACE FUNCTION public.close_my_collected_route(p_route uuid,p_depot_return_confirmed boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone=''UTC'' SET extra_float_digits=0 AS '||quote_literal(src);
END $collected_guard$;


CREATE FUNCTION public.get_my_donation_coordination(p_donation uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.donations WHERE donation_id=p_donation AND donor_user_id=auth.uid()) THEN RAISE EXCEPTION 'DONATION_OWNER_REQUIRED'; END IF;
 RETURN jsonb_build_object('donation_id',p_donation,'contexts',(SELECT coalesce(jsonb_agg(public.get_my_claim_coordination(x.claim_id)),'[]') FROM
  (SELECT rc.claim_id FROM public.claim_reconciliation_cases rc JOIN public.donation_claims c USING(claim_id) JOIN public.listings l USING(listing_id)
   WHERE l.donation_id=p_donation AND l.source_type='DIRECT_DONATION' ORDER BY (rc.resolved_at IS NULL) DESC,rc.opened_at DESC LIMIT 10) x));
END $$;

-- Existing reader contracts keep their shapes but only current-round testimony
-- participates in actionable projections. Receipt/history reads remain unfiltered.
CREATE VIEW routing_private.coord_current_evidence WITH (security_barrier=true) AS
 SELECT e.* FROM public.claim_reconciliation_evidence e JOIN public.claim_reconciliation_cases rc USING(case_id) WHERE e.evidence_round=rc.evidence_round;
REVOKE ALL ON routing_private.coord_current_evidence FROM PUBLIC,anon,authenticated,service_role;
DO $reader_rounds$ DECLARE f record; src text; observed int; BEGIN
 FOR f IN SELECT * FROM (VALUES
  ('public.get_my_reconciliation_cases()',0),
  ('public.get_my_donation_claim_reconciliation(uuid)',2),
  ('public.get_my_claim_cards_v2()',0)
 ) expected(signature,expected_refs) LOOP
  SELECT pg_get_functiondef(to_regprocedure(f.signature)) INTO src;
  observed:=(length(src)-length(replace(src,'public.claim_reconciliation_evidence','')))/length('public.claim_reconciliation_evidence');
  IF observed IS DISTINCT FROM f.expected_refs THEN RAISE EXCEPTION 'COORDINATION_READER_ANCHOR_DRIFT:%',f.signature; END IF;
  IF f.expected_refs>0 THEN EXECUTE replace(src,'public.claim_reconciliation_evidence','routing_private.coord_current_evidence'); END IF;
 END LOOP;
END $reader_rounds$;

-- The deferred lifecycle invariant must distinguish goods available at source
-- from an expired listing that is intentionally not discoverable.
CREATE FUNCTION routing_private.coord_expired_released_listing(p_listing uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM public.listings l JOIN public.donation_claims c USING(listing_id)
 JOIN public.claim_leases le USING(claim_id) JOIN public.pickup_tasks t USING(claim_id) JOIN public.claim_reconciliation_cases rc USING(claim_id)
 WHERE l.listing_id=p_listing AND l.listing_status='CLOSED' AND NOT routing_private.coord_listing_window_valid(l.listing_id)
 AND c.claim_status='RELEASED' AND le.lease_status='RELEASED' AND t.task_status='STALE'
 AND c.close_reason IN('RECONCILED_NO_HANDOVER','RECONCILED_STARTED_NO_HANDOVER') AND le.release_reason=c.close_reason
 AND rc.case_status='RESOLVED_RELEASED' AND rc.resolved_at IS NOT NULL AND rc.resolution_reason='BOTH_PARTIES_CONFIRMED_NO_HANDOVER'
 AND routing_private.coord_votes(c.claim_id)->>'count'='2' AND routing_private.coord_votes(c.claim_id)->>'valid'='2' AND routing_private.coord_votes(c.claim_id)->>'yes'='0')
$$;
DO $commit_invariant$ DECLARE src text; anchor text:=$old$v_l.listing_status<>'AVAILABLE' or exists(select 1 from public.donation_claims c$old$; BEGIN
 SELECT prosrc INTO src FROM pg_proc WHERE oid='public.geolock_assert_donation_lifecycle(uuid)'::regprocedure;
 IF (length(src)-length(replace(src,anchor,'')))/length(anchor)<>1 THEN RAISE EXCEPTION 'EXPIRED_RELEASE_COMMIT_GUARD_DRIFT'; END IF;
 src:=replace(src,anchor,$new$(v_l.listing_status<>'AVAILABLE' AND NOT routing_private.coord_expired_released_listing(v_l.listing_id)) or exists(select 1 from public.donation_claims c$new$);
 EXECUTE 'CREATE OR REPLACE FUNCTION public.geolock_assert_donation_lifecycle(p_donation uuid) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS '||quote_literal(src);
END $commit_invariant$;

-- Newly created private functions have no direct client execution privileges.
DO $permissions$ DECLARE f record; BEGIN
 FOR f IN SELECT p.oid::regprocedure sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='routing_private' AND (p.proname LIKE 'coord_%' OR p.proname IN('has_recorded_pickup','can_cancel_released_unstarted')) LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated,service_role',f.sig);
 END LOOP;
 FOR f IN SELECT p.oid::regprocedure sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN('submit_claim_reconciliation_v2','resolve_my_claim_reconciliation','review_my_claim_reconciliation','get_my_coordination_receipt','get_my_claim_coordination','get_my_donation_coordination','get_my_authorized_route','confirm_my_route_depot_checkpoint') LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,service_role',f.sig);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated',f.sig);
 END LOOP;
END $permissions$;
COMMIT;
