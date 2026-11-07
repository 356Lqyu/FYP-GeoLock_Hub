-- PREPARATION ONLY. Separate approval and nominated existing account UUIDs required.
-- No auth impersonation, eligibility refresh, discovery RPC, fixture or business write.
-- Owner-export observations do not prove authenticated RLS/HTTP behavior.
\set ON_ERROR_STOP on
\if :{?ngo_id}
\else
\echo Missing nominated ngo_id UUID. STOP.
\quit 3
\endif
\if :{?donor_id}
\else
\echo Missing nominated donor_id UUID. STOP.
\quit 3
\endif
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='2s';
SET LOCAL search_path=pg_catalog,public,pg_temp;
SELECT jsonb_build_object('section','identity','observed_at',statement_timestamp(),
 'database',current_database(),'session_user',session_user,'current_user',current_user,
 'read_only',current_setting('transaction_read_only'),
 'ssl',(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()));
SELECT 1/CASE WHEN current_database()='postgres' AND session_user='postgres' AND current_user='postgres'
 AND current_setting('transaction_read_only')='on'
 AND coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),false)
 THEN 1 ELSE 0 END AS identity_guard;
SELECT 1/CASE WHEN :'ngo_id'::uuid<>:'donor_id'::uuid
 AND :'ngo_id'::uuid<>'8e50bc66-7a8d-4791-bc6b-640682daa496'::uuid
 AND NOT EXISTS(SELECT 1 FROM public.pickup_routes r
  WHERE r.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9' AND r.ngo_user_id=:'ngo_id'::uuid)
 THEN 1 ELSE 0 END AS independent_identity_guard;
SELECT jsonb_build_object('section','nominated_accounts',
 'donor_role',(SELECT role FROM public.user_profiles WHERE user_id=:'donor_id'::uuid),
 'donor_profile_exists',EXISTS(SELECT 1 FROM public.donor_profiles WHERE user_id=:'donor_id'::uuid),
 'ngo_role',(SELECT role FROM public.user_profiles WHERE user_id=:'ngo_id'::uuid),
 'ngo',(SELECT jsonb_build_object('user_id',user_id,'active',active_flag,
  'location_verified_at',location_verified_at,'road_node_id',road_node_id)
  FROM public.ngo_profiles WHERE user_id=:'ngo_id'::uuid),
 'existing_active_claims',(SELECT count(*) FROM public.donation_claims WHERE ngo_user_id=:'ngo_id'::uuid AND claim_status='ACTIVE'),
 'open_vehicle_bindings',(SELECT count(*) FROM routing_private.bindings WHERE ngo_id=:'ngo_id'::uuid AND closed_at IS NULL),
 'open_reconciliation_cases',(SELECT count(*) FROM public.claim_reconciliation_cases rc
  JOIN public.donation_claims c ON c.claim_id=rc.claim_id
  WHERE c.ngo_user_id=:'ngo_id'::uuid AND rc.case_status IN('OPEN','MANUAL_REVIEW')));
SELECT jsonb_build_object('section','owned_vehicle_options','vehicles',(
 SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) FROM (
  SELECT v.vehicle_id,v.vehicle_label,v.payload_capacity_kg,v.max_route_duration_min,
   v.active_flag,v.available_for_planning,v.depot_road_node_id,v.vehicle_version,
   EXISTS(SELECT 1 FROM routing_private.bindings b WHERE b.vehicle_id=v.vehicle_id AND b.closed_at IS NULL) AS open_binding
  FROM public.vehicles v WHERE v.ngo_user_id=:'ngo_id'::uuid
  ORDER BY v.vehicle_label,v.vehicle_id LIMIT 10) x));
SELECT jsonb_build_object('section','current_config','direct_min_kg',donation_direct_min_kg,
 'claim_lease_minutes',claim_lease_minutes,'geofence_radius_m',geofence_radius_m)
FROM public.coordination_config WHERE singleton;
SELECT jsonb_build_object('section','approved_graph','graph_id',graph_id,'snapshot',coverage_snapshot,
 'digest',content_digest,'node_count',node_count,'edge_count',edge_count)
FROM routing_private.graphs WHERE graph_id='eab1f7ee-a8e0-4bed-a0e1-2c4bff024936';
SELECT jsonb_build_object('section','pilot_nodes','nodes',(
 SELECT coalesce(jsonb_agg(jsonb_build_object('node',osm_node_id,'active',active_flag,
 'snapshot',network_snapshot_id)),'[]'::jsonb) FROM public.road_network_nodes
 WHERE osm_node_id IN(1755847853,1755847924)));
SELECT jsonb_build_object('section','policy','policy_id',policy_id,'digest',digest,
 'horizon',body->>'horizon_minutes','margin',body->>'dispatch_margin_minutes')
FROM routing_private.policies WHERE policy_id='80db858b-93e8-4a0a-94e2-dbe14940f0a1';
-- Catalog inspection only: never invoke these protected functions as postgres.
SELECT jsonb_build_object('section','discovery_contract','signature',p.oid::regprocedure::text,
 'body_md5',md5(replace(p.prosrc,E'\r\n',E'\n')),'definition',pg_get_functiondef(p.oid))
FROM pg_proc p WHERE p.oid IN(
 to_regprocedure('public.discover_eligible_listing_cards()'),
 to_regprocedure('public.geolock_road_eligible_km(uuid,uuid)'),
 to_regprocedure('public.claim_listing(uuid,uuid)'));
SELECT jsonb_build_object('section','visibility_qualification',
 'other_active_verified_ngos',(SELECT count(*) FROM public.ngo_profiles
  WHERE user_id<>:'ngo_id'::uuid AND active_flag AND location_verified_at IS NOT NULL),
 'actual_fixture_visibility','NOT VERIFIED: fixture/listing does not exist yet',
 'required_followup','Review deployed discovery scope now; after separately approved creation, compare protected participant discovery and current eligibility rows before any claim. No label-based access-control assumption.');
ROLLBACK;
