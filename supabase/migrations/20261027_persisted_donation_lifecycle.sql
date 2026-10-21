-- DEV review-only deployment artifact. Do not run against the shared project.
-- Persisted donation lifecycle; apply after 20261026 and both async refresh migrations.
-- Run as postgres in one transaction during a brief writer maintenance window.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '10min';
lock table public.donations, public.listings, public.donation_claims,
  public.claim_leases, public.pickup_tasks, public.hub_batches,
  public.hub_batch_members, public.hub_inventory in share row exclusive mode;

-- Abort rather than infer physical progress or discard ambiguous claim evidence.
do $preflight$
begin
  if not exists(select 1 from public.coordination_config where singleton
    and donation_direct_min_kg=10 and geofence_radius_m=20000
    and claim_lease_minutes=360 and hub_reservation_minutes=120) then
    raise exception 'LIFECYCLE_CONFIG_MISMATCH';
  end if;
  if exists(select 1 from public.donations where collection_path is null
    or total_weight_kg is null or total_weight_kg<=0
    or (collection_path='DIRECT_PICKUP') is distinct from (total_weight_kg>=10)
    or (donation_status='READY_FOR_PICKUP' and collection_path<>'DIRECT_PICKUP')) then
    raise exception 'LIFECYCLE_BACKFILL_INVALID_CLASSIFICATION';
  end if;
  if exists(
    select 1 from public.donations d
    left join public.listings l on l.donation_id=d.donation_id and l.source_type='DIRECT_DONATION'
    where d.donation_status='READY_FOR_PICKUP' and (
      l.listing_id is null or l.listing_status not in ('AVAILABLE','CLAIMED')
      or (l.listing_status='AVAILABLE' and exists(select 1 from public.donation_claims c
        where c.listing_id=l.listing_id and c.claim_status in ('ACTIVE','RECONCILIATION_REQUIRED')))
      or (l.listing_status='CLAIMED' and not exists(
        select 1 from public.donation_claims c join public.claim_leases le using(claim_id)
        join public.pickup_tasks t using(claim_id)
        where c.listing_id=l.listing_id and t.listing_id=l.listing_id
          and c.claim_status in ('ACTIVE','RECONCILIATION_REQUIRED')
          and le.lease_status=c.claim_status and t.task_status in ('CONFIRMED','PLANNED'))))) then
    raise exception 'LIFECYCLE_BACKFILL_AMBIGUOUS_DIRECT_EVIDENCE';
  end if;
  if exists(select 1 from public.listings l
    where l.source_type='HUB_BATCH' and l.listing_status='CLAIMED'
      and (not exists(select 1 from public.donation_claims c join public.claim_leases le using(claim_id)
        join public.pickup_tasks t using(claim_id)
        where c.listing_id=l.listing_id and c.claim_status in ('ACTIVE','RECONCILIATION_REQUIRED')
          and le.lease_status=c.claim_status and t.task_status in ('CONFIRMED','PLANNED','DISPATCHED'))
      or exists(select 1 from public.hub_batch_members m join public.donations d using(donation_id)
        where m.batch_id=l.batch_id and m.membership_status='ACTIVE'
          and d.donation_status not in ('BATCHED','PICKUP_IN_PROGRESS')))) then
    raise exception 'LIFECYCLE_BACKFILL_AMBIGUOUS_BATCH_EVIDENCE';
  end if;
  if exists(select 1 from public.hub_batches b
    join public.listings l on l.batch_id=b.batch_id and l.source_type='HUB_BATCH'
    where l.listing_status in ('AVAILABLE','CLAIMED') and (
      b.batch_status<>'PUBLISHED' or b.batch_donation_count<=0
      or b.batch_donation_count<>(select count(*) from public.hub_batch_members m
        where m.batch_id=b.batch_id and m.membership_status='ACTIVE')
      or exists(select 1 from public.hub_batch_members m
        where m.batch_id=b.batch_id and m.membership_status='ACTIVE'
          and not exists(select 1 from public.hub_inventory hi
            where hi.donation_id=m.donation_id and hi.hub_id=b.hub_id and hi.inventory_status='BATCHED')))) then
    raise exception 'LIFECYCLE_BACKFILL_INCOMPLETE_BATCH';
  end if;
end;
$preflight$;

-- The existing transition trigger is removed only within this locked transaction;
-- no concurrent writer can observe the temporary backfill exemption.
drop trigger trg_donation_transition on public.donations;
alter table public.donations drop constraint donations_donation_status_check;
alter table public.donations alter column donation_status set default 'SUBMITTED';

with changed as (
  update public.donations d set donation_status=case when l.listing_status='AVAILABLE'
    then 'AVAILABLE' else 'CLAIMED' end
  from public.listings l where l.donation_id=d.donation_id
    and l.source_type='DIRECT_DONATION' and d.donation_status='READY_FOR_PICKUP'
  returning d.donation_id,d.donation_status
)
insert into public.audit_events(actor_role,entity_type,entity_id,event_type,
  previous_state,resulting_state,outcome,details)
select 'SYSTEM','DONATION',donation_id,'DONATION_STATUS_BACKFILL',
  'READY_FOR_PICKUP',donation_status,'SUCCESS',
  jsonb_build_object('migration','20261027_persisted_donation_lifecycle') from changed;

with changed as (
  update public.donations d set donation_status='CLAIMED'
  from public.hub_batch_members m join public.listings l on l.batch_id=m.batch_id
    and l.source_type='HUB_BATCH'
  where d.donation_id=m.donation_id and m.membership_status='ACTIVE'
    and d.donation_status='BATCHED' and l.listing_status='CLAIMED'
    and exists(select 1 from public.donation_claims c join public.pickup_tasks t using(claim_id)
      where c.listing_id=l.listing_id and c.claim_status in ('ACTIVE','RECONCILIATION_REQUIRED')
        and t.task_status in ('CONFIRMED','PLANNED'))
  returning d.donation_id
)
insert into public.audit_events(actor_role,entity_type,entity_id,event_type,
  previous_state,resulting_state,outcome,details)
select 'SYSTEM','DONATION',donation_id,'DONATION_STATUS_BACKFILL','BATCHED','CLAIMED','SUCCESS',
  jsonb_build_object('migration','20261027_persisted_donation_lifecycle') from changed;

alter table public.donations add constraint donations_donation_status_check
check(donation_status in ('SUBMITTED','AVAILABLE','HUB_ASSIGNED','AT_HUB','BATCHED',
  'CLAIMED','PICKUP_IN_PROGRESS','COLLECTED','CANCELLED'));

-- Internal helpers execute under the calling SECURITY DEFINER RPC's postgres role.
-- No new client-callable coordination endpoint is introduced.
create function public.geolock_lock_listing_donations(p_listing uuid, p_states text[])
returns boolean language plpgsql
set search_path to 'pg_catalog','public','pg_temp'
as $function$
declare v_l public.listings%rowtype; v_b public.hub_batches%rowtype;
  v_id uuid; v_count integer:=0; v_ok boolean:=true; v_d public.donations%rowtype;
begin
  select * into v_l from public.listings where listing_id=p_listing for update;
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
alter function public.geolock_lock_listing_donations(uuid,text[]) owner to postgres;
revoke all on function public.geolock_lock_listing_donations(uuid,text[])
  from public,anon,authenticated,service_role;

create function public.geolock_transition_listing_donations(
  p_listing uuid,p_from text,p_to text)
