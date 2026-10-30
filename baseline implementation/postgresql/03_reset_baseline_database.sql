-- Reset the baseline database to empty: removes everything 01 and baseline 3 created,
-- all baseline runs and the @geolock.example.com accounts. Run 01 again afterwards.
-- Baseline database only: stops without changing anything if it finds other donations.

begin;

do $$
declare n integer;
begin
  if to_regclass('public.donations') is not null then
    execute $q$select count(*) from public.donations d left join auth.users u on u.id = d.donor_user_id
               where u.email is null or u.email not like '%@geolock.example.com'$q$ into n;
    if n > 0 then
      raise exception 'NOT_A_BASELINE_DATABASE: % donations from other accounts; nothing was deleted', n;
    end if;
  end if;
end $$;

drop schema if exists e2_baseline cascade;

drop table if exists
  public.active_task_route_assignments, public.pickup_route_stops, public.pickup_routes,
  public.pickup_tasks, public.vehicles, public.claim_leases, public.donation_claims,
  public.claim_requests, public.listings, public.hub_batch_members, public.hub_batches,
  public.hub_inventory, public.hub_receipts, public.hub_reservations, public.donation_items,
  public.donations, public.hub_accepted_categories, public.community_hubs,
  public.donation_categories, public.coordination_config, public.hub_admin_profiles,
  public.ngo_profiles, public.donor_profiles, public.audit_events, public.user_profiles
  cascade;

do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace
    where s.nspname = 'public' and p.proname = any (array[
      'prevent_role_change', 'enforce_donation_transition', 'enforce_listing_transition',
      'guard_donation_items', 'guard_batch_immutability', 'prevent_audit_mutation',
      'register_role_profile', 'create_and_validate_donation', 'register_community_hub',
      'reserve_hub_capacity', 'confirm_hub_receipt', 'publish_whole_donation_batch',
      'discover_eligible_listings', 'claim_listing', 'start_pickup', 'complete_pickup',
      'recover_expired_claims', 'assign_task_to_route'])
  loop
    execute format('drop function %s', f);
  end loop;
end $$;

delete from auth.users where email like '%@geolock.example.com';

drop extension if exists postgis;

commit;

-- Check: every value should be 0.
select (select count(*) from pg_tables where schemaname = 'public') as public_tables,
       (select count(*) from pg_proc p join pg_namespace s on s.oid = p.pronamespace
         where s.nspname = 'public' and p.prokind = 'f'
           and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')) as public_functions,
       (select count(*) from pg_namespace where nspname = 'e2_baseline') as e2_baseline_schema,
       (select count(*) from auth.users where email like '%@geolock.example.com') as baseline_accounts;
