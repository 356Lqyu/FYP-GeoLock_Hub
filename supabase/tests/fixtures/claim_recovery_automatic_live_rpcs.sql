-- ISOLATED FIXTURE ONLY. Exact RPC source captured by SELECT from DEV.
-- Dependency tables/auth/road-eligibility are explicit test fixtures.
CREATE OR REPLACE FUNCTION public.assign_task_to_route(p_route uuid, p_task uuid, p_stop_order integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_actor uuid:=auth.uid();v_r public.pickup_routes%rowtype;
 v_t public.pickup_tasks%rowtype;
begin
 select * into v_r from public.pickup_routes where route_id=p_route for update;
 if not found or v_r.ngo_user_id is distinct from v_actor or v_r.route_status<>'DRAFT'
 then raise exception 'ROUTE_NOT_EDITABLE_BY_NGO'; end if;
 select * into v_t from public.pickup_tasks where task_id=p_task for update;
 if not found or v_t.ngo_user_id<>v_actor or v_t.task_status not in ('CONFIRMED','PLANNED')
 then raise exception 'TASK_NOT_ASSIGNABLE'; end if;
 if not exists(select 1 from public.donation_claims c
 join public.claim_leases l on l.claim_id=c.claim_id
 where c.claim_id=v_t.claim_id and c.claim_status='ACTIVE'
 and l.lease_status='ACTIVE' and l.expires_at>clock_timestamp())
 then raise exception 'STALE_CLAIM'; end if;
 insert into public.active_task_route_assignments(task_id,route_id)
 values(p_task,p_route);
 insert into public.pickup_route_stops(route_id,ngo_user_id,stop_order,task_id)
 values(p_route,v_actor,p_stop_order,p_task);
 update public.pickup_tasks set task_status='PLANNED' where task_id=p_task;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 requested_state,resulting_state,outcome,details)
 values(v_actor,'NGO','TASK',p_task,'ASSIGN_ROUTE','PLANNED','PLANNED','SUCCESS',
 jsonb_build_object('route_id',p_route));
end $function$;