returns void language plpgsql
set search_path to 'pg_catalog','public','pg_temp'
as $function$
declare v_l public.listings%rowtype; v_id uuid; v_claim uuid; v_lease uuid;
begin
  if not public.geolock_lock_listing_donations(p_listing,array[p_from]) then
    raise exception 'LISTING_DONATION_SET_STATE_MISMATCH';
  end if;
  select * into v_l from public.listings where listing_id=p_listing;
  select c.claim_id,le.lease_id into v_claim,v_lease
  from public.donation_claims c left join public.claim_leases le using(claim_id)
  where c.listing_id=p_listing order by c.claimed_at desc,c.claim_id desc limit 1;
  for v_id in
    select d.donation_id from public.donations d
    where (v_l.source_type='DIRECT_DONATION' and d.donation_id=v_l.donation_id)
      or (v_l.source_type='HUB_BATCH' and exists(select 1 from public.hub_batch_members m
        where m.batch_id=v_l.batch_id and m.donation_id=d.donation_id and m.membership_status='ACTIVE'))
    order by d.donation_id
  loop
    update public.donations set donation_status=p_to where donation_id=v_id and donation_status=p_from;
    if not found then raise exception 'LISTING_DONATION_SET_CHANGED'; end if;
    insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
      claim_id,lease_id,previous_state,requested_state,resulting_state,outcome,details)
    values(auth.uid(),case when auth.uid() is null then 'SYSTEM'
      else (select role from public.user_profiles where user_id=auth.uid()) end,
      'DONATION',v_id,'DONATION_STATUS_CHANGED',v_claim,v_lease,p_from,p_to,p_to,'SUCCESS',
      jsonb_build_object('listing_id',p_listing));
  end loop;
end;
$function$;
alter function public.geolock_transition_listing_donations(uuid,text,text) owner to postgres;
revoke all on function public.geolock_transition_listing_donations(uuid,text,text)
  from public,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.enforce_donation_transition()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public','pg_temp'
AS $function$
begin
  if new.donation_status is distinct from old.donation_status and not (
    (old.donation_status='SUBMITTED' and new.donation_status='AVAILABLE'
      and new.collection_path='DIRECT_PICKUP' and new.total_weight_kg>=10)
    or (old.donation_status='SUBMITTED' and new.donation_status='HUB_ASSIGNED'
      and new.collection_path='HUB_COLLECTION' and new.total_weight_kg>0 and new.total_weight_kg<10)
    or (old.donation_status in ('SUBMITTED','AVAILABLE','HUB_ASSIGNED') and new.donation_status='CANCELLED')
    or (old.donation_status='AVAILABLE' and new.donation_status='CLAIMED' and new.collection_path='DIRECT_PICKUP')
    or (old.donation_status='HUB_ASSIGNED' and new.donation_status='AT_HUB')
    or (old.donation_status='AT_HUB' and new.donation_status='BATCHED')
    or (old.donation_status='BATCHED' and new.donation_status='CLAIMED' and new.collection_path='HUB_COLLECTION')
    or (old.donation_status='CLAIMED' and new.donation_status='PICKUP_IN_PROGRESS')
    or (old.donation_status='CLAIMED' and new.donation_status='AVAILABLE' and new.collection_path='DIRECT_PICKUP')
    or (old.donation_status='CLAIMED' and new.donation_status='BATCHED' and new.collection_path='HUB_COLLECTION')
    or (old.donation_status='PICKUP_IN_PROGRESS' and new.donation_status='COLLECTED')
  ) then
    raise exception 'INVALID_DONATION_TRANSITION: % -> %',old.donation_status,new.donation_status;
  end if;
  new.updated_at=clock_timestamp();
  return new;
end;
$function$;
create trigger trg_donation_transition before update on public.donations
for each row execute function public.enforce_donation_transition();

