-- SELECT-only. Isolated DEV rcgyuwiidqvrgbxswhqj only.
-- Pre-deployment inspection: run through a connection already verified as DEV.
-- This file neither invokes lifecycle RPCs nor takes row locks.
-- The required nine-argument identity below is PRE-deployment only. This revision
-- replaces it with the seven-argument identity; see POST-deployment checks below.

with required(signature) as (values
  ('public.create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text,timestamptz,timestamptz)'),
  ('public.create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb)'),
  ('public.claim_listing(uuid,uuid)'),('public.start_pickup(uuid)'),
  ('public.complete_pickup(uuid,boolean)'),('public.cancel_claim(uuid,uuid)'),
  ('public.recover_expired_claims(integer)'),('public.submit_claim_reconciliation(uuid,boolean,uuid)'),
  ('public.geolock_ngo_eligibility_ready(uuid)'),('public.geolock_listing_eligibility_ready(uuid)'),
  ('public.geolock_road_eligible_km(uuid,uuid)'),('public.geolock_ngo_listing_road_check(uuid,uuid)'),
  ('public.guard_donation_items()'),('public.require_donation_photo_before_commit()'),
  ('public.guard_batch_immutability()'),('public.can_read_geolock_donation_image(text)'),
  ('public.process_listing_eligibility_refresh_jobs()'),
  ('public.process_ngo_eligibility_refresh_jobs()')
)
select r.signature,p.oid is not null as exists,
  pg_get_userbyid(p.proowner) as owner,p.prosecdef as security_definer,
  p.proconfig,p.proacl,pg_get_function_result(p.oid) as result
from required r left join pg_proc p on p.oid=to_regprocedure(r.signature)
order by r.signature;

-- Inspect exact overloads, defaults, owners and ACLs before identity replacement.
select p.oid::regprocedure as signature,pg_get_function_arguments(p.oid) as arguments,
  pg_get_userbyid(p.proowner) as owner,p.proacl,p.proconfig
from pg_proc p where p.pronamespace='public'::regnamespace
  and p.proname in ('create_and_validate_donation','create_donation_with_images');
-- DROP RESTRICT will abort on any unreviewed tracked dependency; no CASCADE.
select pg_describe_object(d.classid,d.objid,d.objsubid) as tracked_dependency,d.deptype
from pg_depend d where d.refclassid='pg_proc'::regclass and d.refobjid=to_regprocedure(
  'public.create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text,timestamptz,timestamptz)');
-- PL/pgSQL string bodies do not necessarily record pg_depend edges.
select p.oid::regprocedure as text_caller
from pg_proc p where p.pronamespace='public'::regnamespace
  and p.proname<>'create_and_validate_donation'
  and position('public.create_and_validate_donation(' in p.prosrc)>0;

-- New helper names must be absent before first deployment; inspect any collision.
select p.oid::regprocedure as signature,pg_get_userbyid(p.proowner) as owner,
  p.prosecdef,p.proconfig,p.proacl
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in (
  'geolock_lock_listing_donations','geolock_transition_listing_donations',
  'geolock_assert_donation_lifecycle','geolock_validate_donation_at_commit');

select donation_direct_min_kg,geofence_radius_m,claim_lease_minutes,
  hub_reservation_minutes,batch_min_donations,batch_max_donations,batch_max_weight_kg
from public.coordination_config where singleton;

select c.conrelid::regclass as relation,c.conname,pg_get_constraintdef(c.oid) as definition
from pg_constraint c where c.conrelid in (
  'public.donations'::regclass,'public.audit_events'::regclass,
  'public.hub_batches'::regclass,'public.hub_batch_members'::regclass,
  'public.pickup_tasks'::regclass,'public.claim_leases'::regclass)
order by c.conrelid::regclass::text,c.conname;

select t.tgrelid::regclass as relation,t.tgname,t.tgdeferrable,t.tginitdeferred,
  pg_get_triggerdef(t.oid) as definition
from pg_trigger t where not t.tgisinternal and t.tgrelid in (
  'public.donations'::regclass,'public.donation_items'::regclass,
  'public.listings'::regclass,'public.hub_batches'::regclass,
  'public.hub_batch_members'::regclass,'public.audit_events'::regclass)
