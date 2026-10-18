--
-- PostgreSQL database dump
--

\restrict pWVgjZe2Qtw7xbofj1az9GWi6GbShhMsJAuOoRf9BB7vzDwjr3AYXYnXEv8hyFn

-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: add_donation_image(uuid, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_donation_image(p_donation uuid, p_storage_path text, p_content_type text, p_size_bytes integer) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $_$
declare
  v_actor uuid:=auth.uid();
  v_d public.donations%rowtype;
  v_count integer;
  v_order smallint;
  v_image uuid;
  v_role text;
  v_actual_size bigint;
  v_actual_type text;
  v_ext text;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_d from public.donations where donation_id=p_donation for update;
  if not found or v_d.donor_user_id<>v_actor then raise exception 'DONATION_NOT_FOUND_OR_FORBIDDEN'; end if;
  -- Adding an image does not mutate structured donation items or operational
  -- state. This compatibility RPC may append photos to older records; it cannot
  -- overwrite, reorder, or remove the existing cover.
  select count(*) into v_count from public.donation_images where donation_id=p_donation;
  if v_count>=3 then raise exception 'MAXIMUM_THREE_DONATION_PHOTOS'; end if;
  v_ext:=lower(split_part(p_storage_path,'.',array_length(string_to_array(p_storage_path,'.'),1)));
  if p_storage_path !~ ('^'||v_actor::text||'/'||p_donation::text||'/[0-9a-fA-F-]{36}[.](jpg|jpeg|png|webp)$')
     or p_content_type not in ('image/jpeg','image/png','image/webp')
     or p_size_bytes is null or p_size_bytes not between 1 and 5242880
     or (v_ext in ('jpg','jpeg') and p_content_type<>'image/jpeg')
     or (v_ext='png' and p_content_type<>'image/png')
     or (v_ext='webp' and p_content_type<>'image/webp') then raise exception 'INVALID_IMAGE_METADATA'; end if;
  select nullif(o.metadata->>'size','')::bigint,o.metadata->>'mimetype'
    into v_actual_size,v_actual_type from storage.objects o
    where o.bucket_id='geolock-donation-images' and o.name=p_storage_path;
  if not found or v_actual_size is distinct from p_size_bytes::bigint
     or v_actual_type is distinct from p_content_type then
    raise exception 'STORED_IMAGE_MISSING_OR_MISMATCHED';
  end if;
  v_order:=(v_count+1)::smallint;
  insert into public.donation_images(donation_id,owner_user_id,storage_path,content_type,size_bytes,is_primary,display_order)
  values(p_donation,v_actor,p_storage_path,p_content_type,p_size_bytes,v_order=1,v_order)
  returning image_id into v_image;
  select role into v_role from public.user_profiles where user_id=v_actor;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    requested_state,resulting_state,outcome,details,configuration_version)
  values(v_actor,v_role,'DONATION',p_donation,'DONATION_IMAGE_ADDED','IMAGE_ATTACHED','IMAGE_ATTACHED','SUCCESS',
    jsonb_build_object('image_id',v_image,'display_order',v_order),
    (select config_version from public.coordination_config where singleton));
  return v_image;
end;
$_$;


--
-- Name: add_hub_batch_image(uuid, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_hub_batch_image(p_batch uuid, p_storage_path text, p_content_type text, p_size_bytes integer) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $_$
declare v_actor uuid:=auth.uid();v_image uuid;v_role text;v_ext text;v_actual_size bigint;v_actual_type text;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_size_bytes is null or p_size_bytes not between 1 and 5242880
     or p_content_type not in ('image/jpeg','image/png','image/webp') then
    raise exception 'INVALID_IMAGE_METADATA';
  end if;
  v_ext:=lower(split_part(p_storage_path,'.',array_length(string_to_array(p_storage_path,'.'),1)));
  if p_storage_path !~ ('^'||v_actor::text||'/batches/'||p_batch::text||'/[0-9a-fA-F-]{36}[.](jpg|jpeg|png|webp)$')
     or (v_ext in ('jpg','jpeg') and p_content_type<>'image/jpeg')
     or (v_ext='png' and p_content_type<>'image/png')
     or (v_ext='webp' and p_content_type<>'image/webp') then
    raise exception 'INVALID_IMAGE_PATH';
  end if;
  select nullif(o.metadata->>'size','')::bigint,o.metadata->>'mimetype'
    into v_actual_size,v_actual_type from storage.objects o
    where o.bucket_id='geolock-donation-images' and o.name=p_storage_path;
  if not found or v_actual_size is distinct from p_size_bytes::bigint
     or v_actual_type is distinct from p_content_type then
    raise exception 'STORED_IMAGE_MISSING_OR_MISMATCHED';
  end if;
  if not exists(select 1 from public.hub_batches b join public.community_hubs h using(hub_id)
      where b.batch_id=p_batch and h.admin_user_id=v_actor) then
    raise exception 'BATCH_NOT_FOUND_OR_FORBIDDEN';
  end if;
  if exists(select 1 from public.hub_batch_images where batch_id=p_batch) then
    raise exception 'BATCH_PHOTO_ALREADY_SET';
  end if;
  insert into public.hub_batch_images(batch_id,owner_user_id,storage_path,content_type,size_bytes,is_primary)
  values(p_batch,v_actor,p_storage_path,p_content_type,p_size_bytes,true)
  returning image_id into v_image;
  select role into v_role from public.user_profiles where user_id=v_actor;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    requested_state,resulting_state,outcome,details,configuration_version)
  values(v_actor,v_role,'BATCH',p_batch,'BATCH_IMAGE_ADDED','IMAGE_ATTACHED','IMAGE_ATTACHED','SUCCESS',
    jsonb_build_object('image_id',v_image,'content_type',p_content_type,'size_bytes',p_size_bytes),
    (select config_version from public.coordination_config where singleton));
  return v_image;
end;
$_$;


--
-- Name: assign_task_to_route(uuid, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assign_task_to_route(p_route uuid, p_task uuid, p_stop_order integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
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
end $$;


--
-- Name: can_read_geolock_batch_image(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_read_geolock_batch_image(p_path text) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
    AS $$
  select auth.uid() is not null and exists(
    select 1 from public.hub_batch_images i
    join public.hub_batches b using(batch_id)
    where i.storage_path=p_path and (
      exists(select 1 from public.community_hubs h where h.hub_id=b.hub_id and h.admin_user_id=auth.uid())
      or exists(
        select 1 from public.ngo_profiles n
        join public.coordination_config cfg on cfg.singleton
        join public.listings l on l.batch_id=b.batch_id and l.source_type='HUB_BATCH'
        where n.user_id=auth.uid() and n.active_flag and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c left join public.claim_leases le using(claim_id)
                where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
                  and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                       or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at>clock_timestamp())))
          and extensions.ST_DWithin(
            extensions.ST_SetSRID(extensions.ST_MakePoint(n.longitude,n.latitude),4326)::extensions.geography,
            extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography,
            cfg.geofence_radius_m)
      )
    )
  );
$$;


--
-- Name: can_read_geolock_donation_image(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_read_geolock_donation_image(p_path text) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
    AS $$
  select auth.uid() is not null and exists(
    select 1 from public.donation_images i
    join public.donations d using(donation_id)
    where i.storage_path=p_path and (
      d.donor_user_id=auth.uid()
      or exists(
        select 1 from public.ngo_profiles n
        join public.coordination_config cfg on cfg.singleton
        join public.listings l on l.donation_id=d.donation_id and l.source_type='DIRECT_DONATION'
        where n.user_id=auth.uid() and n.active_flag and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c
                left join public.claim_leases le using(claim_id)
                where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
                  and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                       or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at>clock_timestamp())))
          and extensions.ST_DWithin(
            extensions.ST_SetSRID(extensions.ST_MakePoint(n.longitude,n.latitude),4326)::extensions.geography,
            extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography,
            cfg.geofence_radius_m)
      )
      or exists(
        select 1 from public.ngo_profiles n
        join public.coordination_config cfg on cfg.singleton
        join public.hub_batch_members m on m.donation_id=d.donation_id and m.membership_status='ACTIVE'
        join public.listings l on l.batch_id=m.batch_id and l.source_type='HUB_BATCH'
        join public.hub_batches b on b.batch_id=m.batch_id and b.batch_status='PUBLISHED'
        where n.user_id=auth.uid() and n.active_flag and n.location_verified_at is not null
          and exists(select 1 from public.donation_claims c
                left join public.claim_leases le using(claim_id)
                where c.listing_id=l.listing_id and c.ngo_user_id=auth.uid()
                  and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
                       or (c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at>clock_timestamp())))
          and extensions.ST_DWithin(
            extensions.ST_SetSRID(extensions.ST_MakePoint(n.longitude,n.latitude),4326)::extensions.geography,
            extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography,
            cfg.geofence_radius_m)
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
$$;


