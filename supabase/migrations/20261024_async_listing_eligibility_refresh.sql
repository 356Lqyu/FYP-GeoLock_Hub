-- DEV-only forward migration. Deploy manually as postgres after readiness review.
-- No routing algorithms, donation/photo RPCs, or NGO worker bodies are changed.
begin;
do $$
begin
  if current_user <> 'postgres' then raise exception 'MIGRATION_REQUIRES_POSTGRES'; end if;
  if to_regprocedure('cron.schedule(text,text,text)') is null
     or to_regprocedure('public.process_ngo_eligibility_refresh_jobs()') is null
     or to_regprocedure('public.geolock_ngo_eligibility_ready(uuid)') is null
     or to_regprocedure('public.geolock_refresh_listing_road_eligibility(uuid,uuid)') is null
     or to_regprocedure('public.geolock_ngo_listing_road_check(uuid,uuid)') is null then
    raise exception 'ASYNC_LISTING_DEPENDENCY_MISSING';
  end if;
  if (select count(*) from public.road_network_coverage where active_flag
      and dataset_kind='OPERATIONAL' and approved_at is not null and max_snap_distance_m=500) <> 1 then
    raise exception 'ONE_APPROVED_500M_SNAPSHOT_REQUIRED';
  end if;
end;
$$;

alter table public.listings add column eligibility_generation bigint not null default 0;
create table public.listing_eligibility_refresh_jobs (
  job_id bigint generated always as identity primary key,
  listing_id uuid not null references public.listings(listing_id) on delete cascade,
  eligibility_generation bigint not null,
  expected_road_node_id text not null,
  expected_snapshot_id text not null references public.road_network_coverage(network_snapshot_id),
  job_status text not null default 'PENDING'
    check (job_status in ('PENDING','PROCESSING','COMPLETED','FAILED','SUPERSEDED')),
  attempt_count integer not null default 0 check (attempt_count>=0),
  requested_at timestamptz not null default clock_timestamp(),
  started_at timestamptz, completed_at timestamptz, last_error_code text,
  unique(listing_id,eligibility_generation)
);
create index ix_listing_eligibility_refresh_queue
  on public.listing_eligibility_refresh_jobs(job_status,requested_at,job_id);
alter table public.listing_eligibility_refresh_jobs enable row level security;
revoke all on public.listing_eligibility_refresh_jobs from public,anon,authenticated,service_role;
revoke all on sequence public.listing_eligibility_refresh_jobs_job_id_seq
  from public,anon,authenticated,service_role;

-- Bootstrap existing AVAILABLE listings through the same fail-closed queue.
-- BEFORE installing the generation guard, so application writes cannot forge it.
update public.listings set eligibility_generation=1 where listing_status='AVAILABLE';

create or replace function public.geolock_prepare_listing_eligibility()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare v_snapshot text; v_node text; v_distance double precision; v_resolved text;
  v_refresh boolean;
begin
  if tg_op='INSERT' then
    new.eligibility_generation:=1;
    v_refresh:=true;
  else
    v_refresh:=new.pickup_latitude is distinct from old.pickup_latitude
      or new.pickup_longitude is distinct from old.pickup_longitude
      or new.pickup_road_node_id is distinct from old.pickup_road_node_id
      or (new.listing_status='AVAILABLE' and old.listing_status<>'AVAILABLE');
    new.eligibility_generation:=old.eligibility_generation;
    if v_refresh then new.eligibility_generation:=old.eligibility_generation+1; end if;
  end if;
  if v_refresh then
    select c.network_snapshot_id into v_snapshot from public.road_network_coverage c
     where c.active_flag and c.dataset_kind='OPERATIONAL' and c.approved_at is not null
       and c.max_snap_distance_m=500 for share;
    select r.node_id,r.snap_distance_m,r.snapshot_id into v_node,v_distance,v_resolved
      from public.geolock_resolve_road_node(new.pickup_latitude,new.pickup_longitude) r;
    if v_snapshot is null or v_node is null or v_distance is null or v_distance<0
       or v_distance>500 or v_resolved is distinct from v_snapshot then
      raise exception 'LISTING_LOCATION_NOT_ROUTABLE';
    end if;
    -- Always replace client-supplied road nodes, including UPDATE/republication.
    new.pickup_road_node_id:=v_node;
  end if;
  return new;
