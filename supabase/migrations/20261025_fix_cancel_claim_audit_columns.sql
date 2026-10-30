-- Review-only until manually approved for isolated DEV rcgyuwiidqvrgbxswhqj.
-- Fix audit projection only; preserve the deployed cancellation transaction,
-- ownership checks, request UUID replay, lock order, state guards and grants.
-- audit_events has neither donation_id nor listing_id columns. Related IDs
-- belong in details; the event remains entity_type=CLAIM / entity_id=p_claim.
begin;
do $$
begin
  if current_user <> 'postgres' then raise exception 'MIGRATION_REQUIRES_POSTGRES'; end if;
  if to_regprocedure('public.cancel_claim(uuid,uuid)') is null then
    raise exception 'CANCEL_CLAIM_DEPENDENCY_MISSING';
  end if;
  if (select count(*) from information_schema.columns
      where table_schema='public' and table_name='audit_events'
        and column_name in ('actor_user_id','actor_role','entity_type','entity_id',
          'event_type','request_id','claim_id','lease_id','correlation_id',
          'previous_state','requested_state','resulting_state','reason_code',
          'outcome','software_version','configuration_version','details')) <> 17 then
    raise exception 'AUDIT_EVENTS_CONTRACT_MISMATCH';
  end if;
end;
$$;

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

  if not found then v_reason := 'PICKUP_TASK_MISSING_REQUIRES_RECONCILIATION';
  elsif v_c.claim_status <> 'ACTIVE' then v_reason := 'CLAIM_NOT_ACTIVE';
  elsif v_le.lease_status <> 'ACTIVE' then v_reason := 'LEASE_NOT_ACTIVE';
  elsif v_le.expires_at <= clock_timestamp() then v_reason := 'LEASE_EXPIRED_USE_RECOVERY';
  elsif v_l.listing_status <> 'CLAIMED' then v_reason := 'LISTING_NOT_CLAIMED';
  elsif v_t.task_status <> 'CONFIRMED' then v_reason := 'PICKUP_ALREADY_STARTED_OR_CLOSED';
  elsif v_l.source_type='DIRECT_DONATION' and not exists(select 1 from public.donations d
      where d.donation_id=v_l.donation_id and d.donation_status='READY_FOR_PICKUP') then
    v_reason := 'DONATION_STATE_REQUIRES_RECONCILIATION';
  elsif v_l.source_type='HUB_BATCH' and (
      not exists(select 1 from public.hub_batch_members m
        where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE')
      or exists(select 1 from public.hub_batch_members m join public.donations d using(donation_id)
        where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE' and d.donation_status<>'BATCHED')
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

-- CREATE OR REPLACE preserves postgres ownership and the existing EXECUTE ACL.
-- No audit rows are rewritten; the append-only audit trigger is unchanged.
commit;