--
-- Name: cancel_donation(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cancel_donation(p_donation uuid, p_request uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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
  elsif v_previous not in ('SUBMITTED','VALIDATED','READY_FOR_PICKUP','HUB_ASSIGNED') then
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
    join public.donation_claims c using(claim_id)
    join public.listings l using(listing_id)
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
  elsif v_previous in ('SUBMITTED','VALIDATED') and v_path='HUB_COLLECTION'
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


--
-- Name: claim_listing(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_listing(p_listing uuid, p_request uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
declare v_actor uuid:=auth.uid();v_ngo public.ngo_profiles%rowtype;
 v_req public.claim_requests%rowtype;v_l public.listings%rowtype;
 v_digest text;v_reason text;v_claim uuid;v_lease uuid;v_mins integer;
 v_node text;v_success boolean:=false;v_outcome text;
begin
 if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
 select * into v_ngo from public.ngo_profiles where user_id=v_actor and active_flag;
 if not found then raise exception 'ACTIVE_NGO_ONLY'; end if;
 if p_request is null or p_listing is null then raise exception 'REQUEST_AND_LISTING_REQUIRED'; end if;
 v_digest=md5(p_listing::text||':'||v_actor::text);
 insert into public.claim_requests(request_id,listing_id,ngo_user_id,request_digest)
 values(p_request,p_listing,v_actor,v_digest) on conflict(request_id) do nothing;
 select * into v_req from public.claim_requests where request_id=p_request for update;
 if v_req.request_digest<>v_digest or v_req.listing_id<>p_listing or v_req.ngo_user_id<>v_actor
 then raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'; end if;
 if v_req.outcome is not null then
  return jsonb_build_object('outcome',v_req.outcome,'claim_id',v_req.result_claim_id,
    'reason_code',v_req.reason_code,'replayed',true);
 end if;
 select * into v_l from public.listings where listing_id=p_listing for update;
 if not found then v_reason='LISTING_NOT_FOUND';
 elsif v_l.listing_status<>'AVAILABLE' then v_reason='CLAIM_CONFLICT';
 elsif v_l.listing_expires_at is not null and v_l.listing_expires_at<=clock_timestamp()
 then v_reason='LISTING_EXPIRED';
 elsif v_ngo.location_verified_at is null then v_reason='ELIGIBILITY_UNDETERMINED';
 elsif not ST_DWithin(
  ST_SetSRID(ST_MakePoint(v_ngo.longitude,v_ngo.latitude),4326)::geography,
  ST_SetSRID(ST_MakePoint(v_l.pickup_longitude,v_l.pickup_latitude),4326)::geography,
  20000) then v_reason='NGO_INELIGIBLE';
 elsif v_l.pickup_road_node_id is null then v_reason='ROUTING_NODE_MISSING';
 elsif v_l.source_type='DIRECT_DONATION' and not exists(
  select 1 from public.donations d where d.donation_id=v_l.donation_id
  and d.donation_status='READY_FOR_PICKUP')
 then v_reason='DONATION_NOT_READY';
 elsif v_l.source_type='HUB_BATCH' and not exists(
  select 1 from public.hub_batches b where b.batch_id=v_l.batch_id and b.batch_status='PUBLISHED')
 then v_reason='BATCH_NOT_PUBLISHED';
 else
  select claim_lease_minutes into v_mins from public.coordination_config where singleton;
  if v_mins is null then raise exception 'CLAIM_LEASE_NOT_CONFIGURED'; end if;
  insert into public.donation_claims(listing_id,ngo_user_id,request_id)
  values(p_listing,v_actor,p_request) returning claim_id into v_claim;
  insert into public.claim_leases(claim_id,expires_at)
  values(v_claim,clock_timestamp()+make_interval(mins=>v_mins))
  returning lease_id into v_lease;
  update public.listings set listing_status='CLAIMED',listing_version=listing_version+1
   where listing_id=p_listing;
  insert into public.pickup_tasks(claim_id,listing_id,ngo_user_id,pickup_road_node_id,load_kg)
  values(v_claim,p_listing,v_actor,v_l.pickup_road_node_id,v_l.listing_weight_kg);
  v_success=true;
 end if;
 v_outcome=case when v_success then 'SUCCESS'
  when v_reason='NGO_INELIGIBLE' then 'INELIGIBLE' else 'CONFLICT' end;
 update public.claim_requests set outcome=v_outcome,result_claim_id=v_claim,
  reason_code=v_reason,completed_at=clock_timestamp() where request_id=p_request;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 request_id,claim_id,lease_id,previous_state,requested_state,resulting_state,
 reason_code,outcome,details,configuration_version)
 select v_actor,'NGO','LISTING',p_listing,'CLAIM_ATTEMPT',p_request,v_claim,v_lease,
 v_l.listing_status,'CLAIMED',
 case when v_success then 'CLAIMED' else v_l.listing_status end,v_reason,
 case when v_success then 'SUCCESS' else 'REJECTED' end,
 jsonb_build_object('ngo_id',v_actor),cfg.config_version
 from public.coordination_config cfg where cfg.singleton;
 return jsonb_build_object('outcome',v_outcome,'claim_id',v_claim,
   'reason_code',v_reason,'replayed',false);
end $$;


--
-- Name: complete_pickup(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.complete_pickup(p_claim uuid, p_handover_confirmed boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
declare v_actor uuid:=auth.uid();v_c public.donation_claims%rowtype;
 v_l public.listings%rowtype;v_lease public.claim_leases%rowtype;
begin
 select * into v_c from public.donation_claims where claim_id=p_claim for update;
 if not found or v_c.ngo_user_id is distinct from v_actor or v_c.claim_status<>'ACTIVE'
 then raise exception 'NOT_ACTIVE_CLAIM_HOLDER'; end if;
 select * into v_lease from public.claim_leases where claim_id=p_claim for update;
 if v_lease.lease_status<>'ACTIVE' or v_lease.expires_at<=clock_timestamp()
 then raise exception 'STALE_OR_EXPIRED_LEASE'; end if;
 if p_handover_confirmed is distinct from true then raise exception 'HANDOVER_NOT_CONFIRMED'; end if;
 select * into v_l from public.listings where listing_id=v_c.listing_id for update;
 if v_l.listing_status<>'CLAIMED' then raise exception 'LISTING_NOT_CLAIMED'; end if;
 update public.pickup_tasks set task_status='COLLECTED'
 where claim_id=p_claim and task_status='DISPATCHED';
 if not found then raise exception 'PICKUP_NOT_STARTED'; end if;
 if v_l.source_type='DIRECT_DONATION' then
  update public.donations set donation_status='COLLECTED'
  where donation_id=v_l.donation_id and donation_status='PICKUP_IN_PROGRESS';
  if not found then raise exception 'INVALID_DONATION_STATE'; end if;
 else
  update public.donations set donation_status='COLLECTED'
  where donation_id in(select donation_id from public.hub_batch_members
    where batch_id=v_l.batch_id and membership_status='ACTIVE')
    and donation_status='PICKUP_IN_PROGRESS';
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
end $$;


--
-- Name: confirm_hub_receipt(uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.confirm_hub_receipt(p_reservation uuid, p_received_weight numeric) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
declare v_actor uuid:=auth.uid(); v_r public.hub_reservations%rowtype;
  v_d public.donations%rowtype; v_h public.community_hubs%rowtype; v_receipt uuid;
  v_donation_id uuid; v_hub_id uuid;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select donation_id,hub_id into v_donation_id,v_hub_id
  from public.hub_reservations where reservation_id=p_reservation;
  if not found then raise exception 'RESERVATION_NOT_FOUND'; end if;
  select * into v_d from public.donations where donation_id=v_donation_id for update;
  if not found then raise exception 'DONATION_NOT_FOUND'; end if;
  perform 1 from public.community_hubs where hub_id=v_hub_id for update;
  select * into v_h from public.community_hubs where hub_id=v_hub_id;
  if v_h.admin_user_id is distinct from v_actor then raise exception 'NOT_HUB_ADMIN'; end if;
  select * into v_r from public.hub_reservations
  where reservation_id=p_reservation for update;
  if v_r.donation_id is distinct from v_donation_id or v_r.hub_id is distinct from v_hub_id
     or v_r.reservation_status<>'ACTIVE' or v_r.expires_at<=clock_timestamp() then
    raise exception 'RESERVATION_NOT_ACTIVE';
  end if;
  if v_d.donation_status<>'HUB_ASSIGNED' then raise exception 'INVALID_DONATION_STATE'; end if;
  if p_received_weight<=0 or p_received_weight>v_r.reserved_weight_kg then
    raise exception 'RECEIVED_WEIGHT_EXCEEDS_RESERVATION';
  end if;
  insert into public.hub_receipts(reservation_id,donation_id,hub_id,received_by,received_weight_kg)
  values(v_r.reservation_id,v_r.donation_id,v_r.hub_id,v_actor,p_received_weight)
  returning receipt_id into v_receipt;
  insert into public.hub_inventory(donation_id,hub_id)
  values(v_r.donation_id,v_r.hub_id);
  update public.hub_reservations set reservation_status='CONSUMED'
  where reservation_id=p_reservation and reservation_status='ACTIVE';
  update public.donations set donation_status='AT_HUB'
  where donation_id=v_donation_id;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
    event_type,previous_state,requested_state,resulting_state,outcome,details,
    correlation_id,configuration_version)
  select v_actor,'HUB_ADMIN','DONATION',v_donation_id,'CONFIRM_HUB_RECEIPT',
    'HUB_ASSIGNED','AT_HUB','AT_HUB','SUCCESS',
    jsonb_build_object('receipt_id',v_receipt,'reservation_id',p_reservation,
      'hub_id',v_hub_id),v_receipt,c.config_version
  from public.coordination_config c where c.singleton;
  return v_receipt;
end;
$$;


--
-- Name: create_and_validate_donation(text, text, text, double precision, double precision, jsonb, text, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_and_validate_donation(p_title text, p_description text, p_pickup_address text, p_latitude double precision, p_longitude double precision, p_items jsonb, p_pickup_road_node_id text DEFAULT NULL::text, p_availability_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_availability_end timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
declare v_actor uuid:=auth.uid(); v_donation uuid; v_item jsonb;
 v_count integer:=0; v_weight numeric(12,3):=0; v_threshold numeric(12,3);
 v_path text; v_category uuid; v_qty integer; v_unit numeric(12,3);
begin
 if not exists(select 1 from public.donor_profiles where user_id=v_actor)
 then raise exception 'DONOR_ONLY'; end if;
 if nullif(btrim(p_title),'') is null or nullif(btrim(p_pickup_address),'') is null
   or p_latitude is null or p_longitude is null
   or p_latitude not between -90 and 90 or p_longitude not between -180 and 180
 then raise exception 'INVALID_DONATION_LOCATION_OR_TITLE'; end if;
 if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items)=0
 then raise exception 'AT_LEAST_ONE_ITEM_REQUIRED'; end if;
 select donation_direct_min_kg into v_threshold from public.coordination_config where singleton;
 if v_threshold is null then raise exception 'DONATION_THRESHOLD_NOT_CONFIGURED'; end if;
 insert into public.donations(donor_user_id,title,description,pickup_address,latitude,longitude,
  pickup_road_node_id,availability_start,availability_end)
 values(v_actor,p_title,p_description,p_pickup_address,p_latitude,p_longitude,
  p_pickup_road_node_id,null,null)
 returning donation_id into v_donation;
 for v_item in select value from jsonb_array_elements(p_items) loop
   v_category=(v_item->>'category_id')::uuid;
   v_qty=(v_item->>'quantity')::integer;
   v_unit=(v_item->>'unit_weight_kg')::numeric;
   if v_qty is null or v_qty<=0 or v_unit is null or v_unit<=0
      or nullif(btrim(v_item->>'item_name'),'') is null
      or not exists(select 1 from public.donation_categories
                    where category_id=v_category and active_flag)
   then raise exception 'INVALID_DONATION_ITEM'; end if;
   insert into public.donation_items(donation_id,category_id,item_name,description,
      quantity,unit_label,unit_weight_kg,item_condition)
   values(v_donation,v_category,v_item->>'item_name',v_item->>'description',
      v_qty,coalesce(v_item->>'unit_label','piece'),v_unit,
      coalesce(v_item->>'item_condition','GOOD'));
   v_count=v_count+1;
   v_weight=v_weight+(v_qty*v_unit);
 end loop;
 if v_count=0 or v_weight<=0 then raise exception 'INVALID_TOTAL_WEIGHT'; end if;
 v_path=case when v_weight>=v_threshold then 'DIRECT_PICKUP' else 'HUB_COLLECTION' end;
 update public.donations set donation_status='VALIDATED',
  collection_path=v_path,total_weight_kg=v_weight where donation_id=v_donation;
 if v_path='DIRECT_PICKUP' then
   update public.donations set donation_status='READY_FOR_PICKUP' where donation_id=v_donation;
   insert into public.listings(source_type,donation_id,listing_weight_kg,
      pickup_latitude,pickup_longitude,pickup_road_node_id,listing_expires_at)
   values('DIRECT_DONATION',v_donation,v_weight,p_latitude,p_longitude,
      p_pickup_road_node_id,null);
 end if;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
  previous_state,requested_state,resulting_state,outcome,details,configuration_version)
 select v_actor,'DONOR','DONATION',v_donation,'CREATE_VALIDATE',
   null,'VALIDATED',case when v_path='DIRECT_PICKUP' then 'READY_FOR_PICKUP' else 'VALIDATED' end,
   'SUCCESS',jsonb_build_object('weight_kg',v_weight,'collection_path',v_path),config_version
 from public.coordination_config where singleton;
 return v_donation;
end $$;


--
-- Name: create_donation_with_images(uuid, text, text, text, double precision, double precision, jsonb, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_donation_with_images(p_request uuid, p_title text, p_description text, p_pickup_address text, p_latitude double precision, p_longitude double precision, p_items jsonb, p_pickup_road_node_id text, p_images jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'storage', 'pg_temp'
    AS $_$
declare
  v_actor uuid:=auth.uid();
  v_digest text;
  v_existing public.donation_create_requests%rowtype;
  v_donation uuid;
  v_image jsonb;
  v_order integer:=0;
  v_path text;
  v_type text;
  v_size integer;
  v_ext text;
  v_stored_size bigint;
  v_stored_type text;
  v_role text;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_request is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
  if nullif(btrim(p_title),'') is null or char_length(btrim(p_title))>80 then
    raise exception 'INVALID_DONATION_TITLE';
  end if;
  if p_description is not null and char_length(p_description)>1000 then
    raise exception 'DONATION_DESCRIPTION_TOO_LONG';
  end if;
  if jsonb_typeof(p_images) is distinct from 'array'
     or jsonb_array_length(p_images) not between 1 and 3 then
    raise exception 'ONE_TO_THREE_PHOTOS_REQUIRED';
  end if;
  v_digest:=md5(jsonb_build_object(
    'title',btrim(p_title),'description',p_description,'address',p_pickup_address,
    'lat',p_latitude,'lon',p_longitude,'items',p_items,'road_node',p_pickup_road_node_id,
    'images',p_images
  )::text);
  insert into public.donation_create_requests(request_id,donor_user_id,request_digest)
  values(p_request,v_actor,v_digest) on conflict(request_id) do nothing;
  select * into v_existing from public.donation_create_requests
  where request_id=p_request for update;
  if v_existing.donor_user_id<>v_actor or v_existing.request_digest<>v_digest then
    raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
  end if;
  if v_existing.donation_id is not null then return v_existing.donation_id; end if;

  for v_image in select value from jsonb_array_elements(p_images) loop
    v_order:=v_order+1;
    v_path:=v_image->>'storage_path';
    v_type:=v_image->>'content_type';
    v_size:=nullif(v_image->>'size_bytes','')::integer;
    v_ext:=lower(split_part(v_path,'.',array_length(string_to_array(v_path,'.'),1)));
    if v_path !~ ('^'||v_actor::text||'/pending/'||p_request::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|jpeg|png|webp)$')
       or v_size is null or v_size not between 1 and 5242880
       or v_type not in ('image/jpeg','image/png','image/webp')
       or (v_ext in ('jpg','jpeg') and v_type<>'image/jpeg')
       or (v_ext='png' and v_type<>'image/png')
       or (v_ext='webp' and v_type<>'image/webp') then
      raise exception 'INVALID_DONATION_IMAGE_%',v_order;
    end if;
    select nullif(o.metadata->>'size','')::bigint,o.metadata->>'mimetype'
      into v_stored_size,v_stored_type
    from storage.objects o
    where o.bucket_id='geolock-donation-images' and o.name=v_path;
    if not found or v_stored_size is null or v_stored_size<>v_size
       or v_stored_type<>v_type then
      raise exception 'STAGED_DONATION_IMAGE_MISSING_OR_MISMATCHED_%',v_order;
    end if;
  end loop;

  v_donation:=public.create_and_validate_donation(
    p_title,p_description,p_pickup_address,p_latitude,p_longitude,
    p_items,p_pickup_road_node_id,null,null
  );
  v_order:=0;
  for v_image in select value from jsonb_array_elements(p_images) loop
    v_order:=v_order+1;
    insert into public.donation_images(
      donation_id,owner_user_id,storage_path,content_type,size_bytes,is_primary,display_order
    ) values(
      v_donation,v_actor,v_image->>'storage_path',v_image->>'content_type',
      (v_image->>'size_bytes')::integer,v_order=1,v_order::smallint
    );
  end loop;
  update public.donation_create_requests set donation_id=v_donation
  where request_id=p_request;
  select role into v_role from public.user_profiles where user_id=v_actor;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    requested_state,resulting_state,outcome,details,configuration_version)
  values(v_actor,v_role,'DONATION',v_donation,'DONATION_PHOTOS_ATTACHED',
    'ONE_TO_THREE_PHOTOS','ONE_TO_THREE_PHOTOS','SUCCESS',
    jsonb_build_object('request_id',p_request,'photo_count',v_order),
    (select config_version from public.coordination_config where singleton));
  return v_donation;
end;
$_$;


--
-- Name: discover_eligible_listing_cards(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.discover_eligible_listing_cards() RETURNS TABLE(listing_id uuid, source_type text, title text, listing_weight_kg numeric, listing_created_at timestamp with time zone, collection_path text, distance_m double precision, routing_status text, primary_image_path text, batch_id uuid, donation_id uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
    AS $$
declare v_ngo public.ngo_profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles where user_id=auth.uid() and active_flag;
  if not found or v_ngo.location_verified_at is null then return; end if;
  return query
  select l.listing_id,l.source_type,
    case when l.source_type='DIRECT_DONATION' then d.title else 'Community Hub Batch' end,
    l.listing_weight_kg,l.created_at,
    case when l.source_type='DIRECT_DONATION' then d.collection_path else 'HUB_COLLECTION' end,
    extensions.ST_Distance(
      extensions.ST_SetSRID(extensions.ST_MakePoint(v_ngo.longitude,v_ngo.latitude),4326)::extensions.geography,
      extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography),
    case when l.pickup_road_node_id is null then 'PENDING_NODE' else 'UNVERIFIED' end,
    null::text,l.batch_id,l.donation_id
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
    and extensions.ST_DWithin(
      extensions.ST_SetSRID(extensions.ST_MakePoint(v_ngo.longitude,v_ngo.latitude),4326)::extensions.geography,
      extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography,
      cfg.geofence_radius_m)
    and ((l.source_type='DIRECT_DONATION' and d.donation_status='READY_FOR_PICKUP')
      or (l.source_type='HUB_BATCH' and b.batch_status='PUBLISHED'))
  order by l.created_at desc;
end;
$$;


--
-- Name: discover_eligible_listings(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.discover_eligible_listings() RETURNS TABLE(listing_id uuid, source_type text, listing_weight_kg numeric, listing_created_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
declare v_actor uuid:=auth.uid();v_ngo public.ngo_profiles%rowtype;
begin
 select * into v_ngo from public.ngo_profiles where user_id=v_actor and active_flag;
 if not found or v_ngo.location_verified_at is null then return; end if;
 return query
 select l.listing_id,l.source_type,l.listing_weight_kg,l.created_at
 from public.listings l join public.coordination_config cfg on cfg.singleton
 where l.listing_status='AVAILABLE'
 and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
 and ST_DWithin(
  ST_SetSRID(ST_MakePoint(v_ngo.longitude,v_ngo.latitude),4326)::geography,
  ST_SetSRID(ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::geography,
  cfg.geofence_radius_m)
 and ((l.source_type='DIRECT_DONATION' and exists(
   select 1 from public.donations d where d.donation_id=l.donation_id
   and d.donation_status='READY_FOR_PICKUP'))
 or (l.source_type='HUB_BATCH' and exists(
   select 1 from public.hub_batches b where b.batch_id=l.batch_id
   and b.batch_status='PUBLISHED')))
 order by l.created_at desc;
end $$;


--
-- Name: enforce_donation_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_donation_transition() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
 if tg_op='UPDATE' and new.donation_status is distinct from old.donation_status then
   if not (
     (old.donation_status='SUBMITTED' and new.donation_status in ('VALIDATED','CANCELLED'))
     or (old.donation_status='VALIDATED' and new.donation_status in ('READY_FOR_PICKUP','HUB_ASSIGNED','CANCELLED'))
     or (old.donation_status='READY_FOR_PICKUP' and new.donation_status in ('PICKUP_IN_PROGRESS','CANCELLED'))
     or (old.donation_status='HUB_ASSIGNED' and new.donation_status in ('AT_HUB','CANCELLED'))
     or (old.donation_status='AT_HUB' and new.donation_status='BATCHED')
     or (old.donation_status='BATCHED' and new.donation_status='PICKUP_IN_PROGRESS')
     or (old.donation_status='PICKUP_IN_PROGRESS' and new.donation_status='COLLECTED')
     or (old.donation_status='COLLECTED' and new.donation_status='DELIVERED')
   ) then raise exception 'INVALID_DONATION_TRANSITION: % -> %',old.donation_status,new.donation_status; end if;
 end if;
 new.updated_at=clock_timestamp();
 return new;
end $$;


--
-- Name: enforce_listing_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_listing_transition() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
 if tg_op='UPDATE' and new.listing_status is distinct from old.listing_status then
   if not ((old.listing_status='AVAILABLE' and new.listing_status in ('CLAIMED','CANCELLED'))
       or (old.listing_status='CLAIMED' and new.listing_status in ('AVAILABLE','CLOSED')))
   then raise exception 'INVALID_LISTING_TRANSITION'; end if;
 end if;
 return new;
end $$;


--
-- Name: geolock_app_capabilities(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geolock_app_capabilities() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $_$
declare
  v_user uuid := auth.uid();
  v_road_node_resolution boolean := false;
  v_config_version text;
begin
  if v_user is null then
    raise exception 'UNAUTHENTICATED';
  end if;

  -- V3 itself has no road-network tables. Check them dynamically so this
  -- migration remains compatible with V3 and reports false until a later,
  -- separately reviewed migration and trusted graph import configure coverage.
  if to_regclass('public.road_network_nodes') is not null
     and to_regclass('public.road_network_coverage') is not null then
    begin
      execute $query$
        select exists (
          select 1
          from public.road_network_nodes as n
          join public.road_network_coverage as c using (network_snapshot_id)
          where n.active_flag
            and c.active_flag
            and c.dataset_kind = 'OPERATIONAL'
            and c.approved_at is not null
            and extensions.st_covers(
              c.coverage_area,
              extensions.st_setsrid(
                extensions.st_makepoint(n.longitude, n.latitude), 4326
              )
            )
        )
      $query$
      into v_road_node_resolution;
    exception
      when undefined_table or undefined_column or undefined_function then
        -- A partial or incompatible graph setup is not an available capability.
        v_road_node_resolution := false;
    end;
  end if;

  select c.config_version
  into v_config_version
  from public.coordination_config as c
  where c.singleton;

  return jsonb_build_object(
    'ngo_location_registration', 'UNVERIFIED',
    'road_node_resolution', v_road_node_resolution,
    'configuration_version', v_config_version
  );
end;
$_$;


--
-- Name: geolock_storage_can_delete_unattached_image(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geolock_storage_can_delete_unattached_image(p_bucket text, p_name text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $_$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null or p_bucket<>'geolock-donation-images' then return false; end if;
  if p_name ~ ('^'||v_actor::text||'/pending/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    return exists(select 1 from public.donor_profiles dp where dp.user_id=v_actor)
      and not exists(select 1 from public.donation_images i where i.storage_path=p_name)
      and not exists(select 1 from public.hub_batch_images i where i.storage_path=p_name);
  end if;
  if p_name ~ ('^'||v_actor::text||'/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    return exists(select 1 from public.donor_profiles dp where dp.user_id=v_actor)
      and exists(select 1 from public.donations d
        where d.donation_id::text=split_part(p_name,'/',2) and d.donor_user_id=v_actor)
      and not exists(select 1 from public.donation_images i where i.storage_path=p_name)
      and not exists(select 1 from public.hub_batch_images i where i.storage_path=p_name);
  end if;
  if p_name ~ ('^'||v_actor::text||'/batches/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    return exists(select 1 from public.hub_batches b
        join public.community_hubs h using(hub_id)
        where b.batch_id::text=split_part(p_name,'/',3) and h.admin_user_id=v_actor)
      and not exists(select 1 from public.donation_images i where i.storage_path=p_name)
      and not exists(select 1 from public.hub_batch_images i where i.storage_path=p_name);
  end if;
  return false;
end;
$_$;


--
-- Name: geolock_storage_can_read_image(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geolock_storage_can_read_image(p_bucket text, p_name text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $_$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null or p_bucket<>'geolock-donation-images' then return false; end if;
  if p_name ~ ('^'||v_actor::text||'/pending/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    if exists(select 1 from public.donor_profiles dp where dp.user_id=v_actor) then
      return true;
    end if;
    -- Once attached, the same pending-path object can also be read by a
    -- permitted NGO claimant or hub admin through the existing role helper.
  end if;
  return public.can_read_geolock_donation_image(p_name)
    or public.can_read_geolock_batch_image(p_name);
end;
$_$;


--
-- Name: geolock_storage_can_upload_batch_image(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geolock_storage_can_upload_batch_image(p_bucket text, p_name text, p_metadata jsonb) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $_$
declare
  v_actor uuid:=auth.uid();
  v_ext text:=lower(split_part(coalesce(p_name,''),'.',array_length(string_to_array(coalesce(p_name,''),'.'),1)));
  v_type text:=p_metadata->>'mimetype';
begin
  if v_actor is null or p_bucket<>'geolock-donation-images'
     or coalesce(v_type,'') not in ('image/jpeg','image/png','image/webp')
     or not exists(select 1 from storage.buckets b where b.id=p_bucket and not b.public
       and b.file_size_limit=5242880
       and b.allowed_mime_types=array['image/jpeg','image/png','image/webp']::text[])
     or (v_ext in ('jpg','jpeg') and v_type<>'image/jpeg')
     or (v_ext='png' and v_type<>'image/png')
     or (v_ext='webp' and v_type<>'image/webp')
     or v_ext not in ('jpg','jpeg','png','webp')
     or p_name !~ ('^'||v_actor::text||'/batches/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    return false;
  end if;
  return exists(select 1 from public.hub_batches b
    join public.community_hubs h using(hub_id)
    where b.batch_id::text=split_part(p_name,'/',3) and h.admin_user_id=v_actor)
    and not exists(select 1 from public.hub_batch_images i
      where i.batch_id::text=split_part(p_name,'/',3));
end;
$_$;


--
-- Name: geolock_storage_can_upload_donation_image(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.geolock_storage_can_upload_donation_image(p_bucket text, p_name text, p_metadata jsonb) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $_$
declare
  v_actor uuid:=auth.uid();
  v_ext text:=lower(split_part(coalesce(p_name,''),'.',array_length(string_to_array(coalesce(p_name,''),'.'),1)));
  v_type text:=p_metadata->>'mimetype';
begin
  if v_actor is null or p_bucket<>'geolock-donation-images'
     or coalesce(v_type,'') not in ('image/jpeg','image/png','image/webp')
     or not exists(select 1 from storage.buckets b where b.id=p_bucket and not b.public
       and b.file_size_limit=5242880
       and b.allowed_mime_types=array['image/jpeg','image/png','image/webp']::text[])
     or (v_ext in ('jpg','jpeg') and v_type<>'image/jpeg')
     or (v_ext='png' and v_type<>'image/png')
     or (v_ext='webp' and v_type<>'image/webp')
     or v_ext not in ('jpg','jpeg','png','webp')
     or not exists(select 1 from public.donor_profiles dp where dp.user_id=v_actor) then
    return false;
  end if;
  -- Storage's pre-insert RLS probe supplies mimetype and contentLength; it does
  -- not reliably supply the final size key yet. The private bucket enforces the
  -- 5 MB transfer limit, and the create RPC checks stored metadata.size before
  -- attaching the object.
  if p_name ~ ('^'||v_actor::text||'/pending/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    return true;
  end if;
  -- Legacy path remains supported for an existing donor-owned donation.
  if p_name ~ ('^'||v_actor::text||'/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.](jpg|jpeg|png|webp)$') then
    return exists(select 1 from public.donations d
      where d.donation_id::text=split_part(p_name,'/',2) and d.donor_user_id=v_actor);
  end if;
  return false;
end;
$_$;


--
-- Name: get_active_donation_categories(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_active_donation_categories() RETURNS TABLE(category_id uuid, category_name text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED';
  end if;
  if not exists (
    select 1 from public.user_profiles p where p.user_id = auth.uid()
  ) then
    raise exception 'PROFILE_REQUIRED';
  end if;

  return query
  select c.category_id, c.category_name
  from public.donation_categories c
  where c.active_flag
  order by c.category_name;
end;
$$;


--
-- Name: get_batch_images(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_batch_images(p_batch uuid) RETURNS TABLE(image_id uuid, storage_path text, is_cover boolean, content_type text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.hub_batch_images i
    where i.batch_id=p_batch and public.can_read_geolock_batch_image(i.storage_path)) then
    raise exception 'BATCH_IMAGES_NOT_FOUND_OR_FORBIDDEN';
  end if;
  return query select i.image_id,i.storage_path,i.is_primary,i.content_type
  from public.hub_batch_images i where i.batch_id=p_batch order by i.created_at,i.image_id;
end;
$$;


--
-- Name: get_claimed_listing_constituents(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_claimed_listing_constituents(p_claim uuid) RETURNS TABLE(donation_id uuid, title text, total_weight_kg numeric, donation_status text, primary_image_path text, batch_cover_path text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare v_listing public.listings%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select l.* into v_listing from public.donation_claims c
  join public.listings l using(listing_id)
  where c.claim_id=p_claim and c.ngo_user_id=auth.uid()
    and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED')
      or (c.claim_status='ACTIVE' and exists(select 1 from public.claim_leases le
          where le.claim_id=c.claim_id and le.lease_status='ACTIVE'
            and le.expires_at>clock_timestamp())));
  if not found then raise exception 'CLAIM_NOT_FOUND_OR_FORBIDDEN'; end if;
  return query
  select d.donation_id,d.title,d.total_weight_kg,d.donation_status,di.storage_path,bi.storage_path
  from public.donations d
  left join lateral(select i.storage_path from public.donation_images i
    where i.donation_id=d.donation_id and i.display_order=1 limit 1) di on true
  left join lateral(select i.storage_path from public.hub_batch_images i
    where i.batch_id=v_listing.batch_id and i.is_primary limit 1) bi on true
  where (v_listing.source_type='DIRECT_DONATION' and d.donation_id=v_listing.donation_id)
     or (v_listing.source_type='HUB_BATCH' and exists(
       select 1 from public.hub_batch_members m where m.batch_id=v_listing.batch_id
         and m.donation_id=d.donation_id and m.membership_status='ACTIVE'))
  order by d.created_at,d.donation_id;
end;
$$;


--
-- Name: get_claimed_listing_detail(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_claimed_listing_detail(p_claim uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare v jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select jsonb_build_object(
    'claim_id',c.claim_id,'claim_status',c.claim_status,
    'listing_id',l.listing_id,'listing_status',l.listing_status,
    'source_type',l.source_type,
    'pickup_address',case when l.source_type='DIRECT_DONATION' then d.pickup_address else h.address_text end,
    'latitude',l.pickup_latitude,'longitude',l.pickup_longitude,
    'listing_weight_kg',l.listing_weight_kg,'lease_status',le.lease_status,
    'lease_expires_at',le.expires_at,
    'donation_ids',coalesce((select jsonb_agg(m.donation_id)
      from public.hub_batch_members m
      where m.batch_id=l.batch_id and m.membership_status='ACTIVE'),
      case when d.donation_id is null then '[]'::jsonb else jsonb_build_array(d.donation_id) end)
  ) into v
  from public.donation_claims c
  join public.listings l using(listing_id)
  left join public.donations d on d.donation_id=l.donation_id
  left join public.hub_batches b on b.batch_id=l.batch_id
  left join public.community_hubs h on h.hub_id=b.hub_id
  left join public.claim_leases le using(claim_id)
  where c.claim_id=p_claim and c.ngo_user_id=auth.uid();
  if v is null then raise exception 'CLAIM_NOT_FOUND_OR_FORBIDDEN'; end if;
  return v;
end;
$$;


--
-- Name: get_donation_images(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_donation_images(p_donation uuid) RETURNS TABLE(image_id uuid, storage_path text, display_order smallint, is_cover boolean, content_type text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.donation_images i
    where i.donation_id=p_donation and public.can_read_geolock_donation_image(i.storage_path)) then
    raise exception 'DONATION_IMAGES_NOT_FOUND_OR_FORBIDDEN';
  end if;
  return query select i.image_id,i.storage_path,i.display_order,i.display_order=1,i.content_type
  from public.donation_images i where i.donation_id=p_donation order by i.display_order;
end;
$$;


--
-- Name: get_eligible_hubs(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_eligible_hubs(p_donation uuid) RETURNS TABLE(hub_id uuid, hub_name text, address_text text, latitude double precision, longitude double precision, capacity_kg numeric, available_capacity_kg numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_donation public.donations%rowtype; v_latest public.hub_reservations%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select d.* into v_donation
  from public.donations d
  where d.donation_id = p_donation and d.donor_user_id = auth.uid();
  if not found then raise exception 'DONATION_NOT_FOUND_OR_FORBIDDEN'; end if;

  if v_donation.collection_path <> 'HUB_COLLECTION'
     or v_donation.donation_status not in ('VALIDATED','HUB_ASSIGNED') then
    raise exception 'DONATION_NOT_HUB_ELIGIBLE';
  end if;
  if v_donation.donation_status='HUB_ASSIGNED' then
    select * into v_latest from public.hub_reservations r
    where r.donation_id=p_donation
    order by r.reserved_at desc,r.reservation_id desc limit 1;
    if v_latest.reservation_id is null or exists(select 1 from public.hub_reservations r
        where r.donation_id=p_donation and r.reservation_status in ('RELEASED','CONSUMED'))
      or exists(select 1 from public.hub_reservations r where r.donation_id=p_donation
          and r.reservation_status='EXPIRED' and r.expires_at>clock_timestamp())
      or (select count(*) from public.hub_reservations r
          where r.donation_id=p_donation and r.reservation_status='ACTIVE')>1
      or (v_latest.reservation_status='EXPIRED' and exists(
          select 1 from public.hub_reservations r where r.donation_id=p_donation
            and r.reservation_status='ACTIVE'))
      or not (
      v_latest.reservation_status='EXPIRED'
      or (v_latest.reservation_status='ACTIVE'
          and v_latest.expires_at<=statement_timestamp())
    ) then raise exception 'HUB_RESERVATION_NOT_EXPIRED'; end if;
  end if;
  if exists (select 1 from public.hub_receipts r where r.donation_id=p_donation)
     or exists (select 1 from public.hub_inventory i where i.donation_id=p_donation)
     or exists (select 1 from public.hub_batch_members m
                where m.donation_id=p_donation and m.membership_status='ACTIVE') then
    raise exception 'DONATION_HAS_PHYSICAL_CUSTODY';
  end if;
  if exists (select 1 from public.hub_reservations r
             where r.donation_id=p_donation
               and r.reservation_status='ACTIVE'
               and r.expires_at > statement_timestamp()) then
    raise exception 'HUB_RESERVATION_STILL_ACTIVE';
  end if;

  return query
  with hub_usage as (
    select h.hub_id,
      coalesce((select sum(hr.received_weight_kg)
        from public.hub_inventory hi join public.hub_receipts hr using(donation_id)
        where hi.hub_id=h.hub_id
          and hi.inventory_status in ('STORED','BATCHED','RECONCILIATION_REQUIRED')),0)
      + coalesce((select sum(r.reserved_weight_kg)
        from public.hub_reservations r
        where r.hub_id=h.hub_id and r.reservation_status='ACTIVE'
          and r.expires_at > statement_timestamp()
          and not exists(select 1 from public.hub_receipts hr
                         where hr.reservation_id=r.reservation_id)),0) as used_kg
    from public.community_hubs h
  )
  select h.hub_id,h.hub_name,h.address_text,h.latitude,h.longitude,
         h.capacity_kg,greatest(0,h.capacity_kg-u.used_kg)::numeric
  from public.community_hubs h join hub_usage u using(hub_id)
  where h.active_flag
    and u.used_kg+v_donation.total_weight_kg<=h.capacity_kg
    and not exists (
      select 1 from public.donation_items i
      where i.donation_id=p_donation
        and not exists(select 1 from public.hub_accepted_categories a
                       where a.hub_id=h.hub_id and a.category_id=i.category_id)
    )
  order by h.hub_name;
end;
$$;


--
-- Name: get_eligible_listing_constituents(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_eligible_listing_constituents(p_listing uuid) RETURNS TABLE(donation_id uuid, title text, total_weight_kg numeric, donation_status text, primary_image_path text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
    AS $$
declare v_ngo public.ngo_profiles%rowtype; v_listing public.listings%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles where user_id=auth.uid() and active_flag;
  if not found or v_ngo.location_verified_at is null then raise exception 'VERIFIED_NGO_ONLY'; end if;
  select l.* into v_listing from public.listings l
  join public.coordination_config cfg on cfg.singleton
  where l.listing_id=p_listing and l.listing_status='AVAILABLE'
    and (l.listing_expires_at is null or l.listing_expires_at>clock_timestamp())
    and extensions.ST_DWithin(
      extensions.ST_SetSRID(extensions.ST_MakePoint(v_ngo.longitude,v_ngo.latitude),4326)::extensions.geography,
      extensions.ST_SetSRID(extensions.ST_MakePoint(l.pickup_longitude,l.pickup_latitude),4326)::extensions.geography,
      cfg.geofence_radius_m)
    and ((l.source_type='DIRECT_DONATION' and exists(select 1 from public.donations d
      where d.donation_id=l.donation_id and d.donation_status='READY_FOR_PICKUP'))
      or (l.source_type='HUB_BATCH' and exists(select 1 from public.hub_batches b
        where b.batch_id=l.batch_id and b.batch_status='PUBLISHED')));
  if not found then raise exception 'LISTING_NOT_ELIGIBLE'; end if;
  return query
  -- Listing photos remain withheld until an approved graph can establish that
  -- discovery eligibility includes trusted road-node validation.
  select d.donation_id,d.title,d.total_weight_kg,d.donation_status,null::text
  from public.donations d
  left join lateral(select x.storage_path from public.donation_images x
    where x.donation_id=d.donation_id and x.display_order=1 limit 1) i on true
  where (v_listing.source_type='DIRECT_DONATION' and d.donation_id=v_listing.donation_id)
     or (v_listing.source_type='HUB_BATCH' and exists(select 1 from public.hub_batch_members m
       where m.batch_id=v_listing.batch_id and m.donation_id=d.donation_id and m.membership_status='ACTIVE'))
  order by d.created_at,d.donation_id;
end;
$$;


--
-- Name: get_hub_batch_details(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_hub_batch_details(p_hub uuid, p_batch uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare v_result jsonb;
begin
  if auth.uid() is null or not exists(select 1 from public.community_hubs
    where hub_id=p_hub and admin_user_id=auth.uid()) then raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN'; end if;
  select jsonb_build_object(
    'batch_id',b.batch_id,'batch_status',b.batch_status,'batch_weight_kg',b.batch_weight_kg,
    'batch_cover_path',coalesce(bi.storage_path,member_img.storage_path),
    'donations',coalesce((select jsonb_agg(jsonb_build_object(
      'donation_id',d.donation_id,'title',d.title,'weight_kg',d.total_weight_kg,
      'donation_status',d.donation_status,'primary_image_path',di.storage_path)
      order by d.created_at,d.donation_id)
      from public.hub_batch_members m join public.donations d using(donation_id)
      left join lateral(select i.storage_path from public.donation_images i
        where i.donation_id=d.donation_id and i.display_order=1 limit 1) di on true
      where m.batch_id=b.batch_id and m.membership_status='ACTIVE'),'[]'::jsonb)
  ) into v_result
  from public.hub_batches b
  left join lateral(select i.storage_path from public.hub_batch_images i
    where i.batch_id=b.batch_id and i.is_primary limit 1) bi on true
  left join lateral(select i.storage_path from public.hub_batch_members m
    join public.donations d using(donation_id)
    join public.donation_images i on i.donation_id=d.donation_id and i.display_order=1
    where m.batch_id=b.batch_id and m.membership_status='ACTIVE'
    order by d.created_at,d.donation_id limit 1) member_img on true
  where b.hub_id=p_hub and b.batch_id=p_batch;
  if v_result is null then raise exception 'BATCH_NOT_FOUND_OR_FORBIDDEN'; end if;
  return v_result;
end;
$$;


--
-- Name: get_hub_dashboard(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_hub_dashboard(p_hub uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_hub public.community_hubs%rowtype;
  v_stored numeric;
  v_reserved numeric;
  v_awaiting bigint;
  v_stored_count bigint;
  v_published bigint;
  v_collections bigint;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select h.* into v_hub from public.community_hubs h
  where h.hub_id=p_hub and h.admin_user_id=auth.uid();
  if not found then raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN'; end if;

  select coalesce(sum(hr.received_weight_kg),0) into v_stored
  from public.hub_inventory hi
  join public.hub_receipts hr using(donation_id)
  where hi.hub_id=p_hub
    and hi.inventory_status in ('STORED','BATCHED','RECONCILIATION_REQUIRED');
  select coalesce(sum(r.reserved_weight_kg),0),
    count(*) filter(where r.reservation_status='ACTIVE'
      and r.expires_at>statement_timestamp()
      and not exists(select 1 from public.hub_receipts hr where hr.reservation_id=r.reservation_id))
  into v_reserved,v_awaiting
  from public.hub_reservations r
  where r.hub_id=p_hub and r.reservation_status='ACTIVE'
    and r.expires_at>statement_timestamp()
    and not exists(select 1 from public.hub_receipts hr where hr.reservation_id=r.reservation_id);
  select count(*) into v_stored_count from public.hub_inventory hi
  where hi.hub_id=p_hub and hi.inventory_status in ('STORED','BATCHED','RECONCILIATION_REQUIRED');
  select count(*) into v_published from public.hub_batches b
  where b.hub_id=p_hub and b.batch_status='PUBLISHED';
  select count(distinct pt.task_id) into v_collections
  from public.pickup_tasks pt
  join public.listings l using(listing_id)
  join public.hub_batches b on b.batch_id=l.batch_id
  where b.hub_id=p_hub and b.batch_status in ('PUBLISHED','CLAIMED')
    and pt.task_status in ('CONFIRMED','PLANNED','DISPATCHED');

  return jsonb_build_object(
    'hub_id',v_hub.hub_id,'hub_name',v_hub.hub_name,
    'capacity_kg',v_hub.capacity_kg,
    'committed_capacity_kg',v_stored+v_reserved,
    'available_capacity_kg',greatest(0,v_hub.capacity_kg-v_stored-v_reserved),
    'awaiting_dropoff_count',v_awaiting,
    'stored_donation_count',v_stored_count,
    'published_batch_count',v_published,
    'upcoming_collection_count',v_collections
  );
end;
$$;


--
-- Name: get_hub_donation_covers(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_hub_donation_covers(p_hub uuid) RETURNS TABLE(donation_id uuid, primary_image_path text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null or not exists(select 1 from public.community_hubs h
    where h.hub_id=p_hub and h.admin_user_id=auth.uid()) then
    raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN';
  end if;
  return query select distinct d.donation_id,i.storage_path
  from public.donations d
  join public.donation_images i on i.donation_id=d.donation_id and i.display_order=1
  where exists(select 1 from public.hub_reservations r where r.donation_id=d.donation_id and r.hub_id=p_hub
                 and r.reservation_status='ACTIVE' and r.expires_at>clock_timestamp())
     or exists(select 1 from public.hub_inventory hi where hi.donation_id=d.donation_id and hi.hub_id=p_hub);
end;
$$;


--
-- Name: get_my_claim_cards(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_claim_cards() RETURNS TABLE(claim_id uuid, listing_id uuid, claim_status text, claimed_at timestamp with time zone, lease_id uuid, lease_status text, lease_expires_at timestamp with time zone, task_status text, source_type text, listing_weight_kg numeric, title text, primary_image_path text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null or not exists(select 1 from public.ngo_profiles
    where user_id=auth.uid() and active_flag) then raise exception 'ACTIVE_NGO_ONLY'; end if;
  return query
  select c.claim_id,c.listing_id,c.claim_status,c.claimed_at,le.lease_id,le.lease_status,
    le.expires_at,pt.task_status,l.source_type,l.listing_weight_kg,
    case when l.source_type='DIRECT_DONATION' then d.title else 'Community Hub Batch' end,
    case when di.storage_path is not null and public.can_read_geolock_donation_image(di.storage_path)
      then di.storage_path
      when bi.storage_path is not null and public.can_read_geolock_batch_image(bi.storage_path)
      then bi.storage_path
      when member_img.storage_path is not null and public.can_read_geolock_donation_image(member_img.storage_path)
      then member_img.storage_path end
  from public.donation_claims c join public.listings l using(listing_id)
  left join public.donations d on d.donation_id=l.donation_id
  left join public.hub_batches b on b.batch_id=l.batch_id
  left join public.claim_leases le using(claim_id)
  left join public.pickup_tasks pt using(claim_id)
  left join lateral(select i.storage_path from public.donation_images i
    where i.donation_id=d.donation_id and i.display_order=1 limit 1) di on true
  left join lateral(select i.storage_path from public.hub_batch_images i
    where i.batch_id=b.batch_id and i.is_primary limit 1) bi on true
  left join lateral(select i.storage_path from public.hub_batch_members m
    join public.donation_images i on i.donation_id=m.donation_id and i.display_order=1
    join public.donations md on md.donation_id=m.donation_id
    where m.batch_id=b.batch_id and m.membership_status='ACTIVE'
    order by md.created_at,md.donation_id limit 1) member_img on true
  where c.ngo_user_id=auth.uid() order by c.claimed_at desc;
end;
$$;


--
-- Name: get_my_claims(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_claims() RETURNS TABLE(claim_id uuid, listing_id uuid, claim_status text, claimed_at timestamp with time zone, lease_id uuid, lease_status text, lease_expires_at timestamp with time zone, task_status text, source_type text, listing_weight_kg numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.ngo_profiles where user_id=auth.uid() and active_flag) then
    raise exception 'ACTIVE_NGO_ONLY';
  end if;
  return query select c.claim_id,c.listing_id,c.claim_status,c.claimed_at,
    le.lease_id,le.lease_status,le.expires_at,pt.task_status,l.source_type,l.listing_weight_kg
  from public.donation_claims c
  join public.listings l using(listing_id)
  left join public.claim_leases le using(claim_id)
  left join public.pickup_tasks pt using(claim_id)
  where c.ngo_user_id=auth.uid()
  order by c.claimed_at desc;
end;
$$;


--
-- Name: get_my_donation_dashboard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_donation_dashboard() RETURNS TABLE(donation_id uuid, title text, donation_status text, collection_path text, total_weight_kg numeric, created_at timestamp with time zone, hub_name text, reservation_status text, listing_status text, receipt_status text, inventory_status text, item_count bigint, primary_image_path text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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
  left join public.listings l on l.donation_id=d.donation_id
    and l.source_type='DIRECT_DONATION'
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
$$;


--
-- Name: get_my_donation_dashboard_v2(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_donation_dashboard_v2() RETURNS TABLE(donation_id uuid, title text, donation_status text, collection_path text, total_weight_kg numeric, created_at timestamp with time zone, hub_name text, reservation_status text, reservation_effective_status text, reservation_expires_at timestamp with time zone, listing_status text, receipt_status text, inventory_status text, item_count bigint, primary_image_path text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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
  left join public.listings l on l.donation_id=d.donation_id
    and l.source_type='DIRECT_DONATION'
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
$$;


--
-- Name: get_my_donation_detail(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_donation_detail(p_donation uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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
      when l.pickup_road_node_id is null then 'PENDING_NODE' else 'UNVERIFIED' end,
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
  left join public.listings l on l.donation_id=d.donation_id
    and l.source_type='DIRECT_DONATION'
  where d.donation_id=p_donation and d.donor_user_id=auth.uid();
  return v_result;
end;
$$;


--
-- Name: get_my_donations(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_donations() RETURNS TABLE(donation_id uuid, title text, donation_status text, collection_path text, total_weight_kg numeric, created_at timestamp with time zone, hub_name text, reservation_status text, listing_routing_status text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED';
  end if;
  if not exists (
    select 1 from public.donor_profiles dp where dp.user_id = auth.uid()
  ) then
    raise exception 'DONOR_ONLY';
  end if;

  return query
  select d.donation_id, d.title, d.donation_status, d.collection_path,
    d.total_weight_kg, d.created_at,
    latest.hub_name, latest.reservation_status,
    case
      when l.listing_id is null then null::text
      when l.pickup_road_node_id is null then 'PENDING_NODE'::text
      else 'UNVERIFIED'::text
    end as listing_routing_status
  from public.donations d
  left join lateral (
    select h.hub_name, r.reservation_status
    from public.hub_reservations r
    join public.community_hubs h using (hub_id)
    where r.donation_id = d.donation_id
    order by r.reserved_at desc
    limit 1
  ) latest on true
  left join public.listings l
    on l.donation_id = d.donation_id
   and l.source_type = 'DIRECT_DONATION'
  where d.donor_user_id = auth.uid()
  order by d.created_at desc, d.donation_id;
end;
$$;


--
-- Name: get_my_hub_batches_dashboard(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_hub_batches_dashboard(p_hub uuid) RETURNS TABLE(batch_id uuid, batch_status text, batch_weight_kg numeric, batch_donation_count integer, category_name text, published_at timestamp with time zone, primary_image_path text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null or not exists(select 1 from public.community_hubs
    where hub_id=p_hub and admin_user_id=auth.uid()) then raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN'; end if;
  return query
  select b.batch_id,b.batch_status,b.batch_weight_kg,b.batch_donation_count,c.category_name,
    b.published_at,coalesce(bi.storage_path,member_img.storage_path)
  from public.hub_batches b
  left join public.donation_categories c on c.category_id=b.batch_category_id
  left join lateral(select i.storage_path from public.hub_batch_images i
    where i.batch_id=b.batch_id and i.is_primary limit 1) bi on true
  left join lateral(select i.storage_path from public.hub_batch_members m
    join public.donations d using(donation_id)
    join public.donation_images i on i.donation_id=d.donation_id and i.display_order=1
    where m.batch_id=b.batch_id and m.membership_status='ACTIVE'
    order by d.created_at,d.donation_id limit 1) member_img on true
  where b.hub_id=p_hub and b.batch_status<>'DRAFT' order by b.created_at desc;
end;
$$;


--
-- Name: get_my_hub_inventory(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_hub_inventory(p_hub uuid) RETURNS TABLE(donation_id uuid, title text, donation_status text, received_weight_kg numeric, inventory_status text, category_ids uuid[], category_name text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.community_hubs h
    where h.hub_id=p_hub and h.admin_user_id=auth.uid()) then
    raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN';
  end if;
  return query
  select d.donation_id,d.title,d.donation_status,hr.received_weight_kg,
    hi.inventory_status,array_agg(distinct di.category_id),
    case when count(distinct di.category_id)=1 then min(cat.category_name)
      else 'Mixed categories' end
  from public.hub_inventory hi
  join public.donations d using(donation_id)
  join public.hub_receipts hr using(donation_id)
  left join public.donation_items di using(donation_id)
  left join public.donation_categories cat using(category_id)
  where hi.hub_id=p_hub
  group by d.donation_id,hr.received_weight_kg,hi.inventory_status
  order by min(hr.received_at) desc;
end;
$$;


--
-- Name: get_my_hub_reservations(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_hub_reservations(p_hub uuid) RETURNS TABLE(reservation_id uuid, donation_id uuid, title text, reserved_weight_kg numeric, status text, expires_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.community_hubs h
    where h.hub_id=p_hub and h.admin_user_id=auth.uid()) then
    raise exception 'HUB_NOT_FOUND_OR_FORBIDDEN';
  end if;
  return query select r.reservation_id,r.donation_id,d.title,r.reserved_weight_kg,
    case when r.reservation_status='ACTIVE'
      and r.expires_at<=statement_timestamp() then 'EXPIRED'
      else r.reservation_status end,r.expires_at
  from public.hub_reservations r join public.donations d using(donation_id)
  where r.hub_id=p_hub order by r.reserved_at desc,r.reservation_id desc;
end;
$$;


--
-- Name: get_my_hubs(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_hubs() RETURNS TABLE(hub_id uuid, hub_name text, address_text text, latitude double precision, longitude double precision, capacity_kg numeric, active_flag boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.hub_admin_profiles where user_id=auth.uid()) then
    raise exception 'HUB_ADMIN_ONLY';
  end if;
  return query select h.hub_id,h.hub_name,h.address_text,h.latitude,h.longitude,
    h.capacity_kg,h.active_flag from public.community_hubs h
  where h.admin_user_id=auth.uid() order by h.created_at desc;
end;
$$;


--
-- Name: get_my_profile(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_profile() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare
  v_user uuid := auth.uid();
  v_profile jsonb;
begin
  if v_user is null then
    raise exception 'UNAUTHENTICATED';
  end if;

  select jsonb_build_object(
    'user_id', u.user_id,
    'full_name', u.full_name,
    'phone_number', u.phone_number,
    'role', u.role,
    'created_at', u.created_at,
    'ngo_name', n.ngo_name,
    'operating_address', n.operating_address,
    'latitude', n.latitude,
    'longitude', n.longitude,
    'location_verified_at', n.location_verified_at,
    'location_status', case
      when n.user_id is null then null
      when n.location_verified_at is null then 'PENDING_VERIFICATION'
      else 'VERIFIED'
    end,
    'hub_admin', h.user_id is not null
  )
  into v_profile
  from public.user_profiles as u
  left join public.ngo_profiles as n on n.user_id = u.user_id
  left join public.hub_admin_profiles as h on h.user_id = u.user_id
  where u.user_id = v_user;

  -- No role profile yet is a normal onboarding state; return JSON null.
  return v_profile;
end;
$$;


--
-- Name: guard_batch_immutability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_batch_immutability() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_status text;
begin
 if tg_table_name='hub_batch_members' then
   select batch_status into v_status from public.hub_batches
   where batch_id=coalesce(new.batch_id,old.batch_id) for update;
   if v_status<>'DRAFT' then raise exception 'PUBLISHED_BATCH_IMMUTABLE'; end if;
   return case when tg_op='DELETE' then old else new end;
 end if;
 if tg_op='DELETE' then
   if old.batch_status<>'DRAFT' then raise exception 'PUBLISHED_BATCH_IMMUTABLE'; end if;
   return old;
 end if;
 if old.batch_status<>'DRAFT' then
   -- Only operational status changes are permitted after publishing.
   if row(new.hub_id,new.batch_category_id,new.batch_weight_kg,new.batch_donation_count,
          new.batch_version,new.created_by,new.published_at)
      is distinct from
      row(old.hub_id,old.batch_category_id,old.batch_weight_kg,old.batch_donation_count,
          old.batch_version,old.created_by,old.published_at) then
      raise exception 'PUBLISHED_BATCH_IMMUTABLE';
   end if;
 end if;
 return new;
end $$;


--
-- Name: guard_donation_items(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_donation_items() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_donation uuid; v_status text;
begin
 v_donation=case when tg_op='DELETE' then old.donation_id else new.donation_id end;
 if tg_op='UPDATE' and new.donation_id<>old.donation_id then
  raise exception 'DONATION_ITEM_REPARENT_FORBIDDEN';
 end if;
 select donation_status into v_status from public.donations
 where donation_id=v_donation for update;
 if v_status is distinct from 'SUBMITTED' then
  raise exception 'DONATION_ITEMS_FROZEN';
 end if;
 return case when tg_op='DELETE' then old else new end;
end $$;


--
-- Name: prevent_audit_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_audit_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin raise exception 'AUDIT_APPEND_ONLY'; end $$;


--
-- Name: prevent_role_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_role_change() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
 if new.user_id is distinct from old.user_id or new.role is distinct from old.role then
   raise exception 'IMMUTABLE_ROLE';
 end if;
 return new;
end $$;


--
-- Name: publish_whole_donation_batch(uuid, uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.publish_whole_donation_batch(p_hub uuid, p_donation_ids uuid[]) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
declare
  v_actor uuid:=auth.uid(); v_batch uuid; v_count integer; v_weight numeric;
  v_min integer; v_max integer; v_limit numeric; v_cat uuid; v_cat_count integer;
  v_h public.community_hubs%rowtype; v_d uuid;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_h from public.community_hubs where hub_id=p_hub;
  if not found or v_h.admin_user_id is distinct from v_actor then
    raise exception 'NOT_HUB_ADMIN';
  end if;
  if not v_h.active_flag then raise exception 'HUB_INACTIVE'; end if;

  select batch_min_donations,batch_max_donations,batch_max_weight_kg
  into v_min,v_max,v_limit from public.coordination_config where singleton;
  select count(distinct x) into v_count from unnest(p_donation_ids) x;
  if v_count<>coalesce(array_length(p_donation_ids,1),0)
     or v_count<v_min or v_count>v_max then raise exception 'INVALID_BATCH_COUNT'; end if;

  -- All writers that can conflict on these donations acquire donation rows
  -- before hub rows. Stable UUID order prevents batch-vs-batch lock inversion.
  for v_d in select distinct unnest(p_donation_ids) order by 1 loop
    perform 1 from public.donations d
    where d.donation_id=v_d and d.donation_status='AT_HUB' for update;
    if not found then raise exception 'DONATION_NOT_STORED_AT_HUB'; end if;
  end loop;
  select * into v_h from public.community_hubs where hub_id=p_hub for update;
  if not found or v_h.admin_user_id is distinct from v_actor then
    raise exception 'NOT_HUB_ADMIN';
  end if;
  if not v_h.active_flag then raise exception 'HUB_INACTIVE'; end if;

  for v_d in select distinct unnest(p_donation_ids) order by 1 loop
    perform 1 from public.hub_inventory hi
    where hi.donation_id=v_d and hi.hub_id=p_hub
      and hi.inventory_status='STORED' for update;
    if not found then raise exception 'DONATION_NOT_STORED_AT_HUB'; end if;
    if exists(select 1 from public.hub_batch_members
      where donation_id=v_d and membership_status='ACTIVE') then
      raise exception 'DONATION_ALREADY_BATCHED';
    end if;
  end loop;

  select coalesce(sum(hr.received_weight_kg),0) into v_weight
  from public.hub_receipts hr where hr.donation_id=any(p_donation_ids);
  if v_weight>v_limit then raise exception 'BATCH_WEIGHT_EXCEEDED'; end if;
  select count(distinct di.category_id) into v_cat_count
  from public.donation_items di where di.donation_id=any(p_donation_ids);
  select di.category_id into v_cat from public.donation_items di
  where di.donation_id=any(p_donation_ids) limit 1;
  if v_cat_count<>1 then raise exception 'BATCH_CATEGORY_INCOMPATIBLE'; end if;

  insert into public.hub_batches(hub_id,batch_category_id,batch_weight_kg,
    batch_donation_count,created_by)
  values(p_hub,v_cat,v_weight,v_count,v_actor) returning batch_id into v_batch;
  insert into public.hub_batch_members(batch_id,hub_id,donation_id)
  select v_batch,p_hub,unnest(p_donation_ids);
  update public.hub_inventory set inventory_status='BATCHED'
  where donation_id=any(p_donation_ids);
  update public.donations set donation_status='BATCHED'
  where donation_id=any(p_donation_ids);
  update public.hub_batches set batch_status='PUBLISHED',published_at=clock_timestamp()
  where batch_id=v_batch;
  insert into public.listings(source_type,batch_id,listing_weight_kg,
    pickup_latitude,pickup_longitude,pickup_road_node_id)
  values('HUB_BATCH',v_batch,v_weight,v_h.latitude,v_h.longitude,v_h.road_node_id);
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
    event_type,requested_state,resulting_state,outcome,details)
  values(v_actor,'HUB_ADMIN','BATCH',v_batch,'PUBLISH_BATCH','PUBLISHED',
    'PUBLISHED','SUCCESS',jsonb_build_object('count',v_count,'weight_kg',v_weight));
  return v_batch;
end;
$$;


--
-- Name: recover_expired_claims(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recover_expired_claims(p_limit integer DEFAULT 100) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
declare v_rec record;v_task_status text;v_l public.listings%rowtype;
 v_processed integer:=0;v_uncertain boolean;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'SERVICE_ROLE_ONLY'; end if;
 for v_rec in
  select c.claim_id,c.listing_id,cl.lease_id from public.claim_leases cl
  join public.donation_claims c on c.claim_id=cl.claim_id
  where cl.lease_status='ACTIVE' and cl.expires_at<=clock_timestamp()
  order by cl.expires_at
  for update of cl skip locked limit greatest(1,least(p_limit,1000))
 loop
  select * into v_l from public.listings where listing_id=v_rec.listing_id for update;
  select task_status into v_task_status from public.pickup_tasks where claim_id=v_rec.claim_id for update;
  v_uncertain=v_task_status in ('DISPATCHED','COLLECTED')
   or v_l.listing_status='CLOSED'
   or (v_l.source_type='DIRECT_DONATION' and exists(
    select 1 from public.donations where donation_id=v_l.donation_id
    and donation_status in ('PICKUP_IN_PROGRESS','COLLECTED','DELIVERED')))
   or (v_l.source_type='HUB_BATCH' and exists(
    select 1 from public.donations where donation_id in
     (select donation_id from public.hub_batch_members where batch_id=v_l.batch_id)
    and donation_status in ('PICKUP_IN_PROGRESS','COLLECTED','DELIVERED')));
  if v_uncertain then
   update public.claim_leases set lease_status='RECONCILIATION_REQUIRED'
    where lease_id=v_rec.lease_id;
   update public.donation_claims set claim_status='RECONCILIATION_REQUIRED'
    where claim_id=v_rec.claim_id;
  else
   update public.claim_leases set lease_status='RELEASED',closed_at=clock_timestamp(),
    release_reason='EXPIRED_SAFE_RELEASE' where lease_id=v_rec.lease_id;
   update public.donation_claims set claim_status='RELEASED',closed_at=clock_timestamp(),
    close_reason='EXPIRED_SAFE_RELEASE' where claim_id=v_rec.claim_id;
   update public.pickup_tasks set task_status='STALE' where claim_id=v_rec.claim_id;
   if v_l.listing_status='CLAIMED'
      and (v_l.listing_expires_at is null or v_l.listing_expires_at>clock_timestamp()) then
     update public.listings set listing_status='AVAILABLE',listing_version=listing_version+1
      where listing_id=v_l.listing_id;
   end if;
  end if;
  insert into public.audit_events(actor_role,entity_type,entity_id,event_type,claim_id,
   lease_id,previous_state,requested_state,resulting_state,outcome,reason_code)
  values('SYSTEM','CLAIM',v_rec.claim_id,'LEASE_RECOVERY',v_rec.claim_id,v_rec.lease_id,
   'ACTIVE',case when v_uncertain then 'RECONCILIATION_REQUIRED' else 'RELEASED' end,
   case when v_uncertain then 'RECONCILIATION_REQUIRED' else 'RELEASED' end,'SUCCESS',
   case when v_uncertain then 'HANDOVER_UNCERTAIN' else 'EXPIRED_SAFE_RELEASE' end);
  v_processed=v_processed+1;
 end loop;
 return v_processed;
end $$;


--
-- Name: register_community_hub(text, text, double precision, double precision, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.register_community_hub(p_name text, p_address text, p_lat double precision, p_lon double precision, p_capacity_kg numeric, p_road_node text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
declare v_actor uuid:=auth.uid();v_hub uuid;
begin
 if not exists(select 1 from public.hub_admin_profiles where user_id=v_actor)
 then raise exception 'HUB_ADMIN_ONLY'; end if;
 if p_capacity_kg not between 50 and 250 then raise exception 'CAPACITY_MUST_BE_50_TO_250_KG'; end if;
 insert into public.community_hubs(admin_user_id,hub_name,address_text,latitude,longitude,
 capacity_kg,road_node_id)
 values(v_actor,p_name,p_address,p_lat,p_lon,p_capacity_kg,p_road_node)
 returning hub_id into v_hub;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
 event_type,requested_state,resulting_state,outcome)
 values(v_actor,'HUB_ADMIN','HUB',v_hub,'REGISTER_HUB','ACTIVE','ACTIVE','SUCCESS');
 return v_hub;
end $$;


--
-- Name: register_role_profile(text, text, text, text, text, text, double precision, double precision, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.register_role_profile(p_full_name text, p_role text, p_phone text DEFAULT NULL::text, p_ngo_name text DEFAULT NULL::text, p_registration_number text DEFAULT NULL::text, p_operating_address text DEFAULT NULL::text, p_latitude double precision DEFAULT NULL::double precision, p_longitude double precision DEFAULT NULL::double precision, p_road_node_id text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
    AS $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'UNAUTHENTICATED';
  end if;

  if p_role not in ('DONOR', 'NGO') then
    raise exception 'ROLE_NOT_SELF_SERVICE';
  end if;

  if nullif(btrim(p_full_name), '') is null then
    raise exception 'FULL_NAME_REQUIRED';
  end if;

  if exists (
    select 1 from public.user_profiles as u where u.user_id = v_user
  ) then
    raise exception 'ROLE_ALREADY_REGISTERED';
  end if;

  if p_role = 'NGO' and (
    nullif(btrim(p_ngo_name), '') is null
    or nullif(btrim(p_operating_address), '') is null
    or p_latitude is null
    or p_longitude is null
    or p_latitude not between -90 and 90
    or p_longitude not between -180 and 180
  ) then
    raise exception 'NGO_LOCATION_REQUIRED';
  end if;

  insert into public.user_profiles(user_id, full_name, phone_number, role)
  values (v_user, p_full_name, p_phone, p_role);

  if p_role = 'DONOR' then
    insert into public.donor_profiles(user_id) values (v_user);
  else
    insert into public.ngo_profiles(
      user_id, ngo_name, registration_number, operating_address,
      latitude, longitude, road_node_id, location_verified_at
    )
    values (
      v_user, p_ngo_name, p_registration_number, p_operating_address,
      p_latitude, p_longitude, null, null
    );
  end if;

  insert into public.audit_events(
    actor_user_id, actor_role, entity_type, entity_id, event_type,
    requested_state, resulting_state, reason_code, outcome
  )
  values (
    v_user, p_role, 'USER', v_user, 'REGISTER_ROLE', p_role, p_role,
    case when p_role = 'NGO' then 'LOCATION_PENDING_TRUSTED_VERIFICATION' end,
    'SUCCESS'
  );

  return v_user;
end;
$$;


--
-- Name: require_donation_photo_before_commit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.require_donation_photo_before_commit() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  if not exists(select 1 from public.donation_images i where i.donation_id=new.donation_id) then
    raise exception 'DONATION_REQUIRES_AT_LEAST_ONE_PHOTO';
  end if;
  return null;
end;
$$;


--
-- Name: reserve_hub_capacity(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reserve_hub_capacity(p_donation uuid, p_hub uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
declare
  v_actor uuid:=auth.uid(); v_d public.donations%rowtype;
  v_h public.community_hubs%rowtype; v_old_hub uuid;
  v_latest public.hub_reservations%rowtype;
  v_used numeric; v_reserved numeric; v_res uuid; v_minutes integer; v_active_count integer;
  v_old public.hub_reservations%rowtype;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_d from public.donations where donation_id=p_donation for update;
  if not found or v_d.donor_user_id is distinct from v_actor then
    raise exception 'NOT_DONOR_OWNER';
  end if;
  if v_d.collection_path<>'HUB_COLLECTION'
     or v_d.donation_status not in ('VALIDATED','HUB_ASSIGNED') then
    raise exception 'DONATION_NOT_HUB_ELIGIBLE';
  end if;

  if v_d.donation_status='HUB_ASSIGNED' then
    select * into v_latest from public.hub_reservations
    where donation_id=p_donation
    order by reserved_at desc,reservation_id desc limit 1;
    select count(*) into v_active_count from public.hub_reservations
    where donation_id=p_donation and reservation_status='ACTIVE';
    if v_latest.reservation_id is null or exists(select 1 from public.hub_reservations r
        where r.donation_id=p_donation and r.reservation_status in ('RELEASED','CONSUMED'))
      or exists(select 1 from public.hub_reservations r where r.donation_id=p_donation
          and r.reservation_status='EXPIRED' and r.expires_at>clock_timestamp())
      or (select count(*) from public.hub_reservations r
          where r.donation_id=p_donation and r.reservation_status='ACTIVE')>1
      or (v_latest.reservation_status='EXPIRED' and v_active_count<>0)
      or not (v_latest.reservation_status='EXPIRED'
      or (v_latest.reservation_status='ACTIVE'
        and v_latest.expires_at<=clock_timestamp())) then
      raise exception 'HUB_RESERVATION_NOT_EXPIRED';
    end if;
  end if;

  select * into v_old from public.hub_reservations
  where donation_id=p_donation and reservation_status='ACTIVE'
  order by reserved_at desc limit 1;
  if found then v_old_hub:=v_old.hub_id; end if;
  if v_d.donation_status='HUB_ASSIGNED' and v_old.reservation_id is not null
     and v_old.expires_at>clock_timestamp() then
    raise exception 'HUB_RESERVATION_STILL_ACTIVE';
  end if;
  if exists(select 1 from public.hub_receipts where donation_id=p_donation)
     or exists(select 1 from public.hub_inventory where donation_id=p_donation)
     or exists(select 1 from public.hub_batch_members
       where donation_id=p_donation and membership_status='ACTIVE') then
    raise exception 'DONATION_HAS_PHYSICAL_CUSTODY';
  end if;

  -- Deterministic hub lock order protects cross-hub reassignment.
  perform 1 from public.community_hubs h
  where h.hub_id=p_hub or h.hub_id=v_old_hub
  order by h.hub_id for update;
  if v_old_hub is not null and not exists(
      select 1 from public.community_hubs where hub_id=v_old_hub) then
    raise exception 'OLD_RESERVATION_HUB_MISSING';
  end if;
  select * into v_h from public.community_hubs where hub_id=p_hub;
  if not found or not v_h.active_flag then raise exception 'HUB_INACTIVE'; end if;

  if v_old.reservation_id is not null then
    select * into v_old from public.hub_reservations
    where reservation_id=v_old.reservation_id for update;
    if not found or v_old.donation_id is distinct from p_donation
        or v_old.hub_id is distinct from v_old_hub then
      raise exception 'OLD_RESERVATION_CHANGED';
    end if;
    if v_old.reservation_status='ACTIVE' then
      if v_old.expires_at>clock_timestamp() then
        raise exception 'HUB_RESERVATION_STILL_ACTIVE';
      end if;
      update public.hub_reservations set reservation_status='EXPIRED'
      where reservation_id=v_old.reservation_id and reservation_status='ACTIVE';
      insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
        event_type,previous_state,requested_state,resulting_state,reason_code,
        outcome,correlation_id,details,configuration_version)
      select v_actor,'DONOR','HUB_RESERVATION',v_old.reservation_id,
        'EXPIRE_HUB_RESERVATION','ACTIVE','EXPIRED','EXPIRED','RESERVATION_TIMEOUT',
        'SUCCESS',v_old.reservation_id,
        jsonb_build_object('donation_id',p_donation,'hub_id',v_old.hub_id),c.config_version
      from public.coordination_config c where c.singleton;
    end if;
  end if;

  if not exists(select 1 from public.donation_items where donation_id=p_donation)
    then raise exception 'EMPTY_DONATION'; end if;
  if exists(select 1 from public.donation_items di where di.donation_id=p_donation
    and not exists(select 1 from public.hub_accepted_categories a
      where a.hub_id=p_hub and a.category_id=di.category_id)) then
    raise exception 'CATEGORY_NOT_ACCEPTED';
  end if;

  select coalesce(sum(hr.received_weight_kg),0) into v_used
  from public.hub_inventory hi join public.hub_receipts hr using(donation_id)
  where hi.hub_id=p_hub
    and hi.inventory_status in ('STORED','BATCHED','RECONCILIATION_REQUIRED');
  select coalesce(sum(r.reserved_weight_kg),0) into v_reserved
  from public.hub_reservations r
  where r.hub_id=p_hub and r.reservation_status='ACTIVE'
    and r.expires_at>clock_timestamp()
    and not exists(select 1 from public.hub_receipts hr
      where hr.reservation_id=r.reservation_id);
  if v_used+v_reserved+v_d.total_weight_kg>v_h.capacity_kg then
    raise exception 'HUB_CAPACITY_EXCEEDED';
  end if;
  select hub_reservation_minutes into v_minutes
  from public.coordination_config where singleton;
  insert into public.hub_reservations(donation_id,hub_id,reserved_weight_kg,expires_at)
  values(p_donation,p_hub,v_d.total_weight_kg,
    clock_timestamp()+make_interval(mins=>v_minutes)) returning reservation_id into v_res;
  if v_d.donation_status='VALIDATED' then
    update public.donations set donation_status='HUB_ASSIGNED'
    where donation_id=p_donation;
  end if;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
    event_type,previous_state,requested_state,resulting_state,outcome,details,
    correlation_id,configuration_version)
  select v_actor,'DONOR','DONATION',p_donation,'RESERVE_HUB',v_d.donation_status,
    'HUB_ASSIGNED','HUB_ASSIGNED','SUCCESS',
    jsonb_build_object('hub_id',p_hub,'reservation_id',v_res,
      'supersedes_reservation_id',v_old.reservation_id),v_res,c.config_version
  from public.coordination_config c where c.singleton;
  return v_res;
end;
$$;


--
-- Name: start_pickup(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.start_pickup(p_claim uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
declare v_actor uuid:=auth.uid();v_c public.donation_claims%rowtype;
 v_l public.listings%rowtype;v_lease public.claim_leases%rowtype;
begin
 select * into v_c from public.donation_claims where claim_id=p_claim for update;
 if not found or v_c.ngo_user_id is distinct from v_actor or v_c.claim_status<>'ACTIVE'
 then raise exception 'NOT_ACTIVE_CLAIM_HOLDER'; end if;
 select * into v_lease from public.claim_leases where claim_id=p_claim for update;
 if v_lease.lease_status<>'ACTIVE' or v_lease.expires_at<=clock_timestamp()
 then raise exception 'STALE_OR_EXPIRED_LEASE'; end if;
 select * into v_l from public.listings where listing_id=v_c.listing_id for update;
 if v_l.listing_status<>'CLAIMED' then raise exception 'LISTING_NOT_CLAIMED'; end if;
 update public.pickup_tasks set task_status='DISPATCHED'
 where claim_id=p_claim and task_status in ('CONFIRMED','PLANNED');
 if not found then raise exception 'PICKUP_TASK_NOT_DISPATCHABLE'; end if;
 if v_l.source_type='DIRECT_DONATION' then
  update public.donations set donation_status='PICKUP_IN_PROGRESS'
  where donation_id=v_l.donation_id and donation_status='READY_FOR_PICKUP';
 else
  update public.donations set donation_status='PICKUP_IN_PROGRESS'
  where donation_id in(select donation_id from public.hub_batch_members
    where batch_id=v_l.batch_id and membership_status='ACTIVE')
    and donation_status='BATCHED';
 end if;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 claim_id,lease_id,requested_state,resulting_state,outcome)
 values(v_actor,'NGO','CLAIM',p_claim,'START_PICKUP',p_claim,v_lease.lease_id,
 'PICKUP_IN_PROGRESS','PICKUP_IN_PROGRESS','SUCCESS');
end $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: active_task_route_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_task_route_assignments (
    task_id uuid NOT NULL,
    route_id uuid NOT NULL,
    assigned_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    event_id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor_user_id uuid,
    actor_role text,
    entity_type text NOT NULL,
    entity_id uuid,
    event_type text NOT NULL,
    request_id uuid,
    claim_id uuid,
    lease_id uuid,
    correlation_id uuid,
    previous_state text,
    requested_state text,
    resulting_state text,
    reason_code text,
    outcome text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    software_version text,
    configuration_version text,
    occurred_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT audit_events_outcome_check CHECK ((outcome = ANY (ARRAY['SUCCESS'::text, 'REJECTED'::text, 'ERROR'::text])))
);


--
-- Name: claim_leases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.claim_leases (
    lease_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_id uuid NOT NULL,
    lease_status text DEFAULT 'ACTIVE'::text NOT NULL,
    issued_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    closed_at timestamp with time zone,
    release_reason text,
    CONSTRAINT claim_leases_check CHECK ((expires_at > issued_at)),
    CONSTRAINT claim_leases_lease_status_check CHECK ((lease_status = ANY (ARRAY['ACTIVE'::text, 'EXPIRED'::text, 'RELEASED'::text, 'COMPLETED'::text, 'RECONCILIATION_REQUIRED'::text])))
);


--
-- Name: claim_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.claim_requests (
    request_id uuid NOT NULL,
    listing_id uuid NOT NULL,
    ngo_user_id uuid NOT NULL,
    request_digest text NOT NULL,
    outcome text,
    result_claim_id uuid,
    reason_code text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    CONSTRAINT claim_requests_outcome_check CHECK ((outcome = ANY (ARRAY['SUCCESS'::text, 'CONFLICT'::text, 'INELIGIBLE'::text, 'ERROR'::text])))
);


--
-- Name: community_hubs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.community_hubs (
    hub_id uuid DEFAULT gen_random_uuid() NOT NULL,
    admin_user_id uuid NOT NULL,
    hub_name text NOT NULL,
    address_text text NOT NULL,
    latitude double precision NOT NULL,
    longitude double precision NOT NULL,
    road_node_id text,
    capacity_kg numeric(12,3) NOT NULL,
    active_flag boolean DEFAULT true NOT NULL,
    operating_hours jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT community_hubs_capacity_kg_check CHECK (((capacity_kg >= (50)::numeric) AND (capacity_kg <= (250)::numeric))),
    CONSTRAINT community_hubs_latitude_check CHECK (((latitude >= ('-90'::integer)::double precision) AND (latitude <= (90)::double precision))),
    CONSTRAINT community_hubs_longitude_check CHECK (((longitude >= ('-180'::integer)::double precision) AND (longitude <= (180)::double precision)))
);


--
-- Name: coordination_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coordination_config (
    singleton boolean DEFAULT true NOT NULL,
    geofence_radius_m integer DEFAULT 20000 NOT NULL,
    donation_direct_min_kg numeric(12,3) DEFAULT 10.000 NOT NULL,
    claim_lease_minutes integer DEFAULT 360 NOT NULL,
    hub_reservation_minutes integer DEFAULT 120 NOT NULL,
    batch_min_donations integer DEFAULT 3 NOT NULL,
    batch_max_donations integer DEFAULT 5 NOT NULL,
    batch_max_weight_kg numeric(12,3) DEFAULT 30 NOT NULL,
    config_version text DEFAULT 'v2.0'::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT coordination_config_batch_max_donations_check CHECK ((batch_max_donations >= 3)),
    CONSTRAINT coordination_config_batch_max_weight_kg_check CHECK ((batch_max_weight_kg > (0)::numeric)),
    CONSTRAINT coordination_config_batch_min_donations_check CHECK ((batch_min_donations > 0)),
    CONSTRAINT coordination_config_check CHECK ((batch_min_donations <= batch_max_donations)),
    CONSTRAINT coordination_config_claim_lease_minutes_check CHECK ((claim_lease_minutes = 360)),
    CONSTRAINT coordination_config_donation_direct_min_kg_check CHECK ((donation_direct_min_kg = 10.000)),
    CONSTRAINT coordination_config_geofence_radius_m_check CHECK ((geofence_radius_m = 20000)),
    CONSTRAINT coordination_config_hub_reservation_minutes_check CHECK (((hub_reservation_minutes >= 1) AND (hub_reservation_minutes <= 10080))),
    CONSTRAINT coordination_config_singleton_check CHECK (singleton)
);


--
-- Name: donation_cancellation_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.donation_cancellation_requests (
    request_id uuid NOT NULL,
    donor_user_id uuid NOT NULL,
    donation_id uuid NOT NULL,
    request_fingerprint text NOT NULL,
    response jsonb,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    completed_at timestamp with time zone,
    CONSTRAINT donation_cancellation_requests_response_check CHECK (((response IS NULL) OR (jsonb_typeof(response) = 'object'::text)))
);


--
-- Name: donation_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.donation_categories (
    category_id uuid DEFAULT gen_random_uuid() NOT NULL,
    category_name text NOT NULL,
    active_flag boolean DEFAULT true NOT NULL
);


--
-- Name: donation_claims; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.donation_claims (
    claim_id uuid DEFAULT gen_random_uuid() NOT NULL,
    listing_id uuid NOT NULL,
    ngo_user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    claim_status text DEFAULT 'ACTIVE'::text NOT NULL,
    claimed_at timestamp with time zone DEFAULT now() NOT NULL,
    closed_at timestamp with time zone,
    close_reason text,
    CONSTRAINT donation_claims_claim_status_check CHECK ((claim_status = ANY (ARRAY['ACTIVE'::text, 'RELEASED'::text, 'EXPIRED'::text, 'COMPLETED'::text, 'CANCELLED'::text, 'RECONCILIATION_REQUIRED'::text])))
);


--
-- Name: donation_create_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.donation_create_requests (
    request_id uuid NOT NULL,
    donor_user_id uuid NOT NULL,
    request_digest text NOT NULL,
    donation_id uuid,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL
);


--
-- Name: donation_images; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.donation_images (
    image_id uuid DEFAULT gen_random_uuid() NOT NULL,
    donation_id uuid NOT NULL,
    owner_user_id uuid NOT NULL,
    storage_path text NOT NULL,
    content_type text NOT NULL,
    size_bytes integer NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    display_order smallint NOT NULL,
    CONSTRAINT donation_images_content_type_check CHECK ((content_type = ANY (ARRAY['image/jpeg'::text, 'image/png'::text, 'image/webp'::text]))),
    CONSTRAINT donation_images_order_range CHECK ((((display_order >= 1) AND (display_order <= 3)) AND (is_primary = (display_order = 1)))),
    CONSTRAINT donation_images_size_bytes_check CHECK (((size_bytes >= 1) AND (size_bytes <= 5242880)))
);


--
-- Name: donation_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.donation_items (
    item_id uuid DEFAULT gen_random_uuid() NOT NULL,
    donation_id uuid NOT NULL,
    category_id uuid NOT NULL,
    item_name text NOT NULL,
    description text,
    quantity integer NOT NULL,
    unit_label text DEFAULT 'piece'::text NOT NULL,
    unit_weight_kg numeric(12,3) NOT NULL,
    item_condition text DEFAULT 'GOOD'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT donation_items_item_condition_check CHECK ((item_condition = ANY (ARRAY['NEW'::text, 'GOOD'::text, 'FAIR'::text]))),
    CONSTRAINT donation_items_quantity_check CHECK ((quantity > 0)),
    CONSTRAINT donation_items_unit_weight_kg_check CHECK ((unit_weight_kg > (0)::numeric))
);


--
-- Name: donations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.donations (
    donation_id uuid DEFAULT gen_random_uuid() NOT NULL,
    donor_user_id uuid NOT NULL,
    title text NOT NULL,
    description text,
    collection_path text,
    donation_status text DEFAULT 'SUBMITTED'::text NOT NULL,
    pickup_address text,
    latitude double precision,
    longitude double precision,
    pickup_road_node_id text,
    total_weight_kg numeric(12,3),
    availability_start timestamp with time zone,
    availability_end timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT donations_check CHECK (((availability_start IS NULL) OR (availability_end IS NULL) OR (availability_end > availability_start))),
    CONSTRAINT donations_check1 CHECK (((latitude IS NULL) = (longitude IS NULL))),
    CONSTRAINT donations_collection_path_check CHECK ((collection_path = ANY (ARRAY['DIRECT_PICKUP'::text, 'HUB_COLLECTION'::text]))),
    CONSTRAINT donations_donation_status_check CHECK ((donation_status = ANY (ARRAY['SUBMITTED'::text, 'VALIDATED'::text, 'READY_FOR_PICKUP'::text, 'HUB_ASSIGNED'::text, 'AT_HUB'::text, 'BATCHED'::text, 'PICKUP_IN_PROGRESS'::text, 'COLLECTED'::text, 'DELIVERED'::text, 'CANCELLED'::text]))),
    CONSTRAINT donations_latitude_check CHECK (((latitude >= ('-90'::integer)::double precision) AND (latitude <= (90)::double precision))),
    CONSTRAINT donations_longitude_check CHECK (((longitude >= ('-180'::integer)::double precision) AND (longitude <= (180)::double precision))),
    CONSTRAINT donations_total_weight_kg_check CHECK ((total_weight_kg > (0)::numeric))
);


--
-- Name: COLUMN donations.availability_start; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.donations.availability_start IS 'Deprecated compatibility column. Donor-defined availability is not used by current creation, discovery, or claim rules.';


--
-- Name: COLUMN donations.availability_end; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.donations.availability_end IS 'Deprecated compatibility column. Donor-defined availability is not used by current creation, discovery, or claim rules.';


--
-- Name: donor_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.donor_profiles (
    user_id uuid NOT NULL,
    role text DEFAULT 'DONOR'::text NOT NULL,
    CONSTRAINT donor_profiles_role_check CHECK ((role = 'DONOR'::text))
);


--
-- Name: hub_accepted_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hub_accepted_categories (
    hub_id uuid NOT NULL,
    category_id uuid NOT NULL
);


--
-- Name: hub_admin_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hub_admin_profiles (
    user_id uuid NOT NULL,
    role text DEFAULT 'HUB_ADMIN'::text NOT NULL,
    CONSTRAINT hub_admin_profiles_role_check CHECK ((role = 'HUB_ADMIN'::text))
);


--
-- Name: hub_batch_images; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hub_batch_images (
    image_id uuid DEFAULT gen_random_uuid() NOT NULL,
    batch_id uuid NOT NULL,
    owner_user_id uuid NOT NULL,
    storage_path text NOT NULL,
    content_type text NOT NULL,
    size_bytes integer NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT hub_batch_images_content_type_check CHECK ((content_type = ANY (ARRAY['image/jpeg'::text, 'image/png'::text, 'image/webp'::text]))),
    CONSTRAINT hub_batch_images_size_bytes_check CHECK (((size_bytes >= 1) AND (size_bytes <= 5242880)))
);


--
-- Name: hub_batch_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hub_batch_members (
    batch_id uuid NOT NULL,
    hub_id uuid NOT NULL,
    donation_id uuid NOT NULL,
    membership_status text DEFAULT 'ACTIVE'::text NOT NULL,
    added_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT hub_batch_members_membership_status_check CHECK ((membership_status = ANY (ARRAY['ACTIVE'::text, 'RELEASED'::text])))
);


--
-- Name: hub_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hub_batches (
    batch_id uuid DEFAULT gen_random_uuid() NOT NULL,
    hub_id uuid NOT NULL,
    batch_category_id uuid,
    batch_status text DEFAULT 'DRAFT'::text NOT NULL,
    batch_weight_kg numeric(12,3) DEFAULT 0 NOT NULL,
    batch_donation_count integer DEFAULT 0 NOT NULL,
    batch_version bigint DEFAULT 1 NOT NULL,
    created_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    published_at timestamp with time zone,
    CONSTRAINT hub_batches_batch_donation_count_check CHECK ((batch_donation_count >= 0)),
    CONSTRAINT hub_batches_batch_status_check CHECK ((batch_status = ANY (ARRAY['DRAFT'::text, 'PUBLISHED'::text, 'CLAIMED'::text, 'COLLECTED'::text, 'CANCELLED'::text]))),
    CONSTRAINT hub_batches_batch_version_check CHECK ((batch_version > 0)),
    CONSTRAINT hub_batches_batch_weight_kg_check CHECK ((batch_weight_kg >= (0)::numeric))
);


--
-- Name: hub_inventory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hub_inventory (
    donation_id uuid NOT NULL,
    hub_id uuid NOT NULL,
    inventory_status text DEFAULT 'STORED'::text NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT hub_inventory_inventory_status_check CHECK ((inventory_status = ANY (ARRAY['STORED'::text, 'BATCHED'::text, 'COLLECTED'::text, 'RECONCILIATION_REQUIRED'::text])))
);


--
-- Name: hub_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hub_receipts (
    receipt_id uuid DEFAULT gen_random_uuid() NOT NULL,
    reservation_id uuid NOT NULL,
    donation_id uuid NOT NULL,
    hub_id uuid NOT NULL,
    received_by uuid NOT NULL,
    receipt_status text DEFAULT 'CONFIRMED'::text NOT NULL,
    received_weight_kg numeric(12,3) NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT hub_receipts_receipt_status_check CHECK ((receipt_status = ANY (ARRAY['CONFIRMED'::text, 'RECONCILIATION_REQUIRED'::text]))),
    CONSTRAINT hub_receipts_received_weight_kg_check CHECK ((received_weight_kg > (0)::numeric))
);


--
-- Name: hub_reservations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hub_reservations (
    reservation_id uuid DEFAULT gen_random_uuid() NOT NULL,
    donation_id uuid NOT NULL,
    hub_id uuid NOT NULL,
    reserved_weight_kg numeric(12,3) NOT NULL,
    reservation_status text DEFAULT 'ACTIVE'::text NOT NULL,
    reserved_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT hub_reservations_check CHECK ((expires_at > reserved_at)),
    CONSTRAINT hub_reservations_reservation_status_check CHECK ((reservation_status = ANY (ARRAY['ACTIVE'::text, 'CONSUMED'::text, 'RELEASED'::text, 'EXPIRED'::text]))),
    CONSTRAINT hub_reservations_reserved_weight_kg_check CHECK ((reserved_weight_kg > (0)::numeric))
);


--
-- Name: listings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.listings (
    listing_id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_type text NOT NULL,
    donation_id uuid,
    batch_id uuid,
    listing_status text DEFAULT 'AVAILABLE'::text NOT NULL,
    listing_weight_kg numeric(12,3) NOT NULL,
    pickup_latitude double precision NOT NULL,
    pickup_longitude double precision NOT NULL,
    pickup_road_node_id text,
    listing_version bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    listing_expires_at timestamp with time zone,
    CONSTRAINT listings_check CHECK ((((source_type = 'DIRECT_DONATION'::text) AND (donation_id IS NOT NULL) AND (batch_id IS NULL)) OR ((source_type = 'HUB_BATCH'::text) AND (batch_id IS NOT NULL) AND (donation_id IS NULL)))),
    CONSTRAINT listings_listing_status_check CHECK ((listing_status = ANY (ARRAY['AVAILABLE'::text, 'CLAIMED'::text, 'CLOSED'::text, 'CANCELLED'::text]))),
    CONSTRAINT listings_listing_version_check CHECK ((listing_version > 0)),
    CONSTRAINT listings_listing_weight_kg_check CHECK ((listing_weight_kg > (0)::numeric)),
    CONSTRAINT listings_pickup_latitude_check CHECK (((pickup_latitude >= ('-90'::integer)::double precision) AND (pickup_latitude <= (90)::double precision))),
    CONSTRAINT listings_pickup_longitude_check CHECK (((pickup_longitude >= ('-180'::integer)::double precision) AND (pickup_longitude <= (180)::double precision))),
    CONSTRAINT listings_source_type_check CHECK ((source_type = ANY (ARRAY['DIRECT_DONATION'::text, 'HUB_BATCH'::text])))
);


--
-- Name: ngo_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ngo_profiles (
    user_id uuid NOT NULL,
    role text DEFAULT 'NGO'::text NOT NULL,
    ngo_name text NOT NULL,
    registration_number text,
    operating_address text NOT NULL,
    latitude double precision NOT NULL,
    longitude double precision NOT NULL,
    road_node_id text,
    active_flag boolean DEFAULT true NOT NULL,
    location_verified_at timestamp with time zone,
    CONSTRAINT ngo_profiles_latitude_check CHECK (((latitude >= ('-90'::integer)::double precision) AND (latitude <= (90)::double precision))),
    CONSTRAINT ngo_profiles_longitude_check CHECK (((longitude >= ('-180'::integer)::double precision) AND (longitude <= (180)::double precision))),
    CONSTRAINT ngo_profiles_operating_address_check CHECK ((btrim(operating_address) <> ''::text)),
    CONSTRAINT ngo_profiles_role_check CHECK ((role = 'NGO'::text))
);


--
-- Name: pickup_route_stops; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pickup_route_stops (
    route_id uuid NOT NULL,
    ngo_user_id uuid NOT NULL,
    stop_order integer NOT NULL,
    task_id uuid NOT NULL,
    planned_arrival timestamp with time zone,
    CONSTRAINT pickup_route_stops_stop_order_check CHECK ((stop_order > 0))
);


--
-- Name: pickup_routes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pickup_routes (
    route_id uuid DEFAULT gen_random_uuid() NOT NULL,
    ngo_user_id uuid NOT NULL,
    vehicle_id uuid NOT NULL,
    route_status text DEFAULT 'DRAFT'::text NOT NULL,
    matrix_id text,
    total_distance_km numeric(14,3),
    total_duration_min numeric(14,3),
    planned_at timestamp with time zone DEFAULT now() NOT NULL,
    authorised_at timestamp with time zone,
    validation_reference text,
    CONSTRAINT pickup_routes_route_status_check CHECK ((route_status = ANY (ARRAY['DRAFT'::text, 'VALIDATED'::text, 'AUTHORISED'::text, 'IN_PROGRESS'::text, 'COMPLETED'::text, 'CANCELLED'::text, 'STALE'::text]))),
    CONSTRAINT pickup_routes_total_distance_km_check CHECK ((total_distance_km >= (0)::numeric)),
    CONSTRAINT pickup_routes_total_duration_min_check CHECK ((total_duration_min >= (0)::numeric))
);


--
-- Name: pickup_tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pickup_tasks (
    task_id uuid DEFAULT gen_random_uuid() NOT NULL,
    claim_id uuid NOT NULL,
    listing_id uuid NOT NULL,
    ngo_user_id uuid NOT NULL,
    pickup_road_node_id text NOT NULL,
    load_kg numeric(12,3) NOT NULL,
    task_status text DEFAULT 'CONFIRMED'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pickup_tasks_load_kg_check CHECK ((load_kg > (0)::numeric)),
    CONSTRAINT pickup_tasks_task_status_check CHECK ((task_status = ANY (ARRAY['CONFIRMED'::text, 'PLANNED'::text, 'DISPATCHED'::text, 'COLLECTED'::text, 'CANCELLED'::text, 'STALE'::text])))
);


--
-- Name: user_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_profiles (
    user_id uuid NOT NULL,
    full_name text NOT NULL,
    phone_number text,
    role text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_profiles_role_check CHECK ((role = ANY (ARRAY['DONOR'::text, 'NGO'::text, 'HUB_ADMIN'::text])))
);


--
-- Name: vehicles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vehicles (
    vehicle_id uuid DEFAULT gen_random_uuid() NOT NULL,
    ngo_user_id uuid NOT NULL,
    vehicle_label text NOT NULL,
    payload_capacity_kg numeric(12,3) NOT NULL,
    depot_road_node_id text,
    active_flag boolean DEFAULT true NOT NULL,
    CONSTRAINT vehicles_payload_capacity_kg_check CHECK ((payload_capacity_kg > (0)::numeric))
);


--
-- Name: active_task_route_assignments active_task_route_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_task_route_assignments
    ADD CONSTRAINT active_task_route_assignments_pkey PRIMARY KEY (task_id);


--
-- Name: active_task_route_assignments active_task_route_assignments_task_id_route_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_task_route_assignments
    ADD CONSTRAINT active_task_route_assignments_task_id_route_id_key UNIQUE (task_id, route_id);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (event_id);


--
-- Name: claim_leases claim_leases_claim_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_leases
    ADD CONSTRAINT claim_leases_claim_id_key UNIQUE (claim_id);


--
-- Name: claim_leases claim_leases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_leases
    ADD CONSTRAINT claim_leases_pkey PRIMARY KEY (lease_id);


--
-- Name: claim_requests claim_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_requests
    ADD CONSTRAINT claim_requests_pkey PRIMARY KEY (request_id);


--
-- Name: community_hubs community_hubs_hub_id_admin_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_hubs
    ADD CONSTRAINT community_hubs_hub_id_admin_user_id_key UNIQUE (hub_id, admin_user_id);


--
-- Name: community_hubs community_hubs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_hubs
    ADD CONSTRAINT community_hubs_pkey PRIMARY KEY (hub_id);


--
-- Name: coordination_config coordination_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coordination_config
    ADD CONSTRAINT coordination_config_pkey PRIMARY KEY (singleton);


--
-- Name: donation_cancellation_requests donation_cancellation_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_cancellation_requests
    ADD CONSTRAINT donation_cancellation_requests_pkey PRIMARY KEY (request_id);


--
-- Name: donation_categories donation_categories_category_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_categories
    ADD CONSTRAINT donation_categories_category_name_key UNIQUE (category_name);


--
-- Name: donation_categories donation_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_categories
    ADD CONSTRAINT donation_categories_pkey PRIMARY KEY (category_id);


--
-- Name: donation_claims donation_claims_claim_id_listing_id_ngo_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_claims
    ADD CONSTRAINT donation_claims_claim_id_listing_id_ngo_user_id_key UNIQUE (claim_id, listing_id, ngo_user_id);


--
-- Name: donation_claims donation_claims_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_claims
    ADD CONSTRAINT donation_claims_pkey PRIMARY KEY (claim_id);


--
-- Name: donation_claims donation_claims_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_claims
    ADD CONSTRAINT donation_claims_request_id_key UNIQUE (request_id);


--
-- Name: donation_create_requests donation_create_requests_donation_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_create_requests
    ADD CONSTRAINT donation_create_requests_donation_id_key UNIQUE (donation_id);


--
-- Name: donation_create_requests donation_create_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_create_requests
    ADD CONSTRAINT donation_create_requests_pkey PRIMARY KEY (request_id);


--
-- Name: donation_images donation_images_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_images
    ADD CONSTRAINT donation_images_pkey PRIMARY KEY (image_id);


--
-- Name: donation_images donation_images_storage_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_images
    ADD CONSTRAINT donation_images_storage_path_key UNIQUE (storage_path);


--
-- Name: donation_items donation_items_item_id_donation_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_items
    ADD CONSTRAINT donation_items_item_id_donation_id_key UNIQUE (item_id, donation_id);


--
-- Name: donation_items donation_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_items
    ADD CONSTRAINT donation_items_pkey PRIMARY KEY (item_id);


--
-- Name: donations donations_description_length; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.donations
    ADD CONSTRAINT donations_description_length CHECK (((description IS NULL) OR (char_length(description) <= 1000))) NOT VALID;


--
-- Name: donations donations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donations
    ADD CONSTRAINT donations_pkey PRIMARY KEY (donation_id);


--
-- Name: donations donations_title_length; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.donations
    ADD CONSTRAINT donations_title_length CHECK (((char_length(btrim(title)) >= 1) AND (char_length(btrim(title)) <= 80))) NOT VALID;


--
-- Name: donor_profiles donor_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donor_profiles
    ADD CONSTRAINT donor_profiles_pkey PRIMARY KEY (user_id);


--
-- Name: hub_accepted_categories hub_accepted_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_accepted_categories
    ADD CONSTRAINT hub_accepted_categories_pkey PRIMARY KEY (hub_id, category_id);


--
-- Name: hub_admin_profiles hub_admin_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_admin_profiles
    ADD CONSTRAINT hub_admin_profiles_pkey PRIMARY KEY (user_id);


--
-- Name: hub_batch_images hub_batch_images_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_batch_images
    ADD CONSTRAINT hub_batch_images_pkey PRIMARY KEY (image_id);


--
-- Name: hub_batch_images hub_batch_images_storage_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_batch_images
    ADD CONSTRAINT hub_batch_images_storage_path_key UNIQUE (storage_path);


--
-- Name: hub_batch_members hub_batch_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_batch_members
    ADD CONSTRAINT hub_batch_members_pkey PRIMARY KEY (batch_id, donation_id);


--
-- Name: hub_batches hub_batches_batch_id_hub_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_batches
    ADD CONSTRAINT hub_batches_batch_id_hub_id_key UNIQUE (batch_id, hub_id);


--
-- Name: hub_batches hub_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_batches
    ADD CONSTRAINT hub_batches_pkey PRIMARY KEY (batch_id);


--
-- Name: hub_inventory hub_inventory_donation_id_hub_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_inventory
    ADD CONSTRAINT hub_inventory_donation_id_hub_id_key UNIQUE (donation_id, hub_id);


--
-- Name: hub_inventory hub_inventory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_inventory
    ADD CONSTRAINT hub_inventory_pkey PRIMARY KEY (donation_id);


--
-- Name: hub_receipts hub_receipts_donation_id_hub_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_receipts
    ADD CONSTRAINT hub_receipts_donation_id_hub_id_key UNIQUE (donation_id, hub_id);


--
-- Name: hub_receipts hub_receipts_donation_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_receipts
    ADD CONSTRAINT hub_receipts_donation_id_key UNIQUE (donation_id);


--
-- Name: hub_receipts hub_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_receipts
    ADD CONSTRAINT hub_receipts_pkey PRIMARY KEY (receipt_id);


--
-- Name: hub_receipts hub_receipts_reservation_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_receipts
    ADD CONSTRAINT hub_receipts_reservation_id_key UNIQUE (reservation_id);


--
-- Name: hub_reservations hub_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_reservations
    ADD CONSTRAINT hub_reservations_pkey PRIMARY KEY (reservation_id);


--
-- Name: hub_reservations hub_reservations_reservation_id_donation_id_hub_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_reservations
    ADD CONSTRAINT hub_reservations_reservation_id_donation_id_hub_id_key UNIQUE (reservation_id, donation_id, hub_id);


--
-- Name: listings listings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listings
    ADD CONSTRAINT listings_pkey PRIMARY KEY (listing_id);


--
-- Name: ngo_profiles ngo_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ngo_profiles
    ADD CONSTRAINT ngo_profiles_pkey PRIMARY KEY (user_id);


--
-- Name: ngo_profiles ngo_profiles_registration_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ngo_profiles
    ADD CONSTRAINT ngo_profiles_registration_number_key UNIQUE (registration_number);


--
-- Name: pickup_route_stops pickup_route_stops_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_route_stops
    ADD CONSTRAINT pickup_route_stops_pkey PRIMARY KEY (route_id, stop_order);


--
-- Name: pickup_route_stops pickup_route_stops_route_id_task_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_route_stops
    ADD CONSTRAINT pickup_route_stops_route_id_task_id_key UNIQUE (route_id, task_id);


--
-- Name: pickup_routes pickup_routes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_routes
    ADD CONSTRAINT pickup_routes_pkey PRIMARY KEY (route_id);


--
-- Name: pickup_routes pickup_routes_route_id_ngo_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_routes
    ADD CONSTRAINT pickup_routes_route_id_ngo_user_id_key UNIQUE (route_id, ngo_user_id);


--
-- Name: pickup_tasks pickup_tasks_claim_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_tasks
    ADD CONSTRAINT pickup_tasks_claim_id_key UNIQUE (claim_id);


--
-- Name: pickup_tasks pickup_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_tasks
    ADD CONSTRAINT pickup_tasks_pkey PRIMARY KEY (task_id);


--
-- Name: user_profiles user_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_pkey PRIMARY KEY (user_id);


--
-- Name: user_profiles user_profiles_user_id_role_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_user_id_role_key UNIQUE (user_id, role);


--
-- Name: vehicles vehicles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT vehicles_pkey PRIMARY KEY (vehicle_id);


--
-- Name: vehicles vehicles_vehicle_id_ngo_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT vehicles_vehicle_id_ngo_user_id_key UNIQUE (vehicle_id, ngo_user_id);


--
-- Name: idx_active_lease_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_active_lease_expiry ON public.claim_leases USING btree (expires_at) WHERE (lease_status = 'ACTIVE'::text);


--
-- Name: idx_audit_entity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_entity ON public.audit_events USING btree (entity_type, entity_id, occurred_at);


--
-- Name: idx_audit_request; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_request ON public.audit_events USING btree (request_id);


--
-- Name: idx_donation_images_owner_donation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_donation_images_owner_donation ON public.donation_images USING btree (owner_user_id, donation_id, created_at);


--
-- Name: idx_donations_donor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_donations_donor ON public.donations USING btree (donor_user_id);


--
-- Name: idx_items_donation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_items_donation ON public.donation_items USING btree (donation_id);


--
-- Name: ux_active_batch_member; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_active_batch_member ON public.hub_batch_members USING btree (donation_id) WHERE (membership_status = 'ACTIVE'::text);


--
-- Name: ux_active_claim; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_active_claim ON public.donation_claims USING btree (listing_id) WHERE (claim_status = ANY (ARRAY['ACTIVE'::text, 'RECONCILIATION_REQUIRED'::text]));


--
-- Name: ux_active_reservation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_active_reservation ON public.hub_reservations USING btree (donation_id) WHERE (reservation_status = 'ACTIVE'::text);


--
-- Name: ux_batch_listing; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_batch_listing ON public.listings USING btree (batch_id) WHERE (source_type = 'HUB_BATCH'::text);


--
-- Name: ux_direct_listing; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_direct_listing ON public.listings USING btree (donation_id) WHERE (source_type = 'DIRECT_DONATION'::text);


--
-- Name: ux_donation_images_display_order; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_donation_images_display_order ON public.donation_images USING btree (donation_id, display_order);


--
-- Name: ux_donation_images_primary; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_donation_images_primary ON public.donation_images USING btree (donation_id) WHERE is_primary;


--
-- Name: ux_hub_batch_images_primary; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_hub_batch_images_primary ON public.hub_batch_images USING btree (batch_id) WHERE is_primary;


--
-- Name: ux_hub_batch_single_photo; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_hub_batch_single_photo ON public.hub_batch_images USING btree (batch_id);


--
-- Name: donations donations_require_photo_at_commit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER donations_require_photo_at_commit AFTER INSERT ON public.donations DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.require_donation_photo_before_commit();


--
-- Name: audit_events trg_audit_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_audit_append_only BEFORE DELETE OR UPDATE ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_mutation();


--
-- Name: hub_batches trg_batch_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_guard BEFORE DELETE OR UPDATE ON public.hub_batches FOR EACH ROW EXECUTE FUNCTION public.guard_batch_immutability();


--
-- Name: donations trg_donation_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_donation_transition BEFORE UPDATE ON public.donations FOR EACH ROW EXECUTE FUNCTION public.enforce_donation_transition();


--
-- Name: donation_items trg_items_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_items_guard BEFORE INSERT OR DELETE OR UPDATE ON public.donation_items FOR EACH ROW EXECUTE FUNCTION public.guard_donation_items();


--
-- Name: listings trg_listing_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_listing_transition BEFORE UPDATE ON public.listings FOR EACH ROW EXECUTE FUNCTION public.enforce_listing_transition();


--
-- Name: hub_batch_members trg_members_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_members_guard BEFORE INSERT OR DELETE OR UPDATE ON public.hub_batch_members FOR EACH ROW EXECUTE FUNCTION public.guard_batch_immutability();


--
-- Name: user_profiles trg_role_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_role_immutable BEFORE UPDATE ON public.user_profiles FOR EACH ROW EXECUTE FUNCTION public.prevent_role_change();


--
-- Name: active_task_route_assignments active_task_route_assignments_route_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_task_route_assignments
    ADD CONSTRAINT active_task_route_assignments_route_id_fkey FOREIGN KEY (route_id) REFERENCES public.pickup_routes(route_id);


--
-- Name: active_task_route_assignments active_task_route_assignments_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_task_route_assignments
    ADD CONSTRAINT active_task_route_assignments_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.pickup_tasks(task_id);


--
-- Name: audit_events audit_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES auth.users(id);


--
-- Name: claim_leases claim_leases_claim_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_leases
    ADD CONSTRAINT claim_leases_claim_id_fkey FOREIGN KEY (claim_id) REFERENCES public.donation_claims(claim_id);


--
-- Name: claim_requests claim_requests_listing_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_requests
    ADD CONSTRAINT claim_requests_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES public.listings(listing_id);


--
-- Name: claim_requests claim_requests_ngo_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_requests
    ADD CONSTRAINT claim_requests_ngo_user_id_fkey FOREIGN KEY (ngo_user_id) REFERENCES public.ngo_profiles(user_id);


--
-- Name: community_hubs community_hubs_admin_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.community_hubs
    ADD CONSTRAINT community_hubs_admin_user_id_fkey FOREIGN KEY (admin_user_id) REFERENCES public.hub_admin_profiles(user_id);


--
-- Name: donation_claims donation_claims_listing_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_claims
    ADD CONSTRAINT donation_claims_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES public.listings(listing_id);


--
-- Name: donation_claims donation_claims_ngo_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_claims
    ADD CONSTRAINT donation_claims_ngo_user_id_fkey FOREIGN KEY (ngo_user_id) REFERENCES public.ngo_profiles(user_id);


--
-- Name: donation_claims donation_claims_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_claims
    ADD CONSTRAINT donation_claims_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.claim_requests(request_id);


--
-- Name: donation_create_requests donation_create_requests_donation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_create_requests
    ADD CONSTRAINT donation_create_requests_donation_id_fkey FOREIGN KEY (donation_id) REFERENCES public.donations(donation_id);


--
-- Name: donation_create_requests donation_create_requests_donor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_create_requests
    ADD CONSTRAINT donation_create_requests_donor_user_id_fkey FOREIGN KEY (donor_user_id) REFERENCES auth.users(id);


--
-- Name: donation_images donation_images_donation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_images
    ADD CONSTRAINT donation_images_donation_id_fkey FOREIGN KEY (donation_id) REFERENCES public.donations(donation_id) ON DELETE CASCADE;


--
-- Name: donation_images donation_images_owner_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_images
    ADD CONSTRAINT donation_images_owner_user_id_fkey FOREIGN KEY (owner_user_id) REFERENCES auth.users(id);


--
-- Name: donation_items donation_items_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_items
    ADD CONSTRAINT donation_items_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.donation_categories(category_id);


--
-- Name: donation_items donation_items_donation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donation_items
    ADD CONSTRAINT donation_items_donation_id_fkey FOREIGN KEY (donation_id) REFERENCES public.donations(donation_id);


--
-- Name: donations donations_donor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donations
    ADD CONSTRAINT donations_donor_user_id_fkey FOREIGN KEY (donor_user_id) REFERENCES public.donor_profiles(user_id);


--
-- Name: donor_profiles donor_profiles_user_id_role_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.donor_profiles
    ADD CONSTRAINT donor_profiles_user_id_role_fkey FOREIGN KEY (user_id, role) REFERENCES public.user_profiles(user_id, role);


--
-- Name: claim_requests fk_request_result; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.claim_requests
    ADD CONSTRAINT fk_request_result FOREIGN KEY (result_claim_id) REFERENCES public.donation_claims(claim_id);


--
-- Name: hub_accepted_categories hub_accepted_categories_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_accepted_categories
    ADD CONSTRAINT hub_accepted_categories_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.donation_categories(category_id);


--
-- Name: hub_accepted_categories hub_accepted_categories_hub_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_accepted_categories
    ADD CONSTRAINT hub_accepted_categories_hub_id_fkey FOREIGN KEY (hub_id) REFERENCES public.community_hubs(hub_id);


--
-- Name: hub_admin_profiles hub_admin_profiles_user_id_role_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_admin_profiles
    ADD CONSTRAINT hub_admin_profiles_user_id_role_fkey FOREIGN KEY (user_id, role) REFERENCES public.user_profiles(user_id, role);


--
-- Name: hub_batch_images hub_batch_images_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_batch_images
    ADD CONSTRAINT hub_batch_images_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.hub_batches(batch_id) ON DELETE CASCADE;


--
-- Name: hub_batch_images hub_batch_images_owner_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_batch_images
    ADD CONSTRAINT hub_batch_images_owner_user_id_fkey FOREIGN KEY (owner_user_id) REFERENCES auth.users(id);


--
-- Name: hub_batch_members hub_batch_members_batch_id_hub_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_batch_members
    ADD CONSTRAINT hub_batch_members_batch_id_hub_id_fkey FOREIGN KEY (batch_id, hub_id) REFERENCES public.hub_batches(batch_id, hub_id);


--
-- Name: hub_batch_members hub_batch_members_donation_id_hub_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_batch_members
    ADD CONSTRAINT hub_batch_members_donation_id_hub_id_fkey FOREIGN KEY (donation_id, hub_id) REFERENCES public.hub_inventory(donation_id, hub_id);


--
-- Name: hub_batches hub_batches_batch_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_batches
    ADD CONSTRAINT hub_batches_batch_category_id_fkey FOREIGN KEY (batch_category_id) REFERENCES public.donation_categories(category_id);


--
-- Name: hub_batches hub_batches_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_batches
    ADD CONSTRAINT hub_batches_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.hub_admin_profiles(user_id);


--
-- Name: hub_batches hub_batches_hub_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_batches
    ADD CONSTRAINT hub_batches_hub_id_fkey FOREIGN KEY (hub_id) REFERENCES public.community_hubs(hub_id);


--
-- Name: hub_inventory hub_inventory_donation_id_hub_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_inventory
    ADD CONSTRAINT hub_inventory_donation_id_hub_id_fkey FOREIGN KEY (donation_id, hub_id) REFERENCES public.hub_receipts(donation_id, hub_id);


--
-- Name: hub_receipts hub_receipts_received_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_receipts
    ADD CONSTRAINT hub_receipts_received_by_fkey FOREIGN KEY (received_by) REFERENCES public.hub_admin_profiles(user_id);


--
-- Name: hub_receipts hub_receipts_reservation_id_donation_id_hub_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_receipts
    ADD CONSTRAINT hub_receipts_reservation_id_donation_id_hub_id_fkey FOREIGN KEY (reservation_id, donation_id, hub_id) REFERENCES public.hub_reservations(reservation_id, donation_id, hub_id);


--
-- Name: hub_reservations hub_reservations_donation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_reservations
    ADD CONSTRAINT hub_reservations_donation_id_fkey FOREIGN KEY (donation_id) REFERENCES public.donations(donation_id);


--
-- Name: hub_reservations hub_reservations_hub_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hub_reservations
    ADD CONSTRAINT hub_reservations_hub_id_fkey FOREIGN KEY (hub_id) REFERENCES public.community_hubs(hub_id);


--
-- Name: listings listings_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listings
    ADD CONSTRAINT listings_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.hub_batches(batch_id);


--
-- Name: listings listings_donation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listings
    ADD CONSTRAINT listings_donation_id_fkey FOREIGN KEY (donation_id) REFERENCES public.donations(donation_id);


--
-- Name: ngo_profiles ngo_profiles_user_id_role_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ngo_profiles
    ADD CONSTRAINT ngo_profiles_user_id_role_fkey FOREIGN KEY (user_id, role) REFERENCES public.user_profiles(user_id, role);


--
-- Name: pickup_route_stops pickup_route_stops_route_id_ngo_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_route_stops
    ADD CONSTRAINT pickup_route_stops_route_id_ngo_user_id_fkey FOREIGN KEY (route_id, ngo_user_id) REFERENCES public.pickup_routes(route_id, ngo_user_id);


--
-- Name: pickup_route_stops pickup_route_stops_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_route_stops
    ADD CONSTRAINT pickup_route_stops_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.pickup_tasks(task_id);


--
-- Name: pickup_routes pickup_routes_ngo_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_routes
    ADD CONSTRAINT pickup_routes_ngo_user_id_fkey FOREIGN KEY (ngo_user_id) REFERENCES public.ngo_profiles(user_id);


--
-- Name: pickup_routes pickup_routes_vehicle_id_ngo_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_routes
    ADD CONSTRAINT pickup_routes_vehicle_id_ngo_user_id_fkey FOREIGN KEY (vehicle_id, ngo_user_id) REFERENCES public.vehicles(vehicle_id, ngo_user_id);


--
-- Name: pickup_tasks pickup_tasks_claim_id_listing_id_ngo_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_tasks
    ADD CONSTRAINT pickup_tasks_claim_id_listing_id_ngo_user_id_fkey FOREIGN KEY (claim_id, listing_id, ngo_user_id) REFERENCES public.donation_claims(claim_id, listing_id, ngo_user_id);


--
-- Name: user_profiles user_profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: vehicles vehicles_ngo_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT vehicles_ngo_user_id_fkey FOREIGN KEY (ngo_user_id) REFERENCES public.ngo_profiles(user_id);


--
-- Name: active_task_route_assignments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.active_task_route_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;

--
-- Name: claim_leases; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.claim_leases ENABLE ROW LEVEL SECURITY;

--
-- Name: claim_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.claim_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: community_hubs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.community_hubs ENABLE ROW LEVEL SECURITY;

--
-- Name: coordination_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.coordination_config ENABLE ROW LEVEL SECURITY;

--
-- Name: donation_cancellation_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.donation_cancellation_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: donation_categories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.donation_categories ENABLE ROW LEVEL SECURITY;

--
-- Name: donation_claims; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.donation_claims ENABLE ROW LEVEL SECURITY;

--
-- Name: donation_create_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.donation_create_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: donation_images; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.donation_images ENABLE ROW LEVEL SECURITY;

--
-- Name: donation_images donation_images_owner_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY donation_images_owner_read ON public.donation_images FOR SELECT TO authenticated USING (public.can_read_geolock_donation_image(storage_path));


--
-- Name: donation_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.donation_items ENABLE ROW LEVEL SECURITY;

--
-- Name: donations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.donations ENABLE ROW LEVEL SECURITY;

--
-- Name: donor_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.donor_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: donation_images geolock_donation_images_authenticated_read_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY geolock_donation_images_authenticated_read_guard ON public.donation_images AS RESTRICTIVE FOR SELECT TO authenticated USING (public.can_read_geolock_donation_image(storage_path));


--
-- Name: hub_batch_images geolock_hub_batch_images_authenticated_read_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY geolock_hub_batch_images_authenticated_read_guard ON public.hub_batch_images AS RESTRICTIVE FOR SELECT TO authenticated USING (public.can_read_geolock_batch_image(storage_path));


--
-- Name: hub_accepted_categories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hub_accepted_categories ENABLE ROW LEVEL SECURITY;

--
-- Name: hub_admin_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hub_admin_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: hub_batch_images; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hub_batch_images ENABLE ROW LEVEL SECURITY;

--
-- Name: hub_batch_images hub_batch_images_owner_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY hub_batch_images_owner_read ON public.hub_batch_images FOR SELECT TO authenticated USING (public.can_read_geolock_batch_image(storage_path));


--
-- Name: hub_batch_members; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hub_batch_members ENABLE ROW LEVEL SECURITY;

--
-- Name: hub_batches; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hub_batches ENABLE ROW LEVEL SECURITY;

--
-- Name: hub_inventory; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hub_inventory ENABLE ROW LEVEL SECURITY;

--
-- Name: hub_receipts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hub_receipts ENABLE ROW LEVEL SECURITY;

--
-- Name: hub_reservations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hub_reservations ENABLE ROW LEVEL SECURITY;

--
-- Name: listings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.listings ENABLE ROW LEVEL SECURITY;

--
-- Name: ngo_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ngo_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: pickup_route_stops; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pickup_route_stops ENABLE ROW LEVEL SECURITY;

--
-- Name: pickup_routes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pickup_routes ENABLE ROW LEVEL SECURITY;

--
-- Name: pickup_tasks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pickup_tasks ENABLE ROW LEVEL SECURITY;

--
-- Name: user_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: vehicles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict pWVgjZe2Qtw7xbofj1az9GWi6GbShhMsJAuOoRf9BB7vzDwjr3AYXYnXEv8hyFn