end;
$$;
-- Replace only the listing INSERT-only assignment trigger: this guard also
-- validates UPDATE/republication and avoids resolving the listing point twice.
-- The donation road-node trigger and the resolver algorithm remain unchanged.
drop trigger trg_listing_road_node on public.listings;
create trigger zz_listing_eligibility_generation before insert or update on public.listings
  for each row execute function public.geolock_prepare_listing_eligibility();

create or replace function public.geolock_listing_eligibility_trigger()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare v_snapshot text;
begin
  if tg_op='UPDATE' then
    if new.eligibility_generation=old.eligibility_generation then return null; end if;
  end if;
  delete from public.ngo_listing_road_eligibility where listing_id=new.listing_id;
  -- Do not lock old queue rows here: workers lock queue before listing, while
  -- this trigger already holds listing. Workers supersede old generations.
  if new.listing_status='AVAILABLE' then
    select c.network_snapshot_id into v_snapshot from public.road_network_coverage c
     where c.active_flag and c.dataset_kind='OPERATIONAL' and c.approved_at is not null
       and c.max_snap_distance_m=500 for share;
    if v_snapshot is null then raise exception 'OPERATIONAL_ROAD_COVERAGE_UNAVAILABLE'; end if;
    insert into public.listing_eligibility_refresh_jobs(
      listing_id,eligibility_generation,expected_road_node_id,expected_snapshot_id)
    values(new.listing_id,new.eligibility_generation,new.pickup_road_node_id,v_snapshot);
  end if;
  return null;
end;
$$;
drop trigger trg_listing_road_eligibility on public.listings;
create trigger trg_listing_road_eligibility after insert or update on public.listings
  for each row execute function public.geolock_listing_eligibility_trigger();

delete from public.ngo_listing_road_eligibility e using public.listings l
 where e.listing_id=l.listing_id and l.listing_status='AVAILABLE';
insert into public.listing_eligibility_refresh_jobs(
  listing_id,eligibility_generation,expected_road_node_id,expected_snapshot_id)
select l.listing_id,l.eligibility_generation,l.pickup_road_node_id,c.network_snapshot_id
 from public.listings l cross join public.road_network_coverage c
 where l.listing_status='AVAILABLE' and c.active_flag and c.dataset_kind='OPERATIONAL'
   and c.approved_at is not null and c.max_snap_distance_m=500;
-- A missing legacy node aborts deployment rather than silently exposing a listing.

create or replace function public.geolock_listing_eligibility_ready(p_listing uuid)
returns boolean language sql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
  -- Only historical non-AVAILABLE rows retain generation zero. Republishing
  -- them bumps the generation and queues work before they can be claimed.
  select exists(select 1 from public.listings legacy
    where legacy.listing_id=p_listing and legacy.eligibility_generation=0)
  or exists(
    select 1 from public.listings l join public.listing_eligibility_refresh_jobs j
      on j.listing_id=l.listing_id and j.eligibility_generation=l.eligibility_generation
     where l.listing_id=p_listing and j.job_status='COMPLETED'
       and j.expected_road_node_id=l.pickup_road_node_id
       and j.expected_snapshot_id=public.geolock_active_road_snapshot()
  )
$$;

create or replace function public.geolock_road_eligible_km(p_ngo uuid,p_listing uuid)
returns double precision language sql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select e.road_distance_km from public.ngo_listing_road_eligibility e
    join public.ngo_profiles n on n.user_id=e.ngo_user_id
    join public.listings l on l.listing_id=e.listing_id
    join public.coordination_config cfg on cfg.singleton
   where e.ngo_user_id=p_ngo and e.listing_id=p_listing and e.outcome='ELIGIBLE'
     and e.network_snapshot_id=public.geolock_active_road_snapshot()
     and e.ngo_road_node_id=n.road_node_id and e.listing_road_node_id=l.pickup_road_node_id
     and e.geofence_radius_m=cfg.geofence_radius_m
     and e.road_distance_km*1000<=cfg.geofence_radius_m
     and n.location_verified_at is not null and n.active_flag
     and public.geolock_ngo_eligibility_ready(p_ngo)
     and public.geolock_listing_eligibility_ready(p_listing)
