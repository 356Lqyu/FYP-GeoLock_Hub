-- Move expensive NGO->listing road-distance refreshes off the 8s Authenticated
-- PostgREST request. Location validation and cache invalidation remain atomic.
-- Requires Supabase Cron (pg_cron) enabled before deployment. The scheduled
-- database worker runs as postgres; no service-role key or HTTP worker is used.

begin;

do $$
begin
  if current_user <> 'postgres' then
    raise exception 'MIGRATION_MUST_RUN_AS_POSTGRES_FOR_TRUSTED_CRON_JOB';
  end if;
  if to_regprocedure('public.geolock_resolve_road_node(double precision,double precision)') is null
     or to_regprocedure('public.geolock_refresh_ngo_road_eligibility(uuid)') is null
     or to_regprocedure('public.geolock_refresh_listing_road_eligibility(uuid,uuid)') is null
     or to_regprocedure('public.geolock_road_eligible_km(uuid,uuid)') is null
     or to_regprocedure('public.set_ngo_operating_location(text,double precision,double precision)') is null
     or to_regprocedure('public.discover_eligible_listings()') is null
     or to_regprocedure('public.discover_eligible_listing_cards()') is null then
    raise exception 'NGO_ELIGIBILITY_REFRESH_DEPENDENCY_MISSING';
  end if;
  if to_regclass('public.ngo_profiles') is null
     or to_regclass('public.road_network_coverage') is null
     or to_regclass('public.ngo_listing_road_eligibility') is null
     or to_regclass('public.listings') is null
     or to_regclass('public.donation_claims') is null then
    raise exception 'NGO_ELIGIBILITY_REFRESH_TABLE_MISSING';
  end if;
  if to_regprocedure('cron.schedule(text,text,text)') is null then
    raise exception 'ENABLE_SUPABASE_CRON_PG_CRON_BEFORE_THIS_MIGRATION';
  end if;
  if (select count(*) from public.road_network_coverage
      where active_flag and dataset_kind='OPERATIONAL' and approved_at is not null
        and max_snap_distance_m=500) <> 1 then
    raise exception 'ONE_APPROVED_500M_OPERATIONAL_SNAPSHOT_REQUIRED';
  end if;
end;
$$;

alter table public.ngo_profiles
  add column if not exists location_generation bigint not null default 0;

