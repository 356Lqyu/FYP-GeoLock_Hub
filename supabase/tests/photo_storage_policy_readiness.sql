-- Read-only checks after applying 20261018_fix_photo_storage_policy_permissions.sql.
-- These inspect installed definitions; they do not simulate authenticated Storage API calls.

select
  to_regprocedure('public.geolock_storage_can_upload_donation_image(text,text,jsonb)') is not null
    as donor_upload_guard_present,
  to_regprocedure('public.geolock_storage_can_upload_batch_image(text,text,jsonb)') is not null
    as batch_upload_guard_present,
  to_regprocedure('public.geolock_storage_can_delete_unattached_image(text,text)') is not null
    as unattached_delete_guard_present,
  to_regprocedure('public.geolock_storage_can_read_image(text,text)') is not null
    as committed_image_read_guard_present;

select p.oid::regprocedure as function_signature,
       p.prosecdef as security_definer,
       pg_get_userbyid(p.proowner) as function_owner,
       p.proconfig as function_settings,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon_can_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_can_execute,
       has_table_privilege(pg_get_userbyid(p.proowner),'public.donations','select')
         as function_owner_can_read_donations,
       has_table_privilege(pg_get_userbyid(p.proowner),'public.donation_images','select')
         as function_owner_can_read_donation_images,
       has_table_privilege(pg_get_userbyid(p.proowner),'public.hub_batches','select')
         as function_owner_can_read_batches,
       has_table_privilege(pg_get_userbyid(p.proowner),'public.community_hubs','select')
         as function_owner_can_read_hubs,
       has_table_privilege(pg_get_userbyid(p.proowner),'storage.buckets','select')
         as function_owner_can_read_bucket_configuration
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in (
  'geolock_storage_can_upload_donation_image',
  'geolock_storage_can_upload_batch_image',
  'geolock_storage_can_delete_unattached_image',
  'geolock_storage_can_read_image')
order by p.proname;

-- Reader ownership determines whether an RLS policy calling the reader can
-- query the same metadata table without recursively invoking itself.
select p.oid::regprocedure as reader_signature,
       r.rolname as reader_owner,
       r.rolsuper or r.rolbypassrls as owner_bypasses_rls,
       c.relowner=p.proowner and not c.relforcerowsecurity as owner_bypasses_target_table_rls,
       c.relforcerowsecurity as target_table_forces_rls,
       has_table_privilege(p.proowner,c.oid,'select') as owner_can_select_target_table
from pg_proc p
join pg_roles r on r.oid=p.proowner
join pg_class c on c.oid=case p.proname
  when 'can_read_geolock_donation_image' then 'public.donation_images'::regclass
  when 'can_read_geolock_batch_image' then 'public.hub_batch_images'::regclass
end
where p.oid in ('public.can_read_geolock_donation_image(text)'::regprocedure,
                'public.can_read_geolock_batch_image(text)'::regprocedure);

-- Search-path comparison is whitespace-insensitive because pg_proc.proconfig
-- may preserve or normalize spaces. Both repository definitions specify this path.
select p.oid::regprocedure as reader_signature,
       p.prosecdef as security_definer,
       array(select regexp_replace(split_part(s.setting,'=',2),'[[:space:]]','','g')
         from unnest(coalesce(p.proconfig,'{}'::text[])) s(setting)
         where split_part(s.setting,'=',1)='search_path') as normalized_search_paths,
       exists(select 1 from unnest(coalesce(p.proconfig,'{}'::text[])) s(setting)
         where split_part(s.setting,'=',1)='search_path'
           and regexp_replace(split_part(s.setting,'=',2),'[[:space:]]','','g')
             ='pg_catalog,public,extensions,pg_temp') as expected_search_path
from pg_proc p
where p.oid in ('public.can_read_geolock_donation_image(text)'::regprocedure,
                'public.can_read_geolock_batch_image(text)'::regprocedure);

-- SECURITY DEFINER ownership/RLS prerequisite. Either the helper owner has
-- BYPASSRLS, or it owns each table it reads and FORCE ROW LEVEL SECURITY is off.
select current_user as migration_role,
       r.rolsuper,
       r.rolbypassrls,
       bool_and(c.relowner=(select oid from pg_roles where rolname=current_user)
         and not c.relforcerowsecurity) as owns_all_helper_tables_without_force_rls
from pg_roles r
cross join pg_class c
join pg_namespace n on n.oid=c.relnamespace
where r.rolname=current_user and (n.nspname,c.relname) in
  (('public','donor_profiles'),('public','donations'),
   ('public','donation_images'),('public','hub_batches'),
   ('public','community_hubs'),('public','hub_batch_images'),
   ('storage','buckets'))
group by r.rolname,r.rolsuper,r.rolbypassrls;

-- The pre-existing role-aware photo readers are the authorization boundary
-- for NGO and hub access. Confirm their SECURITY DEFINER status, owner,
-- configured search path, and grants as well as the corrective wrappers.
select p.oid::regprocedure as function_signature,
       p.prosecdef as security_definer,
       pg_get_userbyid(p.proowner) as function_owner,
       p.proconfig as function_settings,
       has_function_privilege('anon',p.oid,'EXECUTE') as anon_can_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_can_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in
  ('can_read_geolock_donation_image','can_read_geolock_batch_image')
