-- Read-only checks. Run in Supabase SQL Editor before/after manual deployment.
-- No statements below modify schema or data.

-- 1) Confirm required schema, V3 RPC signatures, and ordered photo metadata.
select
  to_regprocedure('public.create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text,timestamp with time zone,timestamp with time zone') is not null as v3_create_signature_present,
  to_regprocedure('public.create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb)') is not null as photo_create_rpc_present,
  to_regprocedure('public.discover_eligible_listings()') is not null as v3_discovery_present,
  to_regprocedure('public.claim_listing(uuid,uuid)') is not null as v3_claim_present,
  to_regclass('public.donation_images') is not null as donation_image_table_present,
  to_regclass('public.donation_create_requests') is not null as idempotency_table_present;

select column_name,is_nullable,data_type
from information_schema.columns
where table_schema='public' and table_name='donation_images'
order by ordinal_position;

-- 2) Confirm the installed creation/discovery/claim bodies no longer use donor
-- availability dates. Historical columns remain during compatibility rollout.
select p.oid::regprocedure as function_signature,
       (p.prosrc ilike '%availability_start%' or p.prosrc ilike '%availability_end%') as still_references_donor_dates,
       p.prosecdef as security_definer,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon_can_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_can_execute
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.oid in (
    to_regprocedure('public.create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text,timestamp with time zone,timestamp with time zone'),
    to_regprocedure('public.discover_eligible_listings()'),
    to_regprocedure('public.claim_listing(uuid,uuid)')
  )
order by 1;

-- 2a) Focused post-deployment invariants for the explicit V3-compatible
-- replacements. Every result should be true. The configured geofence radius
-- should be 20000 metres and claim_lease_minutes should be 360.
select
  position('cfg.geofence_radius_m' in pg_get_functiondef(
    'public.discover_eligible_listings()'::regprocedure))>0 as discovery_uses_configured_geofence,
  position('20000' in pg_get_functiondef(
    'public.claim_listing(uuid,uuid)'::regprocedure))>0 as claim_keeps_20km_geofence,
  position('listing_expires_at' in pg_get_functiondef(
    'public.discover_eligible_listings()'::regprocedure))>0 as discovery_keeps_listing_expiry,
  position('listing_expires_at' in pg_get_functiondef(
    'public.claim_listing(uuid,uuid)'::regprocedure))>0 as claim_keeps_listing_expiry,
  position('pickup_road_node_id is null' in lower(pg_get_functiondef(
    'public.claim_listing(uuid,uuid)'::regprocedure)))>0 as claim_keeps_routing_node_rejection,
  position('claim_requests' in pg_get_functiondef(
    'public.claim_listing(uuid,uuid)'::regprocedure))>0 as claim_keeps_request_idempotency,
  position('for update' in lower(pg_get_functiondef(
    'public.claim_listing(uuid,uuid)'::regprocedure)))>0 as claim_keeps_row_locking,
  position('claim_lease_minutes' in pg_get_functiondef(
    'public.claim_listing(uuid,uuid)'::regprocedure))>0 as claim_keeps_configured_lease,
  (select claim_lease_minutes=360 from public.coordination_config where singleton)
    as configured_lease_is_360_minutes,
  (select geofence_radius_m=20000 from public.coordination_config where singleton)
    as configured_discovery_geofence_is_20km,
  position('values(v_actor,p_title,p_description,p_pickup_address,p_latitude,p_longitude,' in
    pg_get_functiondef('public.create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text,timestamptz,timestamptz)'::regprocedure))>0
    as creation_function_present_with_expected_signature,
  has_function_privilege('anon','public.claim_listing(uuid,uuid)','EXECUTE')=false
    as anon_cannot_claim,
  has_function_privilege('authenticated','public.claim_listing(uuid,uuid)','EXECUTE')
    as authenticated_can_claim;

-- 3) Inspect other deployed public function bodies before any future column drop.
select p.oid::regprocedure as dependent_function
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and (p.prosrc ilike '%availability_start%' or p.prosrc ilike '%availability_end%')
order by 1;

-- 4) Confirm images are private, row access is enabled, and photo ordering is
-- bounded. Existing image counts are shown for a manual historical-data review.
select id,name,public,file_size_limit,allowed_mime_types
from storage.buckets where id='geolock-donation-images';

