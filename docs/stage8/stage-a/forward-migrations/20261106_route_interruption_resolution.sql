-- LOCAL PROTOTYPE ONLY. No DEV deployment approval. Forward-only, default disabled.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';
DO $$ BEGIN
 IF current_user<>'postgres' OR session_user<>'postgres' THEN RAISE EXCEPTION 'POSTGRES_INSTALLER_REQUIRED'; END IF;
 IF (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid='fleet_private.route_vehicle_guard()'::regprocedure)<>'af9b1e0e2afd2201b4ac9c284fabf105' THEN RAISE EXCEPTION 'FLEET_GUARD_BASELINE_DRIFT'; END IF;
 IF to_regnamespace('resolution_private') IS NOT NULL THEN RAISE EXCEPTION 'RESOLUTION_ALREADY_INSTALLED'; END IF;
 IF (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid='public.enforce_donation_transition()'::regprocedure)<>'c0cbbe68574ea42fafe9d2f60d08cff1' THEN RAISE EXCEPTION 'DONATION_GUARD_BASELINE_DRIFT'; END IF;
 IF (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid='public.complete_pickup(uuid,boolean)'::regprocedure)<>'26f0cd8cebe783c65b45e05649693860' THEN RAISE EXCEPTION 'COMPLETION_BASELINE_DRIFT'; END IF;
 IF (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc WHERE oid='public.recover_expired_claims(integer)'::regprocedure)<>'89e01f42d5ec23bfcbcdc47c1f4fd4e5' THEN RAISE EXCEPTION 'RECOVERY_BASELINE_DRIFT'; END IF;
END $$;

CREATE SCHEMA resolution_private AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA resolution_private FROM PUBLIC,anon,authenticated,service_role;
CREATE TABLE resolution_private.config(singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),enabled boolean NOT NULL DEFAULT false);
INSERT INTO resolution_private.config VALUES(true,false);
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='geolock_route_resolver') THEN
  CREATE ROLE geolock_route_resolver NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='geolock_route_resolver' AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb)) THEN RAISE EXCEPTION 'UNSAFE_RESOLVER_ROLE'; END IF;
END $$;
CREATE TABLE resolution_private.operators(login_name name PRIMARY KEY,operator_label text NOT NULL CHECK(length(operator_label) BETWEEN 1 AND 120),active boolean NOT NULL DEFAULT true);
CREATE TABLE resolution_private.cases(
 case_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),route_id uuid NOT NULL UNIQUE REFERENCES routing_private.bindings,
 ngo_id uuid NOT NULL REFERENCES public.ngo_profiles(user_id),version bigint NOT NULL DEFAULT 1,
 status text NOT NULL CHECK(status IN('AWAITING_EVIDENCE','MANUAL_REVIEW','RESOLVED')),
 reason text NOT NULL,manifest_digest text NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),resolved_at timestamptz);
CREATE TABLE resolution_private.items(
 case_id uuid NOT NULL REFERENCES resolution_private.cases,task_id uuid NOT NULL REFERENCES public.pickup_tasks,
 claim_id uuid NOT NULL REFERENCES public.donation_claims,source_actor uuid NOT NULL REFERENCES public.user_profiles(user_id),
 source_role text NOT NULL CHECK(source_role IN('DONOR','HUB_ADMIN')),initial_class text NOT NULL,
 observation_digest text NOT NULL,PRIMARY KEY(case_id,task_id));
CREATE TABLE resolution_private.evidence(
 evidence_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),case_id uuid NOT NULL REFERENCES resolution_private.cases,
 task_id uuid REFERENCES public.pickup_tasks,actor_id uuid NOT NULL REFERENCES public.user_profiles(user_id),
 assertion text NOT NULL CHECK(assertion IN('NO_HANDOVER_SOURCE_RETAINS_GOODS','HANDOVER_TO_NGO_CONFIRMED','UNKNOWN_CUSTODY','VEHICLE_RETURNED_TO_NGO_CONTROL')),
 version bigint NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(case_id,version));
CREATE TABLE resolution_private.requests(
 actor_key text NOT NULL,request_id uuid NOT NULL,operation text NOT NULL,payload_digest text NOT NULL,result jsonb NOT NULL,
 PRIMARY KEY(actor_key,request_id));
CREATE TABLE resolution_private.incidents(
 incident_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),case_id uuid NOT NULL REFERENCES resolution_private.cases,
 task_id uuid REFERENCES public.pickup_tasks,actor_id uuid NOT NULL REFERENCES public.user_profiles(user_id),
 assertion text NOT NULL CHECK(assertion IN('NO_HANDOVER_SOURCE_RETAINS_GOODS','HANDOVER_TO_NGO_CONFIRMED','UNKNOWN_CUSTODY')),
 case_version bigint NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE TABLE resolution_private.releases(
 case_id uuid NOT NULL REFERENCES resolution_private.cases,task_id uuid NOT NULL REFERENCES public.pickup_tasks,
 original_assignment jsonb NOT NULL,disposition text NOT NULL,released_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(case_id,task_id));
CREATE TABLE resolution_private.permits(
 task_id uuid PRIMARY KEY REFERENCES public.pickup_tasks,case_id uuid NOT NULL REFERENCES resolution_private.cases,
 transaction_id xid8 NOT NULL);
CREATE TABLE resolution_private.finalizations(route_id uuid PRIMARY KEY REFERENCES public.pickup_routes,case_id uuid NOT NULL REFERENCES resolution_private.cases,transaction_id xid8 NOT NULL);
CREATE TABLE resolution_private.test_runs(
 run_id uuid PRIMARY KEY,project_ref text NOT NULL CHECK(project_ref='rcgyuwiidqvrgbxswhqj'),manifest_digest text NOT NULL CHECK(manifest_digest~'^[0-9a-f]{64}$'),
 ngo_id uuid NOT NULL REFERENCES public.ngo_profiles(user_id),vehicle_id uuid NOT NULL REFERENCES public.vehicles,
 fixture_claim_ids uuid[] NOT NULL CHECK(cardinality(fixture_claim_ids)>0),created_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE UNIQUE INDEX resolution_evidence_latest ON resolution_private.evidence(case_id,actor_id,task_id,version DESC);

CREATE FUNCTION resolution_private.immutable() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$ BEGIN RAISE EXCEPTION 'RESOLUTION_HISTORY_IMMUTABLE'; END $$;
CREATE TRIGGER immutable_evidence BEFORE UPDATE OR DELETE ON resolution_private.evidence FOR EACH ROW EXECUTE FUNCTION resolution_private.immutable();
CREATE TRIGGER immutable_receipts BEFORE UPDATE OR DELETE ON resolution_private.requests FOR EACH ROW EXECUTE FUNCTION resolution_private.immutable();
CREATE TRIGGER immutable_incidents BEFORE UPDATE OR DELETE ON resolution_private.incidents FOR EACH ROW EXECUTE FUNCTION resolution_private.immutable();
CREATE TRIGGER immutable_releases BEFORE UPDATE OR DELETE ON resolution_private.releases FOR EACH ROW EXECUTE FUNCTION resolution_private.immutable();
CREATE TRIGGER immutable_test_runs BEFORE UPDATE OR DELETE ON resolution_private.test_runs FOR EACH ROW EXECUTE FUNCTION resolution_private.immutable();

CREATE FUNCTION resolution_private.require_enabled() RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ BEGIN
 IF NOT (SELECT enabled FROM resolution_private.config WHERE singleton) THEN RAISE EXCEPTION 'ROUTE_RESOLUTION_DISABLED'; END IF;
END $$;
CREATE FUNCTION resolution_private.operator_key() RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ BEGIN
 -- Native operators never inherit an authenticated participant's JWT context.
 -- Inspect raw settings first: even malformed JSON/UUIDs must fail before replay.
 IF coalesce(current_setting('request.jwt.claim.sub',true),'')<>''
 OR coalesce(current_setting('request.jwt.claims',true),'')<>''
 OR coalesce(current_setting('request.jwt.claim.role',true),'')<>'' THEN RAISE EXCEPTION 'RESOLVER_JWT_CONTEXT_FORBIDDEN'; END IF;
 IF NOT pg_has_role(session_user,'geolock_route_resolver','MEMBER') OR NOT EXISTS(SELECT 1 FROM resolution_private.operators WHERE login_name=session_user AND active) THEN RAISE EXCEPTION 'RESTRICTED_RESOLVER_REQUIRED'; END IF;
 RETURN 'resolver:'||session_user;
END $$;
CREATE FUNCTION resolution_private.actor_key() RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.user_profiles WHERE user_id=auth.uid()) THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
 RETURN 'user:'||auth.uid()::text;