CREATE OR REPLACE FUNCTION public.create_and_validate_donation(p_title text, p_description text, p_pickup_address text, p_latitude double precision, p_longitude double precision, p_items jsonb, p_pickup_road_node_id text DEFAULT NULL::text, p_availability_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_availability_end timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid(); v_donation uuid; v_item jsonb;
  v_count integer:=0; v_weight numeric(12,3):=0; v_threshold numeric(12,3);
  v_path text; v_category uuid; v_qty integer; v_unit numeric(12,3);
  v_status text;
begin
  if v_actor is null or not exists(
    select 1 from public.donor_profiles where user_id=v_actor
  ) then raise exception 'DONOR_ONLY'; end if;
  if nullif(btrim(p_title),'') is null or nullif(btrim(p_pickup_address),'') is null
     or p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'INVALID_DONATION_LOCATION_OR_TITLE';
  end if;
  if nullif(btrim(coalesce(p_description,'')),'') is null then
    raise exception 'DONATION_DESCRIPTION_REQUIRED';
  end if;
  if char_length(p_description)>1000 then
    raise exception 'DONATION_DESCRIPTION_TOO_LONG';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'AT_LEAST_ONE_ITEM_REQUIRED';
  end if;
  if jsonb_array_length(p_items)=0 then raise exception 'AT_LEAST_ONE_ITEM_REQUIRED'; end if;
  select donation_direct_min_kg into v_threshold
  from public.coordination_config where singleton;
  if v_threshold is null then raise exception 'DONATION_THRESHOLD_NOT_CONFIGURED'; end if;

  -- The parent must temporarily be SUBMITTED so V3's item guard permits these
  -- inserts. This row is not externally visible until the whole RPC commits.
  insert into public.donations(
    donor_user_id,title,description,pickup_address,latitude,longitude,
    pickup_road_node_id,availability_start,availability_end,donation_status
  ) values(
    v_actor,p_title,p_description,p_pickup_address,p_latitude,p_longitude,
    p_pickup_road_node_id,null,null,'SUBMITTED'
  ) returning donation_id into v_donation;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_category:=(v_item->>'category_id')::uuid;
    v_qty:=(v_item->>'quantity')::integer;
    v_unit:=(v_item->>'unit_weight_kg')::numeric;
    if v_qty is null or v_qty<=0 or v_unit is null or v_unit<=0
       or nullif(btrim(v_item->>'item_name'),'') is null
       or not exists(select 1 from public.donation_categories
         where category_id=v_category and active_flag) then
      raise exception 'INVALID_DONATION_ITEM';
    end if;
    insert into public.donation_items(
      donation_id,category_id,item_name,description,quantity,unit_label,
      unit_weight_kg,item_condition
    ) values(
      v_donation,v_category,v_item->>'item_name',v_item->>'description',
      v_qty,coalesce(v_item->>'unit_label','piece'),v_unit,
      coalesce(v_item->>'item_condition','GOOD')
    );
    v_count:=v_count+1;
    v_weight:=v_weight+(v_qty*v_unit);
  end loop;
  if v_count=0 or v_weight<=0 then raise exception 'INVALID_TOTAL_WEIGHT'; end if;

  v_path:=case when v_weight>=v_threshold then 'DIRECT_PICKUP' else 'HUB_COLLECTION' end;
  v_status:=case when v_path='DIRECT_PICKUP' then 'AVAILABLE' else 'SUBMITTED' end;
  update public.donations set donation_status=v_status,
    collection_path=v_path,total_weight_kg=v_weight
  where donation_id=v_donation;

  if v_path='DIRECT_PICKUP' then
    insert into public.listings(
      source_type,donation_id,listing_weight_kg,pickup_latitude,
      pickup_longitude,pickup_road_node_id,listing_expires_at
    ) values(
      'DIRECT_DONATION',v_donation,v_weight,p_latitude,p_longitude,
      p_pickup_road_node_id,null
    );
  end if;

  insert into public.audit_events(
    actor_user_id,actor_role,entity_type,entity_id,event_type,
    previous_state,requested_state,resulting_state,outcome,details,configuration_version
  )
  select v_actor,'DONOR','DONATION',v_donation,'CREATE_DONATION',
    null,v_status,v_status,'SUCCESS',
    jsonb_build_object('validation_passed',true,'weight_kg',v_weight,
      'collection_path',v_path,'threshold_kg',v_threshold),c.config_version
  from public.coordination_config c where c.singleton;
  return v_donation;
end;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_donation(p_donation uuid, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
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
  elsif v_previous not in ('SUBMITTED','AVAILABLE','HUB_ASSIGNED') then
    v_reason:='CANCELLATION_NOT_PERMITTED';
  elsif v_previous='AVAILABLE' and v_path is distinct from 'DIRECT_PICKUP' then
    v_reason:='DONATION_COLLECTION_PATH_INCONSISTENT';
  elsif v_previous='AVAILABLE' and v_listing is null then
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
$function$;

CREATE OR REPLACE FUNCTION public.discover_eligible_listing_cards()
 RETURNS TABLE(listing_id uuid, source_type text, title text, listing_weight_kg numeric, listing_created_at timestamp with time zone, collection_path text, distance_m double precision, routing_status text, primary_image_path text, batch_id uuid, donation_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_ngo public.ngo_profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles
   where user_id=auth.uid() and active_flag;
  if not found or v_ngo.location_verified_at is null then return; end if;
  return query
  select l.listing_id,l.source_type,
    case when l.source_type='DIRECT_DONATION' then d.title else 'Community Hub Batch' end,
    l.listing_weight_kg,l.created_at,
    case when l.source_type='DIRECT_DONATION' then d.collection_path else 'HUB_COLLECTION' end,
    public.geolock_road_eligible_km(v_ngo.user_id,l.listing_id)*1000,
    'READY'::text,
    case
      when l.source_type='DIRECT_DONATION'
        and public.can_read_geolock_donation_image(di.storage_path) then di.storage_path
      when l.source_type='HUB_BATCH'
        and public.can_read_geolock_batch_image(bi.storage_path) then bi.storage_path
      when l.source_type='HUB_BATCH'
        and public.can_read_geolock_donation_image(member_img.storage_path) then member_img.storage_path
      else null
    end,
    l.batch_id,l.donation_id
  from public.listings l
  join public.coordination_config cfg on cfg.singleton
  left join public.donations d on d.donation_id=l.donation_id
  left join public.hub_batches b on b.batch_id=l.batch_id
  left join lateral(select i.storage_path from public.donation_images i
    where i.donation_id=d.donation_id and i.display_order=1 limit 1) di on true
  left join lateral(select i.storage_path from public.hub_batch_images i
    where i.batch_id=b.batch_id and i.is_primary limit 1) bi on true
  left join lateral(select i.storage_path from public.hub_batch_members m
    join public.donation_images i on i.donation_id=m.donation_id and i.display_order=1
    join public.donations md on md.donation_id=m.donation_id
    where m.batch_id=b.batch_id and m.membership_status='ACTIVE'
    order by md.created_at,md.donation_id limit 1) member_img on true
  where l.listing_status='AVAILABLE'
    and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
    and public.geolock_road_eligible_km(v_ngo.user_id,l.listing_id) is not null
    and ((l.source_type='DIRECT_DONATION' and d.donation_status='AVAILABLE')
      or (l.source_type='HUB_BATCH' and b.batch_status='PUBLISHED'))
  order by l.created_at desc;
end;
$function$;

CREATE OR REPLACE FUNCTION public.discover_eligible_listings()
 RETURNS TABLE(listing_id uuid, source_type text, listing_weight_kg numeric, listing_created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_actor uuid:=auth.uid();v_ngo public.ngo_profiles%rowtype;
begin
 select * into v_ngo from public.ngo_profiles where user_id=v_actor and active_flag;
 if not found or v_ngo.location_verified_at is null then return; end if;
 return query
 select l.listing_id,l.source_type,l.listing_weight_kg,l.created_at
 from public.listings l join public.coordination_config cfg on cfg.singleton
 where l.listing_status='AVAILABLE'
 and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
 and public.geolock_road_eligible_km(v_ngo.user_id,l.listing_id) is not null
 and ((l.source_type='DIRECT_DONATION' and exists(
   select 1 from public.donations d where d.donation_id=l.donation_id
   and d.donation_status='AVAILABLE'))
 or (l.source_type='HUB_BATCH' and exists(
   select 1 from public.hub_batches b where b.batch_id=l.batch_id
   and b.batch_status='PUBLISHED')))
 order by l.created_at desc;
end $function$;

CREATE OR REPLACE FUNCTION public.get_eligible_listing_constituents(p_listing uuid)
 RETURNS TABLE(donation_id uuid, title text, total_weight_kg numeric, donation_status text, primary_image_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_ngo public.ngo_profiles%rowtype; v_listing public.listings%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles where user_id=auth.uid() and active_flag;
  if not found or v_ngo.location_verified_at is null then raise exception 'VERIFIED_NGO_ONLY'; end if;
  select l.* into v_listing from public.listings l
   where l.listing_id=p_listing and l.listing_status='AVAILABLE'
     and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
     and public.geolock_road_eligible_km(v_ngo.user_id,l.listing_id) is not null
     and ((l.source_type='DIRECT_DONATION' and exists(select 1 from public.donations d
       where d.donation_id=l.donation_id and d.donation_status='AVAILABLE'))
       or (l.source_type='HUB_BATCH' and exists(select 1 from public.hub_batches b
         where b.batch_id=l.batch_id and b.batch_status='PUBLISHED')));
  if not found then raise exception 'LISTING_NOT_ELIGIBLE'; end if;
  return query
  select d.donation_id,d.title,d.total_weight_kg,d.donation_status,
    case when public.can_read_geolock_donation_image(i.storage_path) then i.storage_path end
  from public.donations d
  left join lateral(select x.storage_path from public.donation_images x
    where x.donation_id=d.donation_id and x.display_order=1 limit 1) i on true
  where (v_listing.source_type='DIRECT_DONATION' and d.donation_id=v_listing.donation_id)
     or (v_listing.source_type='HUB_BATCH' and exists(select 1 from public.hub_batch_members m
       where m.batch_id=v_listing.batch_id and m.donation_id=d.donation_id
         and m.membership_status='ACTIVE'))
  order by d.created_at,d.donation_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.can_read_geolock_donation_image(p_path text)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
  select auth.uid() is not null and exists(
    select 1 from public.donation_images i
    join public.donations d using(donation_id)
    where i.storage_path=p_path and (
      d.donor_user_id=auth.uid()
      or exists(
        select 1 from public.ngo_profiles n
        join public.listings l on l.donation_id=d.donation_id
          and l.source_type='DIRECT_DONATION'
        where n.user_id=auth.uid() and n.active_flag
          and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c
            left join public.claim_leases le using(claim_id)
            where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
              and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE'
                    and le.expires_at>clock_timestamp())))
          and public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null
      )
      or exists(
        select 1 from public.ngo_profiles n
        join public.listings l on l.donation_id=d.donation_id
          and l.source_type='DIRECT_DONATION'
        where n.user_id=auth.uid() and n.active_flag
          and n.location_verified_at is not null
          and l.listing_status='AVAILABLE'
          and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
          and d.donation_status='AVAILABLE'
          and public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null
      )
      or exists(
        select 1 from public.ngo_profiles n
        join public.hub_batch_members m on m.donation_id=d.donation_id
          and m.membership_status='ACTIVE'
        join public.listings l on l.batch_id=m.batch_id and l.source_type='HUB_BATCH'
        join public.hub_batches b on b.batch_id=m.batch_id and b.batch_status='PUBLISHED'
        where n.user_id=auth.uid() and n.active_flag
          and n.location_verified_at is not null
          and l.listing_status='AVAILABLE'
          and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
          and public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null
      )
      -- Preserve claimant access after a batch listing leaves AVAILABLE.
      or exists(
        select 1 from public.ngo_profiles n
        join public.coordination_config cfg on cfg.singleton
        join public.hub_batch_members m on m.donation_id=d.donation_id
          and m.membership_status='ACTIVE'
        join public.listings l on l.batch_id=m.batch_id and l.source_type='HUB_BATCH'
        join public.hub_batches b on b.batch_id=m.batch_id and b.batch_status='PUBLISHED'
        where n.user_id=auth.uid() and n.active_flag
          and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c
            left join public.claim_leases le using(claim_id)
            where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
              and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE'
                    and le.expires_at>clock_timestamp())))
          and public.geolock_road_eligible_km(n.user_id,l.listing_id) is not null
      )
      or exists(select 1 from public.hub_reservations r
        join public.community_hubs h using(hub_id)
        where r.donation_id=d.donation_id and h.admin_user_id=auth.uid()
          and r.reservation_status='ACTIVE' and r.expires_at>clock_timestamp())
      or exists(select 1 from public.hub_inventory hi
        join public.community_hubs h using(hub_id)
        where hi.donation_id=d.donation_id and h.admin_user_id=auth.uid())
    )
  );
