-- Reject non-finite unit weights before rounding and summing donation items.
-- Read the threshold and its audit version from the same configuration row.
begin;

CREATE OR REPLACE FUNCTION public.create_and_validate_donation(p_title text, p_description text, p_pickup_address text, p_latitude double precision, p_longitude double precision, p_items jsonb, p_pickup_road_node_id text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid(); v_donation uuid; v_item jsonb;
  v_count integer:=0; v_weight numeric(12,3):=0; v_threshold numeric(12,3);
  v_path text; v_category uuid; v_qty integer; v_unit numeric(12,3);
  v_status text; v_config_version text; v_raw_unit numeric;
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
  select donation_direct_min_kg, config_version into v_threshold, v_config_version
  from public.coordination_config where singleton;
  if v_threshold is null then raise exception 'DONATION_THRESHOLD_NOT_CONFIGURED'; end if;

  -- The parent must temporarily be SUBMITTED so V3's item guard permits these
  -- inserts. This row is not externally visible until the whole RPC commits.
  insert into public.donations(
    donor_user_id,title,description,pickup_address,latitude,longitude,
    pickup_road_node_id,donation_status
  ) values(
    v_actor,p_title,p_description,p_pickup_address,p_latitude,p_longitude,
    p_pickup_road_node_id,'SUBMITTED'
  ) returning donation_id into v_donation;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_category:=(v_item->>'category_id')::uuid;
    v_qty:=(v_item->>'quantity')::integer;
    v_raw_unit:=(v_item->>'unit_weight_kg')::numeric;
    if v_raw_unit in ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric) then
      raise exception 'INVALID_DONATION_ITEM';
    end if;
    v_unit:=v_raw_unit;
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
  values (v_actor,'DONOR','DONATION',v_donation,'CREATE_DONATION',
    null,v_status,v_status,'SUCCESS',
    jsonb_build_object('validation_passed',true,'weight_kg',v_weight,
      'collection_path',v_path,'threshold_kg',v_threshold),v_config_version);
  return v_donation;
end;
$function$;

commit;
