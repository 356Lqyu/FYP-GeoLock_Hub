-- Correct the duplicate listing_id exposed by the pickup_tasks/donation_claims join.
-- Replaces only cancel_donation(uuid,uuid); no claim, lease, routing, or eligibility logic changes.
begin;

do $preflight$
begin
  if not exists (
    select 1 from pg_proc p
    where p.oid=to_regprocedure('public.cancel_donation(uuid,uuid)')
      and pg_get_function_result(p.oid)='jsonb'
      and p.prosecdef
      and exists (
        select 1 from unnest(coalesce(p.proconfig,array[]::text[])) cfg(setting)
        where split_part(cfg.setting,'=',1)='search_path'
          and regexp_replace(split_part(cfg.setting,'=',2),'[[:space:]]','','g')
              ='pg_catalog,public,pg_temp'
      )
  ) then
    raise exception 'Expected cancel_donation(uuid,uuid) SECURITY DEFINER jsonb function/search_path is missing or incompatible';
  end if;
end
$preflight$;
create or replace function public.cancel_donation(p_donation uuid,p_request uuid)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_actor uuid:=auth.uid(); v_actor_role text; v_owner uuid; v_path text;
  v_previous text; v_listing uuid; v_listing_status text; v_fingerprint text;
  v_request public.donation_cancellation_requests%rowtype; v_response jsonb;
  v_outcome text; v_reason text; v_result_state text;
  v_res public.hub_reservations%rowtype; v_hub public.community_hubs%rowtype;
  v_res_old_status text; v_res_new_status text;
  v_active_count integer; v_latest_res public.hub_reservations%rowtype;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_request is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
  if p_donation is null then raise exception 'DONATION_ID_REQUIRED'; end if;
  select p.role into v_actor_role from public.user_profiles p where p.user_id=v_actor;
  select d.donor_user_id into v_owner from public.donations d where d.donation_id=p_donation;
  if not found or v_owner is distinct from v_actor
     or not exists(select 1 from public.donor_profiles dp where dp.user_id=v_actor) then
    insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
      request_id,correlation_id,requested_state,resulting_state,reason_code,outcome,details,
      configuration_version)
    select v_actor,v_actor_role,'DONATION',p_donation,'CANCEL_DONATION',p_request,p_request,
      'CANCELLED',null,'DONATION_NOT_FOUND_OR_FORBIDDEN','REJECTED',
      jsonb_build_object('request_id',p_request),c.config_version
    from public.coordination_config c where c.singleton;
    return jsonb_build_object('outcome','REJECTED','donation_id',p_donation,
      'reason_code','DONATION_NOT_FOUND_OR_FORBIDDEN');
  end if;

  v_fingerprint:=v_actor::text||':'||p_donation::text;
  insert into public.donation_cancellation_requests(
    request_id,donor_user_id,donation_id,request_fingerprint)
  values(p_request,v_actor,p_donation,v_fingerprint)
  on conflict(request_id) do nothing;
  select * into v_request from public.donation_cancellation_requests
  where request_id=p_request for update;
  if v_request.request_fingerprint<>v_fingerprint then
    v_response:=jsonb_build_object('outcome','REJECTED','donation_id',p_donation,
      'reason_code','IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD');
    insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
      request_id,correlation_id,requested_state,resulting_state,reason_code,outcome,details,
      configuration_version)
    select v_actor,v_actor_role,'DONATION',p_donation,'CANCEL_DONATION',p_request,p_request,
      'CANCELLED',null,'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD','REJECTED',
      jsonb_build_object('request_id',p_request),c.config_version
    from public.coordination_config c where c.singleton;
    return v_response;
  end if;
  if v_request.response is not null then return v_request.response; end if;

  -- Match direct claim lock order; HUB_COLLECTION has no direct listing row.
  select l.listing_id,l.listing_status into v_listing,v_listing_status
  from public.listings l where l.donation_id=p_donation
    and l.source_type='DIRECT_DONATION' for update;
  select d.donor_user_id,d.collection_path,d.donation_status
  into v_owner,v_path,v_previous from public.donations d
  where d.donation_id=p_donation for update;

  if not found then v_reason:='DONATION_NOT_FOUND_OR_FORBIDDEN';
  elsif v_owner is distinct from v_actor
     or not exists(select 1 from public.donor_profiles dp where dp.user_id=v_actor) then
    v_reason:='DONATION_NOT_FOUND_OR_FORBIDDEN';
  elsif v_previous='CANCELLED' then
    -- Preserve deployed semantics: successful idempotent completion.
    v_outcome:='SUCCESS'; v_reason:='ALREADY_CANCELLED';
  elsif v_previous not in ('SUBMITTED','READY_FOR_PICKUP','HUB_ASSIGNED') then
    v_reason:='CANCELLATION_NOT_PERMITTED';
  elsif v_previous='READY_FOR_PICKUP' and v_path is distinct from 'DIRECT_PICKUP' then
    v_reason:='DONATION_COLLECTION_PATH_INCONSISTENT';
  elsif v_previous='READY_FOR_PICKUP' and v_listing is null then
    v_reason:='DIRECT_LISTING_MISSING';
  elsif v_path='HUB_COLLECTION' and v_listing is not null then
    v_reason:='DONATION_LISTING_PATH_INCONSISTENT';
  elsif exists(select 1 from public.hub_receipts where donation_id=p_donation)
     or exists(select 1 from public.hub_inventory where donation_id=p_donation)
     or exists(select 1 from public.hub_batch_members where donation_id=p_donation
               and membership_status='ACTIVE') then
    v_reason:='DONATION_HAS_PHYSICAL_CUSTODY';
  elsif exists(select 1 from public.pickup_tasks pt
     join public.donation_claims c on c.claim_id = pt.claim_id
     join public.listings l on l.listing_id = c.listing_id
    where l.source_type='DIRECT_DONATION' and l.donation_id=p_donation
      and pt.task_status in ('DISPATCHED','COLLECTED')) then
    v_reason:='PICKUP_HANDOVER_MAY_HAVE_OCCURRED';
  elsif exists(select 1 from public.donation_claims c
    join public.listings l using(listing_id)
    left join public.claim_leases le using(claim_id)
    where l.source_type='DIRECT_DONATION' and l.donation_id=p_donation
      and (c.claim_status in ('ACTIVE','RECONCILIATION_REQUIRED')
        or le.lease_status in ('ACTIVE','RECONCILIATION_REQUIRED')))
    or v_listing_status='CLAIMED' then
    v_reason:='DONATION_HAS_ACTIVE_CLAIM';
  elsif v_listing_status in ('CLOSED','CANCELLED') then
    v_reason:='LISTING_NOT_CANCELLABLE';
  elsif v_previous='HUB_ASSIGNED' and v_path is distinct from 'HUB_COLLECTION' then
    v_reason:='DONATION_COLLECTION_PATH_INCONSISTENT';
  elsif v_path is distinct from 'HUB_COLLECTION' and exists(
    select 1 from public.hub_reservations r where r.donation_id=p_donation) then
    v_reason:='DONATION_RESERVATION_PATH_INCONSISTENT';
  elsif v_previous='SUBMITTED' and v_path='HUB_COLLECTION'
      and exists(select 1 from public.hub_reservations r where r.donation_id=p_donation) then
    v_reason:='HUB_RESERVATION_STATE_INCONSISTENT';
  elsif v_previous='HUB_ASSIGNED' and not exists(
    select 1 from public.hub_reservations r where r.donation_id=p_donation) then
    v_reason:='HUB_RESERVATION_HISTORY_MISSING';
  elsif v_previous='HUB_ASSIGNED' and exists(
    select 1 from public.hub_reservations r where r.donation_id=p_donation
      and r.reservation_status in ('RELEASED','CONSUMED')) then
    v_reason:='HUB_RESERVATION_HISTORY_INCONSISTENT';
  elsif v_previous='HUB_ASSIGNED' and exists(
    select 1 from public.hub_reservations r where r.donation_id=p_donation
      and r.reservation_status='EXPIRED' and r.expires_at>clock_timestamp()) then
    v_reason:='HUB_RESERVATION_HISTORY_INCONSISTENT';
  elsif v_previous='HUB_ASSIGNED' and (select count(*) from public.hub_reservations r
      where r.donation_id=p_donation and r.reservation_status='ACTIVE')>1 then
    v_reason:='MULTIPLE_ACTIVE_HUB_RESERVATIONS';
  else
    if v_path='HUB_COLLECTION' then
      select count(*) into v_active_count from public.hub_reservations
      where donation_id=p_donation and reservation_status='ACTIVE';
      select * into v_latest_res from public.hub_reservations
      where donation_id=p_donation
      order by reserved_at desc,reservation_id desc limit 1;
      if v_previous='HUB_ASSIGNED' and v_latest_res.reservation_id is null then
        v_reason:='HUB_RESERVATION_HISTORY_MISSING';
      elsif v_previous='HUB_ASSIGNED' and v_latest_res.reservation_status not in ('ACTIVE','EXPIRED') then
        v_reason:='HUB_RESERVATION_HISTORY_INCONSISTENT';
      elsif v_previous='HUB_ASSIGNED' and v_active_count=1
          and v_latest_res.reservation_status<>'ACTIVE' then
        v_reason:='HUB_RESERVATION_HISTORY_INCONSISTENT';
      elsif v_previous='HUB_ASSIGNED' and v_active_count=0
          and (v_latest_res.reservation_status<>'EXPIRED'
            or v_latest_res.expires_at>clock_timestamp()) then
        v_reason:='HUB_RESERVATION_HISTORY_INCONSISTENT';
      elsif v_latest_res.reservation_status='ACTIVE' then
        -- The donation lock serializes receipt, reassignment and cancellation.
        -- Lock the hub before the reservation, then revalidate every field.
        v_res:=v_latest_res;
        perform 1 from public.community_hubs where hub_id=v_res.hub_id for update;
        select * into v_hub from public.community_hubs where hub_id=v_res.hub_id;
        if not found then
          v_reason:='HUB_RESERVATION_HUB_MISSING';
        else
        select * into v_res from public.hub_reservations
        where reservation_id=v_res.reservation_id for update;
        if not found or v_res.donation_id<>p_donation or v_res.hub_id is distinct from v_latest_res.hub_id
            or v_res.reservation_status<>'ACTIVE' then
          v_reason:='HUB_RESERVATION_CHANGED';
        elsif v_res.expires_at<=clock_timestamp() then
          update public.hub_reservations set reservation_status='EXPIRED'
          where reservation_id=v_res.reservation_id and reservation_status='ACTIVE';
          v_res_old_status:='ACTIVE'; v_res_new_status:='EXPIRED';
        else
            update public.hub_reservations set reservation_status='RELEASED'
            where reservation_id=v_res.reservation_id and reservation_status='ACTIVE';
            v_res_old_status:='ACTIVE'; v_res_new_status:='RELEASED';
        end if;
        end if;
      end if;
    end if;
    if v_reason is not null and v_reason<>'DONOR_REQUEST' then
      v_outcome:='REJECTED';
    else
    -- A current reservation is RELEASED atomically; an expired reservation
    -- is marked EXPIRED and retained. Both are compatible with cancellation.
    v_reason:='DONOR_REQUEST';
    update public.donations set donation_status='CANCELLED'
    where donation_id=p_donation;
    if v_listing is not null and v_listing_status='AVAILABLE' then
      update public.listings set listing_status='CANCELLED',
        listing_version=listing_version+1
      where listing_id=v_listing and listing_status='AVAILABLE';
    end if;
    v_outcome:='SUCCESS';
    if v_res_old_status is not null then
      insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
        event_type,previous_state,requested_state,resulting_state,reason_code,
        outcome,request_id,correlation_id,details,configuration_version)
      select v_actor,v_actor_role,'HUB_RESERVATION',v_res.reservation_id,
        case when v_res_new_status='EXPIRED' then 'EXPIRE_HUB_RESERVATION'
             else 'RELEASE_HUB_RESERVATION' end,
        v_res_old_status,v_res_new_status,v_res_new_status,
        case when v_res_new_status='EXPIRED' then 'RESERVATION_TIMEOUT'
             else 'DONOR_CANCELLATION' end,
        'SUCCESS',p_request,p_request,
        jsonb_build_object('donation_id',p_donation,'hub_id',v_res.hub_id),
        c.config_version
      from public.coordination_config c where c.singleton;
    end if;
    end if;
  end if;

  if v_outcome is distinct from 'SUCCESS' then v_outcome:='REJECTED'; end if;
  v_result_state:=case when v_outcome='SUCCESS' then 'CANCELLED' else v_previous end;
  v_response:=jsonb_build_object('outcome',v_outcome,'donation_id',p_donation,
    'reason_code',v_reason,'resulting_state',v_result_state);
  update public.donation_cancellation_requests set response=v_response,
    completed_at=clock_timestamp() where request_id=p_request;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    request_id,correlation_id,previous_state,requested_state,resulting_state,
    reason_code,outcome,details,configuration_version)
  select v_actor,v_actor_role,'DONATION',p_donation,'CANCEL_DONATION',p_request,p_request,
    v_previous,'CANCELLED',v_result_state,v_reason,v_outcome,
    jsonb_build_object('request_id',p_request,
      'reservation_id',case when v_res.reservation_id is null then null
        else v_res.reservation_id end,
      'reservation_result',v_res_new_status),c.config_version
  from public.coordination_config c where c.singleton;
  return v_response;
end;
$$;
notify pgrst, 'reload schema';
commit;