-- LOCAL REVIEW ONLY. Additive donor reader; no activation or business changes.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '90s';
DO $$ BEGIN
 IF current_user <> 'postgres' OR session_user <> 'postgres' THEN
  RAISE EXCEPTION 'POSTGRES_INSTALLER_REQUIRED';
 END IF;
 IF to_regprocedure('public.get_my_donation_route_resolution(uuid)') IS NOT NULL THEN
  RAISE EXCEPTION 'DONOR_RESOLUTION_READER_ALREADY_INSTALLED';
 END IF;
 IF (SELECT md5(replace(prosrc,E'\r\n',E'\n')) FROM pg_proc
     WHERE oid=to_regprocedure('public.submit_route_resolution_evidence(uuid,uuid,text,bigint,uuid)'))
     IS DISTINCT FROM '7122f77ea8ed84d28bc08fbf77192d40' THEN
  RAISE EXCEPTION 'REVIEWED_RESOLUTION_WRITER_REQUIRED';
 END IF;
END $$;

CREATE FUNCTION public.get_my_donation_route_resolution(p_donation uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE actor uuid := auth.uid(); result jsonb;
BEGIN
 -- Identical denial for absent, foreign, null, non-donor and unauthenticated input.
 IF actor IS NULL OR NOT EXISTS (
  SELECT 1 FROM public.donations d
  JOIN public.donor_profiles dp ON dp.user_id=d.donor_user_id
  JOIN public.user_profiles u ON u.user_id=dp.user_id AND u.role='DONOR'
  WHERE d.donation_id=p_donation AND d.donor_user_id=actor
 ) THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='DONATION_NOT_FOUND_OR_FORBIDDEN';
 END IF;

 -- One stable MVCC snapshot. Never depend on removable active assignments.
 WITH history AS MATERIALIZED (
  SELECT c.claim_id,t.task_id,b.route_id,b.created_at,
   c.claim_status,le.lease_status,t.task_status,pr.route_status,
   rc.case_id,rc.version AS case_version,rc.status AS resolution_status,
   rc.resolved_at,ri.initial_class,cc.case_status AS claim_reconciliation_status,
   cc.resolved_at AS claim_resolved_at,rel.disposition,rel.released_at,
   (c.listing_id=t.listing_id AND c.ngo_user_id=b.ngo_id
    AND pr.ngo_user_id=b.ngo_id AND le.claim_id IS NOT NULL
    AND (cc.case_id IS NULL OR (cc.listing_id=l.listing_id
      AND cc.source_type='DIRECT_DONATION' AND cc.donation_id=p_donation)) AND
    (rc.case_id IS NULL OR (rc.ngo_id=b.ngo_id AND ri.claim_id=c.claim_id
      AND ri.source_actor=actor AND ri.source_role='DONOR'))) IS TRUE AS binding_valid,
   CASE WHEN rc.case_id IS NOT NULL THEN rc.status<>'RESOLVED'
    ELSE b.closed_at IS NULL AND it.released_at IS NULL
      AND t.task_status IN ('PLANNED','DISPATCHED') END AS unresolved,
   b.ngo_id
  FROM public.listings l
  JOIN public.donation_claims c ON c.listing_id=l.listing_id
  JOIN public.pickup_tasks t ON t.claim_id=c.claim_id
  LEFT JOIN public.claim_leases le ON le.claim_id=c.claim_id
  JOIN routing_private.items it ON it.task_id=t.task_id
  JOIN routing_private.bindings b ON b.route_id=it.route_id
  JOIN public.pickup_routes pr ON pr.route_id=b.route_id
  LEFT JOIN resolution_private.cases rc ON rc.route_id=b.route_id
  LEFT JOIN resolution_private.items ri ON ri.case_id=rc.case_id AND ri.task_id=t.task_id
  LEFT JOIN public.claim_reconciliation_cases cc ON cc.claim_id=c.claim_id
  LEFT JOIN resolution_private.releases rel ON rel.case_id=rc.case_id AND rel.task_id=t.task_id
  WHERE l.donation_id=p_donation AND l.source_type='DIRECT_DONATION'
 ), scope AS (
  SELECT count(*) AS total, count(*) FILTER (WHERE unresolved) AS unresolved_count,
   coalesce(bool_and(binding_valid),true) AS valid FROM history
 ), bounded AS (
  SELECT * FROM history ORDER BY created_at DESC,route_id,task_id LIMIT 20
 ), decorated AS (
  SELECT h.*, de.assertion AS donor_assertion,de.version AS donor_version,
   de.created_at AS donor_submitted_at,ne.assertion AS ngo_assertion,
   ne.version AS ngo_version,ne.created_at AS ngo_submitted_at,
   CASE WHEN s.total>20 THEN 'HISTORY_TRUNCATED'
    WHEN NOT s.valid THEN 'ASSOCIATION_CONFLICT'
    WHEN s.unresolved_count>1 THEN 'MULTIPLE_UNRESOLVED_ASSOCIATIONS'
    WHEN NOT cfg.enabled THEN 'RESOLUTION_DISABLED'
    WHEN h.case_id IS NULL THEN 'AWAITING_NGO_REPORT'
    WHEN h.resolution_status='RESOLVED' THEN 'TERMINAL_READ_ONLY'
    WHEN h.initial_class NOT IN ('NEVER_STARTED','DISPATCHED')
      OR h.task_status NOT IN ('PLANNED','DISPATCHED')
      OR h.claim_status<>'RECONCILIATION_REQUIRED'
      OR h.lease_status<>'RECONCILIATION_REQUIRED'
      OR coalesce(h.claim_reconciliation_status,'') NOT IN ('OPEN','MANUAL_REVIEW')
      THEN 'PICKUP_STATE_REQUIRES_REVIEW'
    ELSE NULL END AS blocker
  FROM bounded h CROSS JOIN scope s CROSS JOIN resolution_private.config cfg
  LEFT JOIN LATERAL (
   SELECT e.assertion,e.version,e.created_at FROM resolution_private.evidence e
   WHERE h.binding_valid AND e.case_id=h.case_id AND e.task_id=h.task_id
    AND e.actor_id=actor ORDER BY e.version DESC LIMIT 1
  ) de ON true
  LEFT JOIN LATERAL (
   SELECT e.assertion,e.version,e.created_at FROM resolution_private.evidence e
   WHERE h.binding_valid AND e.case_id=h.case_id AND e.task_id=h.task_id
    AND e.actor_id=h.ngo_id ORDER BY e.version DESC LIMIT 1
  ) ne ON true
  WHERE cfg.singleton
 )
 SELECT jsonb_build_object(
  'contract','geolock.donor-route-resolution.v1','donation_id',p_donation,
  'title',(SELECT d.title FROM public.donations d WHERE d.donation_id=p_donation),
  'server_now',statement_timestamp(),
  'enabled',coalesce((SELECT enabled FROM resolution_private.config WHERE singleton),false),
  'history_truncated',s.total>20,'association_conflict',NOT s.valid OR s.unresolved_count>1,
  'contexts',coalesce((SELECT jsonb_agg(jsonb_build_object(
   'claim_id',x.claim_id,'task_id',x.task_id,'route_id',x.route_id,
   'case_id',x.case_id,'case_version',x.case_version,'initial_class',x.initial_class,
   'claim_status',x.claim_status,'lease_status',x.lease_status,'task_status',x.task_status,
   'route_status',x.route_status,'resolution_status',x.resolution_status,
   'claim_reconciliation_status',x.claim_reconciliation_status,
   'disposition',x.disposition,'resolved_at',x.resolved_at,
   'claim_resolved_at',x.claim_resolved_at,'released_at',x.released_at,
   'donor_evidence',jsonb_build_object('assertion',x.donor_assertion,'version',x.donor_version,'submitted_at',x.donor_submitted_at),
   'ngo_evidence',jsonb_build_object('assertion',x.ngo_assertion,'version',x.ngo_version,'submitted_at',x.ngo_submitted_at),
   'can_submit_evidence',x.blocker IS NULL,'blocking_reason',x.blocker,
   'allowed_assertions',CASE WHEN x.blocker IS NOT NULL THEN '[]'::jsonb
    WHEN x.initial_class='NEVER_STARTED' THEN jsonb_build_array('NO_HANDOVER_SOURCE_RETAINS_GOODS','UNKNOWN_CUSTODY')
    ELSE jsonb_build_array('NO_HANDOVER_SOURCE_RETAINS_GOODS','HANDOVER_TO_NGO_CONFIRMED','UNKNOWN_CUSTODY') END
  ) ORDER BY x.created_at DESC,x.route_id,x.task_id) FROM decorated x),'[]'::jsonb)
 ) INTO result FROM scope s;
 RETURN result;
END $$;

ALTER FUNCTION public.get_my_donation_route_resolution(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_my_donation_route_resolution(uuid)
 FROM PUBLIC,anon,authenticated,service_role,geolock_graph_worker,geolock_planner,geolock_validator,geolock_route_resolver;
GRANT EXECUTE ON FUNCTION public.get_my_donation_route_resolution(uuid) TO authenticated;
COMMIT;