create table if not exists public.ngo_eligibility_refresh_jobs (
  job_id bigint generated always as identity primary key,
  ngo_user_id uuid not null references public.ngo_profiles(user_id) on delete cascade,
  location_generation bigint not null,
  expected_road_node_id text not null,
  expected_snapshot_id text not null
    references public.road_network_coverage(network_snapshot_id),
  job_status text not null default 'PENDING'
    check (job_status in ('PENDING','PROCESSING','COMPLETED','FAILED','SUPERSEDED')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  requested_at timestamptz not null default clock_timestamp(),
  started_at timestamptz,
  completed_at timestamptz,
  last_error_code text,
  unique (ngo_user_id,location_generation)
);
-- Supabase default ACLs may grant application roles sequence access even when
-- table access is revoked. Queue identity values are internal to the trusted
-- worker; the table owner (postgres) retains the privileges it needs.
revoke all privileges on sequence public.ngo_eligibility_refresh_jobs_job_id_seq
  from public, anon, authenticated, service_role;
create index if not exists ix_ngo_eligibility_refresh_queue
  on public.ngo_eligibility_refresh_jobs(job_status,requested_at,job_id);

alter table public.ngo_eligibility_refresh_jobs enable row level security;
revoke all on public.ngo_eligibility_refresh_jobs from public,anon,authenticated,service_role;

-- A profile-row lock serializes this write with claim_listing(). The location
-- and cache invalidation/job enqueue commit together; no road-distance work is
-- done in the API request.
create or replace function public.set_ngo_operating_location(
  p_operating_address text,
  p_latitude double precision,
  p_longitude double precision
)
returns jsonb language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_ngo public.ngo_profiles%rowtype;
  v_snapshot text;
  v_node text;
  v_snap_distance double precision;
  v_resolved_snapshot text;
  v_generation bigint;
begin
  if v_user is null then raise exception 'UNAUTHENTICATED'; end if;
  if nullif(btrim(p_operating_address),'') is null
     or p_latitude is null or p_longitude is null
     or p_latitude not between -90 and 90
     or p_longitude not between -180 and 180 then
    raise exception 'INVALID_NGO_LOCATION';
  end if;

  -- Keep the approved snapshot fixed through validation, invalidation and enqueue.
  select c.network_snapshot_id into v_snapshot
    from public.road_network_coverage c
   where c.active_flag and c.dataset_kind='OPERATIONAL'
     and c.approved_at is not null and c.max_snap_distance_m=500
   for share;
  if v_snapshot is null then raise exception 'OPERATIONAL_ROAD_COVERAGE_UNAVAILABLE'; end if;

  select * into v_ngo from public.ngo_profiles n
   where n.user_id=v_user and n.active_flag for update;
  if not found then raise exception 'ACTIVE_NGO_PROFILE_REQUIRED'; end if;

  if exists(
    select 1 from public.donation_claims c
     where c.ngo_user_id=v_user and (
       c.claim_status in ('ACTIVE','RECONCILIATION_REQUIRED')
       or exists(select 1 from public.claim_leases le
                  where le.claim_id=c.claim_id
                    and le.lease_status in ('ACTIVE','RECONCILIATION_REQUIRED'))
       or not exists(select 1 from public.claim_leases le where le.claim_id=c.claim_id
          and ((c.claim_status='COMPLETED' and le.lease_status='COMPLETED')
            or (c.claim_status in ('RELEASED','EXPIRED','CANCELLED')
                and le.lease_status in ('RELEASED','EXPIRED'))))
     )
  ) then raise exception 'NGO_HAS_ACTIVE_OR_UNRESOLVED_CLAIMS'; end if;

  select r.node_id,r.snap_distance_m,r.snapshot_id
    into v_node,v_snap_distance,v_resolved_snapshot
    from public.geolock_resolve_road_node(p_latitude,p_longitude) r;
  if v_node is null or v_snap_distance is null or v_snap_distance < 0
     or v_snap_distance > 500 or v_resolved_snapshot is distinct from v_snapshot then
    raise exception 'NGO_LOCATION_NOT_ROUTABLE';
  end if;

  v_generation := v_ngo.location_generation + 1;
  update public.ngo_profiles set operating_address=btrim(p_operating_address),
    latitude=p_latitude,longitude=p_longitude,road_node_id=v_node,
    location_verified_at=clock_timestamp(),location_generation=v_generation
   where user_id=v_user;
  -- Existing trigger derives vehicle depots from the trusted NGO node.
  update public.vehicles set depot_road_node_id=null where ngo_user_id=v_user;

  -- Remove every prior result before committing the new location generation.
  delete from public.ngo_listing_road_eligibility where ngo_user_id=v_user;
  insert into public.ngo_eligibility_refresh_jobs(
    ngo_user_id,location_generation,expected_road_node_id,expected_snapshot_id)
  values(v_user,v_generation,v_node,v_snapshot);

  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,
    event_type,request_id,correlation_id,previous_state,requested_state,
    resulting_state,reason_code,outcome,details)
  values(v_user,'NGO','NGO',v_user,'SET_NGO_OPERATING_LOCATION',gen_random_uuid(),
    gen_random_uuid(),case when v_ngo.location_verified_at is null then 'INCOMPLETE' else 'VERIFIED' end,
    'VERIFIED','ELIGIBILITY_PENDING','SERVER_ROAD_NODE_VALIDATION','SUCCESS',
    jsonb_build_object('network_snapshot_id',v_snapshot,'road_node_id',v_node,
      'snap_distance_m',round(v_snap_distance::numeric,1),
      'location_generation',v_generation));

  return jsonb_build_object('location_status','VERIFIED','eligibility_status','PENDING',
    'road_node_id',v_node,'snap_distance_m',round(v_snap_distance::numeric,1),
    'network_snapshot_id',v_snapshot,'location_generation',v_generation);
end;
$$;

-- Internal status predicate gates every listing read that uses the cached
-- eligibility helper. Legacy verified NGOs (generation 0) retain existing rows.
create or replace function public.geolock_ngo_eligibility_ready(p_ngo uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select case
      when n.location_generation=0 then true
      -- A non-legacy location generation without its atomic queue row is not
      -- ready. This is a fail-closed guard for manual corruption/partial repair.
      when not exists(select 1 from public.ngo_eligibility_refresh_jobs j
        where j.ngo_user_id=n.user_id and j.location_generation=n.location_generation) then false
      when exists(select 1 from public.ngo_eligibility_refresh_jobs j
        where j.ngo_user_id=n.user_id and j.location_generation=n.location_generation
          and (j.job_status in ('PENDING','PROCESSING')
            or (j.job_status='FAILED' and j.attempt_count<3))) then false
      when exists(select 1 from public.ngo_eligibility_refresh_jobs j
        where j.ngo_user_id=n.user_id and j.location_generation=n.location_generation
          and (j.job_status='SUPERSEDED'
            or (j.job_status='FAILED' and j.attempt_count>=3))) then false
      else true
    end
    from public.ngo_profiles n where n.user_id=p_ngo
      and n.active_flag and n.location_verified_at is not null and n.road_node_id is not null
  ),false)