order by p.proname;

select schemaname,tablename,policyname,roles,cmd,qual,with_check
from pg_policies where schemaname='public'
  and tablename in ('donation_images','hub_batch_images')
order by tablename,policyname;

-- Expected policy pairing: each table has one permissive owner/read-helper
-- policy and one restrictive policy using the same authorization predicate.
select polname,polcmd,polpermissive,polroles::regrole[] as roles,
       pg_get_expr(polqual,polrelid) as using_expression
from pg_policy where polrelid in
  ('public.donation_images'::regclass,'public.hub_batch_images'::regclass)
  and polcmd='r'
order by polrelid::regclass::text,polpermissive,polname;

-- Inspect every policy because Supabase Storage policies are permissive ORs.
-- Confirm no unrecognized policy grants broader access to this bucket.
select polname,polcmd,polroles::regrole[] as roles,
       pg_get_expr(polqual,polrelid) as using_expression,
       pg_get_expr(polwithcheck,polrelid) as check_expression
from pg_policy where polrelid='storage.objects'::regclass order by polname;

-- The known GeoLock write policies should delegate table lookups to helpers,
-- rather than containing public.donations/public.hub_batches references.
select polname,polcmd,
       coalesce(pg_get_expr(polqual,polrelid),'') as using_expression,
       coalesce(pg_get_expr(polwithcheck,polrelid),'') as check_expression,
       (coalesce(pg_get_expr(polqual,polrelid),'')||' '||
        coalesce(pg_get_expr(polwithcheck,polrelid),'')) ilike '%public.donations%'
         or (coalesce(pg_get_expr(polqual,polrelid),'')||' '||
        coalesce(pg_get_expr(polwithcheck,polrelid),'')) ilike '%public.hub_batches%'
         or (coalesce(pg_get_expr(polqual,polrelid),'')||' '||
        coalesce(pg_get_expr(polwithcheck,polrelid),'')) ilike '%public.community_hubs%'
         as directly_reads_protected_tables
from pg_policy where polrelid='storage.objects'::regclass
  and polname in ('geolock_donation_image_owner_insert',
    'geolock_batch_image_owner_insert','geolock_unattached_donation_image_delete',
    'geolock_unattached_batch_image_delete')
order by polname;

select id,name,public,file_size_limit,allowed_mime_types
from storage.buckets where id='geolock-donation-images';

select polname,polcmd,polpermissive,polroles::regrole[] as roles,
       pg_get_expr(polqual,polrelid) as using_expression,
       pg_get_expr(polwithcheck,polrelid) as check_expression
from pg_policy where polrelid='storage.objects'::regclass
  and polname like 'geolock_donation_images_%_guard'
order by polname;

-- Development-project API integration matrix (run as real test accounts).
-- These are behavioral checks; catalog inspection above cannot prove them.
-- 1. Registered donor uploads 1 and 3 photos to its own pending UUID path: pass.
-- 2. Donor with no donor_profiles row uploads pending image: denied.
-- 3. Different donor uploads under another user's prefix: denied.
-- 4. NGO and hub admin attempt donor pending upload: denied.
-- 5. Wrong bucket, MIME/extension mismatch, malformed UUID: denied. Supabase's
-- upload preflight supplies metadata.mimetype and contentLength; it may not
-- supply final metadata.size before INSERT RLS. Verify declared MIME is denied
-- when invalid, >5 MB bytes are rejected by the configured bucket limit, and
-- the post-upload metadata.size is checked by create/add-image RPC before attach.
-- 6. Donor lists own pending folder before any upload and after partial upload; retry sees
--    its existing photo and does not need UPDATE/upsert. Another donor, NGO, and hub admin
--    cannot list/read that folder. An empty folder listing returns no objects but succeeds.
-- 7. Donor reads own committed donation_images rows and gets signed URLs; unrelated donor denied.
-- 8. NGO unverified, outside the geofence, pre-claim, or with an expired lease cannot read
--    donation metadata or Storage objects. Verified eligible active claimant can read only the
--    claimed listing's constituent photos. Completed/reconciliation claim access follows the
--    existing helper. Test both public metadata SELECT and Storage signed-URL/object SELECT.
-- 9. Owning hub admin reads donation-image metadata/object for an active reservation and
--    stored inventory, plus its own batch photo. Unrelated hub admin is denied. NGO receives
--    batch image access only with a verified, eligible claim permitted by the existing helper.
-- 10. Unattached pending photo can be deleted by its donor; attached donation/batch photos cannot.
-- 11. Authenticated UPDATE/upsert and all anon operations on this bucket are denied; other
--     Storage buckets retain their existing policies.
-- 12. Retry same request UUID and unchanged payload returns the same donation; changed payload
--     with same UUID is rejected. Confirm one donation and 1-3 ordered metadata rows only.
-- 13. Batch image upload succeeds only for the owning hub admin and remains separate from
--     constituent donation_images metadata. NGO access to the batch object and metadata is
--     allowed only after the same verified eligible-claim condition; unrelated NGO is denied.
