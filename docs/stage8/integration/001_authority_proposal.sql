-- REVIEW PROPOSAL ONLY. DEV rcgyuwiidqvrgbxswhqj. Never auto-apply.
-- No policy/graph is seeded; no source rows, claims or vehicles are created.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';
DO $pin$ BEGIN
 IF to_regnamespace('routing_private') IS NOT NULL THEN RAISE EXCEPTION 'ROUTING_INSTALL_EXISTS_REVIEW_VERSION_INSTEAD_OF_REPLAY'; END IF;
 IF encode(sha256(convert_to(pg_get_functiondef('public.start_pickup(uuid)'::regprocedure),'UTF8')),'hex') IS DISTINCT FROM 'a87e59bd4c790bc593f76da42bff47e8864c2f27affffc623d6f7161a63a84a7'
 OR encode(sha256(convert_to(pg_get_functiondef('public.complete_pickup(uuid,boolean)'::regprocedure),'UTF8')),'hex') IS DISTINCT FROM 'de1f32f68ced1b9ffae70983cd7988c8e140509ef7aa9bf8c69a23dca512f4a0'
 OR encode(sha256(convert_to(pg_get_functiondef('public.assign_task_to_route(uuid,uuid,integer)'::regprocedure),'UTF8')),'hex') IS DISTINCT FROM '0341fd334439b319b0bc78b8910ce2de5e2f51b5803ab4a53d0e0e89b50e11cf'
 THEN RAISE EXCEPTION 'CAPTURED_LIFECYCLE_SOURCE_DRIFT'; END IF;
END $pin$;
DO $b$ BEGIN
 IF current_user<>'postgres' THEN RAISE EXCEPTION 'REVIEWED_POSTGRES_INSTALLER_REQUIRED'; END IF;
 IF to_regnamespace('fleet_private') IS NULL THEN RAISE EXCEPTION 'C1_REQUIRED'; END IF;
 IF obj_description('fleet_private'::regnamespace,'pg_namespace') IS DISTINCT FROM
    'geolock-stage8-c1-v2:'||fleet_private.installation_fingerprint()
 THEN RAISE EXCEPTION 'C1_DRIFT'; END IF;
 IF to_regnamespace('routing_private') IS NOT NULL THEN
   RAISE EXCEPTION 'ROUTING_INSTALL_EXISTS_REVIEW_VERSION_INSTEAD_OF_REPLAY';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname IN ('geolock_graph_worker','geolock_planner','geolock_validator')) THEN RAISE EXCEPTION 'ROUTING_ROLE_COLLISION'; END IF;
 CREATE ROLE geolock_graph_worker NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
 CREATE ROLE geolock_planner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
 CREATE ROLE geolock_validator NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
END $b$;
CREATE SCHEMA routing_private AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA routing_private FROM PUBLIC,anon,authenticated,service_role;
GRANT USAGE ON SCHEMA public TO geolock_graph_worker,geolock_planner,geolock_validator;
CREATE FUNCTION routing_private.hash(p jsonb) RETURNS text LANGUAGE sql IMMUTABLE
 SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ SELECT encode(sha256(convert_to(p::text,'UTF8')),'hex') $$;
CREATE FUNCTION routing_private.worker(p_role text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ BEGIN
 IF NOT (pg_has_role(session_user,p_role,'MEMBER') AND current_setting('role') IN (p_role,'none'))
 THEN RAISE EXCEPTION 'ROUTING_WORKER_ONLY'; END IF;
END $$;
CREATE TABLE routing_private.policies(
 policy_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), request_id uuid UNIQUE NOT NULL,
 body jsonb NOT NULL, digest text NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE TABLE routing_private.graphs(
 graph_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), request_id uuid UNIQUE NOT NULL,
 coverage_snapshot text NOT NULL, content_digest text NOT NULL, speed_profile text NOT NULL,
 node_count bigint NOT NULL, edge_count bigint NOT NULL,
 precision_policy text NOT NULL,
 float_output_profile text NOT NULL DEFAULT 'PG_REAL_OUTPUT_0' CHECK(float_output_profile='PG_REAL_OUTPUT_0'),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE TABLE routing_private.matrices(
 matrix_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), request_id uuid UNIQUE NOT NULL,
 graph_id uuid NOT NULL REFERENCES routing_private.graphs, body jsonb NOT NULL,
 digest text NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE TABLE routing_private.snapshots(
 snapshot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), ngo_id uuid NOT NULL REFERENCES public.ngo_profiles(user_id),
 request_id uuid NOT NULL, policy_id uuid NOT NULL REFERENCES routing_private.policies,
 cutoff timestamptz NOT NULL, body jsonb NOT NULL, digest text NOT NULL,
 matrix_id uuid REFERENCES routing_private.matrices, sealed_at timestamptz,
 UNIQUE(ngo_id,request_id), CHECK ((matrix_id IS NULL)=(sealed_at IS NULL)));
