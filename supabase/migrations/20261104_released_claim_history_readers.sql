-- Owner-scoped, read-only history for completed/released/expired claims.
-- Direct-donor pickup coordinates are returned only while the claim, lease,
-- and listing are all actively authorized. Hub locations remain available as
-- community pickup locations. No claim, lease, task, or donation rows change.

create or replace function public.get_claimed_listing_detail(p_claim uuid)
returns jsonb
language plpgsql stable security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare v jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select jsonb_build_object(
    'claim_id',c.claim_id,'claim_status',c.claim_status,
    'claim_close_reason',c.close_reason,'claim_closed_at',c.closed_at,
    'listing_id',l.listing_id,'listing_status',l.listing_status,
    'source_type',l.source_type,
    'pickup_address',case
      when l.source_type='HUB_BATCH' then h.address_text
      when l.source_type='DIRECT_DONATION'
        and c.claim_status='ACTIVE'
        and le.lease_status='ACTIVE'
        and le.expires_at>statement_timestamp()
        and l.listing_status='CLAIMED'
      then d.pickup_address
      else null end,
    'latitude',case
      when l.source_type='HUB_BATCH' then h.latitude
      when l.source_type='DIRECT_DONATION'
        and c.claim_status='ACTIVE'
        and le.lease_status='ACTIVE'
        and le.expires_at>statement_timestamp()
        and l.listing_status='CLAIMED'
      then l.pickup_latitude
      else null end,
    'longitude',case
      when l.source_type='HUB_BATCH' then h.longitude
      when l.source_type='DIRECT_DONATION'
        and c.claim_status='ACTIVE'
        and le.lease_status='ACTIVE'
        and le.expires_at>statement_timestamp()
        and l.listing_status='CLAIMED'
      then l.pickup_longitude
      else null end,
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

create or replace function public.get_claimed_listing_constituents(p_claim uuid)
returns table(donation_id uuid,title text,total_weight_kg numeric,donation_status text,
  primary_image_path text,batch_cover_path text)
language plpgsql volatile security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare v_listing public.listings%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select l.* into v_listing from public.donation_claims c
  join public.listings l using(listing_id)
  where c.claim_id=p_claim and c.ngo_user_id=auth.uid()
    and (c.claim_status in ('COMPLETED','RECONCILIATION_REQUIRED','RELEASED','EXPIRED','CANCELLED')
      or (c.claim_status='ACTIVE' and exists(select 1 from public.claim_leases le
          where le.claim_id=c.claim_id and le.lease_status='EXPIRED'))
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

-- Historical detail intentionally omits direct donor address, coordinates,
-- and road-node identifiers. Published hub membership and validated donation
-- items are protected from later edits by the deployed immutability triggers.
create or replace function public.get_my_historical_claim_detail(p_claim uuid)
returns jsonb
language plpgsql volatile security definer
set search_path=pg_catalog,public,pg_temp
as $$
declare v jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists(select 1 from public.ngo_profiles n
    where n.user_id=auth.uid() and n.active_flag) then
    raise exception 'ACTIVE_NGO_ONLY';
  end if;

  select jsonb_build_object(
    'contract','geolock.ngo-historical-claim.v1',
    'read_only',true,
    'claim_id',c.claim_id,
    'claim_status',c.claim_status,
    'claim_created_at',c.claimed_at,
    'claim_closed_at',c.closed_at,
    'claim_close_reason',c.close_reason,
    'listing_id',l.listing_id,
    'listing_status',l.listing_status,
    'source_type',l.source_type,
    'listing_weight_kg',l.listing_weight_kg,
    'lease_status',le.lease_status,
    'lease_issued_at',le.issued_at,
    'lease_expires_at',le.expires_at,
    'lease_closed_at',le.closed_at,
    'lease_release_reason',le.release_reason,
    'task_status',pt.task_status,
    'reconciliation',case when rc.case_id is null then null else jsonb_build_object(
      'case_status',rc.case_status,'opened_at',rc.opened_at,
      'resolved_at',rc.resolved_at,'resolution_reason',rc.resolution_reason) end,
    'pickup_location_type',case when l.source_type='HUB_BATCH' then 'COMMUNITY_HUB' else 'PRIVATE_DONOR' end,
    'pickup_address',case when l.source_type='HUB_BATCH' then h.address_text else null end,
    'latitude',case when l.source_type='HUB_BATCH' then h.latitude else null end,
    'longitude',case when l.source_type='HUB_BATCH' then h.longitude else null end,
    'constituents',coalesce((
      select jsonb_agg(jsonb_build_object(
        'donation_id',d.donation_id,
        'title',d.title,
        'donation_status',d.donation_status,
        'total_weight_kg',case when l.source_type='DIRECT_DONATION'
          then l.listing_weight_kg else (
            select sum(iw.quantity*iw.unit_weight_kg)
            from public.donation_items iw where iw.donation_id=d.donation_id) end,
        'weight_source',case when l.source_type='DIRECT_DONATION'
          then 'LISTING_SNAPSHOT'
          when exists(select 1 from public.donation_items iw where iw.donation_id=d.donation_id)
          then 'FROZEN_DONATION_ITEMS' else 'UNAVAILABLE' end,
        'primary_image_path',di.storage_path,
        'batch_cover_path',bi.storage_path,
        'items',coalesce((
          select jsonb_agg(jsonb_build_object(
            'item_id',i.item_id,'category_id',i.category_id,
            'category_name',dc.category_name,'item_name',i.item_name,
            'description',i.description,'quantity',i.quantity,
            'unit_label',i.unit_label,'unit_weight_kg',i.unit_weight_kg,
            'item_condition',i.item_condition)
            order by i.created_at,i.item_id)
          from public.donation_items i
          join public.donation_categories dc using(category_id)
          where i.donation_id=d.donation_id), '[]'::jsonb)
      ) order by d.created_at,d.donation_id)
      from public.donations d
      left join lateral(select x.storage_path from public.donation_images x
        where x.donation_id=d.donation_id and x.display_order=1 limit 1) di on true
      left join lateral(select x.storage_path from public.hub_batch_images x
        where x.batch_id=l.batch_id and x.is_primary limit 1) bi on true
      where (l.source_type='DIRECT_DONATION' and d.donation_id=l.donation_id)
         or (l.source_type='HUB_BATCH' and exists(
           select 1 from public.hub_batch_members m
           where m.batch_id=l.batch_id and m.donation_id=d.donation_id
             and m.membership_status='ACTIVE'))
    ),'[]'::jsonb)
  ) into v
  from public.donation_claims c
  join public.listings l using(listing_id)
  left join public.claim_leases le using(claim_id)
  left join public.pickup_tasks pt using(claim_id)
  left join public.hub_batches b on b.batch_id=l.batch_id
  left join public.community_hubs h on h.hub_id=b.hub_id
  left join lateral(select x.* from public.claim_reconciliation_cases x
    where x.claim_id=c.claim_id order by x.opened_at desc,x.case_id limit 1) rc on true
  where c.claim_id=p_claim and c.ngo_user_id=auth.uid()
    and (c.claim_status in ('RELEASED','EXPIRED','COMPLETED','CANCELLED')
      or (c.claim_status='ACTIVE' and
        (le.lease_status='EXPIRED' or
          (le.lease_status='ACTIVE' and le.expires_at<=clock_timestamp()))));

  if v is null then raise exception 'CLAIM_NOT_FOUND_OR_FORBIDDEN'; end if;
  return v;
end;
$$;

-- Keep the existing route-reader contract and ACL, while masking historical
-- direct-donation locations in both the wrapper and its directly callable
-- authenticated pre-deferral reader. Hub coordinates remain community sites.
create or replace function public.get_my_authorized_route_pre_deferral(p_route uuid)
returns jsonb
language plpgsql security definer
set search_path=pg_catalog,pg_temp
set "TimeZone" to 'UTC'
set extra_float_digits to '0'
as $function$
DECLARE ngo uuid:=auth.uid(); b routing_private.bindings%rowtype; r public.pickup_routes%rowtype;
 next_id uuid; ready boolean:=false; authorized boolean; blocked text; rows jsonb; can_close boolean; can_cancel boolean; snap routing_private.snapshots%rowtype;
BEGIN
 SELECT * INTO b FROM routing_private.bindings WHERE route_id=p_route AND ngo_id=ngo;
 IF NOT FOUND OR ngo IS NULL THEN RAISE EXCEPTION 'OWNED_MANAGED_ROUTE_NOT_FOUND'; END IF;
 SELECT * INTO STRICT r FROM public.pickup_routes WHERE route_id=p_route;
 authorized:=b.closed_at IS NULL AND r.ngo_user_id=ngo AND r.vehicle_id=b.vehicle_id AND r.validation_reference=b.candidate_id::text
 AND r.route_status IN ('AUTHORISED','IN_PROGRESS') AND EXISTS(SELECT 1 FROM routing_private.candidates c JOIN routing_private.validations v USING(candidate_id)
 JOIN routing_private.snapshots s USING(snapshot_id) WHERE c.candidate_id=b.candidate_id AND v.candidate_digest=c.digest AND r.matrix_id=s.matrix_id::text);
 SELECT task_id INTO next_id FROM routing_private.items WHERE route_id=p_route AND collected_at IS NULL ORDER BY ordinal LIMIT 1;
 IF authorized AND next_id IS NOT NULL THEN
  BEGIN PERFORM routing_private.check_remaining(p_route,next_id,clock_timestamp()); ready:=true;
  EXCEPTION WHEN OTHERS THEN blocked:=SQLERRM; ready:=false; END;
 END IF;
 SELECT sn.* INTO STRICT snap FROM routing_private.candidates c JOIN routing_private.snapshots sn USING(snapshot_id) WHERE c.candidate_id=b.candidate_id;
 SELECT coalesce(jsonb_agg(jsonb_build_object('stop_order',i.ordinal,'task_id',i.task_id,'claim_id',t.claim_id,'task_status',t.task_status,
 'source_type',l.source_type,'title',d.title,
 'pickup_address',case when l.source_type='HUB_BATCH' then null when authorized and c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at>clock_timestamp() and l.listing_status='CLAIMED' then d.pickup_address else null end,
 'pickup_latitude',case when l.source_type='HUB_BATCH' then (routing_private.snapshot_task(snap.body,t.task_id)->'listing'->>'pickup_latitude')::double precision when authorized and c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at>clock_timestamp() and l.listing_status='CLAIMED' then (routing_private.snapshot_task(snap.body,t.task_id)->'listing'->>'pickup_latitude')::double precision else null end,
 'pickup_longitude',case when l.source_type='HUB_BATCH' then (routing_private.snapshot_task(snap.body,t.task_id)->'listing'->>'pickup_longitude')::double precision when authorized and c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at>clock_timestamp() and l.listing_status='CLAIMED' then (routing_private.snapshot_task(snap.body,t.task_id)->'listing'->>'pickup_longitude')::double precision else null end,
 'pickup_road_node_id',case when l.source_type='HUB_BATCH' then routing_private.snapshot_task(snap.body,t.task_id)->'task'->>'pickup_road_node_id' when authorized and c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at>clock_timestamp() and l.listing_status='CLAIMED' then routing_private.snapshot_task(snap.body,t.task_id)->'task'->>'pickup_road_node_id' else null end,
 'load_kg',routing_private.snapshot_task(snap.body,t.task_id)->'task'->'load_kg','planned_arrival',ps.planned_arrival,'actual_started_at',i.consumed_at,
 'can_start',authorized AND ready AND i.task_id=next_id AND i.consumed_at IS NULL AND t.task_status='PLANNED'
   AND c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' AND le.expires_at>clock_timestamp(),
 'can_complete',authorized AND i.consumed_at IS NOT NULL AND i.collected_at IS NULL AND t.task_status='DISPATCHED'
 AND c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' AND le.expires_at>clock_timestamp()) ORDER BY i.ordinal),'[]') INTO rows
 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) JOIN public.listings l USING(listing_id)
 JOIN public.donation_claims c ON c.claim_id=t.claim_id JOIN public.claim_leases le ON le.claim_id=t.claim_id
 LEFT JOIN public.donations d ON d.donation_id=l.donation_id LEFT JOIN public.pickup_route_stops ps ON ps.route_id=i.route_id AND ps.task_id=i.task_id WHERE i.route_id=p_route;
 can_close:=authorized AND EXISTS(SELECT 1 FROM routing_private.items WHERE route_id=p_route) AND NOT EXISTS(
 SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) JOIN public.donation_claims c USING(claim_id) JOIN public.claim_leases le USING(claim_id)
 WHERE i.route_id=p_route AND (i.collected_at IS NULL OR t.task_status<>'COLLECTED' OR c.claim_status<>'COMPLETED' OR le.lease_status<>'COMPLETED'));
 can_cancel:=authorized AND b.started_at IS NULL AND NOT EXISTS(SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
 WHERE i.route_id=p_route AND (i.consumed_at IS NOT NULL OR t.task_status<>'PLANNED' OR routing_private.task_digest(routing_private.observe_task(t.task_id)) IS DISTINCT FROM i.observation_digest));
 RETURN jsonb_build_object('contract','geolock.ngo-routing.v1','ngo_id',ngo,'route_id',p_route,'server_now',clock_timestamp(),
 'candidate_id',b.candidate_id,'snapshot_id',snap.snapshot_id,'actual_started_at',b.started_at,
 'depot',jsonb_build_object('road_node_id',snap.body->'ngo'->>'road_node_id','latitude',snap.body->'ngo'->'latitude','longitude',snap.body->'ngo'->'longitude'),
 'vehicle_label',(SELECT x->>'vehicle_label' FROM jsonb_array_elements(snap.body->'vehicles') x WHERE x->>'vehicle_id'=b.vehicle_id::text),
 'total_load_kg',(SELECT coalesce(sum((routing_private.snapshot_task(snap.body,(x->>'task_id')::uuid)->'task'->>'load_kg')::numeric),0) FROM jsonb_array_elements(b.plan->'stops') x),
 'pickup_count',jsonb_array_length(b.plan->'stops'),
 'pickup_location_count',(SELECT count(DISTINCT x->>'location_id') FROM jsonb_array_elements(b.plan->'stops') x),
 'validation_status',CASE WHEN EXISTS(SELECT 1 FROM routing_private.candidates c JOIN routing_private.validations v USING(candidate_id) WHERE c.candidate_id=b.candidate_id AND v.candidate_digest=c.digest) THEN 'ATTESTED' ELSE 'NOT_CONFIRMED' END,
 'route_status',r.route_status,'vehicle_id',b.vehicle_id,'depot_road_node_id',b.plan->>'start_node_id','departure_at',b.departure_at,
 'total_distance_km',r.total_distance_km,'total_duration_min',r.total_duration_min,'authorization_confirmed',authorized,
 'dispatch_block_reason',blocked,'can_close',can_close,'can_cancel',can_cancel,'stops',rows);
END $function$;

alter function public.get_claimed_listing_detail(uuid) owner to postgres;
alter function public.get_claimed_listing_constituents(uuid) owner to postgres;
alter function public.get_my_historical_claim_detail(uuid) owner to postgres;
alter function public.get_my_authorized_route_pre_deferral(uuid) owner to postgres;

-- CREATE OR REPLACE retains existing reader ACLs. The new history RPC is
-- explicitly available only to authenticated clients; it has no mutation path.
revoke all on function public.get_my_historical_claim_detail(uuid) from public,anon,authenticated,service_role;
grant execute on function public.get_my_historical_claim_detail(uuid) to authenticated;

notify pgrst,'reload schema';