$$;
revoke all on function public.geolock_ngo_eligibility_ready(uuid) from public,anon,authenticated,service_role;

-- Preserve the public return contract; a cache row is visible to discovery only
-- after every job for the current generation has completed successfully.
create or replace function public.geolock_road_eligible_km(p_ngo uuid,p_listing uuid)
returns double precision language sql stable security definer
set search_path = public, pg_temp
as $$
  select e.road_distance_km
    from public.ngo_listing_road_eligibility e
    join public.ngo_profiles n on n.user_id=e.ngo_user_id
    join public.listings l on l.listing_id=e.listing_id
   where e.ngo_user_id=p_ngo and e.listing_id=p_listing
     and e.outcome='ELIGIBLE'
     and e.network_snapshot_id=public.geolock_active_road_snapshot()
     and e.ngo_road_node_id=n.road_node_id
     and e.listing_road_node_id=l.pickup_road_node_id
     and n.location_verified_at is not null and n.active_flag
     and public.geolock_ngo_eligibility_ready(p_ngo)
$$;

-- One trusted database consumer processes at most one NGO refresh per run.
-- It runs outside PostgREST's authenticated 8s timeout; its function-local
-- timeout is bounded at 10 minutes. Results and COMPLETED status commit together.
create or replace function public.process_ngo_eligibility_refresh_jobs()
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
set statement_timeout = '10min'
as $$
declare
  v_job public.ngo_eligibility_refresh_jobs%rowtype;
  v_ngo public.ngo_profiles%rowtype;
  v_active_snapshot text;
  v_sqlstate text;
begin
  if session_user <> 'postgres' then raise exception 'TRUSTED_CRON_ONLY'; end if;

  select * into v_job from public.ngo_eligibility_refresh_jobs j
   where j.job_status in ('PENDING','FAILED') and j.attempt_count<3
   order by j.requested_at desc,j.job_id desc
   limit 1 for update skip locked;
  if not found then return jsonb_build_object('processed',false); end if;

  update public.ngo_eligibility_refresh_jobs set job_status='PROCESSING',
    attempt_count=attempt_count+1,started_at=clock_timestamp(),last_error_code=null
   where job_id=v_job.job_id;

  begin
    select c.network_snapshot_id into v_active_snapshot
      from public.road_network_coverage c
     where c.active_flag and c.dataset_kind='OPERATIONAL'
       and c.approved_at is not null and c.max_snap_distance_m=500
     for share;

    select * into v_ngo from public.ngo_profiles n
     where n.user_id=v_job.ngo_user_id for update;
    if not found or not v_ngo.active_flag or v_ngo.location_verified_at is null then
      update public.ngo_eligibility_refresh_jobs set job_status='SUPERSEDED',
        completed_at=clock_timestamp(),last_error_code='NGO_LOCATION_NO_LONGER_ACTIVE'
       where job_id=v_job.job_id;
      return jsonb_build_object('processed',true,'outcome','SUPERSEDED');
    end if;

    if v_ngo.location_generation<>v_job.location_generation
       or v_ngo.road_node_id is distinct from v_job.expected_road_node_id then
      update public.ngo_eligibility_refresh_jobs set job_status='SUPERSEDED',
        completed_at=clock_timestamp(),last_error_code='LOCATION_GENERATION_CHANGED'
       where job_id=v_job.job_id;
      return jsonb_build_object('processed',true,'outcome','SUPERSEDED');
    end if;
    if v_active_snapshot is null or v_active_snapshot is distinct from v_job.expected_snapshot_id then
      update public.ngo_eligibility_refresh_jobs set job_status='FAILED',
        completed_at=clock_timestamp(),last_error_code='ROAD_SNAPSHOT_CHANGED'
       where job_id=v_job.job_id;
      return jsonb_build_object('processed',true,'outcome','FAILED','reason_code','ROAD_SNAPSHOT_CHANGED');
    end if;

    -- Existing refresh uses directed pgRouting distances and re-reads the NGO
    -- row and active snapshot while both are protected by transaction locks.
    perform public.geolock_refresh_ngo_road_eligibility(v_job.ngo_user_id);

    if exists(select 1 from public.ngo_listing_road_eligibility e
      join public.listings l on l.listing_id=e.listing_id
      where e.ngo_user_id=v_job.ngo_user_id
        and (e.network_snapshot_id<>v_job.expected_snapshot_id
          or e.ngo_road_node_id<>v_job.expected_road_node_id)
        and (l.listing_status='AVAILABLE' or exists(
          select 1 from public.donation_claims c where c.listing_id=l.listing_id
            and c.ngo_user_id=v_job.ngo_user_id
            and c.claim_status in ('ACTIVE','COMPLETED','RECONCILIATION_REQUIRED')))) then
      raise exception 'REFRESH_RESULT_SNAPSHOT_MISMATCH';
    end if;

    update public.ngo_eligibility_refresh_jobs set job_status='COMPLETED',
      completed_at=clock_timestamp(),last_error_code=null
     where job_id=v_job.job_id;
    return jsonb_build_object('processed',true,'outcome','COMPLETED',
      'location_generation',v_job.location_generation);
  exception when query_canceled then
    update public.ngo_eligibility_refresh_jobs set job_status='FAILED',
      completed_at=clock_timestamp(),last_error_code='SQLSTATE_57014'
     where job_id=v_job.job_id;
    return jsonb_build_object('processed',true,'outcome','FAILED','reason_code','SQLSTATE_57014',
      'attempt_count',v_job.attempt_count+1);
  when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate;
    update public.ngo_eligibility_refresh_jobs set job_status='FAILED',
      completed_at=clock_timestamp(),last_error_code='SQLSTATE_'||v_sqlstate
     where job_id=v_job.job_id;
    return jsonb_build_object('processed',true,'outcome','FAILED','reason_code','SQLSTATE_'||v_sqlstate,
      'attempt_count',v_job.attempt_count+1);
  end;