CREATE OR REPLACE FUNCTION public.cancel_claim(p_claim uuid, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_role text;
  v_c public.donation_claims%rowtype;
  v_l public.listings%rowtype;
  v_le public.claim_leases%rowtype;
  v_t public.pickup_tasks%rowtype;
  v_req public.claim_cancellation_requests%rowtype;
  v_fingerprint text;
  v_result jsonb;
  v_reason text;
  v_safe boolean := false;
  v_version text;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_claim is null or p_request is null then raise exception 'CLAIM_AND_REQUEST_REQUIRED'; end if;
  select c.* into v_c from public.donation_claims c where c.claim_id=p_claim;
  if not found or v_c.ngo_user_id is distinct from v_actor
     or not exists(select 1 from public.ngo_profiles n where n.user_id=v_actor and n.active_flag) then
    raise exception 'CLAIM_NOT_FOUND_OR_FORBIDDEN';
  end if;
  select p.role into v_role from public.user_profiles p where p.user_id=v_actor;
  v_fingerprint := v_actor::text || ':' || p_claim::text;
  insert into public.claim_cancellation_requests(request_id,claim_id,actor_user_id,request_fingerprint)
    values(p_request,p_claim,v_actor,v_fingerprint) on conflict(request_id) do nothing;
  select r.* into v_req from public.claim_cancellation_requests r
    where r.request_id=p_request for update;
  if v_req.request_fingerprint is distinct from v_fingerprint then
    insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
      request_id,claim_id,correlation_id,requested_state,resulting_state,reason_code,outcome,details)
    values(v_actor,v_role,'CLAIM',p_claim,'CANCEL_CLAIM',p_request,p_claim,p_request,
      'RELEASED',null,'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD','REJECTED',
      jsonb_build_object('request_id',p_request));
    return jsonb_build_object('outcome','REJECTED','claim_id',p_claim,
      'reason_code','IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD');
  end if;
  if v_req.response is not null then return v_req.response; end if;

  -- Keep the deployed pickup lock prefix exactly: claim, lease, listing, task.
  select c.* into v_c from public.donation_claims c where c.claim_id=p_claim for update;
  if not found then raise exception 'CLAIM_NOT_FOUND'; end if;
  select le.* into v_le from public.claim_leases le where le.claim_id=p_claim for update;
  if not found then raise exception 'LEASE_MISSING_REQUIRES_RECONCILIATION'; end if;
  select l.* into v_l from public.listings l where l.listing_id=v_c.listing_id for update;
  if not found then raise exception 'LISTING_MISSING_REQUIRES_RECONCILIATION'; end if;
  select t.* into v_t from public.pickup_tasks t where t.claim_id=p_claim for update;

  if v_t.task_id is null then v_reason := 'PICKUP_TASK_MISSING_REQUIRES_RECONCILIATION';
  elsif not public.geolock_lock_listing_donations(v_l.listing_id,array['CLAIMED']) then
    v_reason := 'DONATION_SET_REQUIRES_RECONCILIATION';
  elsif v_c.claim_status <> 'ACTIVE' then v_reason := 'CLAIM_NOT_ACTIVE';
  elsif v_le.lease_status <> 'ACTIVE' then v_reason := 'LEASE_NOT_ACTIVE';
  elsif v_le.expires_at <= clock_timestamp() then v_reason := 'LEASE_EXPIRED_USE_RECOVERY';
  elsif v_l.listing_status <> 'CLAIMED' then v_reason := 'LISTING_NOT_CLAIMED';
  elsif v_t.task_status <> 'CONFIRMED' then v_reason := 'PICKUP_ALREADY_STARTED_OR_CLOSED';
  elsif v_l.source_type='DIRECT_DONATION' and not exists(select 1 from public.donations d
      where d.donation_id=v_l.donation_id and d.donation_status='CLAIMED') then
    v_reason := 'DONATION_STATE_REQUIRES_RECONCILIATION';
  elsif v_l.source_type='HUB_BATCH' and (
      not exists(select 1 from public.hub_batch_members m
        where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE')
      or exists(select 1 from public.hub_batch_members m join public.donations d using(donation_id)
        where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE' and d.donation_status<>'CLAIMED')
      or exists(select 1 from public.hub_batch_members m
        where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'
          and not exists(select 1 from public.hub_inventory hi
            where hi.donation_id=m.donation_id and hi.inventory_status='BATCHED'))) then
    v_reason := 'BATCH_CUSTODY_STATE_REQUIRES_RECONCILIATION';
  elsif exists(select 1 from public.active_task_route_assignments a where a.task_id=v_t.task_id)
     or exists(select 1 from public.pickup_route_stops s
      join public.pickup_routes r using(route_id)
      where s.task_id=v_t.task_id and r.route_status not in ('CANCELLED','STALE')) then
    v_reason := 'TASK_HAS_ROUTE_ACTIVITY';
  elsif v_l.listing_expires_at is not null and v_l.listing_expires_at <= clock_timestamp() then
    v_reason := 'LISTING_EXPIRED';
  else
    v_safe := true;
  end if;

  if v_safe then
    update public.donation_claims set claim_status='RELEASED',closed_at=clock_timestamp(),
      close_reason='NGO_CANCELLED_BEFORE_PICKUP' where claim_id=p_claim;
    update public.claim_leases set lease_status='RELEASED',closed_at=clock_timestamp(),
      release_reason='NGO_CANCELLED_BEFORE_PICKUP' where lease_id=v_le.lease_id;
    update public.pickup_tasks set task_status='STALE' where task_id=v_t.task_id;
    update public.listings set listing_status='AVAILABLE',listing_version=listing_version+1
      where listing_id=v_l.listing_id and listing_status='CLAIMED';
    perform public.geolock_transition_listing_donations(v_l.listing_id,'CLAIMED',
      case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end);
    v_reason := 'NGO_CANCELLED_BEFORE_PICKUP';
  end if;
  v_result := jsonb_build_object('outcome',case when v_safe then 'SUCCESS' else 'REJECTED' end,
    'claim_id',p_claim,'listing_id',v_c.listing_id,'reason_code',v_reason,
    'claim_status',case when v_safe then 'RELEASED' else v_c.claim_status end,
    'resulting_listing_status',case when v_safe then 'AVAILABLE' else v_l.listing_status end);
  update public.claim_cancellation_requests set response=v_result,completed_at=clock_timestamp()
    where request_id=p_request;
  select c.config_version into v_version from public.coordination_config c where c.singleton;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    request_id,claim_id,lease_id,correlation_id,previous_state,requested_state,resulting_state,
    reason_code,outcome,software_version,configuration_version,details)
  values(v_actor,v_role,'CLAIM',p_claim,'CANCEL_CLAIM',p_request,p_claim,v_le.lease_id,
    p_request,
    v_c.claim_status,'RELEASED',case when v_safe then 'RELEASED' else v_c.claim_status end,
    v_reason,case when v_safe then 'SUCCESS' else 'REJECTED' end,
    'geolock-stage1-2026-10-19',v_version,
    jsonb_build_object('donation_id',v_l.donation_id,
      'listing_id',v_c.listing_id,'task_id',v_t.task_id));
  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.claim_listing(p_listing uuid, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid(); v_ngo public.ngo_profiles%rowtype;
  v_req public.claim_requests%rowtype; v_l public.listings%rowtype;
  v_digest text; v_reason text; v_claim uuid; v_lease uuid; v_mins integer;
  v_success boolean:=false; v_outcome text;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles
   where user_id=v_actor and active_flag for share;
  if not found then raise exception 'ACTIVE_NGO_ONLY'; end if;
  if p_request is null or p_listing is null then raise exception 'REQUEST_AND_LISTING_REQUIRED'; end if;

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
  select * into v_l from public.listings where listing_id=p_listing for update;
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
      case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end,'CLAIMED');
    v_success:=true;
  end if;
  v_outcome:=case when v_success then 'SUCCESS'
    when v_reason in ('OUTSIDE_GEOFENCE','ROUTE_UNAVAILABLE') then 'INELIGIBLE' else 'CONFLICT' end;
  update public.claim_requests set outcome=v_outcome,result_claim_id=v_claim,
    reason_code=v_reason,completed_at=clock_timestamp() where request_id=p_request;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    request_id,claim_id,lease_id,previous_state,requested_state,resulting_state,
    reason_code,outcome,details,configuration_version)
  select v_actor,'NGO','LISTING',p_listing,'CLAIM_ATTEMPT',p_request,v_claim,v_lease,
    v_l.listing_status,'CLAIMED',case when v_success then 'CLAIMED' else v_l.listing_status end,
    v_reason,case when v_success then 'SUCCESS' else 'REJECTED' end,
    jsonb_build_object('ngo_id',v_actor),cfg.config_version
    from public.coordination_config cfg where cfg.singleton;
  return jsonb_build_object('outcome',v_outcome,'claim_id',v_claim,
    'reason_code',v_reason,'replayed',false);
