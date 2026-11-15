-- Guarded E2-only reset. Never execute directly: run_e2.py performs a read-only
-- identity/catalog preflight and supplies session-local guard values first.
-- No CASCADE is used; an unexpected dependency aborts and rolls back the reset.
begin;
do $$
declare
  marker uuid;
  marker_project_ref text;
  expected_project_ref text;
  marker_exists boolean;
  allowed_ids uuid[];
  unexpected bigint;
begin
  if nullif(current_setting('app.geolock_e2_reset_target_id', true), '') is null
     or nullif(current_setting('app.geolock_e2_allowed_accounts', true), '') is null then
    raise exception 'E2_RESET_GUARD_MISSING: reset must be invoked by the validated E2 harness';
  end if;
  expected_project_ref := nullif(current_setting('app.geolock_e2_project_ref', true), '');
  if expected_project_ref is null then
    if current_database() <> 'geolock_e2'
       or inet_server_addr() is distinct from inet '127.0.0.1/32'
       or inet_server_port() is null or inet_server_port() = 5432 then
      raise exception 'E2_RESET_REFUSED: expected the dedicated local geolock_e2 database';
    end if;
  else
    if current_database() <> 'postgres' or current_user <> 'postgres' or session_user <> 'postgres'
       or expected_project_ref !~ '^[a-z0-9]{20}$'
       or expected_project_ref in ('rcgyuwiidqvrgbxswhqj', 'mffccmlimmbrgasgfnnq')
       or not exists (
         select 1 from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()
           and database = (select oid from pg_database where datname = current_database())
           and classid = 1195724620 and objid = 2 and objsubid = 2
           and mode = 'ExclusiveLock' and granted
       ) then
      raise exception 'E2_RESET_REFUSED: hosted project or run lock is invalid';
    end if;
  end if;
  select to_regclass('public.e2_disposable_target') is not null into marker_exists;
  if not marker_exists then
    raise exception 'E2_RESET_REFUSED: E2 marker table is missing';
  end if;
  if expected_project_ref is not null then
    lock table public.e2_disposable_target in share mode;
    lock table auth.users in share row exclusive mode;
    if row_security_active('auth.users'::regclass) then
      raise exception 'E2_RESET_REFUSED: row security could hide managed Auth users';
    end if;
  end if;
  select target_id, project_ref into strict marker, marker_project_ref
    from public.e2_disposable_target where singleton is true;
  if marker::text is distinct from current_setting('app.geolock_e2_reset_target_id', true)
     or marker_project_ref is distinct from expected_project_ref then
    raise exception 'E2_RESET_TARGET_MISMATCH: marker differs from configured identity';
  end if;
  select coalesce(array_agg(key::uuid), array[]::uuid[]) into allowed_ids
    from jsonb_each_text(current_setting('app.geolock_e2_allowed_accounts', true)::jsonb);
  select count(*) into unexpected from auth.users u
   where not (u.id = any(allowed_ids)) or u.email is null
      or u.email is distinct from (current_setting('app.geolock_e2_allowed_accounts', true)::jsonb ->> u.id::text);
  if unexpected <> 0 then
    raise exception 'E2_RESET_REFUSED: auth account inventory includes unapproved users';
  end if;
end $$;

-- These are the only trigger names installed by the E2 schema. The read-only
-- preflight rejects any other trigger attached to an affected public table.
do $$
declare r record;
  expected_function regprocedure;
  actual_function oid;
