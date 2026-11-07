-- Stage B.4.3 proposed forward correction; review-only, not deployed.
-- Source: supabase/migrations/20261031_claim_audit_and_failure_capture.sql
-- Expected current claim_listing body MD5: 2c1f60c876797c61b44b3cb43591bab8
-- Corrected body MD5: c8d324772b12c843fba231e7ea733914
-- Only the non-key listing row lock mode changes (FOR UPDATE -> FOR NO KEY UPDATE).
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';
CREATE TEMP TABLE b43_claim_acl_before ON COMMIT DROP AS
 SELECT p.oid,p.proacl FROM pg_proc p
 WHERE p.oid=to_regprocedure('public.claim_listing(uuid,uuid)');
DO $b43_preflight$
DECLARE p record;
BEGIN
 SELECT pr.proowner,pr.prosecdef,pr.proconfig,pr.prorettype,pr.proargtypes,
        md5(replace(pr.prosrc,E'\r\n',E'\n')) AS body_md5
 INTO p FROM pg_proc pr WHERE pr.oid=to_regprocedure('public.claim_listing(uuid,uuid)');
 IF NOT FOUND OR p.proowner<>'postgres'::regrole OR NOT p.prosecdef
    OR p.proconfig<>ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
    OR p.prorettype<>'jsonb'::regtype OR p.proargtypes::text<>'2950 2950'
    OR p.body_md5 NOT IN ('2c1f60c876797c61b44b3cb43591bab8','c8d324772b12c843fba231e7ea733914') THEN
   RAISE EXCEPTION 'B43_CLAIM_FUNCTION_PRECONDITION_FAILED';
 END IF;