order by t.tgrelid::regclass::text,t.tgname;

-- Aggregate evidence only; no donor identities, addresses or image paths.
with evidence as (
  select d.donation_status,d.collection_path,l.listing_status,
    c.claim_status,le.lease_status,t.task_status,count(*) as donations
  from public.donations d
  left join public.hub_batch_members m on m.donation_id=d.donation_id and m.membership_status='ACTIVE'
  left join public.listings l on (l.source_type='DIRECT_DONATION' and l.donation_id=d.donation_id)
    or (l.source_type='HUB_BATCH' and l.batch_id=m.batch_id)
  left join public.donation_claims c on c.listing_id=l.listing_id
    and c.claim_status in ('ACTIVE','RECONCILIATION_REQUIRED')
  left join public.claim_leases le using(claim_id)
  left join public.pickup_tasks t using(claim_id)
  group by d.donation_status,d.collection_path,l.listing_status,c.claim_status,le.lease_status,t.task_status
)
select *,case
  when donation_status='READY_FOR_PICKUP' and collection_path='DIRECT_PICKUP'
    and listing_status='AVAILABLE' and claim_status is null then 'AVAILABLE'
  when donation_status='READY_FOR_PICKUP' and collection_path='DIRECT_PICKUP'
    and listing_status='CLAIMED' and claim_status in ('ACTIVE','RECONCILIATION_REQUIRED')
    and lease_status=claim_status and task_status in ('CONFIRMED','PLANNED') then 'CLAIMED'
  when donation_status='BATCHED' and listing_status='CLAIMED'
    and claim_status in ('ACTIVE','RECONCILIATION_REQUIRED')
    and lease_status=claim_status and task_status in ('CONFIRMED','PLANNED') then 'CLAIMED'
  when donation_status='READY_FOR_PICKUP' then 'BLOCKED_AMBIGUOUS'
  else 'UNCHANGED'
end as backfill_action
from evidence order by collection_path,donation_status,listing_status;

select count(*) filter(where collection_path is null or total_weight_kg is null
  or total_weight_kg<=0
  or (collection_path='DIRECT_PICKUP') is distinct from (total_weight_kg>=10)) as invalid_classifications
from public.donations;

select count(*) as inconsistent_published_batches
from public.hub_batches b
where b.batch_status='PUBLISHED' and (
  b.batch_donation_count<>(select count(*) from public.hub_batch_members m
    where m.batch_id=b.batch_id and m.membership_status='ACTIVE')
  or exists(select 1 from public.hub_batch_members m
    where m.batch_id=b.batch_id and m.membership_status='ACTIVE'
      and not exists(select 1 from public.hub_inventory hi
        where hi.donation_id=m.donation_id and hi.hub_id=b.hub_id and hi.inventory_status='BATCHED')));

-- Confirm both guards remain inside the protected cache reader/check.
select p.oid::regprocedure as signature,
  position('geolock_ngo_eligibility_ready' in p.prosrc)>0 as ngo_guard,
  position('geolock_listing_eligibility_ready' in p.prosrc)>0 as listing_guard
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in (
  'geolock_road_eligible_km','geolock_ngo_listing_road_check');

-- Optional post-deployment SELECT-only verification (no RPC invocation).
-- Expect exactly one date-free identity; no stale nine-argument callable overload.
select count(*)=1 and bool_and(p.oid=to_regprocedure(
  'public.create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text)'))
  as single_date_free_creation_identity
from pg_proc p where p.pronamespace='public'::regnamespace
  and p.proname='create_and_validate_donation';
select column_name,is_nullable,column_default from information_schema.columns
where table_schema='public' and table_name='donations'
  and column_name in ('availability_start','availability_end');
select donation_status,collection_path,count(*) from public.donations
group by donation_status,collection_path order by collection_path,donation_status;
select conname,pg_get_constraintdef(oid) from pg_constraint
where conrelid='public.donations'::regclass and conname='donations_donation_status_check';
select t.tgname,t.tgdeferrable,t.tginitdeferred from pg_trigger t
where t.tgrelid='public.donations'::regclass and t.tgname='donations_lifecycle_at_commit';