$function$;

CREATE OR REPLACE FUNCTION public.geolock_backfill_road_nodes()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_hubs integer; v_listings integer; v_donations integer; v_ngos integer := 0;
  v_rows integer; r record;
begin
  if coalesce(auth.role(), '') <> 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    raise exception 'TRUSTED_OPERATOR_ONLY';
  end if;

  update public.community_hubs set road_node_id = null;   -- trigger re-resolves
  get diagnostics v_hubs = row_count;

  update public.donations d
     set pickup_road_node_id = r2.node_id
    from public.donations d2
    left join lateral public.geolock_resolve_road_node(d2.latitude, d2.longitude) r2 on true
   where d.donation_id = d2.donation_id
     and d.donation_status in ('SUBMITTED','AVAILABLE','HUB_ASSIGNED')
     and d.pickup_road_node_id is distinct from r2.node_id;
  get diagnostics v_donations = row_count;

  update public.listings l
     set pickup_road_node_id = r2.node_id
    from public.listings l2
    left join lateral public.geolock_resolve_road_node(l2.pickup_latitude, l2.pickup_longitude) r2 on true
   where l.listing_id = l2.listing_id
     and l.listing_status = 'AVAILABLE'
     and l.pickup_road_node_id is distinct from r2.node_id;
  get diagnostics v_listings = row_count;

  -- Re-check verified NGOs against the new snapshot (verification is kept only
  -- if the stored location still snaps within 500 m).
  for r in select n.user_id, n.latitude, n.longitude from public.ngo_profiles n
            where n.location_verified_at is not null loop
    update public.ngo_profiles
       set road_node_id = (select x.node_id from public.geolock_resolve_road_node(r.latitude, r.longitude) x)
     where user_id = r.user_id;
    update public.vehicles set depot_road_node_id = null where ngo_user_id = r.user_id;
    perform public.geolock_refresh_ngo_road_eligibility(r.user_id);
    v_ngos := v_ngos + 1;
  end loop;
  select count(*) into v_rows from public.ngo_listing_road_eligibility;

  return jsonb_build_object('hubs_rechecked', v_hubs, 'donations_changed', v_donations,
    'listings_changed', v_listings, 'ngos_rechecked', v_ngos, 'eligibility_rows', v_rows);
end $function$;

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