$$;

create or replace function public.process_listing_eligibility_refresh_jobs()
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, extensions, pg_temp
set statement_timeout = '10min'
as $$
declare v_job public.listing_eligibility_refresh_jobs%rowtype;
  v_listing public.listings%rowtype; v_snapshot text; v_state text;
  v_ngos uuid[];
begin
  if session_user<>'postgres' then raise exception 'TRUSTED_CRON_ONLY'; end if;
  select * into v_job from public.listing_eligibility_refresh_jobs j
   where j.job_status in ('PENDING','FAILED') and j.attempt_count<3
   order by j.requested_at,j.job_id limit 1 for update skip locked;
  if not found then return jsonb_build_object('processed',false); end if;
  update public.listing_eligibility_refresh_jobs set job_status='PROCESSING',
    attempt_count=attempt_count+1,started_at=clock_timestamp(),last_error_code=null
   where job_id=v_job.job_id;
  begin
    select c.network_snapshot_id into v_snapshot from public.road_network_coverage c
     where c.active_flag and c.dataset_kind='OPERATIONAL' and c.approved_at is not null
       and c.max_snap_distance_m=500 for share;

    -- Same profile-before-listing order as claim_listing. FOR SHARE conflicts
    -- with NGO worker/location UPDATE locks (FOR KEY SHARE would NOT suffice).
    -- Capture all profiles, including incomplete ones; retry on phantom inserts.
    select coalesce(array_agg(locked.user_id),'{}'::uuid[]) into v_ngos from (
      select n.user_id from public.ngo_profiles n order by n.user_id for share
    ) locked;
    select * into v_listing from public.listings where listing_id=v_job.listing_id for update;
    if not found or v_listing.listing_status<>'AVAILABLE'
       or v_listing.eligibility_generation<>v_job.eligibility_generation
       or v_listing.pickup_road_node_id is distinct from v_job.expected_road_node_id then
      update public.listing_eligibility_refresh_jobs set job_status='SUPERSEDED',
        completed_at=clock_timestamp(),last_error_code='LISTING_CHANGED' where job_id=v_job.job_id;
      return jsonb_build_object('processed',true,'outcome','SUPERSEDED');
    end if;
    if v_snapshot is null or v_snapshot is distinct from v_job.expected_snapshot_id then
      raise exception 'ROAD_SNAPSHOT_CHANGED';
    end if;

    perform public.geolock_refresh_listing_road_eligibility(v_job.listing_id);
    -- A new profile might have entered the refresh statement without a row lock.
    -- Roll back this refresh and retry, rather than delete a concurrently valid
    -- result produced by that NGO's own worker or publish an unprotected result.
    if exists(select 1 from public.ngo_profiles n where not (n.user_id=any(v_ngos))) then
      raise exception 'NGO_SET_CHANGED_RETRY';
    end if;
    if exists(select 1 from public.ngo_listing_road_eligibility e
      join public.ngo_profiles n on n.user_id=e.ngo_user_id
      join public.coordination_config cfg on cfg.singleton
      where e.listing_id=v_job.listing_id and
        (e.network_snapshot_id is distinct from v_snapshot
         or e.listing_road_node_id is distinct from v_job.expected_road_node_id
         or e.ngo_road_node_id is distinct from n.road_node_id
         or e.geofence_radius_m is distinct from cfg.geofence_radius_m)) then
      raise exception 'REFRESH_RESULT_MISMATCH';
    end if;
    update public.listing_eligibility_refresh_jobs set job_status='COMPLETED',
      completed_at=clock_timestamp(),last_error_code=null where job_id=v_job.job_id;
    return jsonb_build_object('processed',true,'outcome','COMPLETED');
  exception when query_canceled then
    update public.listing_eligibility_refresh_jobs set job_status='FAILED',
      completed_at=clock_timestamp(),last_error_code='SQLSTATE_57014' where job_id=v_job.job_id;
    return jsonb_build_object('processed',true,'outcome','FAILED');
  when others then
    get stacked diagnostics v_state=returned_sqlstate;
    update public.listing_eligibility_refresh_jobs set job_status='FAILED',
      completed_at=clock_timestamp(),last_error_code='SQLSTATE_'||v_state where job_id=v_job.job_id;
    return jsonb_build_object('processed',true,'outcome','FAILED','sqlstate',v_state);
  end;
