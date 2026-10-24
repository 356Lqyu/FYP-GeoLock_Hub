-- Automatically validate NGO operating locations against the approved,
-- operational road network during self-registration.
--
-- Forward-only: preserves the deployed register_role_profile signature and
-- replaces only registration/capability behavior. The trusted road resolver
-- and eligibility refresh functions are reused without changing their logic.
-- A successful location check is technical routability validation; it does
-- not verify NGO identity or registration documents.

begin;

do $$
declare
  v_register oid := to_regprocedure(
    'public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text)'
  );
  v_resolver oid := to_regprocedure(
    'public.geolock_resolve_road_node(double precision,double precision)'
  );
  v_refresh oid := to_regprocedure(
    'public.geolock_refresh_ngo_road_eligibility(uuid)'
  );
  v_capabilities oid := to_regprocedure(
    'public.geolock_app_capabilities()'
  );
  v_proc record;
  v_expected_owner oid := to_regrole('postgres');
begin
  if v_register is null then
    raise exception 'REQUIRED_REGISTER_ROLE_PROFILE_SIGNATURE_MISSING';
  end if;
  if v_resolver is null or v_refresh is null then
    raise exception 'APPROVED_ROAD_RESOLUTION_DEPENDENCIES_MISSING';
  end if;
  if v_capabilities is null then
    raise exception 'APP_CAPABILITIES_SIGNATURE_MISSING';
  end if;

  if v_expected_owner is null then
    raise exception 'EXPECTED_FUNCTION_OWNER_ROLE_MISSING';
  end if;

  select p.prosecdef, p.proconfig, p.proowner, p.provolatile,
         pg_get_function_result(p.oid) as result_type
    into v_proc from pg_proc p where p.oid = v_register;
  if not v_proc.prosecdef or v_proc.result_type <> 'uuid'
     or v_proc.proowner <> v_expected_owner
     or v_proc.provolatile <> 'v'
     or not coalesce(v_proc.proconfig @> array[
       'search_path=pg_catalog, public, extensions, pg_temp'
     ]::text[], false) then
    raise exception 'REGISTER_ROLE_PROFILE_SECURITY_OR_RETURN_CONTRACT_MISMATCH';
  end if;

  select p.prosecdef, p.proconfig, p.proowner, p.provolatile,
         pg_get_function_result(p.oid) as result_type
    into v_proc from pg_proc p where p.oid = v_resolver;
  if not v_proc.prosecdef
     or v_proc.proowner <> v_expected_owner
     or v_proc.provolatile <> 's'
     or v_proc.result_type <> 'TABLE(node_id text, snap_distance_m double precision, snapshot_id text)'
     or not coalesce(v_proc.proconfig @> array[
       'search_path=public, extensions, pg_temp'
     ]::text[], false) then
    raise exception 'ROAD_NODE_RESOLVER_CONTRACT_MISMATCH';
  end if;

  select p.prosecdef, p.proconfig, p.proowner, p.provolatile,
         pg_get_function_result(p.oid) as result_type
    into v_proc from pg_proc p where p.oid = v_refresh;
  if not v_proc.prosecdef or v_proc.proowner <> v_expected_owner
     or v_proc.provolatile <> 'v' or v_proc.result_type <> 'void'
     or not coalesce(v_proc.proconfig @> array[
       'search_path=public, extensions, pg_temp'
     ]::text[], false) then
    raise exception 'NGO_ELIGIBILITY_REFRESH_CONTRACT_MISMATCH';
  end if;

  select p.prosecdef, p.proconfig, p.proowner, p.provolatile,
         pg_get_function_result(p.oid) as result_type
    into v_proc from pg_proc p where p.oid = v_capabilities;
  if not v_proc.prosecdef or v_proc.proowner <> v_expected_owner
     or v_proc.provolatile <> 's' or v_proc.result_type <> 'jsonb'
     or not coalesce(v_proc.proconfig @> array[
       'search_path=pg_catalog, public, pg_temp'
     ]::text[], false) then
    raise exception 'APP_CAPABILITIES_SECURITY_OR_RETURN_CONTRACT_MISMATCH';
  end if;

  -- The SECURITY DEFINER registration owner must be able to invoke both
  -- protected dependencies. Client roles intentionally do not need EXECUTE.
  if not has_function_privilege(v_expected_owner, v_resolver, 'EXECUTE')
     or not has_function_privilege(v_expected_owner, v_refresh, 'EXECUTE') then
    raise exception 'REGISTRATION_OWNER_CANNOT_EXECUTE_ROAD_DEPENDENCIES';
  end if;

  if to_regclass('public.user_profiles') is null
     or to_regclass('public.donor_profiles') is null
     or to_regclass('public.ngo_profiles') is null
     or to_regclass('public.audit_events') is null
     or to_regclass('public.road_network_coverage') is null
     or to_regclass('public.road_network_nodes') is null
     or to_regclass('public.ngo_listing_road_eligibility') is null
     or to_regclass('public.coordination_config') is null then
    raise exception 'REQUIRED_REGISTRATION_OR_OPERATIONAL_ROAD_TABLE_MISSING';
  end if;

  if not exists (
    select 1
      from pg_index i
      join pg_class ix on ix.oid = i.indexrelid
     where i.indrelid = 'public.road_network_coverage'::regclass
       and ix.relname = 'road_network_one_active_operational'
       and i.indisunique
       and pg_get_expr(i.indpred, i.indrelid) like '%active_flag%'
       and pg_get_expr(i.indpred, i.indrelid) like '%OPERATIONAL%'
  ) then
    raise exception 'ACTIVE_OPERATIONAL_SNAPSHOT_UNIQUE_INDEX_MISSING';
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'ngo_profiles'
       and column_name in ('road_node_id', 'location_verified_at')
     group by table_schema, table_name
    having count(distinct column_name) = 2
  ) then
    raise exception 'NGO_LOCATION_VALIDATION_COLUMNS_MISSING';
  end if;

  if not exists (
    select 1 from public.coordination_config
     where singleton and geofence_radius_m is not null
  ) then
    raise exception 'COORDINATION_CONFIGURATION_MISSING';
  end if;

  if not exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.road_network_coverage'::regclass
       and c.contype = 'c'
       and pg_get_constraintdef(c.oid) like '%max_snap_distance_m = 500%'
  ) then
    raise exception 'ROAD_SNAP_DISTANCE_MUST_BE_CONFIGURED_TO_500M';
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'audit_events'
       and column_name in ('actor_user_id', 'actor_role', 'entity_type', 'entity_id',
                           'event_type', 'requested_state', 'resulting_state',
                           'reason_code', 'outcome', 'details')
     group by table_schema, table_name
    having count(distinct column_name) = 10
  ) then
    raise exception 'REGISTRATION_AUDIT_SCHEMA_MISMATCH';
  end if;

  -- Fail closed if the active graph is absent, duplicated, unapproved, or not
  -- using the agreed snap limit. The partial unique index should make the
  -- count at most one; this preflight also verifies the live data and schema.
  if (select count(*) from public.road_network_coverage
       where active_flag and dataset_kind = 'OPERATIONAL'
         and approved_at is not null) <> 1
     or exists (
       select 1 from public.road_network_coverage
        where active_flag and dataset_kind = 'OPERATIONAL'
          and approved_at is not null and max_snap_distance_m <> 500
     ) then
    raise exception 'ACTIVE_APPROVED_OPERATIONAL_SNAPSHOT_MUST_BE_UNIQUE_AND_500M';
  end if;
  if (select count(*) from public.coordination_config
       where singleton and geofence_radius_m = 20000) <> 1 then
    raise exception 'SINGLETON_20KM_COORDINATION_CONFIGURATION_REQUIRED';
  end if;