CREATE OR REPLACE FUNCTION public.recover_expired_claims(p_limit integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_rec record; v_c public.donation_claims%rowtype; v_le public.claim_leases%rowtype;
  v_l public.listings%rowtype; v_t public.pickup_tasks%rowtype;
  v_uncertain boolean; v_count integer:=0; v_did uuid; v_cfg text;
begin
  if auth.role() is distinct from 'service_role' and session_user <> 'postgres' then
    raise exception 'TRUSTED_SCHEDULER_ONLY';
  end if;
  for v_rec in
    select c.claim_id,cl.lease_id,cl.expires_at from public.donation_claims c
    join public.claim_leases cl using(claim_id)
    where c.claim_status='ACTIVE' and cl.lease_status='ACTIVE' and cl.expires_at<=clock_timestamp()
    order by cl.expires_at,c.claim_id
    for update of c skip locked
    limit greatest(1,least(coalesce(p_limit,100),1000))
  loop
    select c.* into v_c from public.donation_claims c where c.claim_id=v_rec.claim_id;
    -- Current row lock was obtained on claim above; follow V3 writer order.
    select le.* into v_le from public.claim_leases le where le.lease_id=v_rec.lease_id for update;
    if v_c.claim_status<>'ACTIVE' or v_le.lease_status<>'ACTIVE'
       or v_le.expires_at>clock_timestamp() then continue; end if;
    select l.* into v_l from public.listings l where l.listing_id=v_c.listing_id for update;
    select t.* into v_t from public.pickup_tasks t where t.claim_id=v_c.claim_id for update;

    v_uncertain := v_l.listing_id is null
      or v_t.task_id is null
      or v_l.listing_status<>'CLAIMED'
      or v_t.task_status<>'CONFIRMED'
      or exists(select 1 from public.active_task_route_assignments a where a.task_id=v_t.task_id)
      or exists(select 1 from public.pickup_route_stops s
        where s.task_id=v_t.task_id)
      or (v_l.source_type='DIRECT_DONATION' and exists(select 1 from public.donations d
        where d.donation_id=v_l.donation_id and d.donation_status in ('PICKUP_IN_PROGRESS','COLLECTED','DELIVERED')))
      or (v_l.source_type='HUB_BATCH' and exists(select 1 from public.hub_batch_members m
        join public.donations d using(donation_id) where m.batch_id=v_l.batch_id
        and m.membership_status='ACTIVE' and d.donation_status in ('PICKUP_IN_PROGRESS','COLLECTED','DELIVERED')));
    if v_l.source_type='DIRECT_DONATION' then
      v_uncertain:=v_uncertain or not exists(select 1 from public.donations d
        where d.donation_id=v_l.donation_id and d.donation_status='CLAIMED');
    elsif v_l.source_type='HUB_BATCH' then
      v_uncertain:=v_uncertain
        or not exists(select 1 from public.hub_batch_members m
          where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE')
        or exists(select 1 from public.hub_batch_members m join public.donations d using(donation_id)
          where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'
            and d.donation_status<>'CLAIMED')
        or exists(select 1 from public.hub_batch_members m join public.hub_inventory hi using(donation_id)
          where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'
            and hi.inventory_status<>'BATCHED');
    end if;
    -- An expired listing cannot be safely reopened; retain custody for reconciliation.
    v_uncertain:=v_uncertain
      or (v_l.listing_expires_at is not null and v_l.listing_expires_at<=clock_timestamp());
    if v_l.listing_id is not null then
      v_uncertain:=not public.geolock_lock_listing_donations(v_l.listing_id,array['CLAIMED']) or v_uncertain;
    end if;
    if v_uncertain then
      update public.claim_leases set lease_status='RECONCILIATION_REQUIRED' where lease_id=v_le.lease_id;
      update public.donation_claims set claim_status='RECONCILIATION_REQUIRED' where claim_id=v_c.claim_id;
      if v_l.listing_id is not null then
        insert into public.claim_reconciliation_cases(claim_id,listing_id,donation_id,source_type,case_status)
          values(v_c.claim_id,v_l.listing_id,v_l.donation_id,v_l.source_type,'OPEN')
          on conflict(claim_id) do nothing;
      end if;
    else
      update public.claim_leases set lease_status='RELEASED',closed_at=clock_timestamp(),release_reason='EXPIRED_SAFE_RELEASE'
        where lease_id=v_le.lease_id;
      update public.donation_claims set claim_status='RELEASED',closed_at=clock_timestamp(),close_reason='EXPIRED_SAFE_RELEASE'
        where claim_id=v_c.claim_id;
      update public.pickup_tasks set task_status='STALE' where task_id=v_t.task_id;
      if v_l.listing_status='CLAIMED' and (v_l.listing_expires_at is null or v_l.listing_expires_at>clock_timestamp()) then
        update public.listings set listing_status='AVAILABLE',listing_version=listing_version+1
          where listing_id=v_l.listing_id and listing_status='CLAIMED';
        perform public.geolock_transition_listing_donations(v_l.listing_id,'CLAIMED',
          case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end);
      end if;
    end if;
    select c.config_version into v_cfg from public.coordination_config c where c.singleton;
    insert into public.audit_events(actor_role,entity_type,entity_id,event_type,claim_id,lease_id,
      correlation_id,previous_state,requested_state,resulting_state,reason_code,outcome,
      software_version,configuration_version,details)
    values('SYSTEM','CLAIM',v_c.claim_id,'LEASE_RECOVERY',v_c.claim_id,v_le.lease_id,
      gen_random_uuid(),'ACTIVE',case when v_uncertain then 'RECONCILIATION_REQUIRED' else 'RELEASED' end,
      case when v_uncertain then 'RECONCILIATION_REQUIRED' else 'RELEASED' end,
      case when v_uncertain then 'HANDOVER_OR_ROUTE_ACTIVITY_UNCERTAIN' else 'EXPIRED_SAFE_RELEASE' end,
      'SUCCESS','geolock-stage1-2026-10-19',v_cfg,
      jsonb_build_object('donation_id',v_l.donation_id,
        'listing_id',v_l.listing_id,'task_id',v_t.task_id));
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$function$;

CREATE OR REPLACE FUNCTION public.submit_claim_reconciliation(p_claim uuid, p_handover_confirmed boolean, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid(); v_role text; v_case public.claim_reconciliation_cases%rowtype;
  v_c public.donation_claims%rowtype; v_l public.listings%rowtype;
  v_le public.claim_leases%rowtype; v_t public.pickup_tasks%rowtype;
  v_d public.donations%rowtype; v_counterpart uuid; v_allowed boolean := false;
  v_prior public.claim_reconciliation_evidence%rowtype; v_values integer; v_true integer;
  v_result jsonb; v_cfg text; v_did uuid;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_claim is null or p_request is null or p_handover_confirmed is null then
    raise exception 'CLAIM_EVIDENCE_REQUIRED'; end if;
  -- Same lock prefix as start/complete/recovery.
  select c.* into v_c from public.donation_claims c where c.claim_id=p_claim for update;
  if not found then raise exception 'CLAIM_NOT_FOUND'; end if;
  select le.* into v_le from public.claim_leases le where le.claim_id=p_claim for update;
  if not found then raise exception 'LEASE_NOT_FOUND'; end if;
  select l.* into v_l from public.listings l where l.listing_id=v_c.listing_id for update;
  if not found then raise exception 'LISTING_NOT_FOUND'; end if;
  select t.* into v_t from public.pickup_tasks t where t.claim_id=p_claim for update;
  if not found then raise exception 'PICKUP_TASK_NOT_FOUND'; end if;
  select p.role into v_role from public.user_profiles p where p.user_id=v_actor;
  select * into v_case from public.claim_reconciliation_cases c
    where c.claim_id=p_claim for update;
  if not found then raise exception 'RECONCILIATION_NOT_OPEN'; end if;

  if v_actor=v_c.ngo_user_id and v_role='NGO' then v_allowed:=true; end if;
  if v_l.source_type='DIRECT_DONATION' then
    select d.donor_user_id into v_counterpart from public.donations d where d.donation_id=v_l.donation_id;
    if v_actor=v_counterpart and v_role='DONOR' then v_allowed:=true; end if;
  elsif v_l.source_type='HUB_BATCH' then
    select h.admin_user_id into v_counterpart from public.hub_batches b
      join public.community_hubs h using(hub_id) where b.batch_id=v_l.batch_id;
    if v_actor=v_counterpart and v_role='HUB_ADMIN' then v_allowed:=true; end if;
  end if;
  if not v_allowed then raise exception 'RECONCILIATION_PARTICIPANT_ONLY'; end if;

  select * into v_prior from public.claim_reconciliation_evidence e where e.request_id=p_request;
  if found then
    if v_prior.case_id<>v_case.case_id or v_prior.actor_user_id<>v_actor
       or v_prior.handover_confirmed<>p_handover_confirmed then
      select c.config_version into v_cfg from public.coordination_config c where c.singleton;
      insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
        request_id,claim_id,lease_id,correlation_id,
        previous_state,requested_state,resulting_state,reason_code,outcome,
        software_version,configuration_version,details)
      values(v_actor,v_role,'CLAIM',p_claim,'CLAIM_RECONCILIATION_EVIDENCE',p_request,p_claim,
        v_le.lease_id,p_request,v_c.claim_status,
        case when p_handover_confirmed then 'COLLECTED' else 'RELEASED' end,
        v_c.claim_status,'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD','REJECTED',
        'geolock-stage1-2026-10-19',v_cfg,jsonb_build_object('donation_id',v_l.donation_id,
        'listing_id',v_l.listing_id,'case_id',v_case.case_id));
      return jsonb_build_object('outcome','REJECTED','reason_code','IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD');
    end if;
    if v_prior.response is not null then return v_prior.response; end if;
  else
  if v_c.claim_status<>'RECONCILIATION_REQUIRED'
     or v_le.lease_status<>'RECONCILIATION_REQUIRED'
     or v_l.listing_status<>'CLAIMED' then
    raise exception 'RECONCILIATION_STATE_MISMATCH';
  end if;
    if v_case.case_status not in ('OPEN','MANUAL_REVIEW') then
      raise exception 'RECONCILIATION_NOT_OPEN';
    end if;
    if exists(select 1 from public.claim_reconciliation_evidence e
        where e.case_id=v_case.case_id and e.actor_user_id=v_actor) then
      select c.config_version into v_cfg from public.coordination_config c where c.singleton;
      insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
        request_id,claim_id,lease_id,correlation_id,
        previous_state,requested_state,resulting_state,reason_code,outcome,
        software_version,configuration_version,details)
      values(v_actor,v_role,'CLAIM',p_claim,'CLAIM_RECONCILIATION_EVIDENCE',p_request,p_claim,
        v_le.lease_id,p_request,v_c.claim_status,
        case when p_handover_confirmed then 'COLLECTED' else 'RELEASED' end,
        v_c.claim_status,'EVIDENCE_ALREADY_SUBMITTED','REJECTED',
        'geolock-stage1-2026-10-19',v_cfg,jsonb_build_object('donation_id',v_l.donation_id,
        'listing_id',v_l.listing_id,'case_id',v_case.case_id));
      return jsonb_build_object('outcome','REJECTED','reason_code','EVIDENCE_ALREADY_SUBMITTED');
    end if;
    insert into public.claim_reconciliation_evidence(request_id,case_id,actor_user_id,handover_confirmed)
      values(p_request,v_case.case_id,v_actor,p_handover_confirmed);
  end if;

  if v_c.claim_status<>'RECONCILIATION_REQUIRED'
     or v_le.lease_status<>'RECONCILIATION_REQUIRED'
     or v_l.listing_status<>'CLAIMED' then
    raise exception 'RECONCILIATION_STATE_MISMATCH';
  end if;
  if v_case.case_status not in ('OPEN','MANUAL_REVIEW') then
    raise exception 'RECONCILIATION_NOT_OPEN';
  end if;
  -- Lock and validate the complete immutable member set before finalizing evidence.
  if not public.geolock_lock_listing_donations(v_l.listing_id,
    array['CLAIMED','PICKUP_IN_PROGRESS','COLLECTED']) then
    raise exception 'RECONCILIATION_DONATION_SET_REQUIRES_REVIEW';
  end if;
  select count(*),count(*) filter(where e.handover_confirmed)
    into v_values,v_true from public.claim_reconciliation_evidence e where e.case_id=v_case.case_id;
  if v_values<2 then
    v_result:=jsonb_build_object('outcome','AWAITING_COUNTERPART','case_id',v_case.case_id,
      'reason_code','SECOND_PARTY_CONFIRMATION_REQUIRED');
  elsif v_true not in (0,2) then
    update public.claim_reconciliation_cases set case_status='MANUAL_REVIEW',
      resolution_reason='PARTY_EVIDENCE_CONFLICT' where case_id=v_case.case_id;
    v_result:=jsonb_build_object('outcome','RECONCILIATION_REQUIRED','case_id',v_case.case_id,
      'reason_code','PARTY_EVIDENCE_CONFLICT');
  elsif v_true=2 then
    if v_t.task_status not in ('DISPATCHED','COLLECTED') then
      update public.claim_reconciliation_cases set case_status='MANUAL_REVIEW',
        resolution_reason='HANDOVER_EVIDENCE_CONFLICTS_WITH_TASK_STATE' where case_id=v_case.case_id;
      v_result:=jsonb_build_object('outcome','RECONCILIATION_REQUIRED','case_id',v_case.case_id,
        'reason_code','HANDOVER_EVIDENCE_CONFLICTS_WITH_TASK_STATE');
    else
      if v_l.source_type='DIRECT_DONATION' then
        select d.* into v_d from public.donations d where d.donation_id=v_l.donation_id for update;
        if v_d.donation_status not in ('PICKUP_IN_PROGRESS','COLLECTED') then raise exception 'DONATION_STATE_REQUIRES_REVIEW'; end if;
        if v_d.donation_status='PICKUP_IN_PROGRESS' then
          update public.donations set donation_status='COLLECTED' where donation_id=v_d.donation_id;
        end if;
      else
        for v_did in select m.donation_id from public.hub_batch_members m
          where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE' order by m.donation_id loop
          select d.* into v_d from public.donations d where d.donation_id=v_did for update;
          if v_d.donation_status not in ('PICKUP_IN_PROGRESS','COLLECTED') then raise exception 'BATCH_DONATION_STATE_REQUIRES_REVIEW'; end if;
          if v_d.donation_status='PICKUP_IN_PROGRESS' then
            update public.donations set donation_status='COLLECTED' where donation_id=v_did;
          end if;
        end loop;
        update public.hub_inventory set inventory_status='COLLECTED'
          where donation_id in(select m.donation_id from public.hub_batch_members m
            where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE');
        update public.hub_batches set batch_status='COLLECTED' where batch_id=v_l.batch_id;
      end if;
      update public.pickup_tasks set task_status='COLLECTED' where task_id=v_t.task_id;
      update public.listings set listing_status='CLOSED',listing_version=listing_version+1 where listing_id=v_l.listing_id;
      update public.donation_claims set claim_status='COMPLETED',closed_at=clock_timestamp(),close_reason='RECONCILED_HANDOVER_CONFIRMED' where claim_id=p_claim;
      update public.claim_leases set lease_status='COMPLETED',closed_at=clock_timestamp() where lease_id=v_le.lease_id;
      update public.claim_reconciliation_cases set case_status='RESOLVED_COLLECTED',resolved_at=clock_timestamp(),
        resolution_reason='BOTH_PARTIES_CONFIRMED_HANDOVER' where case_id=v_case.case_id;
      v_result:=jsonb_build_object('outcome','SUCCESS','case_id',v_case.case_id,
        'claim_status','COMPLETED','donation_status','COLLECTED','reason_code','HANDOVER_CONFIRMED');
    end if;
  else
    if v_t.task_status='CONFIRMED'
       and v_l.listing_status='CLAIMED'
       and (v_l.listing_expires_at is null or v_l.listing_expires_at>clock_timestamp())
       and ((v_l.source_type='DIRECT_DONATION' and exists(select 1 from public.donations d
              where d.donation_id=v_l.donation_id and d.donation_status='CLAIMED'))
         or (v_l.source_type='HUB_BATCH'
             and exists(select 1 from public.hub_batch_members m
               where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE')
             and not exists(select 1 from public.hub_batch_members m join public.donations d using(donation_id)
               where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'
                 and d.donation_status<>'CLAIMED')
              and not exists(select 1 from public.hub_batch_members m
                where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'
                  and not exists(select 1 from public.hub_inventory hi
                    where hi.donation_id=m.donation_id and hi.inventory_status='BATCHED'))))
       and not exists(select 1 from public.active_task_route_assignments a where a.task_id=v_t.task_id)
       and not exists(
      select 1 from public.pickup_route_stops s join public.pickup_routes r using(route_id)
      where s.task_id=v_t.task_id and r.route_status not in ('CANCELLED','STALE')) then
      update public.donation_claims set claim_status='RELEASED',closed_at=clock_timestamp(),close_reason='RECONCILED_NO_HANDOVER' where claim_id=p_claim;
      update public.claim_leases set lease_status='RELEASED',closed_at=clock_timestamp(),release_reason='RECONCILED_NO_HANDOVER' where lease_id=v_le.lease_id;
      update public.pickup_tasks set task_status='STALE' where task_id=v_t.task_id;
      update public.listings set listing_status='AVAILABLE',listing_version=listing_version+1 where listing_id=v_l.listing_id;
      perform public.geolock_transition_listing_donations(v_l.listing_id,'CLAIMED',
        case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end);
      update public.claim_reconciliation_cases set case_status='RESOLVED_RELEASED',resolved_at=clock_timestamp(),
        resolution_reason='BOTH_PARTIES_CONFIRMED_NO_HANDOVER' where case_id=v_case.case_id;
      v_result:=jsonb_build_object('outcome','SUCCESS','case_id',v_case.case_id,
        'claim_status','RELEASED','reason_code','NO_HANDOVER_CONFIRMED');
    else
      update public.claim_reconciliation_cases set case_status='MANUAL_REVIEW',
        resolution_reason='NO_HANDOVER_CONFIRMED_AFTER_PICKUP_STARTED' where case_id=v_case.case_id;
      v_result:=jsonb_build_object('outcome','RECONCILIATION_REQUIRED','case_id',v_case.case_id,
        'reason_code','NO_HANDOVER_AFTER_PICKUP_STARTED_REQUIRES_REVIEW');
    end if;
  end if;

  update public.claim_reconciliation_evidence set response=v_result where request_id=p_request;
  select c.config_version into v_cfg from public.coordination_config c where c.singleton;
  -- This path accepted the evidence; waiting/manual review is a workflow state,
  -- not a failed database operation. Earlier rejection paths remain REJECTED.
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    request_id,claim_id,lease_id,correlation_id,previous_state,requested_state,resulting_state,
    reason_code,outcome,software_version,configuration_version,details)
  values(v_actor,v_role,'CLAIM',p_claim,'CLAIM_RECONCILIATION_EVIDENCE',p_request,p_claim,
    v_le.lease_id,p_request,v_c.claim_status,
    case when p_handover_confirmed then 'COLLECTED' else 'RELEASED' end,
    coalesce(v_result->>'claim_status',v_c.claim_status),v_result->>'reason_code','SUCCESS',
    'geolock-stage1-2026-10-19',v_cfg,jsonb_build_object('donation_id',v_l.donation_id,
        'listing_id',v_l.listing_id,'case_id',v_case.case_id,
      'handover_confirmed',p_handover_confirmed,
      'reconciliation_status',v_result->>'outcome'));
  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_authorized_audit_events(p_entity_type text, p_entity_id uuid)
 RETURNS SETOF audit_events
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_user uuid:=auth.uid(); v_role text; v_allowed boolean:=false;
begin
  if v_user is null then raise exception 'UNAUTHENTICATED'; end if;
  select p.role into v_role from public.user_profiles p where p.user_id=v_user;
  if v_role='DONOR' then
    v_allowed:=exists(select 1 from public.donations d where d.donor_user_id=v_user
      and (d.donation_id=p_entity_id or exists(select 1 from public.listings l
      where l.donation_id=d.donation_id and l.listing_id=p_entity_id)));
  elsif v_role='NGO' then
    v_allowed:=exists(select 1 from public.donation_claims c join public.listings l using(listing_id)
      where c.ngo_user_id=v_user and (c.claim_id=p_entity_id or l.listing_id=p_entity_id or l.donation_id=p_entity_id or exists(select 1 from public.hub_batch_members m
        where m.batch_id=l.batch_id and m.donation_id=p_entity_id and m.membership_status='ACTIVE')));
  elsif v_role='HUB_ADMIN' then
    v_allowed:=exists(select 1 from public.community_hubs h where h.admin_user_id=v_user
      and (h.hub_id=p_entity_id or exists(select 1 from public.hub_reservations r
      where r.hub_id=h.hub_id and r.donation_id=p_entity_id) or exists(select 1 from public.hub_inventory i
      where i.hub_id=h.hub_id and i.donation_id=p_entity_id) or exists(select 1 from public.hub_batches b
      where b.hub_id=h.hub_id and b.batch_id=p_entity_id)));
  end if;
  if not v_allowed then raise exception 'AUDIT_NOT_FOUND_OR_FORBIDDEN'; end if;
  return query select a.* from public.audit_events a
    where (a.entity_id=p_entity_id or a.details->>'donation_id'=p_entity_id::text
      or a.details->>'listing_id'=p_entity_id::text or a.claim_id=p_entity_id
      or exists(select 1 from public.donation_claims c join public.listings l using(listing_id)
        where c.claim_id=a.claim_id and (l.donation_id=p_entity_id or l.listing_id=p_entity_id)))
      and (v_role<>'NGO' or a.event_type<>'DONOR_PRIVATE_DATA')
    order by a.occurred_at;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_donation_dashboard()
 RETURNS TABLE(donation_id uuid, title text, donation_status text, collection_path text, total_weight_kg numeric, created_at timestamp with time zone, hub_name text, reservation_status text, listing_status text, receipt_status text, inventory_status text, item_count bigint, primary_image_path text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.donor_profiles dp where dp.user_id=auth.uid()) then
    raise exception 'DONOR_ONLY';
  end if;
  return query
  select d.donation_id,d.title,d.donation_status,d.collection_path,
    d.total_weight_kg,d.created_at,latest.hub_name,latest.reservation_status,
    l.listing_status,latest.receipt_status,hi.inventory_status,
    (select count(*) from public.donation_items di where di.donation_id=d.donation_id),
    img.storage_path
  from public.donations d
  left join lateral (
    select dl.* from public.listings dl
    where (dl.source_type='DIRECT_DONATION' and dl.donation_id=d.donation_id)
      or (dl.source_type='HUB_BATCH' and exists(select 1 from public.hub_batch_members m
        where m.batch_id=dl.batch_id and m.donation_id=d.donation_id and m.membership_status='ACTIVE'))
    limit 1
  ) l on true
  left join public.hub_inventory hi on hi.donation_id=d.donation_id
  left join lateral (
    select h.hub_name,r.reservation_status,hr.receipt_status
    from public.hub_reservations r
    join public.community_hubs h using(hub_id)
    left join public.hub_receipts hr on hr.reservation_id=r.reservation_id
    where r.donation_id=d.donation_id
    order by r.reserved_at desc limit 1
  ) latest on true
  left join lateral (
    select i.storage_path from public.donation_images i
    where i.donation_id=d.donation_id and i.owner_user_id=auth.uid() and i.is_primary
    limit 1
  ) img on true
  where d.donor_user_id=auth.uid()
  order by d.created_at desc,d.donation_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_donation_dashboard_v2()
 RETURNS TABLE(donation_id uuid, title text, donation_status text, collection_path text, total_weight_kg numeric, created_at timestamp with time zone, hub_name text, reservation_status text, reservation_effective_status text, reservation_expires_at timestamp with time zone, listing_status text, receipt_status text, inventory_status text, item_count bigint, primary_image_path text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.donor_profiles dp where dp.user_id=auth.uid())
  then raise exception 'DONOR_ONLY'; end if;
  return query
  select d.donation_id,d.title,d.donation_status,d.collection_path,
    d.total_weight_kg,d.created_at,latest.hub_name,latest.reservation_status,
    case when latest.reservation_status='ACTIVE'
      and latest.reservation_expires_at<=statement_timestamp() then 'EXPIRED'
      else latest.reservation_status end,
    latest.reservation_expires_at,l.listing_status,latest.receipt_status,
    hi.inventory_status,
    (select count(*) from public.donation_items di where di.donation_id=d.donation_id),
    img.storage_path
  from public.donations d
  left join lateral (
    select dl.* from public.listings dl
    where (dl.source_type='DIRECT_DONATION' and dl.donation_id=d.donation_id)
      or (dl.source_type='HUB_BATCH' and exists(select 1 from public.hub_batch_members m
        where m.batch_id=dl.batch_id and m.donation_id=d.donation_id and m.membership_status='ACTIVE'))
    limit 1
  ) l on true
  left join public.hub_inventory hi on hi.donation_id=d.donation_id
  left join lateral (
    select h.hub_name,r.reservation_status,r.expires_at as reservation_expires_at,
      hr.receipt_status
    from public.hub_reservations r join public.community_hubs h using(hub_id)
    left join public.hub_receipts hr on hr.reservation_id=r.reservation_id
    where r.donation_id=d.donation_id
    order by r.reserved_at desc,r.reservation_id desc limit 1
  ) latest on true
  left join lateral (
    select i.storage_path from public.donation_images i
    where i.donation_id=d.donation_id and i.owner_user_id=auth.uid() and i.is_primary
    limit 1
  ) img on true
  where d.donor_user_id=auth.uid()
  order by d.created_at desc,d.donation_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_donation_detail(p_donation uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_result jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.donor_profiles dp where dp.user_id=auth.uid())
  then raise exception 'DONOR_ONLY'; end if;
  select jsonb_build_object(
    'donation_id',d.donation_id,'title',d.title,'description',d.description,
    'status',d.donation_status,'donation_status',d.donation_status,
    'collection_path',d.collection_path,'total_weight_kg',d.total_weight_kg,
    'pickup_address',d.pickup_address,'latitude',d.latitude,'longitude',d.longitude,
    'created_at',d.created_at,'updated_at',d.updated_at,
    'availability_start',d.availability_start,'availability_end',d.availability_end,
    'listing_status',l.listing_status,
    'road_node_status',case when l.listing_id is null then null
      when l.pickup_road_node_id is null then case when public.geolock_active_road_snapshot() is null then 'PENDING_NODE' else 'NOT_ROUTABLE' end else 'READY' end,
    'items',coalesce((select jsonb_agg(jsonb_build_object(
      'item_id',i.item_id,'category_id',i.category_id,'category',c.category_name,
      'item_name',i.item_name,'description',i.description,'quantity',i.quantity,
      'unit_label',i.unit_label,'unit_weight_kg',i.unit_weight_kg,
      'item_condition',i.item_condition) order by i.created_at,i.item_id)
      from public.donation_items i join public.donation_categories c using(category_id)
      where i.donation_id=d.donation_id),'[]'::jsonb),
    'hub_reservations',coalesce((select jsonb_agg(jsonb_build_object(
      'reservation_id',r.reservation_id,'hub_id',r.hub_id,'hub_name',h.hub_name,
      'status',r.reservation_status,
      'effective_status',case when r.reservation_status='ACTIVE'
        and r.expires_at<=statement_timestamp() then 'EXPIRED'
        else r.reservation_status end,
      'reserved_weight_kg',r.reserved_weight_kg,'reserved_at',r.reserved_at,
      'expires_at',r.expires_at,'receipt_status',hr.receipt_status,
      'received_weight_kg',hr.received_weight_kg,'received_at',hr.received_at)
      order by r.reserved_at desc,r.reservation_id desc)
      from public.hub_reservations r join public.community_hubs h using(hub_id)
      left join public.hub_receipts hr on hr.reservation_id=r.reservation_id
      where r.donation_id=d.donation_id),'[]'::jsonb)
  ) into v_result
  from public.donations d
  left join lateral (
    select dl.* from public.listings dl
    where (dl.source_type='DIRECT_DONATION' and dl.donation_id=d.donation_id)
      or (dl.source_type='HUB_BATCH' and exists(select 1 from public.hub_batch_members m
        where m.batch_id=dl.batch_id and m.donation_id=d.donation_id and m.membership_status='ACTIVE'))
    limit 1
  ) l on true
  where d.donation_id=p_donation and d.donor_user_id=auth.uid();
  return v_result;
end;
$function$;

-- Re-read final rows at COMMIT: SUBMITTED staging cannot leak for direct donations.
-- These checks do not take new row locks or calculate routes.
create function public.geolock_assert_donation_lifecycle(p_donation uuid)
returns void language plpgsql
set search_path to 'pg_catalog','public','pg_temp'
as $function$
declare v_d public.donations%rowtype; v_l public.listings%rowtype;
  v_b public.hub_batches%rowtype;
begin
  select * into v_d from public.donations where donation_id=p_donation;
  if not found then return; end if;
  if v_d.collection_path is null or v_d.total_weight_kg is null or v_d.total_weight_kg<=0
    or (v_d.collection_path='DIRECT_PICKUP') is distinct from (v_d.total_weight_kg>=10)
    or (v_d.collection_path='DIRECT_PICKUP' and v_d.donation_status in ('SUBMITTED','HUB_ASSIGNED','AT_HUB','BATCHED'))
    or (v_d.collection_path='HUB_COLLECTION' and v_d.donation_status='AVAILABLE') then
    raise exception 'DONATION_FINALIZATION_REQUIRED: %',p_donation;
  end if;
  if v_d.donation_status in ('CANCELLED','SUBMITTED','HUB_ASSIGNED','AT_HUB') then return; end if;
  if v_d.collection_path='DIRECT_PICKUP' then
    select * into v_l from public.listings where donation_id=p_donation and source_type='DIRECT_DONATION';
  else
    select b.* into v_b from public.hub_batches b join public.hub_batch_members m using(batch_id)
      where m.donation_id=p_donation and m.membership_status='ACTIVE';
    if not found or v_b.batch_status<>case when v_d.donation_status='COLLECTED' then 'COLLECTED' else 'PUBLISHED' end
      or (select count(*) from public.hub_batch_members m
        where m.batch_id=v_b.batch_id and m.membership_status='ACTIVE')<>v_b.batch_donation_count
      or exists(select 1 from public.hub_batch_members m join public.donations d using(donation_id)
        where m.batch_id=v_b.batch_id and m.membership_status='ACTIVE'
          and (d.donation_status<>v_d.donation_status or d.collection_path<>'HUB_COLLECTION'))
      or exists(select 1 from public.hub_batch_members m where m.batch_id=v_b.batch_id
        and m.membership_status='ACTIVE' and not exists(select 1 from public.hub_inventory hi
          where hi.donation_id=m.donation_id and hi.hub_id=v_b.hub_id
            and hi.inventory_status=case when v_d.donation_status='COLLECTED' then 'COLLECTED' else 'BATCHED' end)) then
      raise exception 'BATCH_DONATION_SET_INCONSISTENT: %',p_donation;
    end if;
    select * into v_l from public.listings where batch_id=v_b.batch_id and source_type='HUB_BATCH';
  end if;
  if v_l.listing_id is null then raise exception 'DONATION_LISTING_REQUIRED: %',p_donation; end if;
  if v_d.donation_status in ('AVAILABLE','BATCHED') then
    if v_l.listing_status<>'AVAILABLE' or exists(select 1 from public.donation_claims c
      where c.listing_id=v_l.listing_id and c.claim_status in ('ACTIVE','RECONCILIATION_REQUIRED')) then
      raise exception 'AVAILABLE_DONATION_COORDINATION_MISMATCH: %',p_donation;
    end if;
  elsif v_d.donation_status='COLLECTED' then
    if v_l.listing_status<>'CLOSED' or not exists(
      select 1 from public.donation_claims c join public.claim_leases le using(claim_id)
      join public.pickup_tasks t using(claim_id)
      where c.listing_id=v_l.listing_id and t.listing_id=v_l.listing_id
        and c.claim_status='COMPLETED' and le.lease_status='COMPLETED' and t.task_status='COLLECTED') then
      raise exception 'COLLECTED_DONATION_COORDINATION_MISMATCH: %',p_donation;
    end if;
  elsif v_d.donation_status in ('CLAIMED','PICKUP_IN_PROGRESS') then
    if v_l.listing_status<>'CLAIMED' or not exists(
      select 1 from public.donation_claims c join public.claim_leases le using(claim_id)
      join public.pickup_tasks t using(claim_id)
      where c.listing_id=v_l.listing_id and t.listing_id=v_l.listing_id
        and c.claim_status in ('ACTIVE','RECONCILIATION_REQUIRED') and le.lease_status=c.claim_status
        and ((v_d.donation_status='CLAIMED' and t.task_status in ('CONFIRMED','PLANNED'))
          or (v_d.donation_status='PICKUP_IN_PROGRESS' and t.task_status='DISPATCHED'))) then
      raise exception 'CLAIMED_DONATION_COORDINATION_MISMATCH: %',p_donation;
    end if;
  end if;
end;
$function$;
alter function public.geolock_assert_donation_lifecycle(uuid) owner to postgres;
revoke all on function public.geolock_assert_donation_lifecycle(uuid)
  from public,anon,authenticated,service_role;

create function public.geolock_validate_donation_at_commit()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','pg_temp'
as $function$
begin
  perform public.geolock_assert_donation_lifecycle(new.donation_id);
  return null;
end;
$function$;
alter function public.geolock_validate_donation_at_commit() owner to postgres;
revoke all on function public.geolock_validate_donation_at_commit()
  from public,anon,authenticated,service_role;
create constraint trigger donations_lifecycle_at_commit
after insert or update on public.donations
deferrable initially deferred for each row
execute function public.geolock_validate_donation_at_commit();

-- Validate all backfilled and untouched live rows under the maintenance locks.
do $validate$
declare v_id uuid;
begin
  for v_id in select donation_id from public.donations order by donation_id loop
    perform public.geolock_assert_donation_lifecycle(v_id);
  end loop;
end;
$validate$;
set constraints all immediate;
commit;