end;
$$;
revoke all on function public.process_ngo_eligibility_refresh_jobs() from public,anon,authenticated,service_role;
grant execute on function public.process_ngo_eligibility_refresh_jobs() to postgres;

create or replace function public.get_my_ngo_eligibility_refresh_status()
returns text language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare v_user uuid:=auth.uid(); v_generation bigint; v_status text;
begin
  if v_user is null then raise exception 'UNAUTHENTICATED'; end if;
  select location_generation into v_generation from public.ngo_profiles
   where user_id=v_user and active_flag and location_verified_at is not null;
  if not found then return 'LOCATION_REQUIRED'; end if;
  if v_generation=0 then return 'READY'; end if;
  if not exists(select 1 from public.ngo_eligibility_refresh_jobs j
    where j.ngo_user_id=v_user and j.location_generation=v_generation) then return 'FAILED'; end if;
  if exists(select 1 from public.ngo_eligibility_refresh_jobs j
    where j.ngo_user_id=v_user and j.location_generation=v_generation
      and (j.job_status in ('PENDING','PROCESSING')
        or (j.job_status='FAILED' and j.attempt_count<3))) then return 'PENDING'; end if;
  if exists(select 1 from public.ngo_eligibility_refresh_jobs j
    where j.ngo_user_id=v_user and j.location_generation=v_generation
      and (j.job_status='SUPERSEDED'
        or (j.job_status='FAILED' and j.attempt_count>=3))) then return 'FAILED'; end if;
  return 'READY';
end;
$$;
revoke all on function public.get_my_ngo_eligibility_refresh_status() from public,anon;
grant execute on function public.get_my_ngo_eligibility_refresh_status() to authenticated;

-- One job per minute keeps the service bounded and allows repeated, safe retries.
do $$
declare
  v_existing record;
  v_cron_command constant text :=
    'set statement_timeout = ''10min''; select public.process_ngo_eligibility_refresh_jobs();';
begin
  select schedule,command,username,active into v_existing from cron.job
   where jobname='geolock-ngo-eligibility-refresh';
  if found then
    if v_existing.schedule<>'* * * * *'
       or v_existing.command<>v_cron_command
       or v_existing.username<>'postgres' or not v_existing.active then
      raise exception 'EXISTING_GEOLOCK_REFRESH_CRON_JOB_MISMATCH';
    end if;
  else
    perform cron.schedule('geolock-ngo-eligibility-refresh','* * * * *',
      v_cron_command);
  end if;
end;
$$;

commit;