END $$;
CREATE FUNCTION resolution_private.receipt(p_actor text,p_request uuid,p_operation text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE r resolution_private.requests%rowtype; BEGIN
 IF p_request IS NULL THEN RAISE EXCEPTION 'REQUEST_REQUIRED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('route-resolution-request:'||p_actor||':'||p_request,0));
 SELECT * INTO r FROM resolution_private.requests WHERE actor_key=p_actor AND request_id=p_request;
 IF FOUND THEN
  IF r.operation<>p_operation OR r.payload_digest<>routing_private.hash(p_payload) THEN RAISE EXCEPTION 'REQUEST_PAYLOAD_CONFLICT'; END IF;
  RETURN r.result;
 END IF; RETURN NULL;
END $$;
CREATE FUNCTION resolution_private.save_receipt(p_actor text,p_request uuid,p_operation text,p_payload jsonb,p_result jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ BEGIN
 INSERT INTO resolution_private.requests VALUES(p_actor,p_request,p_operation,routing_private.hash(p_payload),p_result); RETURN p_result;
END $$;
CREATE FUNCTION resolution_private.manifest(p_route uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT routing_private.hash(coalesce(jsonb_agg(jsonb_build_object('task_id',task_id,'ordinal',ordinal) ORDER BY ordinal),'[]')) FROM routing_private.items WHERE route_id=p_route
$$;
CREATE FUNCTION resolution_private.allowed(p_case uuid,p_actor uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT p_actor IS NOT NULL AND EXISTS(SELECT 1 FROM resolution_private.cases c JOIN public.user_profiles u ON u.user_id=p_actor WHERE c.case_id=p_case AND ((c.ngo_id=p_actor AND u.role='NGO') OR EXISTS(SELECT 1 FROM resolution_private.items i WHERE i.case_id=c.case_id AND i.source_actor=p_actor AND i.source_role=u.role)))
$$;
CREATE FUNCTION resolution_private.latest(p_case uuid,p_task uuid,p_actor uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT assertion FROM resolution_private.evidence WHERE case_id=p_case AND task_id IS NOT DISTINCT FROM p_task AND actor_id=p_actor ORDER BY version DESC LIMIT 1
$$;
CREATE FUNCTION resolution_private.audit(p_route uuid,p_case uuid,p_event text,p_request uuid,p_details jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor uuid;role_name text;principal text;label text;BEGIN
 IF EXISTS(SELECT 1 FROM resolution_private.operators WHERE login_name=session_user) THEN
  PERFORM resolution_private.operator_key();
  principal:=session_user::text;
  SELECT operator_label INTO STRICT label FROM resolution_private.operators WHERE login_name=session_user AND active;
  actor:=NULL;role_name:='SYSTEM';
 ELSE
  actor:=auth.uid();role_name:=CASE WHEN actor IS NULL THEN 'SYSTEM' ELSE (SELECT role FROM public.user_profiles WHERE user_id=actor) END;
 END IF;
 INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,request_id,outcome,details)
 VALUES(actor,role_name,'ROUTE',p_route,p_event,p_request,'SUCCESS',p_details||jsonb_build_object('case_id',p_case,'operator_principal',principal,'operator_label',label,'transaction_id',pg_current_xact_id()::text));
END $$;

-- The only synthetic-enrollment entrypoint is restricted; it never changes records.
CREATE FUNCTION public.register_route_test_provenance(p_run uuid,p_manifest text,p_ngo uuid,p_vehicle uuid,p_claims uuid[],p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor text:=resolution_private.operator_key(); payload jsonb:=jsonb_build_object('run',p_run,'manifest',p_manifest,'ngo',p_ngo,'vehicle',p_vehicle,'claims',p_claims); prior jsonb; BEGIN
 PERFORM resolution_private.require_enabled(); prior:=resolution_private.receipt(actor,p_request,'TEST_PROVENANCE',payload); IF prior IS NOT NULL THEN RETURN prior; END IF;
 IF p_run IS NULL OR p_manifest IS NULL OR p_manifest!~'^[0-9a-f]{64}$' OR cardinality(p_claims) IS NULL OR cardinality(p_claims)=0
 OR cardinality(p_claims)<>(SELECT count(DISTINCT x) FROM unnest(p_claims) x) OR array_position(p_claims,NULL) IS NOT NULL
 OR NOT EXISTS(SELECT 1 FROM public.vehicles WHERE vehicle_id=p_vehicle AND ngo_user_id=p_ngo)
 OR EXISTS(SELECT 1 FROM unnest(p_claims) x LEFT JOIN public.donation_claims c ON c.claim_id=x WHERE c.claim_id IS NULL OR c.ngo_user_id<>p_ngo)
 OR EXISTS(SELECT 1 FROM resolution_private.test_runs WHERE fixture_claim_ids && p_claims) THEN RAISE EXCEPTION 'INVALID_TEST_PROVENANCE_SCOPE'; END IF;
 INSERT INTO resolution_private.test_runs VALUES(p_run,'rcgyuwiidqvrgbxswhqj',p_manifest,p_ngo,p_vehicle,p_claims,clock_timestamp());
 RETURN resolution_private.save_receipt(actor,p_request,'TEST_PROVENANCE',payload,jsonb_build_object('run_id',p_run,'outcome','REGISTERED'));
END $$;
CREATE FUNCTION resolution_private.audit_provenance() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE r resolution_private.test_runs%rowtype; rid uuid; BEGIN
 -- Also cover existing donation-transition audit helpers used by finalization.
 IF EXISTS(SELECT 1 FROM resolution_private.operators WHERE login_name=session_user) THEN
  PERFORM resolution_private.operator_key();
  NEW.actor_user_id:=NULL;NEW.actor_role:='SYSTEM';
  NEW.details:=coalesce(NEW.details,'{}')||jsonb_build_object('operator_principal',session_user::text,
   'operator_label',(SELECT operator_label FROM resolution_private.operators WHERE login_name=session_user AND active));
 END IF;
 IF NEW.details ? 'simulation' OR NEW.details ? 'test_run_id' OR NEW.details ? 'test_manifest_digest' THEN RAISE EXCEPTION 'CLIENT_TEST_PROVENANCE_FORBIDDEN'; END IF;
 rid:=CASE WHEN NEW.entity_type='ROUTE' THEN NEW.entity_id ELSE NULL END;
 SELECT tr.* INTO r FROM resolution_private.test_runs tr WHERE
 (NEW.claim_id=ANY(tr.fixture_claim_ids)) OR (rid IS NOT NULL AND EXISTS(
 SELECT 1 FROM routing_private.bindings b WHERE b.route_id=rid AND b.ngo_id=tr.ngo_id AND b.vehicle_id=tr.vehicle_id
 AND NOT EXISTS(SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) WHERE i.route_id=rid AND NOT(t.claim_id=ANY(tr.fixture_claim_ids))))) LIMIT 1;
 IF FOUND THEN NEW.details:=coalesce(NEW.details,'{}')||jsonb_build_object('simulation',true,'test_run_id',r.run_id,'test_manifest_digest',r.manifest_digest); END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER resolution_audit_provenance BEFORE INSERT ON public.audit_events FOR EACH ROW EXECUTE FUNCTION resolution_private.audit_provenance();

CREATE FUNCTION public.report_my_route_interruption(p_route uuid,p_reason text,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor text:=resolution_private.actor_key(); payload jsonb:=jsonb_build_object('route',p_route,'reason',p_reason); prior jsonb;
 b routing_private.bindings%rowtype;c resolution_private.cases%rowtype;x record;counterpart uuid;source_role text;
BEGIN
 PERFORM resolution_private.require_enabled();
 IF NOT EXISTS(SELECT 1 FROM public.user_profiles WHERE user_id=auth.uid() AND role='NGO') THEN RAISE EXCEPTION 'NGO_ROLE_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM routing_private.bindings WHERE route_id=p_route AND ngo_id=auth.uid()) THEN RAISE EXCEPTION 'NOT_ROUTE_OWNER'; END IF;
 prior:=resolution_private.receipt(actor,p_request,'REPORT',payload); IF prior IS NOT NULL THEN RETURN prior; END IF;
 b:=routing_private.lock_route(p_route,false);
 PERFORM resolution_private.assert_test_scope(p_route);
 IF p_reason IS NULL OR p_reason NOT IN('EXECUTION_BUDGET_EXCEEDED','VEHICLE_FAILURE','PICKUP_UNAVAILABLE','OTHER_REQUIRES_REVIEW') THEN RAISE EXCEPTION 'INTERRUPTION_REASON_REQUIRED'; END IF;
 IF b.started_at IS NULL OR b.closed_at IS NOT NULL OR (SELECT route_status FROM public.pickup_routes WHERE route_id=p_route)<>'IN_PROGRESS' THEN RAISE EXCEPTION 'STARTED_OPEN_ROUTE_REQUIRED'; END IF;
 SELECT * INTO c FROM resolution_private.cases WHERE route_id=p_route FOR UPDATE;
 IF NOT FOUND THEN
  INSERT INTO resolution_private.cases(route_id,ngo_id,status,reason,manifest_digest) VALUES(p_route,b.ngo_id,'AWAITING_EVIDENCE',p_reason,resolution_private.manifest(p_route)) RETURNING * INTO c;
  FOR x IN SELECT t.*,i.consumed_at,i.collected_at,l.source_type,l.donation_id,l.batch_id FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) JOIN public.listings l USING(listing_id) WHERE i.route_id=p_route ORDER BY i.ordinal LOOP
   SELECT CASE WHEN x.source_type='DIRECT_DONATION' THEN d.donor_user_id ELSE h.admin_user_id END INTO counterpart
   FROM public.listings l LEFT JOIN public.donations d ON d.donation_id=l.donation_id LEFT JOIN public.hub_batches hb ON hb.batch_id=l.batch_id LEFT JOIN public.community_hubs h ON h.hub_id=hb.hub_id WHERE l.listing_id=x.listing_id;
   source_role:=CASE WHEN x.source_type='DIRECT_DONATION' THEN 'DONOR' ELSE 'HUB_ADMIN' END;
   IF counterpart IS NULL OR counterpart=b.ngo_id OR NOT EXISTS(SELECT 1 FROM public.user_profiles WHERE user_id=counterpart AND role=source_role) THEN RAISE EXCEPTION 'SOURCE_PARTICIPANT_REQUIRED'; END IF;
   IF x.task_status='COLLECTED' AND x.collected_at IS NOT NULL THEN
    IF NOT EXISTS(SELECT 1 FROM public.donation_claims dc JOIN public.claim_leases le USING(claim_id) WHERE dc.claim_id=x.claim_id AND dc.claim_status='COMPLETED' AND le.lease_status='COMPLETED') THEN RAISE EXCEPTION 'COLLECTED_STATE_INCONSISTENT'; END IF;
   ELSE
    IF x.task_status NOT IN('PLANNED','DISPATCHED') OR (x.task_status='PLANNED' AND x.consumed_at IS NOT NULL) OR (x.task_status='DISPATCHED' AND x.consumed_at IS NULL) THEN RAISE EXCEPTION 'ITEM_CLASSIFICATION_INCONSISTENT'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.donation_claims dc JOIN public.claim_leases le USING(claim_id) WHERE dc.claim_id=x.claim_id AND dc.claim_status IN('ACTIVE','RECONCILIATION_REQUIRED') AND le.lease_status IN('ACTIVE','RECONCILIATION_REQUIRED')) THEN RAISE EXCEPTION 'CLAIM_RESOLUTION_STATE_MISMATCH'; END IF;
    UPDATE public.donation_claims SET claim_status='RECONCILIATION_REQUIRED' WHERE claim_id=x.claim_id;
    UPDATE public.claim_leases SET lease_status='RECONCILIATION_REQUIRED' WHERE claim_id=x.claim_id;
    IF NOT EXISTS(SELECT 1 FROM public.claim_reconciliation_cases WHERE claim_id=x.claim_id AND case_status IN('OPEN','MANUAL_REVIEW')) THEN
     INSERT INTO public.claim_reconciliation_cases(claim_id,listing_id,donation_id,source_type,case_status) VALUES(x.claim_id,x.listing_id,x.donation_id,x.source_type,'OPEN');
    END IF;
   END IF;
   INSERT INTO resolution_private.items VALUES(c.case_id,x.task_id,x.claim_id,counterpart,source_role,CASE WHEN x.collected_at IS NOT NULL THEN 'COLLECTED' WHEN x.consumed_at IS NOT NULL THEN 'DISPATCHED' ELSE 'NEVER_STARTED' END,routing_private.task_digest(routing_private.observe_task(x.task_id)));
  END LOOP;
  PERFORM resolution_private.audit(p_route,c.case_id,'ROUTE_INTERRUPTION_REPORTED',p_request,jsonb_build_object('reason',p_reason));
 END IF;
 RETURN resolution_private.save_receipt(actor,p_request,'REPORT',payload,jsonb_build_object('contract','geolock.route-resolution.v1','case_id',c.case_id,'route_id',p_route,'version',c.version,'status',c.status));
END $$;

CREATE FUNCTION public.submit_route_resolution_evidence(p_case uuid,p_task uuid,p_assertion text,p_version bigint,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor text:=resolution_private.actor_key();payload jsonb:=jsonb_build_object('case',p_case,'task',p_task,'assertion',p_assertion,'version',p_version);prior jsonb;c resolution_private.cases%rowtype;i resolution_private.items%rowtype; old_assertion text; lock_claim uuid;
BEGIN
 PERFORM resolution_private.require_enabled();
 IF NOT resolution_private.allowed(p_case,auth.uid()) THEN RAISE EXCEPTION 'RESOLUTION_PARTICIPANT_ONLY'; END IF;
 prior:=resolution_private.receipt(actor,p_request,'EVIDENCE',payload);IF prior IS NOT NULL THEN RETURN prior;END IF;
 SELECT * INTO STRICT c FROM resolution_private.cases WHERE case_id=p_case;
 -- Choose an authorized participant anchor; the unchanged helper still locks
 -- the complete managed route in its existing source/vehicle/route order.
 IF p_task IS NULL THEN
  IF auth.uid()<>c.ngo_id OR p_assertion<>'VEHICLE_RETURNED_TO_NGO_CONTROL' THEN RAISE EXCEPTION 'NGO_VEHICLE_CONFIRMATION_REQUIRED'; END IF;
  SELECT claim_id INTO STRICT lock_claim FROM resolution_private.items WHERE case_id=p_case ORDER BY task_id LIMIT 1;
 ELSE
  SELECT * INTO STRICT i FROM resolution_private.items WHERE case_id=p_case AND task_id=p_task;
  IF auth.uid() NOT IN(c.ngo_id,i.source_actor) OR NOT EXISTS(SELECT 1 FROM public.user_profiles WHERE user_id=auth.uid() AND role=CASE WHEN auth.uid()=c.ngo_id THEN 'NGO' ELSE i.source_role END) THEN RAISE EXCEPTION 'ITEM_PARTICIPANT_ONLY'; END IF;
  lock_claim:=i.claim_id;
 END IF;
 PERFORM routing_private.lock_reconciliation_scope(lock_claim);
 SELECT * INTO STRICT c FROM resolution_private.cases WHERE case_id=p_case FOR UPDATE;
 IF c.resolved_at IS NOT NULL THEN RAISE EXCEPTION 'TERMINAL_RESOLUTION_IMMUTABLE'; END IF;
 IF p_version IS DISTINCT FROM c.version THEN RAISE EXCEPTION 'CASE_VERSION_STALE'; END IF;
 IF p_task IS NULL THEN
  IF auth.uid()<>c.ngo_id OR p_assertion<>'VEHICLE_RETURNED_TO_NGO_CONTROL' THEN RAISE EXCEPTION 'NGO_VEHICLE_CONFIRMATION_REQUIRED'; END IF;
 ELSE
  SELECT * INTO STRICT i FROM resolution_private.items WHERE case_id=p_case AND task_id=p_task;
  IF auth.uid() NOT IN(c.ngo_id,i.source_actor) OR NOT EXISTS(SELECT 1 FROM public.user_profiles WHERE user_id=auth.uid() AND role=CASE WHEN auth.uid()=c.ngo_id THEN 'NGO' ELSE i.source_role END) THEN RAISE EXCEPTION 'ITEM_PARTICIPANT_ONLY'; END IF;
  IF p_assertion IS NULL OR p_assertion NOT IN('NO_HANDOVER_SOURCE_RETAINS_GOODS','HANDOVER_TO_NGO_CONFIRMED','UNKNOWN_CUSTODY') THEN RAISE EXCEPTION 'CUSTODY_ASSERTION_REQUIRED'; END IF;
  IF p_assertion='HANDOVER_TO_NGO_CONFIRMED' AND i.initial_class='NEVER_STARTED' THEN RAISE EXCEPTION 'NEVER_STARTED_HANDOVER_FORBIDDEN'; END IF;
 END IF;
 old_assertion:=resolution_private.latest(p_case,p_task,auth.uid());
 UPDATE resolution_private.cases SET version=version+1,status=CASE WHEN p_assertion='UNKNOWN_CUSTODY' OR (old_assertion IS NOT NULL AND old_assertion<>p_assertion)
 OR (p_task IS NOT NULL AND resolution_private.latest(p_case,p_task,CASE WHEN auth.uid()=c.ngo_id THEN i.source_actor ELSE c.ngo_id END) IS NOT NULL
 AND resolution_private.latest(p_case,p_task,CASE WHEN auth.uid()=c.ngo_id THEN i.source_actor ELSE c.ngo_id END)<>p_assertion)
 THEN 'MANUAL_REVIEW' ELSE 'AWAITING_EVIDENCE' END WHERE case_id=p_case RETURNING * INTO c;
 INSERT INTO resolution_private.evidence(case_id,task_id,actor_id,assertion,version) VALUES(p_case,p_task,auth.uid(),p_assertion,c.version);
 IF p_task IS NOT NULL AND p_assertion='HANDOVER_TO_NGO_CONFIRMED' THEN
  PERFORM public.submit_claim_reconciliation(i.claim_id,true,p_request);
 END IF;
 PERFORM resolution_private.audit(c.route_id,p_case,CASE WHEN old_assertion IS NOT NULL THEN 'ROUTE_RESOLUTION_EVIDENCE_SUPERSEDED' ELSE 'ROUTE_RESOLUTION_EVIDENCE_SUBMITTED' END,p_request,jsonb_build_object('task_id',p_task,'assertion',p_assertion,'version',c.version));
 RETURN resolution_private.save_receipt(actor,p_request,'EVIDENCE',payload,jsonb_build_object('case_id',p_case,'version',c.version,'status',c.status));
END $$;

-- D06: post-terminal statements become linked incidents, never custody changes.
CREATE FUNCTION public.report_route_resolution_incident(p_case uuid,p_task uuid,p_assertion text,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor text:=resolution_private.actor_key();payload jsonb:=jsonb_build_object('case',p_case,'task',p_task,'assertion',p_assertion);prior jsonb;c resolution_private.cases%rowtype;incident uuid;
BEGIN
 PERFORM resolution_private.require_enabled();
 IF NOT resolution_private.allowed(p_case,auth.uid()) THEN RAISE EXCEPTION 'RESOLUTION_PARTICIPANT_ONLY'; END IF;
 prior:=resolution_private.receipt(actor,p_request,'INCIDENT',payload);IF prior IS NOT NULL THEN RETURN prior;END IF;
 SELECT * INTO STRICT c FROM resolution_private.cases WHERE case_id=p_case FOR SHARE;
 IF c.status<>'RESOLVED' OR c.resolved_at IS NULL THEN RAISE EXCEPTION 'TERMINAL_CASE_REQUIRED'; END IF;
 IF p_assertion IS NULL OR p_assertion NOT IN('NO_HANDOVER_SOURCE_RETAINS_GOODS','HANDOVER_TO_NGO_CONFIRMED','UNKNOWN_CUSTODY') THEN RAISE EXCEPTION 'CUSTODY_ASSERTION_REQUIRED'; END IF;
 IF p_task IS NULL OR NOT EXISTS(SELECT 1 FROM resolution_private.items i WHERE i.case_id=p_case AND i.task_id=p_task AND (c.ngo_id=auth.uid() OR i.source_actor=auth.uid())) THEN RAISE EXCEPTION 'ITEM_PARTICIPANT_ONLY'; END IF;
 INSERT INTO resolution_private.incidents(case_id,task_id,actor_id,assertion,case_version) VALUES(p_case,p_task,auth.uid(),p_assertion,c.version) RETURNING incident_id INTO incident;
 PERFORM resolution_private.audit(c.route_id,p_case,'ROUTE_RESOLUTION_INCIDENT_REPORTED',p_request,jsonb_build_object('incident_id',incident,'task_id',p_task,'assertion',p_assertion));
 RETURN resolution_private.save_receipt(actor,p_request,'INCIDENT',payload,jsonb_build_object('case_id',p_case,'incident_id',incident,'status','INCIDENT_RECORDED','route_id',c.route_id));
END $$;

CREATE FUNCTION resolution_private.lock_case(p_case uuid) RETURNS resolution_private.cases LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE c resolution_private.cases%rowtype;b routing_private.bindings%rowtype;ids uuid[];BEGIN
 SELECT * INTO STRICT c FROM resolution_private.cases WHERE case_id=p_case;
 SELECT * INTO STRICT b FROM routing_private.bindings WHERE route_id=c.route_id;
 PERFORM 1 FROM public.ngo_profiles WHERE user_id=c.ngo_id FOR SHARE;
 PERFORM pg_advisory_xact_lock(hashtextextended('routing-ngo:'||c.ngo_id::text,0));
 SELECT array_agg(task_id ORDER BY task_id) INTO ids FROM routing_private.items WHERE route_id=c.route_id;
 PERFORM routing_private.lock_sources(ids);
 PERFORM 1 FROM public.vehicles WHERE vehicle_id=b.vehicle_id FOR UPDATE;
 PERFORM 1 FROM public.pickup_routes WHERE route_id=c.route_id FOR UPDATE;
 PERFORM 1 FROM public.pickup_tasks WHERE task_id=ANY(ids) ORDER BY task_id FOR UPDATE;
 PERFORM 1 FROM routing_private.bindings WHERE route_id=c.route_id FOR UPDATE;
 SELECT * INTO STRICT c FROM resolution_private.cases WHERE case_id=p_case FOR UPDATE;
 RETURN c;
END $$;

CREATE FUNCTION resolution_private.release_allowed(p_donation uuid,p_target text) RETURNS boolean LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT EXISTS(SELECT 1 FROM resolution_private.permits p JOIN resolution_private.cases c USING(case_id)
 JOIN resolution_private.items ri ON ri.case_id=p.case_id AND ri.task_id=p.task_id
 JOIN public.pickup_tasks t ON t.task_id=p.task_id JOIN public.listings l USING(listing_id)
 WHERE p.transaction_id=pg_current_xact_id() AND c.resolved_at IS NULL
 AND pg_has_role(session_user,'geolock_route_resolver','MEMBER')
 AND EXISTS(SELECT 1 FROM resolution_private.operators WHERE login_name=session_user AND active)
 AND resolution_private.latest(c.case_id,p.task_id,c.ngo_id)='NO_HANDOVER_SOURCE_RETAINS_GOODS'
 AND resolution_private.latest(c.case_id,p.task_id,ri.source_actor)='NO_HANDOVER_SOURCE_RETAINS_GOODS'
 AND ((l.source_type='DIRECT_DONATION' AND l.donation_id=p_donation AND p_target='AVAILABLE')
 OR (l.source_type='HUB_BATCH' AND p_target='BATCHED' AND EXISTS(SELECT 1 FROM public.hub_batch_members m WHERE m.batch_id=l.batch_id AND m.donation_id=p_donation AND m.membership_status='ACTIVE'))))
$$;

CREATE FUNCTION public.finalize_route_resolution(p_case uuid,p_version bigint,p_request uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor text:=resolution_private.operator_key();payload jsonb:=jsonb_build_object('case',p_case,'version',p_version);prior jsonb;
 c resolution_private.cases%rowtype;b routing_private.bindings%rowtype;x record;obs jsonb;d jsonb;counterpart uuid;blocked text;result jsonb;
BEGIN
 PERFORM resolution_private.require_enabled(); prior:=resolution_private.receipt(actor,p_request,'FINALIZE',payload);IF prior IS NOT NULL THEN RETURN prior;END IF;
 c:=resolution_private.lock_case(p_case);
 PERFORM resolution_private.assert_test_scope(c.route_id);
 IF c.resolved_at IS NOT NULL THEN RAISE EXCEPTION 'TERMINAL_RESOLUTION_IMMUTABLE'; END IF;
 IF c.version IS DISTINCT FROM p_version THEN RAISE EXCEPTION 'CASE_VERSION_STALE'; END IF;
 SELECT * INTO STRICT b FROM routing_private.bindings WHERE route_id=c.route_id;
 IF b.closed_at IS NOT NULL OR b.started_at IS NULL OR resolution_private.manifest(c.route_id)<>c.manifest_digest
 OR (SELECT route_status FROM public.pickup_routes WHERE route_id=c.route_id)<>'IN_PROGRESS'
 OR NOT EXISTS(SELECT 1 FROM public.vehicles WHERE vehicle_id=b.vehicle_id AND ngo_user_id=c.ngo_id AND vehicle_version=b.vehicle_version)
 OR EXISTS(SELECT 1 FROM public.pickup_routes r WHERE r.route_id=c.route_id AND (r.vehicle_id<>b.vehicle_id OR r.ngo_user_id<>c.ngo_id OR r.validation_reference<>b.candidate_id::text))
 THEN RAISE EXCEPTION 'RESOLUTION_BINDING_DRIFT'; END IF;
 IF resolution_private.latest(p_case,NULL,c.ngo_id) IS DISTINCT FROM 'VEHICLE_RETURNED_TO_NGO_CONTROL' THEN RAISE EXCEPTION 'VEHICLE_ACCOUNTABILITY_REQUIRED'; END IF;
 FOR x IN SELECT ri.*,t.task_status,t.listing_id,it.consumed_at,it.collected_at FROM resolution_private.items ri JOIN public.pickup_tasks t USING(task_id) JOIN routing_private.items it ON it.task_id=t.task_id AND it.route_id=c.route_id WHERE ri.case_id=p_case ORDER BY it.ordinal LOOP
  obs:=routing_private.observe_task(x.task_id);
  IF obs IS NULL OR jsonb_array_length(obs->'donations')=0 THEN RAISE EXCEPTION 'SOURCE_SET_MISSING'; END IF;
  IF x.task_status='COLLECTED' AND x.collected_at IS NOT NULL AND obs->'claim'->>'claim_status'='COMPLETED' AND obs->'lease'->>'lease_status'='COMPLETED'
  AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(obs->'donations') z WHERE z->>'donation_status'<>'COLLECTED') THEN
   IF EXISTS(SELECT 1 FROM (SELECT DISTINCT ON(actor_id) assertion FROM resolution_private.evidence WHERE case_id=p_case AND task_id=x.task_id ORDER BY actor_id,version DESC) latest WHERE assertion<>'HANDOVER_TO_NGO_CONFIRMED') THEN RAISE EXCEPTION 'COLLECTED_CUSTODY_DISPUTED'; END IF;
   CONTINUE;
  END IF;
  IF x.initial_class='COLLECTED' THEN RAISE EXCEPTION 'COLLECTED_STATE_INCONSISTENT'; END IF;
  IF resolution_private.latest(p_case,x.task_id,c.ngo_id) IS DISTINCT FROM 'NO_HANDOVER_SOURCE_RETAINS_GOODS'
  OR resolution_private.latest(p_case,x.task_id,x.source_actor) IS DISTINCT FROM 'NO_HANDOVER_SOURCE_RETAINS_GOODS' THEN RAISE EXCEPTION 'MATCHING_TWO_PARTY_NO_HANDOVER_REQUIRED'; END IF;
  SELECT CASE WHEN l.source_type='DIRECT_DONATION' THEN dn.donor_user_id ELSE h.admin_user_id END INTO counterpart
  FROM public.listings l LEFT JOIN public.donations dn ON dn.donation_id=l.donation_id LEFT JOIN public.hub_batches hb ON hb.batch_id=l.batch_id LEFT JOIN public.community_hubs h ON h.hub_id=hb.hub_id WHERE l.listing_id=x.listing_id;
  IF counterpart IS DISTINCT FROM x.source_actor OR counterpart=c.ngo_id OR NOT EXISTS(SELECT 1 FROM public.user_profiles WHERE user_id=x.source_actor AND role=x.source_role) THEN RAISE EXCEPTION 'SOURCE_PARTICIPANT_DRIFT'; END IF;
  IF routing_private.task_digest(obs)<>x.observation_digest OR obs->'claim'->>'claim_status'<>'RECONCILIATION_REQUIRED'
  OR obs->'lease'->>'lease_status'<>'RECONCILIATION_REQUIRED' OR x.task_status NOT IN('PLANNED','DISPATCHED')
  OR NOT EXISTS(SELECT 1 FROM public.active_task_route_assignments WHERE task_id=x.task_id AND route_id=c.route_id)
  OR EXISTS(SELECT 1 FROM public.claim_reconciliation_evidence e JOIN public.claim_reconciliation_cases rc USING(case_id) WHERE rc.claim_id=x.claim_id AND e.handover_confirmed)
  THEN RAISE EXCEPTION 'CUSTODY_OR_OBSERVATION_CONFLICT'; END IF;
  IF obs->'listing'->>'listing_status'<>'CLAIMED' OR (obs->'listing'->>'listing_expires_at')::timestamptz<=clock_timestamp()
  OR EXISTS(SELECT 1 FROM jsonb_array_elements(obs->'donations') z WHERE (z->>'availability_end')::timestamptz<=clock_timestamp()) THEN blocked:='UNSAFE_LISTING_VALIDITY'; END IF;
  IF jsonb_array_length(obs->'donations')=0 OR EXISTS(SELECT 1 FROM jsonb_array_elements(obs->'donations') z WHERE z->>'donation_status'<>CASE WHEN x.initial_class='DISPATCHED' THEN 'PICKUP_IN_PROGRESS' ELSE 'CLAIMED' END) THEN RAISE EXCEPTION 'SOURCE_CUSTODY_STATE_MISMATCH'; END IF;
 END LOOP;
 IF blocked IS NOT NULL THEN
  UPDATE resolution_private.cases SET status='MANUAL_REVIEW',version=version+1 WHERE case_id=p_case RETURNING * INTO c;
  PERFORM resolution_private.audit(c.route_id,p_case,'ROUTE_RESOLUTION_REVIEW_REQUIRED',p_request,jsonb_build_object('reason',blocked));
  RETURN resolution_private.save_receipt(actor,p_request,'FINALIZE',payload,jsonb_build_object('case_id',p_case,'status','MANUAL_REVIEW','reason',blocked,'version',c.version));
 END IF;
 FOR x IN SELECT ri.*,t.task_status,t.listing_id,l.source_type,it.collected_at FROM resolution_private.items ri JOIN public.pickup_tasks t USING(task_id) JOIN public.listings l USING(listing_id) JOIN routing_private.items it ON it.task_id=t.task_id AND it.route_id=c.route_id WHERE ri.case_id=p_case ORDER BY it.ordinal LOOP
  INSERT INTO resolution_private.releases SELECT p_case,x.task_id,to_jsonb(a),CASE WHEN x.task_status='COLLECTED' THEN 'RETAINED_COLLECTED' ELSE 'NO_HANDOVER_RELEASED' END,clock_timestamp() FROM public.active_task_route_assignments a WHERE a.task_id=x.task_id AND a.route_id=c.route_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_ASSIGNMENT_MISSING'; END IF;
  IF x.task_status<>'COLLECTED' THEN
   INSERT INTO resolution_private.permits VALUES(x.task_id,p_case,pg_current_xact_id()) ON CONFLICT(task_id) DO UPDATE SET case_id=excluded.case_id,transaction_id=excluded.transaction_id;
   PERFORM public.geolock_transition_listing_donations(x.listing_id,CASE WHEN x.initial_class='DISPATCHED' THEN 'PICKUP_IN_PROGRESS' ELSE 'CLAIMED' END,CASE WHEN x.source_type='DIRECT_DONATION' THEN 'AVAILABLE' ELSE 'BATCHED' END,x.claim_id,p_request,'ROUTE_RESOLUTION_NO_HANDOVER');
   UPDATE public.pickup_tasks SET task_status='STALE' WHERE task_id=x.task_id;
   UPDATE public.donation_claims SET claim_status='RELEASED',closed_at=clock_timestamp(),close_reason='ROUTE_INTERRUPTED_NO_HANDOVER' WHERE claim_id=x.claim_id;
   UPDATE public.claim_leases SET lease_status='RELEASED',closed_at=clock_timestamp(),release_reason='ROUTE_INTERRUPTED_NO_HANDOVER' WHERE claim_id=x.claim_id;
   UPDATE public.listings SET listing_status='AVAILABLE',listing_version=listing_version+1 WHERE listing_id=x.listing_id;
   UPDATE public.claim_reconciliation_cases SET case_status='RESOLVED_RELEASED',resolved_at=clock_timestamp(),resolution_reason='ROUTE_INTERRUPTED_NO_HANDOVER' WHERE claim_id=x.claim_id AND case_status IN('OPEN','MANUAL_REVIEW');
   PERFORM resolution_private.audit(c.route_id,p_case,'CLAIM_RESOLVED_NO_HANDOVER',p_request,jsonb_build_object('claim_id',x.claim_id,'task_id',x.task_id));
  END IF;
 END LOOP;
 DELETE FROM public.active_task_route_assignments WHERE route_id=c.route_id;
 UPDATE routing_private.items SET released_at=clock_timestamp(),release_xid=pg_current_xact_id() WHERE route_id=c.route_id;
 UPDATE routing_private.bindings SET closed_at=clock_timestamp() WHERE route_id=c.route_id;
 INSERT INTO resolution_private.finalizations VALUES(c.route_id,p_case,pg_current_xact_id());
 UPDATE resolution_private.cases SET status='RESOLVED',resolved_at=clock_timestamp(),version=version+1 WHERE case_id=p_case RETURNING * INTO c;
 UPDATE public.pickup_routes SET route_status='ABANDONED' WHERE route_id=c.route_id;
 PERFORM resolution_private.audit(c.route_id,p_case,'ROUTE_ASSIGNMENTS_RELEASED',p_request,jsonb_build_object('route_manifest_digest',c.manifest_digest));
 PERFORM resolution_private.audit(c.route_id,p_case,'ROUTE_ABANDONED_RECONCILED',p_request,jsonb_build_object('version',c.version));
 result:=jsonb_build_object('contract','geolock.route-resolution.v1','case_id',p_case,'route_id',c.route_id,'status','RESOLVED','route_status','ABANDONED','version',c.version);
 RETURN resolution_private.save_receipt(actor,p_request,'FINALIZE',payload,result);
END $$;

CREATE FUNCTION resolution_private.test_metadata(p_route uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT jsonb_build_object('simulation',true,'test_run_id',tr.run_id,'test_manifest_digest',tr.manifest_digest) FROM resolution_private.test_runs tr JOIN routing_private.bindings b ON b.ngo_id=tr.ngo_id AND b.vehicle_id=tr.vehicle_id
 WHERE b.route_id=p_route AND NOT EXISTS(SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) WHERE i.route_id=p_route AND NOT(t.claim_id=ANY(tr.fixture_claim_ids))) LIMIT 1
$$;
CREATE FUNCTION public.get_my_route_resolution(p_route uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE c resolution_private.cases%rowtype;is_owner boolean;BEGIN
 PERFORM resolution_private.actor_key();
 SELECT * INTO c FROM resolution_private.cases WHERE route_id=p_route;
 IF NOT FOUND THEN
  IF NOT EXISTS(SELECT 1 FROM routing_private.bindings WHERE route_id=p_route AND ngo_id=auth.uid()) THEN RAISE EXCEPTION 'NOT_ROUTE_OWNER'; END IF;
  RETURN jsonb_build_object('contract','geolock.route-resolution.v1','route_id',p_route,'status','NOT_REPORTED','enabled',(SELECT enabled FROM resolution_private.config WHERE singleton))||coalesce(resolution_private.test_metadata(p_route),'{}');
 END IF;
 IF NOT resolution_private.allowed(c.case_id,auth.uid()) THEN RAISE EXCEPTION 'RESOLUTION_PARTICIPANT_ONLY'; END IF;
 is_owner:=auth.uid()=c.ngo_id;
 RETURN jsonb_build_object('contract','geolock.route-resolution.v1','route_id',p_route,'case_id',c.case_id,'version',c.version,'status',c.status,'enabled',(SELECT enabled FROM resolution_private.config WHERE singleton),
 'is_owner',is_owner,'vehicle_confirmed',CASE WHEN is_owner THEN resolution_private.latest(c.case_id,NULL,c.ngo_id)='VEHICLE_RETURNED_TO_NGO_CONTROL' END,
 'items',(SELECT coalesce(jsonb_agg(jsonb_build_object('task_id',i.task_id,'claim_id',i.claim_id,'initial_class',i.initial_class,'my_assertion',resolution_private.latest(c.case_id,i.task_id,auth.uid()),'ngo_assertion',resolution_private.latest(c.case_id,i.task_id,c.ngo_id),'source_assertion',resolution_private.latest(c.case_id,i.task_id,i.source_actor)) ORDER BY i.task_id),'[]') FROM resolution_private.items i WHERE i.case_id=c.case_id AND (is_owner OR i.source_actor=auth.uid())))||coalesce(resolution_private.test_metadata(p_route),'{}');
END $$;
CREATE FUNCTION public.list_my_route_resolution_cases() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ BEGIN
 PERFORM resolution_private.actor_key();
 RETURN jsonb_build_object('contract','geolock.route-resolution.v1','cases',(SELECT coalesce(jsonb_agg(jsonb_build_object('case_id',c.case_id,'route_id',c.route_id,'status',c.status,'version',c.version) ORDER BY c.created_at DESC),'[]') FROM resolution_private.cases c WHERE resolution_private.allowed(c.case_id,auth.uid())));
END $$;
CREATE FUNCTION public.get_my_route_resolution_receipt(p_request uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE actor text;r jsonb;BEGIN
 IF pg_has_role(session_user,'geolock_route_resolver','MEMBER') THEN actor:=resolution_private.operator_key(); ELSE actor:=resolution_private.actor_key(); END IF;
 IF p_request IS NULL THEN RAISE EXCEPTION 'REQUEST_REQUIRED'; END IF;
 SELECT result INTO r FROM resolution_private.requests WHERE actor_key=actor AND request_id=p_request;
 IF actor LIKE 'user:%' AND r->>'case_id' IS NOT NULL AND NOT resolution_private.allowed((r->>'case_id')::uuid,auth.uid()) THEN RAISE EXCEPTION 'RESOLUTION_PARTICIPANT_ONLY'; END IF;
 RETURN jsonb_build_object('outcome',CASE WHEN r IS NULL THEN 'NOT_FOUND' ELSE 'FOUND' END,'request_id',p_request,'result',r);
END $$;

CREATE FUNCTION resolution_private.assert_test_scope(p_route uuid) RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE ids uuid[];b routing_private.bindings%rowtype;BEGIN
 SELECT * INTO b FROM routing_private.bindings WHERE route_id=p_route;
 SELECT array_agg(t.claim_id ORDER BY t.claim_id) INTO ids FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) WHERE i.route_id=p_route;
 IF EXISTS(SELECT 1 FROM resolution_private.test_runs WHERE fixture_claim_ids && ids) AND NOT EXISTS(SELECT 1 FROM resolution_private.test_runs WHERE ngo_id=b.ngo_id AND vehicle_id=b.vehicle_id AND ids <@ fixture_claim_ids) THEN RAISE EXCEPTION 'MIXED_SYNTHETIC_ROUTE_FORBIDDEN'; END IF;
END $$;
CREATE FUNCTION resolution_private.test_scope_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE rid uuid;BEGIN
 IF NEW.task_status IS DISTINCT FROM OLD.task_status THEN
  SELECT route_id INTO rid FROM routing_private.items WHERE task_id=OLD.task_id AND released_at IS NULL;
  IF rid IS NOT NULL THEN PERFORM resolution_private.assert_test_scope(rid); END IF;
 END IF;RETURN NEW;
END $$;
CREATE TRIGGER resolution_test_scope BEFORE UPDATE OF task_status ON public.pickup_tasks FOR EACH ROW EXECUTE FUNCTION resolution_private.test_scope_guard();

CREATE OR REPLACE FUNCTION public.enforce_donation_transition()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public','pg_temp'
AS $function$
begin
  if new.donation_status is distinct from old.donation_status and not (
    (old.donation_status='SUBMITTED' and new.donation_status='AVAILABLE'
      and new.collection_path='DIRECT_PICKUP' and new.total_weight_kg>=10)
    or (old.donation_status='SUBMITTED' and new.donation_status='HUB_ASSIGNED'
      and new.collection_path='HUB_COLLECTION' and new.total_weight_kg>0 and new.total_weight_kg<10)
    or (old.donation_status in ('SUBMITTED','AVAILABLE','HUB_ASSIGNED') and new.donation_status='CANCELLED')
    or (old.donation_status='AVAILABLE' and new.donation_status='CLAIMED' and new.collection_path='DIRECT_PICKUP')
    or (old.donation_status='HUB_ASSIGNED' and new.donation_status='AT_HUB')
    or (old.donation_status='AT_HUB' and new.donation_status='BATCHED')
    or (old.donation_status='BATCHED' and new.donation_status='CLAIMED' and new.collection_path='HUB_COLLECTION')
    or (old.donation_status='CLAIMED' and new.donation_status='PICKUP_IN_PROGRESS')
    or (old.donation_status='CLAIMED' and new.donation_status='AVAILABLE' and new.collection_path='DIRECT_PICKUP')
    or (old.donation_status='CLAIMED' and new.donation_status='BATCHED' and new.collection_path='HUB_COLLECTION')
    or (old.donation_status='PICKUP_IN_PROGRESS' and new.donation_status='COLLECTED')
    or (old.donation_status='PICKUP_IN_PROGRESS'
      and ((new.donation_status='AVAILABLE' and new.collection_path='DIRECT_PICKUP')
        or (new.donation_status='BATCHED' and new.collection_path='HUB_COLLECTION'))
      and resolution_private.release_allowed(old.donation_id,new.donation_status))
  ) then
    raise exception 'INVALID_DONATION_TRANSITION: % -> %',old.donation_status,new.donation_status;
  end if;
  new.updated_at=clock_timestamp();
  return new;
end;
$function$;
CREATE OR REPLACE FUNCTION fleet_private.route_vehicle_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $f$
DECLARE v public.vehicles%rowtype;
BEGIN
  IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'FLEET_REQUIRES_READ_COMMITTED'; END IF;
  IF TG_OP='DELETE' AND OLD.route_status='ABANDONED' THEN RAISE EXCEPTION 'TERMINAL_ROUTE_HISTORY_IMMUTABLE'; END IF;
  IF TG_OP='DELETE' THEN
    IF OLD.route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS')
      OR EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.route_id=OLD.route_id)
      OR EXISTS(SELECT 1 FROM public.pickup_route_stops s JOIN public.pickup_tasks t ON t.task_id=s.task_id
        WHERE s.route_id=OLD.route_id AND t.task_status IN ('PLANNED','DISPATCHED'))
    THEN RAISE EXCEPTION 'ACTIVE_ROUTE_DELETE_FORBIDDEN'; END IF;
    RETURN OLD;
  END IF;
  -- Lock vehicle even when leaving a protected state; fleet edits see committed release.
  IF TG_OP='UPDATE' AND ROW(NEW.vehicle_id,NEW.ngo_user_id) IS DISTINCT FROM ROW(OLD.vehicle_id,OLD.ngo_user_id)
  THEN RAISE EXCEPTION 'ROUTE_VEHICLE_BINDING_IMMUTABLE'; END IF;
  SELECT * INTO v FROM public.vehicles WHERE vehicle_id=NEW.vehicle_id FOR UPDATE;
  IF TG_OP='UPDATE' AND OLD.route_status IN ('COMPLETED','CANCELLED','STALE','ABANDONED')
    AND NEW.route_status IS DISTINCT FROM OLD.route_status
  THEN RAISE EXCEPTION 'ROUTE_TERMINAL_STATE_IMMUTABLE'; END IF;
  IF NEW.route_status IN ('COMPLETED','CANCELLED','STALE','ABANDONED') AND
    (TG_OP='INSERT' OR NEW.route_status IS DISTINCT FROM OLD.route_status) THEN
    IF EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.route_id=NEW.route_id)
      OR EXISTS(SELECT 1 FROM public.pickup_route_stops s JOIN public.pickup_tasks t ON t.task_id=s.task_id
        WHERE s.route_id=NEW.route_id AND (t.task_status IN ('PLANNED','DISPATCHED')
          OR (NEW.route_status='COMPLETED' AND t.task_status<>'COLLECTED')))
    THEN RAISE EXCEPTION 'ROUTE_HAS_UNRESOLVED_ACTIVITY'; END IF;
  END IF;
  IF NEW.route_status='ABANDONED' AND NOT EXISTS(SELECT 1 FROM resolution_private.finalizations f JOIN resolution_private.cases c USING(case_id) WHERE f.route_id=NEW.route_id AND f.transaction_id=pg_current_xact_id() AND c.status='RESOLVED') THEN RAISE EXCEPTION 'RESOLUTION_FINALIZER_REQUIRED'; END IF;
  IF NEW.route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS') THEN
    IF v.vehicle_id IS NULL OR v.ngo_user_id IS DISTINCT FROM NEW.ngo_user_id
      OR NOT v.active_flag OR NOT v.available_for_planning
    THEN RAISE EXCEPTION 'VEHICLE_NOT_AVAILABLE'; END IF;
    IF v.depot_road_node_id IS DISTINCT FROM fleet_private.require_depot(v.ngo_user_id)
    THEN RAISE EXCEPTION 'VEHICLE_DEPOT_STALE'; END IF;
  END IF;
  RETURN NEW;
END $f$;
ALTER TABLE public.pickup_routes DROP CONSTRAINT pickup_routes_route_status_check;
ALTER TABLE public.pickup_routes ADD CONSTRAINT pickup_routes_route_status_check CHECK(route_status IN('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS','COMPLETED','CANCELLED','STALE','ABANDONED'));
CREATE FUNCTION public.get_route_resolution_for_operator(p_case uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ BEGIN
 PERFORM resolution_private.operator_key();
 RETURN (SELECT jsonb_build_object('case',to_jsonb(c),'items',(SELECT coalesce(jsonb_agg(to_jsonb(i)),'[]') FROM resolution_private.items i WHERE i.case_id=p_case),'evidence',(SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.version),'[]') FROM resolution_private.evidence e WHERE e.case_id=p_case),'incidents',(SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.created_at),'[]') FROM resolution_private.incidents e WHERE e.case_id=p_case)) FROM resolution_private.cases c WHERE c.case_id=p_case);
END $$;
REVOKE ALL ON FUNCTION public.get_route_resolution_for_operator(uuid) FROM PUBLIC,anon,authenticated,service_role,geolock_graph_worker,geolock_planner,geolock_validator;
GRANT EXECUTE ON FUNCTION public.get_route_resolution_for_operator(uuid) TO geolock_route_resolver;
REVOKE ALL ON ALL TABLES IN SCHEMA resolution_private FROM PUBLIC,anon,authenticated,service_role,geolock_graph_worker,geolock_planner,geolock_validator,geolock_route_resolver;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA resolution_private FROM PUBLIC,anon,authenticated,service_role,geolock_graph_worker,geolock_planner,geolock_validator,geolock_route_resolver;
REVOKE ALL ON FUNCTION public.report_my_route_interruption(uuid,text,uuid),public.submit_route_resolution_evidence(uuid,uuid,text,bigint,uuid),public.report_route_resolution_incident(uuid,uuid,text,uuid),public.list_my_route_resolution_cases(),public.get_my_route_resolution(uuid),public.get_my_route_resolution_receipt(uuid),public.finalize_route_resolution(uuid,bigint,uuid),public.register_route_test_provenance(uuid,text,uuid,uuid,uuid[],uuid) FROM PUBLIC,anon,authenticated,service_role,geolock_graph_worker,geolock_planner,geolock_validator,geolock_route_resolver;
GRANT EXECUTE ON FUNCTION public.report_my_route_interruption(uuid,text,uuid),public.submit_route_resolution_evidence(uuid,uuid,text,bigint,uuid),public.report_route_resolution_incident(uuid,uuid,text,uuid),public.list_my_route_resolution_cases(),public.get_my_route_resolution(uuid),public.get_my_route_resolution_receipt(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_route_resolution(uuid,bigint,uuid),public.register_route_test_provenance(uuid,text,uuid,uuid,uuid[],uuid),public.get_my_route_resolution_receipt(uuid) TO geolock_route_resolver;
GRANT USAGE ON SCHEMA public TO geolock_route_resolver;
COMMIT;
