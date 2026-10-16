-- Read-only preflight and post-deployment checks for
-- 20261017_role_dashboards_and_images.sql. Do not run the migration here.

-- Preflight: confirm the V3 source columns used by the new RPCs.
select table_name, column_name, data_type, udt_name, is_nullable
from information_schema.columns
where table_schema='public'
  and table_name in (
    'donations','donation_items','donation_images','listings',
    'hub_reservations','hub_receipts','hub_inventory','hub_batches',
    'pickup_tasks','community_hubs','hub_batch_images','user_profiles','donor_profiles',
    'hub_admin_profiles','audit_events','coordination_config'
  )
order by table_name,ordinal_position;

-- Preflight: same-identity function conflicts and exact results.
select p.oid::regprocedure as function_identity,
  pg_get_function_result(p.oid) as result_type,
  pg_get_function_identity_arguments(p.oid) as identity_arguments,
  p.prosecdef as security_definer
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in ('get_my_donation_dashboard','get_hub_dashboard',
    'add_donation_image','add_hub_batch_image','get_my_hub_batches_dashboard',
    'get_my_hubs','get_my_hub_reservations','get_my_hub_inventory',
    'get_my_claims','get_claimed_listing_detail')
order by p.proname,p.oid::regprocedure::text;

-- Preflight: ensure the expected bucket is absent or private before migration.
select id,name,public,file_size_limit,allowed_mime_types
from storage.buckets
where id='geolock-donation-images';

-- Post-deployment: RPC permissions must be authenticated-only.
select p.oid::regprocedure as function_identity,
  has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_exec,
  has_function_privilege('anon',p.oid,'EXECUTE') as anon_exec,
  exists (
    select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
    where a.grantee=0 and a.privilege_type='EXECUTE'
  ) as public_exec
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in ('get_my_donation_dashboard','get_hub_dashboard',
    'add_donation_image','add_hub_batch_image','get_my_hub_batches_dashboard',
    'get_my_hubs','get_my_hub_reservations','get_my_hub_inventory',
    'get_my_claims','get_claimed_listing_detail')
order by p.proname;

-- Post-deployment: the object bucket must stay private with the configured cap.
select id,public,file_size_limit,allowed_mime_types
from storage.buckets
where id='geolock-donation-images';

-- Post-deployment: the metadata tables must have RLS and only owner policies.
select c.oid::regclass as table_name,c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as force_rls
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('donation_images','hub_batch_images');

select schemaname,tablename,policyname,roles,cmd,qual,with_check
from pg_policies
where (schemaname='public' and tablename in ('donation_images','hub_batch_images'))
   or (schemaname='storage' and tablename='objects'
       and policyname like 'geolock_%_image_owner_%')
order by schemaname,tablename,policyname;

-- Post-deployment authenticated-client calls (run separately as matching roles):
--   rpc('get_my_donation_dashboard') -- donor only; never includes another donor
--   rpc('get_hub_dashboard', {'p_hub':'<OWN_HUB_UUID>'}) -- admin ownership checked
--   rpc('get_hub_dashboard', {'p_hub':'<OTHER_HUB_UUID>'}) -- must be denied
--   rpc('add_donation_image', {...}) -- donor-owned donation/path only
-- Storage upload/read/remove should be tested with owner and second user tokens.
