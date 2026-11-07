BEGIN ISOLATION LEVEL READ COMMITTED;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '50s';
SET LOCAL search_path = pg_catalog,public,extensions,pg_temp;

DO $one_claim$
DECLARE
  v_target constant uuid :=
    '323ca3b3-7d7f-438e-8ed7-415f61b3a567';
  v_lease constant uuid :=
    'c845c9d7-edc8-4870-b32a-40e02d22469a';
  v_listing constant uuid :=
    '2d06b504-d2dd-4121-8840-c8bf893f8a60';
  v_donation constant uuid :=
    '5ab67656-bd03-4e19-942f-59a2dd4e6f11';
  v_task constant uuid :=
    '8f0feb98-c97c-4047-91ab-251199b2d1b6';
  v_others constant uuid[] := ARRAY[
    'aa3cd6d2-e5b3-4369-a41f-ec9a0eaae716',
    '9a2ab42b-52c6-4c3a-99fb-b5c95d41e63f'
  ]::uuid[];
  v_expected constant uuid[] :=
    ARRAY[v_target,v_others[1],v_others[2]];
  v_candidates uuid[];
  v_other_before jsonb;
  v_other_after jsonb;
  v_events_before uuid[];
  v_task_before jsonb;
  v_version bigint;
  v_generation bigint;
  v_count integer;