select c.relname as table_name,c.relrowsecurity as rls_enabled,
       has_table_privilege('anon',c.oid,'SELECT') as anon_select,
       has_table_privilege('authenticated',c.oid,'INSERT') as authenticated_direct_insert
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('donation_images','hub_batch_images','donation_create_requests');

select schemaname,tablename,policyname,roles,cmd,qual,with_check
from pg_policies
where schemaname='public' and tablename in ('donation_images','hub_batch_images','donation_create_requests')
order by tablename,policyname;

select donation_id,count(*) as photo_count,
       count(*) filter(where display_order=1 and is_primary) as covers,
       min(display_order) as min_order,max(display_order) as max_order
from public.donation_images group by donation_id order by donation_id;

-- Pre-deployment data review. The availability transition now preserves every
-- existing listing expiry, including values copied by V3 from availability_end.
select l.listing_id,l.listing_status,l.listing_expires_at,d.availability_end,
       (l.listing_expires_at=d.availability_end) as may_be_legacy_donor_expiry
from public.listings l join public.donations d using(donation_id)
where l.source_type='DIRECT_DONATION' and l.listing_expires_at is not null
order by l.listing_expires_at;

-- Candidate upload objects that have no committed photo metadata. Review the
-- age and upload state before deleting through the Supabase Storage API; do not
-- delete rows directly from storage.objects. This includes interrupted drafts.
select o.name,o.created_at,o.metadata->>'size' as size_bytes,
       o.metadata->>'mimetype' as content_type
from storage.objects o
where o.bucket_id='geolock-donation-images'
  and not exists(select 1 from public.donation_images i where i.storage_path=o.name)
  and not exists(select 1 from public.hub_batch_images i where i.storage_path=o.name)
order by o.created_at;

-- 5) Confirm Stage 2 minimum-photo enforcement. It must be absent during client
-- rollout and present after 20261018_enforce_required_donation_photos.sql.
select exists(select 1 from pg_trigger t
  where t.tgrelid='public.donations'::regclass
    and t.tgname='donations_require_photo_at_commit' and not t.tgisinternal)
  as required_photo_trigger_installed;

-- 6) Storage policy inventory. Storage RLS policies are permissive-OR: an
-- older broad policy can override these bucket-specific restrictions. Review
-- every policy applying to authenticated, anon, or public roles and ensure
-- no existing policy admits access to this bucket outside the intended paths.
select polname,polcmd,polroles::regrole[] as roles,pg_get_expr(polqual,polrelid) as using_expression,
       pg_get_expr(polwithcheck,polrelid) as check_expression
from pg_policy where polrelid='storage.objects'::regclass
order by polname;

-- Check exact RPC return signatures before applying CREATE OR REPLACE. Any
-- same-name function with a different return type requires a separately
-- reviewed compatibility migration rather than an automatic drop/recreate.
select p.oid::regprocedure as signature,pg_get_function_result(p.oid) as result_type,
       p.prosecdef as security_definer,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in (
  'add_donation_image','add_hub_batch_image','get_my_donation_dashboard',
  'get_my_hub_batches_dashboard','get_my_claims','create_and_validate_donation',
  'discover_eligible_listings','claim_listing','start_pickup','complete_pickup',
  'recover_expired_claims'
)
order by p.proname,p.oid::regprocedure::text;

-- Manual authenticated checks after rollout:
-- * Donor: create donation with 1 and 3 photos; ensure order 1 is the cover.
-- * Donor: same p_request and same payload returns same donation_id; changed payload is rejected.
-- * Donor: 0 or 4 photos are rejected by the create RPC.
-- * NGO: discover an eligible listing; read only its image paths; test an out-of-radius NGO is denied.
-- * Hub admin: read only images belonging to reservations/inventory and own batches.
-- * Anonymous and unrelated accounts: signed URL creation/read is denied.
-- * During Stage 1 rollout, old create RPC callers remain signature-compatible. After Stage 2,
--   zero-photo donation inserts must fail at commit; test only in a development project.
-- * Verify a non-claiming NGO cannot obtain image metadata or signed URLs while
--   road-node verification is unavailable; claimed NGO access must still obey lease/custody rules.
-- * Verify expired V3 listing expiries remain in force and are not revived by the migration.
-- * Validate claim lease remains 360 minutes and atomic-claim tests separately; this change does not alter them.