end;
$$;

-- Keep the exact V3 signature, role boundary, profile checks and donor flow.
-- p_road_node_id remains accepted for RPC compatibility but is intentionally
-- ignored. NGO road-node assignment comes only from the trusted resolver.
create or replace function public.register_role_profile(
  p_full_name text,
  p_role text,
  p_phone text default null,
  p_ngo_name text default null,
  p_registration_number text default null,
  p_operating_address text default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_road_node_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_node text;
  v_snap_distance_m double precision;
  v_snapshot_id text;
  v_locked_snapshot_id text;
begin
  if v_user is null then
    raise exception 'UNAUTHENTICATED';
  end if;

  if p_role is null or p_role not in ('DONOR', 'NGO') then
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

  if p_role = 'NGO' then
    -- SHARE row lock conflicts with UPDATE of this coverage row in the
    -- repository's activate_snapshot.sql. SHARE locks are mutually compatible,
    -- so concurrent NGO registrations do not serialize with one another.
    -- The row remains locked through resolver, cache refresh and audit commit.
    select c.network_snapshot_id
      into v_locked_snapshot_id
      from public.road_network_coverage as c
     where c.active_flag
       and c.dataset_kind = 'OPERATIONAL'
       and c.approved_at is not null
       and c.max_snap_distance_m = 500
     for share;

    if v_locked_snapshot_id is null then
      raise exception 'NGO_LOCATION_NOT_ROUTABLE';
    end if;

    select r.node_id, r.snap_distance_m, r.snapshot_id
      into v_node, v_snap_distance_m, v_snapshot_id
      from public.geolock_resolve_road_node(p_latitude, p_longitude) as r;

    -- Defense in depth: the approved operational resolver is already limited
    -- by its 500 m coverage setting. Enforce the registration contract here too.
    if v_node is null or v_snap_distance_m is null
       or v_snap_distance_m < 0 or v_snap_distance_m > 500
       or v_snapshot_id is null
       or v_snapshot_id is distinct from v_locked_snapshot_id then
      raise exception 'NGO_LOCATION_NOT_ROUTABLE';
    end if;

    if not exists (
      select 1 from public.coordination_config
       where singleton and geofence_radius_m is not null
    ) then
      raise exception 'NGO_ELIGIBILITY_CONFIGURATION_MISSING';
    end if;
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
      p_latitude, p_longitude, v_node, clock_timestamp()
    );

    -- Cache initialization is part of this RPC transaction. A failure here
    -- aborts profile, role-profile and audit writes together.
    perform public.geolock_refresh_ngo_road_eligibility(v_user);
  end if;

  insert into public.audit_events(
    actor_user_id, actor_role, entity_type, entity_id, event_type,
    requested_state, resulting_state, reason_code, outcome, details
  )
  values (
    v_user, p_role, 'USER', v_user, 'REGISTER_ROLE', p_role, p_role,
    case when p_role = 'NGO' then 'ROAD_LOCATION_TECHNICALLY_VALIDATED' end,
    'SUCCESS',
    case when p_role = 'NGO' then jsonb_build_object(
      'location_validation', 'TECHNICAL_ROAD_NODE_RESOLUTION',
      'road_node_id', v_node,
      'snap_distance_m', round(v_snap_distance_m::numeric, 1),
      'network_snapshot_id', v_snapshot_id,
      'ngo_identity_verified', false
    ) else '{}'::jsonb end
  );

  return v_user;
end;
$$;

-- Registration-mode capability used by Flutter as a rollout/readiness check.
-- The resolver remains authoritative and rejects points without a valid node.
create or replace function public.geolock_app_capabilities()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_road_node_resolution boolean := false;
  v_config_version text;
begin
  if v_user is null then
    raise exception 'UNAUTHENTICATED';
  end if;

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
        v_road_node_resolution := false;
    end;
  end if;

  select c.config_version
    into v_config_version
    from public.coordination_config as c
   where c.singleton;

  return jsonb_build_object(
    'ngo_location_registration', 'AUTO_VALIDATED',
    'location_picker', 'GOOGLE_MAPS',
    'road_node_resolution', v_road_node_resolution,
    'configuration_version', v_config_version
  );
end;
$$;

-- Preserve the authenticated-only RPC boundary explicitly.
revoke all on function public.register_role_profile(
  text, text, text, text, text, text, double precision, double precision, text
) from public, anon;
grant execute on function public.register_role_profile(
  text, text, text, text, text, text, double precision, double precision, text
) to authenticated;

revoke all on function public.geolock_app_capabilities() from public, anon;
grant execute on function public.geolock_app_capabilities() to authenticated;

commit;
