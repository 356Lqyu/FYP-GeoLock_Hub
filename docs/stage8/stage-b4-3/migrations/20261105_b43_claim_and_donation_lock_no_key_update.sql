-- Stage B.4.3 candidate 2; review-only forward correction, not deployed.
-- Candidate 1 (20261104) changed claim_listing only and was disproven by local tests.
-- Current source hashes: claim_listing=2c1f60c876797c61b44b3cb43591bab8; geolock_lock_listing_donations=90816e7c6db3606dc8b6451a899d8036.
-- Candidate hashes: claim_listing=c8d324772b12c843fba231e7ea733914; geolock_lock_listing_donations=e97a3fd80673a827465f3eaa79b65903.
-- Both listing locks use FOR NO KEY UPDATE to remove the confirmed lock upgrade.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='90s';
CREATE TEMP TABLE b43_function_acls_before ON COMMIT DROP AS
 SELECT p.oid,p.proacl FROM pg_proc p
 WHERE p.oid IN (to_regprocedure('public.claim_listing(uuid,uuid)'),
                 to_regprocedure('public.geolock_lock_listing_donations(uuid,text[])'));
DO $b43_preflight$
DECLARE c record; h record;
BEGIN
 SELECT p.proowner,p.prosecdef,p.proconfig,p.prorettype,p.proargtypes,md5(replace(p.prosrc,E'\r\n',E'\n')) body_md5
 INTO c FROM pg_proc p WHERE p.oid=to_regprocedure('public.claim_listing(uuid,uuid)');
 SELECT p.proowner,p.prosecdef,p.proconfig,p.prorettype,p.proargtypes,md5(replace(p.prosrc,E'\r\n',E'\n')) body_md5
 INTO h FROM pg_proc p WHERE p.oid=to_regprocedure('public.geolock_lock_listing_donations(uuid,text[])');
 IF NOT FOUND OR c.proowner<>'postgres'::regrole OR NOT c.prosecdef
    OR c.proconfig<>ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
    OR c.prorettype<>'jsonb'::regtype OR c.proargtypes::text<>'2950 2950'
    OR c.body_md5 NOT IN ('2c1f60c876797c61b44b3cb43591bab8','c8d324772b12c843fba231e7ea733914')
    OR h.proowner<>'postgres'::regrole OR h.prosecdef
    OR h.proconfig<>ARRAY['search_path=pg_catalog, public, pg_temp']
    OR h.prorettype<>'boolean'::regtype OR h.proargtypes::text<>'2950 1009'
    OR h.body_md5 NOT IN ('90816e7c6db3606dc8b6451a899d8036','e97a3fd80673a827465f3eaa79b65903') THEN RAISE EXCEPTION 'B43_FUNCTION_PRECONDITION_FAILED'; END IF;
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
create or replace function public.geolock_lock_listing_donations(p_listing uuid, p_states text[])
returns boolean language plpgsql
set search_path to 'pg_catalog','public','pg_temp'
as $function$
declare v_l public.listings%rowtype; v_b public.hub_batches%rowtype;
  v_id uuid; v_count integer:=0; v_ok boolean:=true; v_d public.donations%rowtype;
begin
  select * into v_l from public.listings where listing_id=p_listing for no key update;
  if not found then return false; end if;
  if v_l.source_type='DIRECT_DONATION' then
    select * into v_d from public.donations where donation_id=v_l.donation_id for update;
    return coalesce(found and v_d.collection_path='DIRECT_PICKUP' and v_d.donation_status=any(p_states),false);
  end if;
  if v_l.source_type<>'HUB_BATCH' then return false; end if;
  select * into v_b from public.hub_batches where batch_id=v_l.batch_id for update;
  if not found or v_b.batch_status not in ('PUBLISHED','COLLECTED') then return false; end if;
  -- Membership is immutable once published, and its parent batch is now locked.
  for v_id in select m.donation_id from public.hub_batch_members m
    where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE' order by m.donation_id
  loop
    v_count:=v_count+1;
    select * into v_d from public.donations where donation_id=v_id for update;
    if not found or v_d.collection_path<>'HUB_COLLECTION'
      or not (v_d.donation_status=any(p_states)) then v_ok:=false; end if;
  end loop;
  -- Lock inventory in the same UUID order after locking the entire donation set.
  for v_id in select m.donation_id from public.hub_batch_members m
    where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE' order by m.donation_id
  loop
    perform 1 from public.hub_inventory hi where hi.donation_id=v_id
      and hi.hub_id=v_b.hub_id
      and (hi.inventory_status='BATCHED'
        or ('COLLECTED'=any(p_states) and hi.inventory_status in ('COLLECTED','RECONCILIATION_REQUIRED'))) for update;
    if not found then v_ok:=false; end if;
  end loop;
  return v_ok and v_count>0 and v_count=v_b.batch_donation_count;
end;
$function$;
DO $b43_postflight$
DECLARE c record; h record;
BEGIN
 SELECT p.oid,p.proowner,p.prosecdef,p.proconfig,p.prorettype,p.proargtypes,md5(replace(p.prosrc,E'\r\n',E'\n')) body_md5,p.proacl
 INTO c FROM pg_proc p WHERE p.oid=to_regprocedure('public.claim_listing(uuid,uuid)');
 SELECT p.oid,p.proowner,p.prosecdef,p.proconfig,p.prorettype,p.proargtypes,md5(replace(p.prosrc,E'\r\n',E'\n')) body_md5,p.proacl
 INTO h FROM pg_proc p WHERE p.oid=to_regprocedure('public.geolock_lock_listing_donations(uuid,text[])');
 IF NOT FOUND OR c.proowner<>'postgres'::regrole OR NOT c.prosecdef
    OR c.proconfig<>ARRAY['search_path=pg_catalog, public, extensions, pg_temp']
    OR c.prorettype<>'jsonb'::regtype OR c.proargtypes::text<>'2950 2950' OR c.body_md5<>'c8d324772b12c843fba231e7ea733914'
    OR h.proowner<>'postgres'::regrole OR h.prosecdef
    OR h.proconfig<>ARRAY['search_path=pg_catalog, public, pg_temp']
    OR h.prorettype<>'boolean'::regtype OR h.proargtypes::text<>'2950 1009' OR h.body_md5<>'e97a3fd80673a827465f3eaa79b65903'
    OR c.proacl IS DISTINCT FROM (SELECT proacl FROM b43_function_acls_before WHERE oid=c.oid)
    OR h.proacl IS DISTINCT FROM (SELECT proacl FROM b43_function_acls_before WHERE oid=h.oid)
 THEN RAISE EXCEPTION 'B43_FUNCTION_POSTCONDITION_FAILED'; END IF;
END
$b43_postflight$;
COMMIT;
