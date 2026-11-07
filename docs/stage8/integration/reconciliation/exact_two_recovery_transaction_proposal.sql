-- UNEXECUTED PROPOSAL. Separate explicit execution approval required.
-- DEV rcgyuwiidqvrgbxswhqj ONLY; confirm project in dashboard first.
-- This file WRITES through the existing protected function. Not read-only diagnostics.
-- Run the ENTIRE file in one SQL Editor execution, never selected fragments.
-- Maintenance window required; keep scheduler/workers disabled and 003 undeployed.
BEGIN ISOLATION LEVEL READ COMMITTED;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SET LOCAL idle_in_transaction_session_timeout='60s';
SET LOCAL search_path=pg_catalog,pg_temp;

-- Conservative maintenance locks: block INSERT/UPDATE/DELETE and conflicting DDL,
-- including phantoms in the recovery queue and routing/reconciliation relations.
-- NOWAIT: abort on active conflicting work instead of waiting behind a writer.
-- Plain SELECTs remain possible. SELECT FOR UPDATE needs explicit row guards below.
LOCK TABLE public.donation_claims,public.claim_leases,public.listings,public.pickup_tasks,
 public.donations,public.hub_batches,public.hub_batch_members,public.hub_inventory,
 public.claim_reconciliation_cases,public.claim_reconciliation_evidence,
 routing_private.items,routing_private.bindings,public.pickup_routes,
 public.pickup_route_stops,public.active_task_route_assignments,routing_private.legacy_inflight,
 routing_private.cancelled_stop_history,public.audit_events,public.coordination_config,
 cron.job IN SHARE ROW EXCLUSIVE MODE NOWAIT;

DO $guarded_recovery$
DECLARE
 ids constant uuid[]:=ARRAY['b4bea793-9755-470a-95bb-6b02bc0c4443'::uuid,
                         'dd1be70f-0e42-4b75-9124-cac3702d76f6'::uuid];
 old_id constant uuid:='8161392c-e1e1-4723-a954-c80b6b61a8c7';
 old_task constant uuid:='270caa8b-5a6d-481c-b199-c9a47156dda2';
 historical_before jsonb; historical_after jsonb; source_before jsonb;
 new_audits jsonb; n integer; r record; audit_row record;
 audit_xid xid:=pg_current_xact_id()::xid;
 audit_count_before bigint:=0; audit_count_after bigint:=0;
 audit_digest_before bytea:=sha256(''::bytea); audit_digest_after bytea:=sha256(''::bytea);
 c public.donation_claims%rowtype; le public.claim_leases%rowtype;
 t public.pickup_tasks%rowtype; l public.listings%rowtype; d public.donations%rowtype;
