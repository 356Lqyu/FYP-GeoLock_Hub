-- E2 reset: empties the experiment project before each condition, so each one starts from the same fresh database.
-- Removes what 01, 02 and 03 created and the @geolock.example.com test accounts. PostGIS and Supabase's own schemas stay.
-- Changes nothing if it finds users or donations that are not E2 test data (for example the app's project).
do $$ declare n bigint; begin
  select count(*) into n from auth.users where email is null or email not like '%@geolock.example.com';
  if n > 0 then
    raise exception 'NOT_AN_EXPERIMENT_PROJECT: % user accounts that are not E2 test accounts; nothing was deleted', n;
  end if;
  if to_regclass('public.donations') is not null then
    execute $q$select count(*) from public.donations d left join auth.users u on u.id = d.donor_user_id
               where u.email is null or u.email not like '%@geolock.example.com'$q$ into n;
    if n > 0 then
      raise exception 'NOT_AN_EXPERIMENT_PROJECT: % donations from other accounts; nothing was deleted', n;
    end if;
  end if;
end $$;

drop schema if exists e2_baseline cascade;
drop schema if exists e2_bench cascade;
drop schema if exists routing_private cascade;
drop schema if exists resolution_private cascade;

drop table if exists
  public.claim_reconciliation_cases, public.operation_failure_events,
  public.active_task_route_assignments, public.pickup_route_stops, public.pickup_routes,
  public.pickup_tasks, public.vehicles, public.claim_leases, public.donation_claims,
  public.claim_requests, public.listings, public.hub_batch_members, public.hub_batches,
  public.hub_inventory, public.hub_receipts, public.hub_reservations, public.donation_items,
  public.donations, public.hub_accepted_categories, public.community_hubs,
  public.donation_categories, public.coordination_config, public.hub_admin_profiles,
  public.ngo_profiles, public.donor_profiles, public.audit_events, public.user_profiles
  cascade;

do $$ declare f regprocedure; begin
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace
    where s.nspname = 'public' and p.proname = any (array[
      'prevent_role_change', 'enforce_donation_transition', 'enforce_listing_transition',
      'guard_donation_items', 'guard_batch_immutability', 'prevent_audit_mutation',
      'register_role_profile', 'create_and_validate_donation', 'register_community_hub',
      'reserve_hub_capacity', 'confirm_hub_receipt', 'publish_whole_donation_batch',
      'discover_eligible_listings', 'claim_listing', 'start_pickup', 'complete_pickup',
      'recover_expired_claims', 'assign_task_to_route', 'geolock_lock_listing_donations',
      'geolock_transition_listing_donations', 'geolock_ngo_listing_road_check'])
  loop
    execute format('drop function %s', f);
  end loop;
end $$;

delete from auth.users where email like '%@geolock.example.com';