end;
$$;

revoke all on function public.geolock_prepare_listing_eligibility(),
  public.geolock_listing_eligibility_trigger(),public.geolock_listing_eligibility_ready(uuid),
  public.process_listing_eligibility_refresh_jobs() from public,anon,authenticated,service_role;
grant execute on function public.process_listing_eligibility_refresh_jobs() to postgres;

CREATE OR REPLACE FUNCTION public.geolock_ngo_listing_road_check(p_ngo uuid, p_listing uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_n public.ngo_profiles%rowtype; v_l public.listings%rowtype;
  v_radius integer; v_km double precision; v_outcome text;
begin
  -- claim_listing already holds NGO FOR SHARE, then listing FOR UPDATE.
  -- Do not let on-demand routing bypass pending/failed/stale queue generations.
  if not public.geolock_ngo_eligibility_ready(p_ngo)
     or not public.geolock_listing_eligibility_ready(p_listing) then
    return jsonb_build_object('outcome','ELIGIBILITY_UNDETERMINED');
  end if;
  select * into v_n from public.ngo_profiles where user_id = p_ngo;
  select * into v_l from public.listings where listing_id = p_listing;
  select geofence_radius_m into v_radius from public.coordination_config where singleton;
  if v_n.user_id is null or v_n.location_verified_at is null
     or v_n.latitude is null or v_n.longitude is null then
    return jsonb_build_object('outcome', 'ELIGIBILITY_UNDETERMINED');
  end if;
  if public.geolock_active_road_snapshot() is null
     or v_n.road_node_id is null or v_l.pickup_road_node_id is null then
    return jsonb_build_object('outcome', 'ROUTE_UNAVAILABLE');
  end if;
  if not extensions.ST_DWithin(
       extensions.ST_SetSRID(extensions.ST_MakePoint(v_n.longitude, v_n.latitude), 4326)::extensions.geography,
       extensions.ST_SetSRID(extensions.ST_MakePoint(v_l.pickup_longitude, v_l.pickup_latitude), 4326)::extensions.geography,
       v_radius) then
    return jsonb_build_object('outcome', 'OUTSIDE_GEOFENCE');
  end if;

  select e.outcome, e.road_distance_km into v_outcome, v_km
    from public.ngo_listing_road_eligibility e
   where e.ngo_user_id = p_ngo and e.listing_id = p_listing
     and e.network_snapshot_id = public.geolock_active_road_snapshot()
     and e.ngo_road_node_id = v_n.road_node_id
     and e.listing_road_node_id = v_l.pickup_road_node_id
     and e.geofence_radius_m = v_radius;
  if not found then
    perform public.geolock_refresh_listing_road_eligibility(p_listing, p_ngo);
    select e.outcome, e.road_distance_km into v_outcome, v_km
      from public.ngo_listing_road_eligibility e
     where e.ngo_user_id = p_ngo and e.listing_id = p_listing;
  end if;
  return jsonb_build_object('outcome', coalesce(v_outcome, 'ROUTE_UNAVAILABLE'),
                            'road_distance_km', round(v_km::numeric, 3));
end $function$;

do $$
declare v_existing record;
  v_command constant text :=
    'set statement_timeout = ''10min''; select public.process_listing_eligibility_refresh_jobs();';
begin
  select schedule,command,username,active into v_existing from cron.job
   where jobname='geolock-listing-eligibility-refresh';
  if found then
    if v_existing.schedule<>'* * * * *' or v_existing.command<>v_command
       or v_existing.username<>'postgres' or not v_existing.active then
      raise exception 'EXISTING_LISTING_REFRESH_CRON_JOB_MISMATCH';
    end if;
  else
    perform cron.schedule('geolock-listing-eligibility-refresh','* * * * *',v_command);
  end if;
end;
$$;
commit;