end;
$function$;

CREATE OR REPLACE FUNCTION public.complete_pickup(p_claim uuid, p_handover_confirmed boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_actor uuid:=auth.uid();v_c public.donation_claims%rowtype;
 v_l public.listings%rowtype;v_lease public.claim_leases%rowtype;
begin
 select * into v_c from public.donation_claims where claim_id=p_claim for update;
 if not found or v_c.ngo_user_id is distinct from v_actor or v_c.claim_status<>'ACTIVE'
 then raise exception 'NOT_ACTIVE_CLAIM_HOLDER'; end if;
 select * into v_lease from public.claim_leases where claim_id=p_claim for update;
 if not found or v_lease.lease_status<>'ACTIVE' or v_lease.expires_at<=clock_timestamp()
 then raise exception 'STALE_OR_EXPIRED_LEASE'; end if;
 if p_handover_confirmed is distinct from true then raise exception 'HANDOVER_NOT_CONFIRMED'; end if;
 select * into v_l from public.listings where listing_id=v_c.listing_id for update;
 if v_l.listing_status<>'CLAIMED' then raise exception 'LISTING_NOT_CLAIMED'; end if;
 update public.pickup_tasks set task_status='COLLECTED'
 where claim_id=p_claim and task_status='DISPATCHED';
 if not found then raise exception 'PICKUP_NOT_STARTED'; end if;
 perform public.geolock_transition_listing_donations(v_l.listing_id,'PICKUP_IN_PROGRESS','COLLECTED');
 if v_l.source_type='HUB_BATCH' then
  update public.hub_inventory set inventory_status='COLLECTED'
  where donation_id in(select donation_id from public.hub_batch_members
    where batch_id=v_l.batch_id and membership_status='ACTIVE');
  update public.hub_batches set batch_status='COLLECTED' where batch_id=v_l.batch_id;
 end if;
 update public.listings set listing_status='CLOSED',listing_version=listing_version+1
 where listing_id=v_l.listing_id;
 update public.donation_claims set claim_status='COMPLETED',closed_at=clock_timestamp()
 where claim_id=p_claim;
 update public.claim_leases set lease_status='COMPLETED',closed_at=clock_timestamp()
 where claim_id=p_claim;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 claim_id,lease_id,requested_state,resulting_state,outcome)
 values(v_actor,'NGO','CLAIM',p_claim,'COMPLETE_PICKUP',p_claim,v_lease.lease_id,
 'COLLECTED','COLLECTED','SUCCESS');
end $function$;

CREATE OR REPLACE FUNCTION public.start_pickup(p_claim uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_actor uuid:=auth.uid();v_c public.donation_claims%rowtype;
 v_l public.listings%rowtype;v_lease public.claim_leases%rowtype;
begin
 select * into v_c from public.donation_claims where claim_id=p_claim for update;
 if not found or v_c.ngo_user_id is distinct from v_actor or v_c.claim_status<>'ACTIVE'
 then raise exception 'NOT_ACTIVE_CLAIM_HOLDER'; end if;
 select * into v_lease from public.claim_leases where claim_id=p_claim for update;
 if not found or v_lease.lease_status<>'ACTIVE' or v_lease.expires_at<=clock_timestamp()
 then raise exception 'STALE_OR_EXPIRED_LEASE'; end if;
 select * into v_l from public.listings where listing_id=v_c.listing_id for update;
 if v_l.listing_status<>'CLAIMED' then raise exception 'LISTING_NOT_CLAIMED'; end if;
 update public.pickup_tasks set task_status='DISPATCHED'
 where claim_id=p_claim and task_status in ('CONFIRMED','PLANNED');
 if not found then raise exception 'PICKUP_TASK_NOT_DISPATCHABLE'; end if;
 perform public.geolock_transition_listing_donations(v_l.listing_id,'CLAIMED','PICKUP_IN_PROGRESS');
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 claim_id,lease_id,requested_state,resulting_state,outcome)
 values(v_actor,'NGO','CLAIM',p_claim,'START_PICKUP',p_claim,v_lease.lease_id,
 'PICKUP_IN_PROGRESS','PICKUP_IN_PROGRESS','SUCCESS');
end $function$;