begin
  for r in select * from (values
    ('public.user_profiles','trg_role_immutable','public.prevent_role_change()'),
    ('public.donations','trg_donation_transition','public.enforce_donation_transition()'),
    ('public.listings','trg_listing_transition','public.enforce_listing_transition()'),
    ('public.donation_items','trg_items_guard','public.guard_donation_items()'),
    ('public.hub_batches','trg_batch_guard','public.guard_batch_immutability()'),
    ('public.hub_batch_members','trg_members_guard','public.guard_batch_immutability()'),
    ('public.audit_events','trg_audit_append_only','public.prevent_audit_mutation()')) as v(rel, trigger_name, function_name)
  loop
    expected_function := to_regprocedure(r.function_name);
    if to_regclass(r.rel) is not null then
      select tgfoid into actual_function from pg_trigger
       where tgrelid=to_regclass(r.rel) and tgname=r.trigger_name and not tgisinternal;
      if actual_function is not null and actual_function is distinct from expected_function then
        raise exception 'E2_RESET_REFUSED: trigger function differs from reviewed E2 definition';
      end if;
      execute format('drop trigger if exists %I on %s', r.trigger_name, r.rel);
    end if;
  end loop;
end $$;

-- Exact signatures prevent a concurrently-created overload from being swept up.
-- Every DROP uses PostgreSQL's default RESTRICT behavior.
drop function if exists public.prevent_role_change();
drop function if exists public.enforce_donation_transition();
drop function if exists public.enforce_listing_transition();
drop function if exists public.guard_donation_items();
drop function if exists public.guard_batch_immutability();
drop function if exists public.prevent_audit_mutation();
drop function if exists public.register_role_profile(text,text,text,text,text,text,double precision,double precision,text);
drop function if exists public.create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text,timestamptz,timestamptz);
drop function if exists public.register_community_hub(text,text,double precision,double precision,numeric,text);
drop function if exists public.reserve_hub_capacity(uuid,uuid);
drop function if exists public.confirm_hub_receipt(uuid,numeric);
drop function if exists public.publish_whole_donation_batch(uuid,uuid[]);
drop function if exists public.discover_eligible_listings();
drop function if exists public.claim_listing(uuid,uuid);
drop function if exists public.start_pickup(uuid);
drop function if exists public.complete_pickup(uuid,boolean);
drop function if exists public.recover_expired_claims(integer);
drop function if exists public.assign_task_to_route(uuid,uuid,integer);
drop function if exists public.geolock_lock_listing_donations(uuid,text[]);
drop function if exists public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text);
drop function if exists public.geolock_transition_listing_donations(uuid,text,text);
drop function if exists public.geolock_ngo_listing_road_check(uuid,uuid);
drop function if exists e2_baseline.non_atomic_check_listing(uuid);
drop function if exists e2_baseline.non_atomic_write_claim(uuid,uuid);
drop function if exists routing_private.lock_route_for_recovery(uuid);
drop function if exists routing_private.release_expired_unstarted_stop(uuid,uuid,uuid,uuid);
drop function if exists routing_private.coord_release_allowed(uuid,text);
drop function if exists resolution_private.release_allowed(uuid,text);

drop table if exists e2_baseline.naive_claims;
drop table if exists e2_bench.road_km;
drop table if exists routing_private.deferred_stops;
drop table if exists routing_private.deferred_release_permits;
drop table if exists routing_private.bindings;
drop table if exists routing_private.items;
drop table if exists resolution_private.cases;
drop table if exists
  public.claim_reconciliation_cases, public.operation_failure_events,
  public.active_task_route_assignments, public.pickup_route_stops, public.pickup_routes,
  public.pickup_tasks, public.vehicles, public.claim_leases, public.donation_claims,
  public.claim_requests, public.listings, public.hub_batch_members, public.hub_batches,
  public.hub_inventory, public.hub_receipts, public.hub_reservations, public.donation_items,
  public.donations, public.hub_accepted_categories, public.community_hubs,
  public.donation_categories, public.coordination_config, public.hub_admin_profiles,
  public.ngo_profiles, public.donor_profiles, public.audit_events, public.user_profiles;

drop schema if exists e2_baseline restrict;
drop schema if exists e2_bench restrict;
drop schema if exists routing_private restrict;
drop schema if exists resolution_private restrict;

delete from auth.users
 where id = any (select key::uuid
                   from jsonb_each_text(current_setting('app.geolock_e2_allowed_accounts', true)::jsonb));
commit;
