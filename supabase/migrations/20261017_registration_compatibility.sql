-- GeoLock Hub registration compatibility for an already-installed V3 schema.
-- This migration adds the two profile/capability read RPCs needed by Flutter
-- and replaces register_role_profile with the same V3 signature. Self-selected
-- NGO locations are stored as unverified. No lifecycle tables or states change.

begin;

create or replace function public.get_my_profile()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
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
$$;

-- Keep the exact deployed V3 signature and existing donor behavior. NGO address
-- and coordinates come from the user and therefore cannot establish trust.
-- The client-provided road node is deliberately ignored until trusted review.
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

-- These RPCs are authenticated-client entry points. Do not leave PostgreSQL's
-- default PUBLIC EXECUTE grant in place.
revoke all on function public.get_my_profile() from public, anon;
revoke all on function public.geolock_app_capabilities() from public, anon;
revoke all on function public.register_role_profile(
  text, text, text, text, text, text, double precision, double precision, text
) from public, anon;

grant execute on function public.get_my_profile() to authenticated;
grant execute on function public.geolock_app_capabilities() to authenticated;
grant execute on function public.register_role_profile(
  text, text, text, text, text, text, double precision, double precision, text
) to authenticated;

commit;
