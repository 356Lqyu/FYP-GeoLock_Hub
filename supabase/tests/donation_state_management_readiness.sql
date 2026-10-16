-- Read-only checks. Run before deployment to inspect the live V3 schema.
-- No mutation statements are included.

-- Existing function signatures and definitions for overlap review.
select
  p.oid::regprocedure as function_identity,
  pg_get_function_result(p.oid) as result_type,
  pg_get_function_identity_arguments(p.oid) as identity_arguments,
  p.prosecdef as security_definer,
  pg_get_functiondef(p.oid) as function_definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'get_active_donation_categories',
    'get_eligible_hubs',
    'get_my_donations',
    'get_my_donation_detail',
    'cancel_donation',
    'create_and_validate_donation',
    'claim_listing',
    'reserve_hub_capacity',
    'confirm_hub_receipt'
  )
order by p.proname, p.oid::regprocedure::text;

-- Explicit compatibility matrix for the five RPCs defined by the proposed
-- donation-state migration. An existing identity with another return type
-- will make CREATE OR REPLACE fail; resolve that conflict before deployment.
with expected(proname, argument_types, expected_result) as (
  values
    ('get_active_donation_categories', '',
      'TABLE(category_id uuid, category_name text)'),
    ('get_eligible_hubs', 'uuid',
      'TABLE(hub_id uuid, hub_name text, address_text text, latitude double precision, longitude double precision, capacity_kg numeric, available_capacity_kg numeric)'),
    ('get_my_donations', '',
      'TABLE(donation_id uuid, title text, donation_status text, collection_path text, total_weight_kg numeric, created_at timestamp with time zone, hub_name text, reservation_status text, listing_routing_status text)'),
    ('get_my_donation_detail', 'uuid', 'jsonb'),
    ('cancel_donation', 'uuid, uuid', 'jsonb')
)
select e.proname,
  e.argument_types as expected_argument_types,
  e.expected_result,
  p.oid::regprocedure as installed_identity,
  pg_get_function_identity_arguments(p.oid) as installed_arguments,
  pg_get_function_result(p.oid) as installed_result,
  case
    when p.oid is null then 'MISSING_OK_FOR_ADDITIVE_CREATE'
    when pg_get_function_result(p.oid) = e.expected_result then 'COMPATIBLE_RESULT'
    else 'BLOCKED_INCOMPATIBLE_RETURN_TYPE'
  end as compatibility
from expected e
left join pg_proc p
  on p.pronamespace = 'public'::regnamespace
 and p.proname = e.proname
 and oidvectortypes(p.proargtypes) = e.argument_types
order by e.proname;

-- Actual installed columns used by the proposed RPCs and cancellation checks.
select table_name, column_name, data_type, udt_name, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name in (
    'donations', 'donation_items', 'donation_categories', 'listings',
    'donation_claims', 'claim_leases', 'hub_reservations', 'hub_receipts',
    'hub_inventory', 'hub_batch_members', 'community_hubs',
    'hub_accepted_categories', 'audit_events'
  )
order by table_name, ordinal_position;

-- Existing state constraints, transition triggers, and audit constraints.
select c.conrelid::regclass as table_name, c.conname,
  pg_get_constraintdef(c.oid) as definition
from pg_constraint c
where c.conrelid in (
  'public.donations'::regclass,
  'public.listings'::regclass,
  'public.audit_events'::regclass
)
order by table_name, c.conname;

select t.tgrelid::regclass as table_name, t.tgname,
  pg_get_triggerdef(t.oid) as trigger_definition,
  pg_get_functiondef(t.tgfoid) as trigger_function
from pg_trigger t
where not t.tgisinternal
  and t.tgrelid in (
    'public.donations'::regclass,
    'public.listings'::regclass,
    'public.audit_events'::regclass
  )
order by table_name, t.tgname;

-- After deployment: authenticated should be true; anon and PUBLIC should be false.
select p.oid::regprocedure as function_identity,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_exec,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
  exists (
    select 1
    from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where a.grantee = 0 and a.privilege_type = 'EXECUTE'
  ) as public_exec
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'get_active_donation_categories', 'get_eligible_hubs',
    'get_my_donations', 'get_my_donation_detail', 'cancel_donation'
  )
order by p.proname;

-- As an authenticated donor, call the read RPCs using the Supabase client:
--   rpc('get_active_donation_categories')
--   rpc('get_my_donations')
--   rpc('get_my_donation_detail', {'p_donation': '<OWN_DONATION_UUID>'})
-- A second donor must receive SQL NULL from the detail RPC for that UUID.