BEGIN
  IF current_user<>'postgres' OR session_user<>'postgres'
     OR auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION 'CLEAN_POSTGRES_SESSION_REQUIRED';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc p
    WHERE p.oid='public.recover_expired_claims(integer)'::regprocedure
      AND md5(replace(p.prosrc,E'\r\n',E'\n'))=
          '50110ff20115c4e5d46380e8e3f8b94c'
      AND p.proowner='postgres'::regrole AND p.prosecdef
      AND p.proconfig=ARRAY[
        'search_path=pg_catalog, public, extensions, pg_temp']
      AND p.proacl=
          '{postgres=X/postgres,service_role=X/postgres}'::aclitem[]
      AND pg_get_function_arguments(p.oid)=
          'p_limit integer DEFAULT 100'
      AND pg_get_function_result(p.oid)='integer'
  ) THEN
    RAISE EXCEPTION 'RECOVERY_DEFINITION_OR_SECURITY_CHANGED';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM cron.job
    WHERE jobid=3
      AND jobname='geolock-expired-claim-recovery'
      AND username='postgres'
      AND database=current_database()
      AND NOT active
  ) OR EXISTS (
    SELECT 1 FROM cron.job_run_details WHERE jobid=3
  ) OR (
    SELECT count(*) FROM cron.job WHERE jobid IN(1,2) AND active
  )<>2 THEN
    RAISE EXCEPTION 'CRON_STATE_CHANGED';
  END IF;

  -- Freeze candidate writes and competing FOR UPDATE selectors.
  -- NOWAIT aborts rather than waiting behind an existing writer/recovery.
  LOCK TABLE public.donation_claims,public.claim_leases
    IN EXCLUSIVE MODE NOWAIT;

  SELECT array_agg(c.claim_id ORDER BY le.expires_at,c.claim_id)
    INTO v_candidates
  FROM public.donation_claims c
  JOIN public.claim_leases le USING(claim_id)
  WHERE c.claim_status='ACTIVE' AND le.lease_status='ACTIVE'
    AND le.expires_at<=clock_timestamp();

  IF v_candidates IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'CANDIDATE_SET_OR_ORDER_CHANGED';
  END IF;

  -- Match the deployed writer lock prefix, then the direct donation.
  PERFORM 1 FROM public.donation_claims
    WHERE claim_id=v_target FOR UPDATE NOWAIT;
  PERFORM 1 FROM public.claim_leases
    WHERE claim_id=v_target FOR UPDATE NOWAIT;
  PERFORM 1 FROM public.listings
    WHERE listing_id=v_listing FOR UPDATE NOWAIT;
  PERFORM 1 FROM public.pickup_tasks
    WHERE claim_id=v_target FOR UPDATE NOWAIT;
  PERFORM 1 FROM public.donations
    WHERE donation_id=v_donation FOR UPDATE NOWAIT;

  IF NOT EXISTS (
    SELECT 1
    FROM public.donation_claims c
    JOIN public.claim_leases le USING(claim_id)
    JOIN public.listings l ON l.listing_id=c.listing_id
    JOIN public.donations d ON d.donation_id=l.donation_id
    JOIN public.pickup_tasks t USING(claim_id)
    WHERE c.claim_id=v_target AND c.claim_status='ACTIVE'
      AND le.lease_id=v_lease AND le.lease_status='ACTIVE'
      AND le.expires_at<=clock_timestamp()
      AND l.listing_id=v_listing
      AND l.source_type='DIRECT_DONATION'
      AND l.listing_status='CLAIMED'
      AND l.listing_expires_at IS NULL
      AND d.donation_id=v_donation
      AND d.collection_path='DIRECT_PICKUP'
      AND d.donation_status='CLAIMED'
      AND t.task_id=v_task AND t.listing_id=v_listing
      AND t.task_status='CONFIRMED'
      AND NOT EXISTS (
        SELECT 1 FROM public.active_task_route_assignments a
        WHERE a.task_id=t.task_id)
      AND NOT EXISTS (
        SELECT 1 FROM public.pickup_route_stops s
        WHERE s.task_id=t.task_id)
      AND NOT EXISTS (
        SELECT 1 FROM public.claim_reconciliation_cases rc
        WHERE rc.claim_id=c.claim_id)
      AND NOT EXISTS (
        SELECT 1 FROM public.audit_events a
        WHERE a.claim_id=c.claim_id AND a.event_type='LEASE_RECOVERY')
  ) THEN
    RAISE EXCEPTION 'TARGET_PRECONDITION_FAILED';
  END IF;

  SELECT listing_version,eligibility_generation
    INTO v_version,v_generation
  FROM public.listings WHERE listing_id=v_listing;

  SELECT to_jsonb(t) INTO v_task_before
  FROM public.pickup_tasks t WHERE task_id=v_task;

  SELECT jsonb_agg(jsonb_build_object(
           'claim',to_jsonb(c),'lease',to_jsonb(le),
           'task',to_jsonb(t),'listing',to_jsonb(l),
           'donation',to_jsonb(d)) ORDER BY c.claim_id)
    INTO v_other_before
  FROM public.donation_claims c
  JOIN public.claim_leases le USING(claim_id)
  JOIN public.pickup_tasks t USING(claim_id)
  JOIN public.listings l ON l.listing_id=c.listing_id
  JOIN public.donations d ON d.donation_id=l.donation_id
  WHERE c.claim_id=ANY(v_others);

  IF v_other_before IS NULL
     OR jsonb_array_length(v_other_before)<>2 THEN
    RAISE EXCEPTION 'OTHER_CLAIM_SNAPSHOT_INCOMPLETE';
  END IF;

  SELECT coalesce(array_agg(event_id),ARRAY[]::uuid[])
    INTO v_events_before
  FROM public.audit_events;

  v_count := public.recover_expired_claims(1);

  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'EXPECTED_ONE_PROCESSED_CLAIM';
  END IF;

  -- Force pending lifecycle/FK constraint checks before final assertions.
  SET CONSTRAINTS ALL IMMEDIATE;

  IF NOT EXISTS (
    SELECT 1
    FROM public.donation_claims c
    JOIN public.claim_leases le USING(claim_id)
    JOIN public.pickup_tasks t USING(claim_id)
    JOIN public.listings l ON l.listing_id=c.listing_id
    JOIN public.donations d ON d.donation_id=l.donation_id
    WHERE c.claim_id=v_target
      AND c.claim_status='RELEASED'
      AND c.close_reason='EXPIRED_SAFE_RELEASE'
      AND c.closed_at IS NOT NULL
      AND le.lease_id=v_lease AND le.lease_status='RELEASED'
      AND le.release_reason='EXPIRED_SAFE_RELEASE'
      AND le.closed_at IS NOT NULL
      AND t.task_id=v_task AND t.task_status='STALE'
      AND (to_jsonb(t)-'task_status')=
          (v_task_before-'task_status')
      AND l.listing_id=v_listing AND l.listing_status='AVAILABLE'
      AND l.listing_expires_at IS NULL
      AND l.listing_version=v_version+1
      AND l.eligibility_generation=v_generation+1
      AND d.donation_id=v_donation
      AND d.donation_status='AVAILABLE'
  ) THEN
    RAISE EXCEPTION 'TARGET_POSTCONDITION_FAILED';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.claim_reconciliation_cases
    WHERE claim_id=ANY(v_expected)
  ) OR EXISTS (
    SELECT 1 FROM public.active_task_route_assignments
    WHERE task_id=v_task
  ) OR EXISTS (
    SELECT 1 FROM public.pickup_route_stops WHERE task_id=v_task
  ) THEN
    RAISE EXCEPTION 'UNEXPECTED_CASE_OR_ROUTE_ACTIVITY';
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
           'claim',to_jsonb(c),'lease',to_jsonb(le),
           'task',to_jsonb(t),'listing',to_jsonb(l),
           'donation',to_jsonb(d)) ORDER BY c.claim_id)
    INTO v_other_after
  FROM public.donation_claims c
  JOIN public.claim_leases le USING(claim_id)
  JOIN public.pickup_tasks t USING(claim_id)
  JOIN public.listings l ON l.listing_id=c.listing_id
  JOIN public.donations d ON d.donation_id=l.donation_id
  WHERE c.claim_id=ANY(v_others);

  IF v_other_after IS DISTINCT FROM v_other_before THEN
    RAISE EXCEPTION 'OTHER_CLAIMS_CHANGED';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.audit_events a
  WHERE NOT(a.event_id=ANY(v_events_before));

  IF v_count<>2 OR NOT EXISTS (
    SELECT 1 FROM public.audit_events a
    WHERE NOT(a.event_id=ANY(v_events_before))
      AND a.event_type='LEASE_RECOVERY'
      AND a.entity_type='CLAIM' AND a.entity_id=v_target
      AND a.claim_id=v_target AND a.lease_id=v_lease
      AND a.actor_role='SYSTEM' AND a.actor_user_id IS NULL
      AND a.previous_state='ACTIVE'
      AND a.requested_state='RELEASED'
      AND a.resulting_state='RELEASED'
      AND a.reason_code='EXPIRED_SAFE_RELEASE'
      AND a.outcome='SUCCESS'
      AND a.details->>'donation_id'=v_donation::text
      AND a.details->>'listing_id'=v_listing::text
      AND a.details->>'task_id'=v_task::text
  ) OR NOT EXISTS (
    SELECT 1 FROM public.audit_events a
    WHERE NOT(a.event_id=ANY(v_events_before))
      AND a.event_type='DONATION_STATUS_CHANGED'
      AND a.entity_type='DONATION' AND a.entity_id=v_donation
      AND a.claim_id=v_target AND a.lease_id=v_lease
      AND a.actor_role='SYSTEM' AND a.actor_user_id IS NULL
      AND a.previous_state='CLAIMED'
      AND a.requested_state='AVAILABLE'
      AND a.resulting_state='AVAILABLE'
      AND a.outcome='SUCCESS'
      AND a.details->>'listing_id'=v_listing::text
  ) THEN
    RAISE EXCEPTION 'AUDIT_POSTCONDITION_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.listing_eligibility_refresh_jobs
    WHERE listing_id=v_listing
      AND eligibility_generation=v_generation+1
  ) THEN
    RAISE EXCEPTION 'ELIGIBILITY_REFRESH_NOT_ENQUEUED';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobid=3 AND NOT active
  ) THEN
    RAISE EXCEPTION 'RECOVERY_CRON_NO_LONGER_PAUSED';
  END IF;

  RAISE NOTICE 'Verified recovery of claim %; awaiting transaction COMMIT',
    v_target;
END;
$one_claim$;

COMMIT;