BEGIN
 IF session_user<>'postgres' OR current_user<>'postgres'
 OR current_setting('transaction_isolation')<>'read committed'
 THEN RAISE EXCEPTION 'POSTGRES_READ_COMMITTED_SESSION_REQUIRED'; END IF;

 IF NOT EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid=to_regprocedure('public.recover_expired_claims(integer)')
  AND p.proowner='postgres'::regrole AND p.prosecdef
  AND p.proconfig=ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
  AND p.proacl='{postgres=X/postgres,service_role=X/postgres}'::aclitem[]
  AND pg_get_function_arguments(p.oid)='p_limit integer DEFAULT 100'
  AND pg_get_function_result(p.oid)='integer'
  AND md5(replace(p.prosrc,E'\r\n',E'\n'))='5ff6d8719db9681aae6f444b89dfbaee')
 THEN RAISE EXCEPTION 'RECOVERY_SOURCE_OR_SECURITY_DRIFT'; END IF;
 IF md5(replace((SELECT prosrc FROM pg_proc WHERE oid=to_regprocedure('public.geolock_lock_listing_donations(uuid,text[])')),E'\r\n',E'\n'))
    IS DISTINCT FROM '90816e7c6db3606dc8b6451a899d8036'
 OR md5(replace((SELECT prosrc FROM pg_proc WHERE oid=to_regprocedure('public.geolock_transition_listing_donations(uuid,text,text)')),E'\r\n',E'\n'))
    IS DISTINCT FROM 'c7f2124b18d75e5af2d7785daeeaa890'
 THEN RAISE EXCEPTION 'CUSTODY_HELPER_SOURCE_DRIFT'; END IF;
 IF EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pickup_tasks'::regclass
  AND tgname='routing_task_authority')
 THEN RAISE EXCEPTION '003_ALREADY_PRESENT_REVIEW_REQUIRED'; END IF;
 IF (SELECT count(*) FROM cron.job WHERE jobname='geolock-expired-claim-recovery' AND NOT active)<>1
 OR EXISTS(SELECT 1 FROM cron.job WHERE active AND
  (jobname='geolock-expired-claim-recovery' OR command ~* '\mrecover_expired_claims\M'))
 THEN RAISE EXCEPTION 'DISABLED_RECOVERY_SCHEDULER_REQUIRED'; END IF;

 -- Reject ALL unrelated ACTIVE/ACTIVE pairs, not just currently expired ones.
 -- Together with queue table locks this also excludes time-driven new eligibility.
 IF (SELECT count(*) FROM public.donation_claims c0 JOIN public.claim_leases le0 ON le0.claim_id=c0.claim_id
  WHERE c0.claim_status='ACTIVE' AND le0.lease_status='ACTIVE')<>2
 OR EXISTS(SELECT 1 FROM public.donation_claims c0 JOIN public.claim_leases le0 ON le0.claim_id=c0.claim_id
  WHERE c0.claim_status='ACTIVE' AND le0.lease_status='ACTIVE' AND NOT(c0.claim_id=ANY(ids)))
 THEN RAISE EXCEPTION 'QUEUE_NOT_EXACTLY_TWO_TARGETS'; END IF;

 -- Own both target claim row locks before calling SKIP LOCKED recovery.
 -- Another session's pure row lock causes NOWAIT failure, never substitution.
 PERFORM 1 FROM public.donation_claims c0 JOIN public.claim_leases le0 ON le0.claim_id=c0.claim_id
 WHERE c0.claim_id=ANY(ids) ORDER BY le0.expires_at,c0.claim_id FOR UPDATE OF c0 NOWAIT;
 PERFORM 1 FROM public.claim_leases WHERE claim_id=ANY(ids) ORDER BY claim_id FOR UPDATE NOWAIT;

 -- Exact historical identities must exist and already be released/stale.
 PERFORM 1 FROM public.donation_claims WHERE claim_id=old_id FOR UPDATE NOWAIT;
 IF NOT FOUND THEN RAISE EXCEPTION 'HISTORICAL_CLAIM_MISSING'; END IF;
 PERFORM 1 FROM public.claim_leases WHERE claim_id=old_id FOR UPDATE NOWAIT;
 PERFORM 1 FROM public.pickup_tasks WHERE claim_id=old_id FOR UPDATE NOWAIT;
 IF (SELECT count(*) FROM public.claim_leases WHERE claim_id=old_id AND lease_status='RELEASED')<>1
 OR (SELECT claim_status FROM public.donation_claims WHERE claim_id=old_id) IS DISTINCT FROM 'RELEASED'
 OR (SELECT count(*) FROM public.pickup_tasks WHERE claim_id=old_id)<>1
 OR NOT EXISTS(SELECT 1 FROM public.pickup_tasks WHERE claim_id=old_id AND task_id=old_task AND task_status='STALE')
 THEN RAISE EXCEPTION 'HISTORICAL_STATE_CHANGED'; END IF;
 SELECT jsonb_build_object('claim',(SELECT to_jsonb(x) FROM public.donation_claims x WHERE claim_id=old_id),
  'leases',(SELECT jsonb_agg(to_jsonb(x) ORDER BY lease_id) FROM public.claim_leases x WHERE claim_id=old_id),
  'tasks',(SELECT jsonb_agg(to_jsonb(x) ORDER BY task_id) FROM public.pickup_tasks x WHERE claim_id=old_id)) INTO historical_before;

 -- DIRECT PICKUP ONLY. Hub custody is not silently mapped to AVAILABLE.
 FOR r IN SELECT * FROM (VALUES
  (ids[1],'521ad842-5d79-4157-97f9-9fb1c73ca632'::uuid),
  (ids[2],'bbbf6b10-cb79-42ed-82cc-8b2246bf8bcb'::uuid)) x(claim_id,task_id)
 LOOP
  SELECT * INTO STRICT c FROM public.donation_claims WHERE claim_id=r.claim_id;
  SELECT * INTO STRICT le FROM public.claim_leases WHERE claim_id=r.claim_id;
  SELECT * INTO STRICT l FROM public.listings WHERE listing_id=c.listing_id FOR UPDATE NOWAIT;
  SELECT * INTO STRICT t FROM public.pickup_tasks WHERE claim_id=r.claim_id FOR UPDATE NOWAIT;
  IF c.claim_status IS DISTINCT FROM 'ACTIVE' OR le.lease_status IS DISTINCT FROM 'ACTIVE'
   OR le.expires_at IS NULL OR le.expires_at>clock_timestamp()
   OR t.task_id IS DISTINCT FROM r.task_id OR t.task_status IS DISTINCT FROM 'CONFIRMED'
   OR t.listing_id IS DISTINCT FROM c.listing_id OR t.ngo_user_id IS DISTINCT FROM c.ngo_user_id
   OR l.source_type IS DISTINCT FROM 'DIRECT_DONATION' OR l.batch_id IS NOT NULL
   OR l.listing_status IS DISTINCT FROM 'CLAIMED'
   OR (l.listing_expires_at IS NOT NULL AND l.listing_expires_at<=clock_timestamp())
  THEN RAISE EXCEPTION 'TARGET_STATE_OR_EXPIRY_CHANGED: %',r.claim_id; END IF;
  SELECT * INTO STRICT d FROM public.donations WHERE donation_id=l.donation_id FOR UPDATE NOWAIT;
  IF d.donation_status IS DISTINCT FROM 'CLAIMED' OR d.collection_path IS DISTINCT FROM 'DIRECT_PICKUP'
  THEN RAISE EXCEPTION 'DIRECT_CUSTODY_MISMATCH: %',r.claim_id; END IF;
  IF EXISTS(SELECT 1 FROM public.donation_claims other WHERE other.listing_id=c.listing_id
    AND other.claim_id<>c.claim_id AND other.claim_status IN ('ACTIVE','RECONCILIATION_REQUIRED'))
   OR c.claim_id IS DISTINCT FROM (SELECT latest.claim_id FROM public.donation_claims latest
    WHERE latest.listing_id=c.listing_id ORDER BY latest.claimed_at DESC,latest.claim_id DESC LIMIT 1)
   OR EXISTS(SELECT 1 FROM public.claim_reconciliation_cases rc WHERE rc.claim_id=c.claim_id OR rc.listing_id=c.listing_id)
  THEN RAISE EXCEPTION 'OWNERSHIP_OR_RECONCILIATION_CONFLICT: %',r.claim_id; END IF;
  -- Stronger than recovery: no routing artifacts for ANY task on this listing.
  IF EXISTS(SELECT 1 FROM public.pickup_tasks tt WHERE tt.listing_id=c.listing_id AND
   (EXISTS(SELECT 1 FROM routing_private.items i WHERE i.task_id=tt.task_id)
    OR EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.task_id=tt.task_id)
    OR EXISTS(SELECT 1 FROM public.pickup_route_stops s WHERE s.task_id=tt.task_id)
    OR EXISTS(SELECT 1 FROM routing_private.legacy_inflight z WHERE z.task_id=tt.task_id)
    OR EXISTS(SELECT 1 FROM routing_private.cancelled_stop_history h WHERE h.task_id=tt.task_id)))
  THEN RAISE EXCEPTION 'ROUTING_REFERENCE_REQUIRES_REVIEW: %',r.claim_id; END IF;
 END LOOP;
 IF (SELECT count(DISTINCT listing_id) FROM public.donation_claims WHERE claim_id=ANY(ids))<>2
 OR (SELECT count(DISTINCT l0.donation_id) FROM public.listings l0 JOIN public.donation_claims c0 ON c0.listing_id=l0.listing_id
  WHERE c0.claim_id=ANY(ids))<>2
 OR (SELECT listing_id FROM public.donation_claims WHERE claim_id=old_id)
    IS DISTINCT FROM (SELECT listing_id FROM public.donation_claims WHERE claim_id=ids[2])
 THEN RAISE EXCEPTION 'LISTING_DONATION_OR_RECLAIM_IDENTITY_MISMATCH'; END IF;

 SELECT jsonb_agg(jsonb_build_object('claim_id',c0.claim_id,'listing_id',l0.listing_id,
  'donation_id',l0.donation_id,'listing_version',l0.listing_version,'lease_id',le0.lease_id) ORDER BY c0.claim_id)
 INTO source_before FROM public.donation_claims c0 JOIN public.listings l0 ON l0.listing_id=c0.listing_id
 JOIN public.claim_leases le0 ON le0.claim_id=c0.claim_id WHERE c0.claim_id=ANY(ids);
 -- Stream one row at a time: retain only a SHA-256 chain and count, not the full audit payload.
 -- Maintenance lock prevents external writes. This invocation has not written any audits yet.
 FOR audit_row IN SELECT a.event_id,to_jsonb(a) AS body FROM public.audit_events a ORDER BY a.event_id LOOP
  audit_digest_before:=sha256(audit_digest_before||sha256(convert_to(audit_row.body::text,'UTF8')));
  audit_count_before:=audit_count_before+1;
 END LOOP;

 -- ONLY data-changing invocation. Existing protected logic remains authoritative.
 n:=public.recover_expired_claims(2);
 IF n<>2 THEN RAISE EXCEPTION 'RECOVERY_COUNT_MISMATCH: %',n; END IF;
 FOR r IN SELECT * FROM jsonb_to_recordset(source_before)
  AS x(claim_id uuid,listing_id uuid,donation_id uuid,listing_version integer,lease_id uuid)
 LOOP
  IF NOT EXISTS(SELECT 1 FROM public.donation_claims c0 JOIN public.claim_leases le0 ON le0.claim_id=c0.claim_id
   JOIN public.pickup_tasks t0 ON t0.claim_id=c0.claim_id JOIN public.listings l0 ON l0.listing_id=c0.listing_id
   JOIN public.donations d0 ON d0.donation_id=l0.donation_id
   WHERE c0.claim_id=r.claim_id AND c0.listing_id=r.listing_id AND le0.lease_id=r.lease_id
   AND c0.claim_status='RELEASED' AND le0.lease_status='RELEASED'
   AND c0.close_reason='EXPIRED_SAFE_RELEASE' AND le0.release_reason='EXPIRED_SAFE_RELEASE'
   AND c0.closed_at IS NOT NULL AND le0.closed_at IS NOT NULL AND t0.task_status='STALE'
   AND t0.listing_id=c0.listing_id AND t0.ngo_user_id=c0.ngo_user_id
   AND t0.task_id=CASE WHEN r.claim_id=ids[1] THEN '521ad842-5d79-4157-97f9-9fb1c73ca632'::uuid ELSE 'bbbf6b10-cb79-42ed-82cc-8b2246bf8bcb'::uuid END
   AND l0.listing_status='AVAILABLE' AND l0.listing_version=r.listing_version+1
   AND (l0.listing_expires_at IS NULL OR l0.listing_expires_at>clock_timestamp())
   AND l0.source_type='DIRECT_DONATION' AND d0.collection_path='DIRECT_PICKUP'
   AND d0.donation_id=r.donation_id AND d0.donation_status='AVAILABLE')
  THEN RAISE EXCEPTION 'SAFE_RELEASE_POSTCONDITION_FAILED: %',r.claim_id; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM public.claim_reconciliation_cases rc WHERE rc.claim_id=ANY(ids)
  OR rc.listing_id IN (SELECT listing_id FROM public.donation_claims WHERE claim_id=ANY(ids)))
 THEN RAISE EXCEPTION 'UNEXPECTED_RECONCILIATION_CASE'; END IF;
 IF EXISTS(SELECT 1 FROM public.pickup_tasks tt WHERE tt.listing_id IN
  (SELECT listing_id FROM public.donation_claims WHERE claim_id=ANY(ids)) AND
  (EXISTS(SELECT 1 FROM routing_private.items i WHERE i.task_id=tt.task_id)
   OR EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.task_id=tt.task_id)
   OR EXISTS(SELECT 1 FROM public.pickup_route_stops s WHERE s.task_id=tt.task_id)
   OR EXISTS(SELECT 1 FROM routing_private.legacy_inflight z WHERE z.task_id=tt.task_id)
   OR EXISTS(SELECT 1 FROM routing_private.cancelled_stop_history h WHERE h.task_id=tt.task_id)))
 THEN RAISE EXCEPTION 'UNEXPECTED_POST_RECOVERY_ROUTING_REFERENCE'; END IF;
 SELECT jsonb_build_object('claim',(SELECT to_jsonb(x) FROM public.donation_claims x WHERE claim_id=old_id),
  'leases',(SELECT jsonb_agg(to_jsonb(x) ORDER BY lease_id) FROM public.claim_leases x WHERE claim_id=old_id),
  'tasks',(SELECT jsonb_agg(to_jsonb(x) ORDER BY task_id) FROM public.pickup_tasks x WHERE claim_id=old_id)) INTO historical_after;
 IF historical_before IS DISTINCT FROM historical_after THEN RAISE EXCEPTION 'HISTORICAL_ROWS_CHANGED'; END IF;
 -- Source helper emits one DONATION_STATUS_CHANGED event per direct donation;
 -- recovery emits one LEASE_RECOVERY event per claim. Require all four, not just the return count.
 -- A deleted/updated old row changes this count/digest. An updated old row has
 -- current xmin and is excluded here, so updates cannot masquerade as preserved history.
 FOR audit_row IN SELECT a.event_id,to_jsonb(a) AS body FROM public.audit_events a
  WHERE a.xmin<>audit_xid ORDER BY a.event_id LOOP
  audit_digest_after:=sha256(audit_digest_after||sha256(convert_to(audit_row.body::text,'UTF8')));
  audit_count_after:=audit_count_after+1;
 END LOOP;
 IF audit_count_before<>audit_count_after OR audit_digest_before IS DISTINCT FROM audit_digest_after
 THEN RAISE EXCEPTION 'EXISTING_AUDIT_CHANGED'; END IF;
 -- xmin is assigned by PostgreSQL, not by callers; xid8 is cast to xid for wrap-safe equality.
 -- Bound payload aggregation to the expected four events before materializing them.
 IF (SELECT count(*) FROM public.audit_events a WHERE a.xmin=audit_xid)<>4
 THEN RAISE EXCEPTION 'RECOVERY_AUDIT_MISMATCH'; END IF;
 SELECT jsonb_agg(to_jsonb(a) ORDER BY a.event_id) INTO new_audits
 FROM public.audit_events a WHERE a.xmin=audit_xid;
 IF jsonb_array_length(new_audits)<>4 OR EXISTS(SELECT 1 FROM jsonb_array_elements(new_audits) e
  WHERE NOT EXISTS(SELECT 1 FROM jsonb_to_recordset(source_before)
   AS x(claim_id uuid,listing_id uuid,donation_id uuid,listing_version integer,lease_id uuid)
   WHERE e->>'claim_id'=x.claim_id::text AND e->>'lease_id'=x.lease_id::text AND e->>'outcome'='SUCCESS'
    AND ((e->>'event_type'='LEASE_RECOVERY' AND e->>'entity_id'=x.claim_id::text
      AND e->>'resulting_state'='RELEASED' AND e->>'reason_code'='EXPIRED_SAFE_RELEASE')
     OR (e->>'event_type'='DONATION_STATUS_CHANGED' AND e->>'entity_id'=x.donation_id::text
      AND e->>'previous_state'='CLAIMED' AND e->>'resulting_state'='AVAILABLE'
      AND e->'details'->>'listing_id'=x.listing_id::text))))
 OR (SELECT count(DISTINCT e->>'claim_id') FROM jsonb_array_elements(new_audits) e WHERE e->>'event_type'='LEASE_RECOVERY')<>2
 OR (SELECT count(DISTINCT e->>'claim_id') FROM jsonb_array_elements(new_audits) e WHERE e->>'event_type'='DONATION_STATUS_CHANGED')<>2
 THEN RAISE EXCEPTION 'RECOVERY_AUDIT_MISMATCH'; END IF;
 IF EXISTS(SELECT 1 FROM cron.job WHERE active AND
  (jobname='geolock-expired-claim-recovery' OR command ~* '\mrecover_expired_claims\M'))
 THEN RAISE EXCEPTION 'SCHEDULER_CHANGED'; END IF;
 RAISE NOTICE 'Guarded recovery assertions passed for exactly two claims; commit follows.';
END;
$guarded_recovery$;
-- Any uncaught assertion/error aborts the transaction; COMMIT cannot commit an aborted transaction.
COMMIT;