CREATE TABLE routing_private.candidates(
 candidate_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), request_id uuid UNIQUE NOT NULL,
 snapshot_id uuid NOT NULL REFERENCES routing_private.snapshots, body jsonb NOT NULL,
 digest text NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE TABLE routing_private.validations(
 candidate_id uuid PRIMARY KEY REFERENCES routing_private.candidates, candidate_digest text NOT NULL,
 report jsonb NOT NULL, validator_role text NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE TABLE routing_private.requests(
 ngo_id uuid NOT NULL, request_id uuid NOT NULL, operation text NOT NULL,
 payload_digest text NOT NULL, result jsonb NOT NULL, PRIMARY KEY(ngo_id,request_id));
CREATE TABLE routing_private.bindings(
 route_id uuid PRIMARY KEY REFERENCES public.pickup_routes, candidate_id uuid NOT NULL REFERENCES routing_private.candidates,
 ngo_id uuid NOT NULL REFERENCES public.ngo_profiles(user_id), vehicle_id uuid NOT NULL REFERENCES public.vehicles,
 vehicle_version bigint NOT NULL, plan jsonb NOT NULL, departure_at timestamptz NOT NULL,
 started_at timestamptz, closed_at timestamptz, created_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE UNIQUE INDEX routing_one_vehicle_booking ON routing_private.bindings(vehicle_id) WHERE closed_at IS NULL;
-- C1 already excludes held vehicles. One outstanding route per vehicle is the
-- conservative minimum, not a scheduling model allowing overlapping bookings.
CREATE TABLE routing_private.items(
 route_id uuid NOT NULL REFERENCES routing_private.bindings, task_id uuid NOT NULL REFERENCES public.pickup_tasks,
 ordinal integer NOT NULL CHECK(ordinal>0), observation_digest text NOT NULL,
 planned_xid xid8 NOT NULL, dispatch_xid xid8, complete_xid xid8, release_xid xid8,
 consumed_at timestamptz, collected_at timestamptz, released_at timestamptz,
 PRIMARY KEY(route_id,task_id), UNIQUE(route_id,ordinal));
CREATE UNIQUE INDEX routing_one_task_booking ON routing_private.items(task_id) WHERE released_at IS NULL;
CREATE TABLE routing_private.cancelled_stop_history(
 route_id uuid NOT NULL REFERENCES public.pickup_routes, task_id uuid NOT NULL REFERENCES public.pickup_tasks,
 ngo_id uuid NOT NULL, stop_order integer NOT NULL, original_stop jsonb NOT NULL,
 archived_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY(route_id,task_id));
CREATE TABLE routing_private.legacy_inflight(task_id uuid PRIMARY KEY REFERENCES public.pickup_tasks, complete_xid xid8);
CREATE INDEX routing_candidate_snapshot ON routing_private.candidates(snapshot_id);
CREATE INDEX routing_binding_candidate ON routing_private.bindings(candidate_id);
CREATE FUNCTION routing_private.append_only() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ BEGIN RAISE EXCEPTION 'ROUTING_ARTIFACT_IMMUTABLE'; END $$;
DO $b$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['policies','graphs','matrices','candidates','validations','cancelled_stop_history'] LOOP
 EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE OR TRUNCATE ON routing_private.%I FOR EACH STATEMENT EXECUTE FUNCTION routing_private.append_only()',t);
 END LOOP;
 FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='routing_private' LOOP
 EXECUTE format('ALTER TABLE routing_private.%I ENABLE ROW LEVEL SECURITY',t);
 EXECUTE format('REVOKE ALL ON routing_private.%I FROM PUBLIC,anon,authenticated,service_role,geolock_graph_worker,geolock_planner,geolock_validator',t);
 END LOOP;
END $b$;
CREATE FUNCTION routing_private.snapshot_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ BEGIN
 IF TG_OP<>'UPDATE' THEN RAISE EXCEPTION 'SNAPSHOT_IMMUTABLE'; END IF;
 IF OLD.sealed_at IS NOT NULL OR NEW.matrix_id IS NULL OR NEW.sealed_at IS NULL
 OR (to_jsonb(NEW)-'matrix_id'-'sealed_at') IS DISTINCT FROM (to_jsonb(OLD)-'matrix_id'-'sealed_at')
 THEN RAISE EXCEPTION 'SNAPSHOT_IMMUTABLE'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER snapshot_seal_guard BEFORE UPDATE OR DELETE ON routing_private.snapshots
 FOR EACH ROW EXECUTE FUNCTION routing_private.snapshot_guard();
CREATE TRIGGER snapshot_no_truncate BEFORE TRUNCATE ON routing_private.snapshots
 FOR EACH STATEMENT EXECUTE FUNCTION routing_private.append_only();
CREATE FUNCTION routing_private.freeze_network() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ BEGIN
 IF EXISTS(SELECT 1 FROM routing_private.graphs) THEN RAISE EXCEPTION 'GRAPH_REVISION_FROZEN'; END IF;
 IF TG_LEVEL='STATEMENT' THEN RETURN NULL; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $$;
DO $b$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['road_network_nodes','road_network_edges','road_network_coverage'] LOOP
 EXECUTE format('CREATE TRIGGER routing_graph_freeze BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION routing_private.freeze_network()',t);
 EXECUTE format('CREATE TRIGGER routing_graph_truncate BEFORE TRUNCATE ON public.%I FOR EACH STATEMENT EXECUTE FUNCTION routing_private.freeze_network()',t);
 END LOOP;
END $b$;
CREATE FUNCTION public.install_routing_policy(p_request uuid,p_body jsonb) RETURNS uuid
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE id uuid; old jsonb; BEGIN
 PERFORM routing_private.worker('geolock_graph_worker');
 PERFORM pg_advisory_xact_lock(hashtextextended('routing-policy:'||p_request::text,0));
 SELECT policy_id,body INTO id,old FROM routing_private.policies WHERE request_id=p_request;
 IF FOUND THEN IF old IS DISTINCT FROM p_body THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF; RETURN id; END IF;
 IF p_request IS NULL OR p_body IS NULL OR jsonb_typeof(p_body->'mandatory') IS DISTINCT FROM 'boolean'
 OR NOT(p_body?'horizon_minutes' AND p_body?'dispatch_margin_minutes' AND p_body?'direct_service_minutes' AND p_body?'hub_service_minutes')
 OR NOT coalesce(((p_body->>'horizon_minutes')::numeric>0 AND (p_body->>'horizon_minutes')::numeric<=1440
 AND (p_body->>'dispatch_margin_minutes')::numeric>=0 AND (p_body->>'direct_service_minutes')::numeric>=0
 AND (p_body->>'hub_service_minutes')::numeric>=0 AND (p_body->>'horizon_minutes')::numeric<'Infinity'::numeric
 AND (p_body->>'dispatch_margin_minutes')::numeric<'Infinity'::numeric AND (p_body->>'direct_service_minutes')::numeric<'Infinity'::numeric
 AND (p_body->>'hub_service_minutes')::numeric<'Infinity'::numeric),false)
 OR jsonb_typeof(p_body->'solver') IS DISTINCT FROM 'object'
 OR jsonb_typeof(p_body->'execution') IS DISTINCT FROM 'object'
 THEN RAISE EXCEPTION 'EXPLICIT_ROUTING_POLICY_REQUIRED'; END IF;
 INSERT INTO routing_private.policies(request_id,body,digest) VALUES(p_request,p_body,routing_private.hash(p_body)) RETURNING policy_id INTO id;
 RETURN id;
END $$;
-- Bounded keyset hash chain: never aggregate millions of edge JSON objects.
CREATE FUNCTION routing_private.network_digest(p_table text,p_key text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE after_key bigint; last_key bigint; page_hash text; n bigint; total bigint:=0; chain text:=routing_private.hash('[]'::jsonb); BEGIN
 IF (p_table,p_key) NOT IN (('road_network_nodes','osm_node_id'),('road_network_edges','edge_id')) THEN RAISE EXCEPTION 'INVALID_GRAPH_RELATION'; END IF;
 LOOP
  EXECUTE format('SELECT routing_private.hash(coalesce(jsonb_agg(to_jsonb(t) ORDER BY %I),''[]'')),max(%I),count(*) FROM
   (SELECT * FROM public.%I WHERE $1 IS NULL OR %I>$1 ORDER BY %I LIMIT 10000) t',p_key,p_key,p_table,p_key,p_key)
   INTO page_hash,last_key,n USING after_key;
  EXIT WHEN n=0;
  chain:=routing_private.hash(jsonb_build_array(chain,page_hash,last_key,n)); total:=total+n; after_key:=last_key;
 END LOOP;
 RETURN jsonb_build_object('digest',chain,'count',total,'page_size',10000);
END $$;
CREATE FUNCTION public.freeze_routing_graph(p_request uuid,p_snapshot text,p_speed_profile text,p_precision_policy text) RETURNS uuid
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE id uuid; old routing_private.graphs%rowtype; nd jsonb; ed jsonb; BEGIN
 PERFORM routing_private.worker('geolock_graph_worker');
 LOCK TABLE public.road_network_nodes,public.road_network_edges,public.road_network_coverage IN SHARE MODE;
 SELECT * INTO old FROM routing_private.graphs WHERE request_id=p_request;
 IF FOUND THEN
  IF ROW(old.coverage_snapshot,old.speed_profile,old.precision_policy) IS DISTINCT FROM ROW(p_snapshot,p_speed_profile,p_precision_policy) THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
  RETURN old.graph_id;
 END IF;
 IF p_request IS NULL OR nullif(btrim(p_speed_profile),'') IS NULL OR p_precision_policy IS DISTINCT FROM 'EXACT_MAX_6_DECIMALS'
 OR NOT EXISTS(SELECT 1 FROM public.road_network_coverage WHERE network_snapshot_id=p_snapshot AND active_flag AND dataset_kind='OPERATIONAL' AND approved_at IS NOT NULL)
 THEN RAISE EXCEPTION 'APPROVED_GRAPH_REQUIRED'; END IF;
 nd:=routing_private.network_digest('road_network_nodes','osm_node_id');
 ed:=routing_private.network_digest('road_network_edges','edge_id');
 INSERT INTO routing_private.graphs(request_id,coverage_snapshot,content_digest,speed_profile,precision_policy,node_count,edge_count)
 VALUES(p_request,p_snapshot,routing_private.hash(jsonb_build_array(nd,ed)),p_speed_profile,p_precision_policy,(nd->>'count')::bigint,(ed->>'count')::bigint) RETURNING graph_id INTO id;
 RETURN id;
END $$;
CREATE FUNCTION public.store_routing_matrix(p_request uuid,p_graph uuid,p_body jsonb) RETURNS uuid
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE id uuid; old routing_private.matrices%rowtype; g routing_private.graphs%rowtype;
 n integer; i integer; j integer; node text; status text; d numeric; t numeric; BEGIN
 PERFORM routing_private.worker('geolock_graph_worker');
 PERFORM pg_advisory_xact_lock(hashtextextended('routing-matrix:'||p_request::text,0));
 SELECT * INTO old FROM routing_private.matrices WHERE request_id=p_request;
 IF FOUND THEN IF old.graph_id IS DISTINCT FROM p_graph OR old.body IS DISTINCT FROM p_body THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF; RETURN old.matrix_id; END IF;
 SELECT * INTO STRICT g FROM routing_private.graphs WHERE graph_id=p_graph;
 n:=jsonb_array_length(p_body->'node_order');
 IF p_request IS NULL OR n IS NULL OR n NOT BETWEEN 1 AND 100 OR p_body->>'network_snapshot_id' IS DISTINCT FROM g.coverage_snapshot
 OR p_body->>'source_kind' IS DISTINCT FROM 'OPERATIONAL_ROAD_NETWORK'
 OR p_body->>'path_policy' IS DISTINCT FROM 'DIRECTED_SHORTEST_DISTANCE_WITH_TIME_ON_SAME_PATH'
 OR p_body->>'edge_speed_profile' IS DISTINCT FROM g.speed_profile
 OR p_body->>'unavailable_policy' IS DISTINCT FROM 'FAIL_SCENARIO'
 OR (SELECT count(DISTINCT v) FROM jsonb_array_elements_text(p_body->'node_order') v)<>n
 THEN RAISE EXCEPTION 'INVALID_MATRIX_MANIFEST'; END IF;
 FOR node IN SELECT jsonb_array_elements_text(p_body->'node_order') LOOP
  IF NOT EXISTS(SELECT 1 FROM public.road_network_nodes WHERE osm_node_id=fleet_private.road_node_key(node) AND network_snapshot_id=g.coverage_snapshot AND active_flag) THEN RAISE EXCEPTION 'INVALID_MATRIX_NODE'; END IF;
 END LOOP;
 IF jsonb_array_length(p_body->'distance_km') IS DISTINCT FROM n OR jsonb_array_length(p_body->'travel_minutes') IS DISTINCT FROM n OR jsonb_array_length(p_body->'arc_status') IS DISTINCT FROM n THEN RAISE EXCEPTION 'INVALID_MATRIX_SHAPE'; END IF;
 FOR i IN 0..n-1 LOOP
 IF jsonb_array_length(p_body->'distance_km'->i) IS DISTINCT FROM n OR jsonb_array_length(p_body->'travel_minutes'->i) IS DISTINCT FROM n OR jsonb_array_length(p_body->'arc_status'->i) IS DISTINCT FROM n THEN RAISE EXCEPTION 'INVALID_MATRIX_SHAPE'; END IF;
 FOR j IN 0..n-1 LOOP
  status:=p_body->'arc_status'->i->>j;
  d:=(p_body->'distance_km'->i->>j)::numeric; t:=(p_body->'travel_minutes'->i->>j)::numeric;
  IF status IS DISTINCT FROM 'AVAILABLE' OR d IS NULL OR t IS NULL OR NOT(d>=0 AND d<'Infinity'::numeric AND t>=0 AND t<'Infinity'::numeric)
 OR d<>round(d,6) OR t<>round(t,6) OR (i=j AND (d<>0 OR t<>0)) OR (i<>j AND (d=0 OR t=0)) THEN RAISE EXCEPTION 'ROUTE_UNAVAILABLE_OR_INVALID_COST'; END IF;
 END LOOP; END LOOP;
 INSERT INTO routing_private.matrices(request_id,graph_id,body,digest) VALUES(p_request,p_graph,p_body,routing_private.hash(p_body)) RETURNING matrix_id INTO id;
 RETURN id;
END $$;
-- One SQL STABLE observation uses the invoking statement's MVCC snapshot.
CREATE FUNCTION routing_private.observe_task(p_task uuid) RETURNS jsonb LANGUAGE sql STABLE
 SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
 SELECT jsonb_build_object('task',to_jsonb(t),'claim',to_jsonb(c),'lease',to_jsonb(le),'listing',to_jsonb(l),
 'has_route_assignment',EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id),
 'donations',(SELECT coalesce(jsonb_agg(jsonb_build_object('donation_id',d.donation_id,'donation_status',d.donation_status,
 'collection_path',d.collection_path,
 'pickup_road_node_id',d.pickup_road_node_id,'total_weight_kg',d.total_weight_kg,'availability_start',d.availability_start,
 'availability_end',d.availability_end,'updated_at',d.updated_at,'latitude',d.latitude,'longitude',d.longitude) ORDER BY d.donation_id),'[]') FROM public.donations d
 WHERE d.donation_id=l.donation_id OR d.donation_id IN(SELECT donation_id FROM public.hub_batch_members WHERE batch_id=l.batch_id AND membership_status='ACTIVE')),
 'batch',(SELECT to_jsonb(b) FROM public.hub_batches b WHERE b.batch_id=l.batch_id),
 'hub',(SELECT jsonb_build_object('hub_id',h.hub_id,'road_node_id',h.road_node_id,'latitude',h.latitude,'longitude',h.longitude,'active_flag',h.active_flag)
 FROM public.community_hubs h JOIN public.hub_batches b ON b.hub_id=h.hub_id WHERE b.batch_id=l.batch_id),
 'inventory',(SELECT coalesce(jsonb_agg(to_jsonb(h) ORDER BY h.donation_id),'[]') FROM public.hub_inventory h WHERE h.donation_id IN
 (SELECT donation_id FROM public.hub_batch_members WHERE batch_id=l.batch_id AND membership_status='ACTIVE')))
 FROM public.pickup_tasks t JOIN public.donation_claims c ON c.claim_id=t.claim_id
 JOIN public.claim_leases le ON le.claim_id=c.claim_id JOIN public.listings l ON l.listing_id=t.listing_id
 WHERE t.task_id=p_task
$$;
CREATE FUNCTION routing_private.task_digest(p jsonb) RETURNS text LANGUAGE sql IMMUTABLE
 SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ SELECT routing_private.hash((p#-'{task,task_status}')-'has_route_assignment') $$;
CREATE FUNCTION routing_private.ngo_observation(p_ngo uuid) RETURNS jsonb LANGUAGE sql STABLE
 SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
 SELECT jsonb_build_object('user_id',user_id,'role',role,'active_flag',active_flag,'road_node_id',road_node_id,
 'location_verified_at',location_verified_at,'location_generation',location_generation,'latitude',latitude,'longitude',longitude)
 FROM public.ngo_profiles WHERE user_id=p_ngo $$;
CREATE FUNCTION public.begin_my_routing_snapshot(p_request uuid,p_policy uuid,p_vehicle_ids uuid[] DEFAULT NULL) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE ngo uuid:=fleet_private.require_ngo(); old routing_private.snapshots%rowtype; raw jsonb; pol jsonb; cut timestamptz:=statement_timestamp(); id uuid;
BEGIN
 PERFORM fleet_private.require_depot(ngo);
 IF p_vehicle_ids IS NOT NULL THEN
  IF cardinality(p_vehicle_ids)>20 OR cardinality(p_vehicle_ids)<>(SELECT count(DISTINCT x) FROM unnest(p_vehicle_ids) x)
  OR EXISTS(SELECT 1 FROM unnest(p_vehicle_ids) x WHERE x IS NULL OR NOT EXISTS(SELECT 1 FROM public.vehicles v WHERE v.vehicle_id=x AND v.ngo_user_id=ngo))
  THEN RAISE EXCEPTION 'INVALID_OWNED_VEHICLE_SELECTION'; END IF;
  SELECT array_agg(x ORDER BY x) INTO p_vehicle_ids FROM unnest(p_vehicle_ids) x;
  p_vehicle_ids:=coalesce(p_vehicle_ids,ARRAY[]::uuid[]);
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('routing-ngo:'||ngo::text,0));
 SELECT * INTO old FROM routing_private.snapshots WHERE ngo_id=ngo AND request_id=p_request;
 IF FOUND THEN IF old.policy_id IS DISTINCT FROM p_policy OR old.body->'selected_vehicle_ids' IS DISTINCT FROM coalesce(to_jsonb(p_vehicle_ids),'null'::jsonb) THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF; RETURN to_jsonb(old); END IF;
 SELECT body INTO STRICT pol FROM routing_private.policies WHERE policy_id=p_policy;
 IF p_request IS NULL THEN RAISE EXCEPTION 'REQUEST_REQUIRED'; END IF;
 SELECT jsonb_build_object('ngo',routing_private.ngo_observation(ngo),'policy',pol,'selected_vehicle_ids',p_vehicle_ids,
 'observations',coalesce((SELECT jsonb_agg(routing_private.observe_task(task_id) ORDER BY task_id) FROM public.pickup_tasks WHERE ngo_user_id=ngo AND task_status='CONFIRMED'),'[]'),
 'vehicles',coalesce((SELECT jsonb_agg(to_jsonb(v)-'registration_payload' ORDER BY vehicle_id) FROM public.vehicles v WHERE ngo_user_id=ngo AND (p_vehicle_ids IS NULL OR vehicle_id=ANY(p_vehicle_ids)) AND active_flag AND available_for_planning AND NOT fleet_private.vehicle_has_hold(vehicle_id)),'[]')) INTO raw;
 IF jsonb_array_length(raw->'observations')>100 THEN RAISE EXCEPTION 'PLANNING_SCOPE_TOO_LARGE'; END IF;
 INSERT INTO routing_private.snapshots(ngo_id,request_id,policy_id,cutoff,body,digest) VALUES(ngo,p_request,p_policy,cut,raw,routing_private.hash(raw)) RETURNING snapshot_id INTO id;
 RETURN (SELECT to_jsonb(s) FROM routing_private.snapshots s WHERE snapshot_id=id);
END $$;
CREATE FUNCTION public.seal_routing_snapshot(p_snapshot uuid,p_matrix uuid) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE s routing_private.snapshots%rowtype; m routing_private.matrices%rowtype; node text; BEGIN
 PERFORM routing_private.worker('geolock_planner');
 SELECT * INTO STRICT s FROM routing_private.snapshots WHERE snapshot_id=p_snapshot FOR UPDATE;
 IF s.sealed_at IS NOT NULL THEN IF s.matrix_id IS DISTINCT FROM p_matrix THEN RAISE EXCEPTION 'SNAPSHOT_IMMUTABLE'; END IF; RETURN to_jsonb(s); END IF;
 SELECT * INTO STRICT m FROM routing_private.matrices WHERE matrix_id=p_matrix;
 IF NOT (m.body->'node_order' ? (s.body->'ngo'->>'road_node_id')) THEN RAISE EXCEPTION 'MISSING_DEPOT_NODE'; END IF;
 -- Excluded tasks need not have matrix nodes. The independent adapter and the
 -- protected publication checker require every actually admitted/served node.
 UPDATE routing_private.snapshots SET matrix_id=p_matrix,sealed_at=clock_timestamp() WHERE snapshot_id=p_snapshot RETURNING * INTO s;
 RETURN to_jsonb(s);
END $$;
CREATE FUNCTION public.submit_routing_candidate(p_request uuid,p_snapshot uuid,p_body jsonb) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE c routing_private.candidates%rowtype; BEGIN
 PERFORM routing_private.worker('geolock_planner');
 PERFORM pg_advisory_xact_lock(hashtextextended('routing-candidate:'||p_request::text,0));
 SELECT * INTO c FROM routing_private.candidates WHERE request_id=p_request;
 IF FOUND THEN IF c.snapshot_id IS DISTINCT FROM p_snapshot OR c.body IS DISTINCT FROM p_body THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF; RETURN to_jsonb(c); END IF;
 IF p_request IS NULL OR NOT EXISTS(SELECT 1 FROM routing_private.snapshots WHERE snapshot_id=p_snapshot AND sealed_at IS NOT NULL) THEN RAISE EXCEPTION 'SEALED_SNAPSHOT_REQUIRED'; END IF;
 INSERT INTO routing_private.candidates(request_id,snapshot_id,body,digest) VALUES(p_request,p_snapshot,p_body,routing_private.hash(p_body)) RETURNING * INTO c;
 RETURN to_jsonb(c);
END $$;
CREATE FUNCTION public.read_routing_work_item(p_candidate uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ BEGIN
 PERFORM routing_private.worker('geolock_validator');
 RETURN (SELECT jsonb_build_object('candidate',to_jsonb(c),'snapshot',to_jsonb(s),'matrix',to_jsonb(m))
 FROM routing_private.candidates c JOIN routing_private.snapshots s USING(snapshot_id) JOIN routing_private.matrices m USING(matrix_id) WHERE c.candidate_id=p_candidate);
END $$;
CREATE FUNCTION public.attest_routing_candidate(p_candidate uuid,p_digest text,p_report jsonb) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE c routing_private.candidates%rowtype; old routing_private.validations%rowtype; s routing_private.snapshots%rowtype; m routing_private.matrices%rowtype; BEGIN
 PERFORM routing_private.worker('geolock_validator');
 SELECT * INTO STRICT c FROM routing_private.candidates WHERE candidate_id=p_candidate;
 SELECT * INTO STRICT s FROM routing_private.snapshots WHERE snapshot_id=c.snapshot_id;
 SELECT * INTO STRICT m FROM routing_private.matrices WHERE matrix_id=s.matrix_id;
 IF c.digest IS DISTINCT FROM p_digest OR p_report->>'candidate_digest' IS DISTINCT FROM c.digest
 OR p_report->>'snapshot_digest' IS DISTINCT FROM s.digest OR p_report->>'matrix_digest' IS DISTINCT FROM m.digest
 OR p_report->>'input_sha256' IS DISTINCT FROM c.body->'plan'->>'snapshot_sha256'
 OR p_report->>'matrix_sha256' IS DISTINCT FROM c.body->'plan'->>'matrix_sha256'
 OR p_report->>'valid' IS DISTINCT FROM 'true' OR p_report->>'feasible' IS DISTINCT FROM 'true'
 OR nullif(p_report->>'validator_build','') IS NULL THEN RAISE EXCEPTION 'TRUSTED_VALIDATION_REQUIRED'; END IF;
 SELECT * INTO old FROM routing_private.validations WHERE candidate_id=p_candidate;
 IF FOUND THEN IF old.report IS DISTINCT FROM p_report THEN RAISE EXCEPTION 'VALIDATION_CONFLICT'; END IF; RETURN; END IF;
 INSERT INTO routing_private.validations VALUES(p_candidate,p_digest,p_report,current_setting('role'),clock_timestamp());
END $$;
-- Keyset exports run against the frozen graph; no offset paging or mutable joins.
CREATE FUNCTION public.read_frozen_routing_graph(p_graph uuid,p_after_node bigint DEFAULT NULL,p_after_edge integer DEFAULT NULL) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$
DECLARE g routing_private.graphs%rowtype; BEGIN
 PERFORM routing_private.worker('geolock_graph_worker');
 SELECT * INTO STRICT g FROM routing_private.graphs WHERE graph_id=p_graph;
 RETURN jsonb_build_object('graph',to_jsonb(g),
 'nodes',(SELECT coalesce(jsonb_agg(to_jsonb(n) ORDER BY osm_node_id),'[]') FROM
 (SELECT osm_node_id,network_snapshot_id,active_flag FROM public.road_network_nodes WHERE p_after_node IS NULL OR osm_node_id>p_after_node ORDER BY osm_node_id LIMIT 10000) n),
 'edges',(SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY edge_id),'[]') FROM
 (SELECT edge_id,source_node,target_node,road_km,travel_minutes FROM public.road_network_edges WHERE p_after_edge IS NULL OR edge_id>p_after_edge ORDER BY edge_id LIMIT 10000) e));
END $$;
CREATE FUNCTION public.read_routing_snapshot_bundle(p_snapshot uuid) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ BEGIN
 PERFORM routing_private.worker('geolock_planner');
 RETURN (SELECT jsonb_build_object('snapshot',to_jsonb(s),'matrix',to_jsonb(m)) FROM routing_private.snapshots s
 JOIN routing_private.matrices m USING(matrix_id) WHERE snapshot_id=p_snapshot AND sealed_at IS NOT NULL);
END $$;
CREATE FUNCTION public.read_pending_routing_snapshot(p_snapshot uuid) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET timezone='UTC' SET extra_float_digits=0 AS $$ BEGIN
 PERFORM routing_private.worker('geolock_planner');
 RETURN (SELECT to_jsonb(s) FROM routing_private.snapshots s WHERE snapshot_id=p_snapshot);
END $$;
REVOKE ALL ON FUNCTION public.read_frozen_routing_graph(uuid,bigint,integer),public.read_routing_snapshot_bundle(uuid),public.read_pending_routing_snapshot(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.read_frozen_routing_graph(uuid,bigint,integer) TO geolock_graph_worker;
GRANT EXECUTE ON FUNCTION public.read_routing_snapshot_bundle(uuid) TO geolock_planner;
GRANT EXECUTE ON FUNCTION public.read_pending_routing_snapshot(uuid) TO geolock_planner;
-- No standard/client/service role receives direct private-schema access.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA routing_private FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.install_routing_policy(uuid,jsonb),public.freeze_routing_graph(uuid,text,text,text),public.store_routing_matrix(uuid,uuid,jsonb),
 public.begin_my_routing_snapshot(uuid,uuid,uuid[]),public.seal_routing_snapshot(uuid,uuid),public.submit_routing_candidate(uuid,uuid,jsonb),
 public.read_routing_work_item(uuid),public.attest_routing_candidate(uuid,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.install_routing_policy(uuid,jsonb),public.freeze_routing_graph(uuid,text,text,text),public.store_routing_matrix(uuid,uuid,jsonb) TO geolock_graph_worker;
GRANT EXECUTE ON FUNCTION public.begin_my_routing_snapshot(uuid,uuid,uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.seal_routing_snapshot(uuid,uuid),public.submit_routing_candidate(uuid,uuid,jsonb) TO geolock_planner;
GRANT EXECUTE ON FUNCTION public.read_routing_work_item(uuid),public.attest_routing_candidate(uuid,text,jsonb) TO geolock_validator;
COMMIT;