END
$b43_preflight$;
CREATE OR REPLACE FUNCTION public.claim_listing(p_listing uuid, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid(); v_ngo public.ngo_profiles%rowtype;
  v_req public.claim_requests%rowtype; v_l public.listings%rowtype;
  v_digest text; v_reason text; v_claim uuid; v_lease uuid; v_mins integer;
  v_success boolean:=false; v_outcome text;
  v_configuration text; v_sqlstate text; v_failure uuid; v_error_message text;
  v_failure_reason text;
  v_transaction text:=pg_current_xact_id()::text;
  v_software constant text:='geolock-claim-audit-v1';
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles
   where user_id=v_actor and active_flag for share;
  if not found then raise exception 'ACTIVE_NGO_ONLY'; end if;
  if p_request is null or p_listing is null then raise exception 'REQUEST_AND_LISTING_REQUIRED'; end if;

  -- Serialize identical authenticated request keys, including failed retries.
  -- Actor derives from auth.uid(), never from a client-supplied NGO identity.
  perform pg_advisory_xact_lock(hashtextextended('claim-request:'||v_actor::text||':'||p_request::text,0));
  begin -- Claim subtransaction: all original claim writes/audits roll back on error.
  v_digest:=md5(p_listing::text||':'||v_actor::text);
  insert into public.claim_requests(request_id,listing_id,ngo_user_id,request_digest)
  values(p_request,p_listing,v_actor,v_digest) on conflict(request_id) do nothing;
  select * into v_req from public.claim_requests where request_id=p_request for update;
  if v_req.request_digest<>v_digest or v_req.listing_id<>p_listing or v_req.ngo_user_id<>v_actor then
    raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
  end if;
  if v_req.outcome is not null then
    return jsonb_build_object('outcome',v_req.outcome,'claim_id',v_req.result_claim_id,
      'reason_code',v_req.reason_code,'replayed',true);
  end if;
  select config_version into v_configuration from public.coordination_config where singleton;
  if v_configuration is null then raise exception 'CLAIM_CONFIGURATION_NOT_AVAILABLE'; end if;
  select * into v_l from public.listings where listing_id=p_listing for no key update;
  if not found then v_reason:='LISTING_NOT_FOUND';
  elsif v_l.listing_status<>'AVAILABLE' then v_reason:='CLAIM_CONFLICT';
  elsif v_l.listing_expires_at is not null and v_l.listing_expires_at<=clock_timestamp() then v_reason:='LISTING_EXPIRED';
  elsif v_ngo.location_verified_at is null or v_ngo.road_node_id is null then v_reason:='ELIGIBILITY_UNDETERMINED';
  elsif public.geolock_ngo_listing_road_check(v_actor,p_listing)->>'outcome'<>'ELIGIBLE'
    then v_reason:=public.geolock_ngo_listing_road_check(v_actor,p_listing)->>'outcome';
  elsif v_l.source_type='DIRECT_DONATION' and not exists(
    select 1 from public.donations d where d.donation_id=v_l.donation_id and d.donation_status='AVAILABLE')
    then v_reason:='DONATION_NOT_READY';
  elsif v_l.source_type='HUB_BATCH' and not exists(
    select 1 from public.hub_batches b where b.batch_id=v_l.batch_id and b.batch_status='PUBLISHED')
    then v_reason:='BATCH_NOT_PUBLISHED';
  elsif not public.geolock_lock_listing_donations(p_listing,
    array[case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end])
    then v_reason:='DONATION_SET_NOT_READY';
  else
    select claim_lease_minutes into v_mins from public.coordination_config where singleton;
    if v_mins is null then raise exception 'CLAIM_LEASE_NOT_CONFIGURED'; end if;
    insert into public.donation_claims(listing_id,ngo_user_id,request_id)
      values(p_listing,v_actor,p_request) returning claim_id into v_claim;
    insert into public.claim_leases(claim_id,expires_at)
      values(v_claim,clock_timestamp()+make_interval(mins=>v_mins)) returning lease_id into v_lease;
    update public.listings set listing_status='CLAIMED',listing_version=listing_version+1
      where listing_id=p_listing;
    insert into public.pickup_tasks(claim_id,listing_id,ngo_user_id,pickup_road_node_id,load_kg)
      values(v_claim,p_listing,v_actor,v_l.pickup_road_node_id,v_l.listing_weight_kg);
    perform public.geolock_transition_listing_donations(p_listing,
      case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end,'CLAIMED',v_claim,p_request,'CLAIM_ACCEPTED');
    v_success:=true;
  end if;
  v_outcome:=case when v_success then 'SUCCESS'
    when v_reason in ('OUTSIDE_GEOFENCE','ROUTE_UNAVAILABLE') then 'INELIGIBLE' else 'CONFLICT' end;
  update public.claim_requests set outcome=v_outcome,result_claim_id=v_claim,
    reason_code=v_reason,completed_at=clock_timestamp() where request_id=p_request;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    request_id,claim_id,lease_id,previous_state,requested_state,resulting_state,
    reason_code,outcome,details,configuration_version,correlation_id,software_version)
  values(v_actor,'NGO','LISTING',p_listing,'CLAIM_ATTEMPT',p_request,v_claim,v_lease,
    v_l.listing_status,'CLAIMED',case when v_success then 'CLAIMED' else v_l.listing_status end,
    coalesce(v_reason,'CLAIM_ACCEPTED'),case when v_success then 'SUCCESS' else 'REJECTED' end,
    jsonb_build_object('ngo_id',v_actor,'listing_id',p_listing,'donation_id',v_l.donation_id,
      'batch_id',v_l.batch_id,'donation_ids',case when v_l.source_type='DIRECT_DONATION'
        then jsonb_build_array(v_l.donation_id) else coalesce((select jsonb_agg(m.donation_id order by m.donation_id)
          from public.hub_batch_members m where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'),'[]'::jsonb) end,
      'transaction_id',v_transaction),v_configuration,p_request,v_software);
  return jsonb_build_object('outcome',v_outcome,'claim_id',v_claim,
    'reason_code',v_reason,'replayed',false);
  exception when others then
    -- PostgreSQL has rolled back ONLY the claim subtransaction at this point.
    -- Cancellation/assertion failures are not caught by OTHERS and stay unconfirmed.
    get stacked diagnostics v_sqlstate=returned_sqlstate,v_error_message=message_text;
    v_failure_reason:=case when v_sqlstate='P0001'
      and v_error_message='IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'
      then 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'
      else 'CLAIM_TRANSACTION_ROLLED_BACK' end;
  end;
  -- No client report or inferred network outcome can reach this trusted path.
  -- Clear rolled-back generated IDs; rejected/failed attempts have no new lease.
  v_claim:=null; v_lease:=null;
  if v_l.listing_id is null then
    select * into v_l from public.listings where listing_id=p_listing;
  end if;
  if v_configuration is null then
    select config_version into v_configuration from public.coordination_config where singleton;
  end if;
  insert into public.operation_failure_events(request_id,actor_user_id,actor_role,
    operation_name,donation_id,listing_id,claim_id,reason_code,details)
  values(p_request,v_actor,'NGO','claim_listing',v_l.donation_id,p_listing,null,
    v_failure_reason,jsonb_build_object('sqlstate',v_sqlstate,
      'ngo_id',v_actor,'donation_id',v_l.donation_id,'batch_id',v_l.batch_id,
      'donation_ids',case when v_l.source_type='DIRECT_DONATION' then jsonb_build_array(v_l.donation_id)
        else coalesce((select jsonb_agg(m.donation_id order by m.donation_id) from public.hub_batch_members m
          where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'),'[]'::jsonb) end,
      'previous_state',v_l.listing_status,'requested_state','CLAIMED',
      'resulting_state',(select listing_status from public.listings where listing_id=p_listing),
      'lease_id',null,'outcome','ERROR','rollback_confirmed',true,
      'correlation_id',p_request,'transaction_id',v_transaction,
      'software_version',v_software,'configuration_version',v_configuration))
  on conflict(actor_user_id,request_id,listing_id,operation_name,reason_code)
    where operation_name='claim_listing' and actor_user_id is not null
      and request_id is not null and listing_id is not null
  do nothing returning failure_id into v_failure;
  if v_failure is null then
    select failure_id into strict v_failure from public.operation_failure_events
    where actor_user_id=v_actor and request_id=p_request and listing_id=p_listing
      and operation_name='claim_listing' and reason_code=v_failure_reason;
  end if;
  -- If audit persistence fails this outer transaction aborts; no confirmed failure is returned.
  return jsonb_build_object('outcome','ERROR','claim_id',null,
    'reason_code',v_failure_reason,'replayed',false,
    'rollback_confirmed',true,'failure_audit_id',v_failure);
end;
$function$;

DO $b43_postflight$
DECLARE p record; old_acl aclitem[];
BEGIN
 SELECT proacl INTO old_acl FROM b43_claim_acl_before
 WHERE oid=to_regprocedure('public.claim_listing(uuid,uuid)');
 SELECT pr.proowner,pr.prosecdef,pr.proconfig,pr.prorettype,pr.proargtypes,
        md5(replace(pr.prosrc,E'\r\n',E'\n')) AS body_md5,pr.proacl
 INTO p FROM pg_proc pr WHERE pr.oid=to_regprocedure('public.claim_listing(uuid,uuid)');
 IF NOT FOUND OR p.proowner<>'postgres'::regrole OR NOT p.prosecdef
    OR p.proconfig<>ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
    OR p.prorettype<>'jsonb'::regtype OR p.proargtypes::text<>'2950 2950'
    OR p.body_md5<>'c8d324772b12c843fba231e7ea733914' OR p.proacl IS DISTINCT FROM old_acl THEN
   RAISE EXCEPTION 'B43_CLAIM_FUNCTION_POSTCONDITION_FAILED';
 END IF;
END
$b43_postflight$;
COMMIT;
