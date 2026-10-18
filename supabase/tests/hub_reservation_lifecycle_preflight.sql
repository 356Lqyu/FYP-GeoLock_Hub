-- READ ONLY metadata and invariant checks. Run on the isolated development
-- project before reviewing/applying the scoped migration. No DDL/DML/RPC calls.

-- Exact deployed identities, return contracts, owners, security, settings and
-- role grants for every replaced/relied-on RPC. Compare with the expected list
-- in the accompanying review notes; any missing, duplicate, or mismatched row
-- blocks migration.
with expected(proname,identity_args,argument_names,result_type,security_definer,search_path,
              auth_exec,service_exec) as (
 values
 ('cancel_donation','uuid, uuid','{p_donation,p_request}','jsonb',true,'pg_catalog, public, pg_temp',true,false),
 ('reserve_hub_capacity','uuid, uuid','{p_donation,p_hub}','uuid',true,'public, extensions, pg_temp',true,false),
 ('confirm_hub_receipt','uuid, numeric','{p_reservation,p_received_weight}','uuid',true,'public, extensions, pg_temp',true,false),
 ('publish_whole_donation_batch','uuid, uuid[]','{p_hub,p_donation_ids}','uuid',true,'public, extensions, pg_temp',true,false),
 ('get_eligible_hubs','uuid','{p_donation}','TABLE(hub_id uuid, hub_name text, address_text text, latitude double precision, longitude double precision, capacity_kg numeric, available_capacity_kg numeric)',true,'pg_catalog, public, pg_temp',true,false),
 ('get_my_hub_reservations','uuid','{p_hub}','TABLE(reservation_id uuid, donation_id uuid, title text, reserved_weight_kg numeric, status text, expires_at timestamp with time zone)',true,'pg_catalog, public, pg_temp',true,false),
 ('get_my_donation_detail','uuid','{p_donation}','jsonb',true,'pg_catalog, public, pg_temp',true,false),
 ('get_my_donation_dashboard_v2','','{}','TABLE(donation_id uuid, title text, donation_status text, collection_path text, total_weight_kg numeric, created_at timestamp with time zone, hub_name text, reservation_status text, reservation_effective_status text, reservation_expires_at timestamp with time zone, listing_status text, receipt_status text, inventory_status text, item_count bigint, primary_image_path text)',true,'pg_catalog, public, pg_temp',true,false),
 ('get_hub_dashboard','uuid','{p_hub}','jsonb',true,'pg_catalog, public, pg_temp',true,false),
 ('claim_listing','uuid, uuid','{p_listing,p_request}','jsonb',true,'public, extensions, pg_temp',true,false),
 ('start_pickup','uuid','{p_claim}','void',true,'public, extensions, pg_temp',true,false),
 ('complete_pickup','uuid, boolean','{p_claim,p_handover_confirmed}','void',true,'public, extensions, pg_temp',true,false),
 ('recover_expired_claims','integer','{p_limit}','integer',true,'public, extensions, pg_temp',false,true)
), actual as (
 select p.proname,p.oid function_oid,p.oid::regprocedure identity,p.proargnames,p.proargmodes,
        p.pronargs::integer input_arg_count,pg_get_function_result(p.oid) result_type,
        p.prosecdef security_definer,
        (select split_part(x,'=',2) from unnest(p.proconfig) x where x like 'search_path=%') search_path,
        p.proowner::regrole owner,
        has_function_privilege('authenticated',p.oid,'EXECUTE') authenticated_exec,
        has_function_privilege('service_role',p.oid,'EXECUTE') service_role_exec,
        has_function_privilege('anon',p.oid,'EXECUTE') anon_exec,
        exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
               where a.grantee=0 and a.privilege_type='EXECUTE') public_exec
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public'
)
select e.*,a.identity,a.proargnames,a.proargmodes,a.input_arg_count,a.result_type,
       a.security_definer,a.search_path,a.owner,a.authenticated_exec,a.service_role_exec,
       a.anon_exec,a.public_exec,
       case when a.identity is null and e.proname='get_my_donation_dashboard_v2'
              and not exists(select 1 from actual x where x.proname=e.proname)
              then 'EXPECTED_NEW_FUNCTION_ABSENT'
            when a.identity is null then 'MISSING_OR_IDENTITY_MISMATCH'
            when replace(a.result_type,' ','')<>replace(e.result_type,' ','') then 'RESULT_MISMATCH'
            when a.security_definer<>e.security_definer then 'SECURITY_MISMATCH'
            when a.owner::text<>'postgres' then 'OWNER_MISMATCH'
            when e.search_path is not null and a.search_path<>e.search_path then 'SEARCH_PATH_MISMATCH'
            when a.authenticated_exec<>e.auth_exec or a.service_role_exec<>e.service_exec
              or a.anon_exec or a.public_exec then 'GRANT_MISMATCH'
            when a.proargnames[1:a.input_arg_count]::text[]<>e.argument_names::text[]
              then 'ARGUMENT_NAME_MISMATCH'
            else 'PASS' end readiness
from expected e left join actual a on a.proname=e.proname
 and pg_get_function_identity_arguments(a.function_oid)=e.identity_args
order by e.proname;

-- An absent dashboard_v2 is expected before the migration. A same-name
-- incompatible overload is a blocker, as are unexpected overloads for existing RPCs.
select p.oid::regprocedure unexpected_or_additional_overload,
       pg_get_function_result(p.oid) result_type,p.prosecdef,p.proconfig
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in (
 'cancel_donation','reserve_hub_capacity','confirm_hub_receipt',
 'publish_whole_donation_batch','get_eligible_hubs','get_my_hub_reservations',
 'get_my_donation_detail','get_my_donation_dashboard_v2')
and p.oid::regprocedure::text not in (
 'cancel_donation(uuid,uuid)','reserve_hub_capacity(uuid,uuid)',
 'confirm_hub_receipt(uuid,numeric)','publish_whole_donation_batch(uuid,uuid[])',
 'get_eligible_hubs(uuid)','get_my_hub_reservations(uuid)',
 'get_my_donation_detail(uuid)','get_my_donation_dashboard_v2()')
order by p.proname;

-- Exact required columns and types (missing rows block). This checks database
-- reality rather than relying on the supplied inventory snapshot.
with expected(table_name,column_name,type_name) as (values
 ('donations','donation_id','uuid'),('donations','donor_user_id','uuid'),
 ('donations','collection_path','text'),('donations','donation_status','text'),
 ('donations','total_weight_kg','numeric'),('donations','title','text'),
 ('donations','created_at','timestamp with time zone'),('donations','updated_at','timestamp with time zone'),
 ('donations','description','text'),('donations','pickup_address','text'),
 ('donations','latitude','double precision'),('donations','longitude','double precision'),
 ('donations','availability_start','timestamp with time zone'),
 ('donations','availability_end','timestamp with time zone'),
 ('donations','pickup_road_node_id','text'),
 ('listings','listing_id','uuid'),
 ('listings','donation_id','uuid'),('listings','source_type','text'),
 ('listings','listing_status','text'),('listings','listing_version','bigint'),
 ('listings','listing_expires_at','timestamp with time zone'),
 ('listings','pickup_road_node_id','text'),('listings','batch_id','uuid'),
 ('hub_reservations','reservation_id','uuid'),('hub_reservations','donation_id','uuid'),
 ('hub_reservations','hub_id','uuid'),('hub_reservations','reservation_status','text'),
 ('hub_reservations','reserved_weight_kg','numeric'),('hub_reservations','reserved_at','timestamp with time zone'),
 ('hub_reservations','expires_at','timestamp with time zone'),
 ('community_hubs','hub_id','uuid'),('community_hubs','admin_user_id','uuid'),
 ('community_hubs','active_flag','boolean'),('community_hubs','capacity_kg','numeric'),
 ('community_hubs','hub_name','text'),('community_hubs','address_text','text'),
 ('community_hubs','latitude','double precision'),('community_hubs','longitude','double precision'),
 ('hub_receipts','receipt_id','uuid'),('hub_receipts','reservation_id','uuid'),
 ('hub_receipts','donation_id','uuid'),('hub_receipts','hub_id','uuid'),
 ('hub_receipts','received_weight_kg','numeric'),('hub_receipts','receipt_status','text'),
 ('hub_receipts','received_at','timestamp with time zone'),
 ('hub_inventory','donation_id','uuid'),
 ('hub_inventory','hub_id','uuid'),('hub_inventory','inventory_status','text'),
 ('hub_batch_members','donation_id','uuid'),('hub_batch_members','membership_status','text'),
 ('donation_items','donation_id','uuid'),('donation_items','category_id','uuid'),
 ('donation_items','created_at','timestamp with time zone'),
 ('donation_categories','category_id','uuid'),('donation_categories','category_name','text'),
 ('donation_categories','active_flag','boolean'),
 ('hub_accepted_categories','hub_id','uuid'),('hub_accepted_categories','category_id','uuid'),
 ('donation_items','item_id','uuid'),('donation_items','item_name','text'),
 ('donation_items','description','text'),('donation_items','quantity','integer'),
 ('donation_items','unit_label','text'),('donation_items','unit_weight_kg','numeric'),
 ('donation_items','item_condition','text'),
 ('donation_images','donation_id','uuid'),('donation_images','owner_user_id','uuid'),
 ('donation_images','storage_path','text'),('donation_images','is_primary','boolean'),
 ('user_profiles','user_id','uuid'),('user_profiles','role','text'),
 ('donor_profiles','user_id','uuid'),
 ('pickup_tasks','claim_id','uuid'),('pickup_tasks','task_status','text'),
 ('donation_claims','claim_id','uuid'),('donation_claims','listing_id','uuid'),
 ('donation_claims','claim_status','text'),
 ('claim_leases','claim_id','uuid'),('claim_leases','lease_status','text'),
 ('hub_batches','batch_id','uuid'),('hub_batches','hub_id','uuid'),
 ('hub_batches','batch_category_id','uuid'),('hub_batches','batch_weight_kg','numeric'),
 ('hub_batches','batch_donation_count','integer'),('hub_batches','created_by','uuid'),
 ('hub_batches','batch_status','text'),('hub_batches','published_at','timestamp with time zone'),
 ('hub_batch_members','batch_id','uuid'),('community_hubs','road_node_id','text'),
 ('donation_cancellation_requests','request_id','uuid'),
 ('donation_cancellation_requests','donor_user_id','uuid'),
 ('donation_cancellation_requests','donation_id','uuid'),
 ('donation_cancellation_requests','request_fingerprint','text'),
 ('donation_cancellation_requests','response','jsonb'),
 ('donation_cancellation_requests','completed_at','timestamp with time zone'),
 ('audit_events','actor_user_id','uuid'),('audit_events','entity_type','text'),
 ('audit_events','entity_id','uuid'),('audit_events','event_type','text'),
 ('audit_events','actor_role','text'),('audit_events','request_id','uuid'),
 ('audit_events','correlation_id','uuid'),('audit_events','previous_state','text'),
 ('audit_events','requested_state','text'),('audit_events','resulting_state','text'),
 ('audit_events','reason_code','text'),('audit_events','outcome','text'),
 ('audit_events','details','jsonb'),('audit_events','occurred_at','timestamp with time zone'),
 ('audit_events','configuration_version','text'),
 ('coordination_config','singleton','boolean'),
 ('coordination_config','hub_reservation_minutes','integer'),
 ('coordination_config','batch_min_donations','integer'),
 ('coordination_config','batch_max_donations','integer'),
 ('coordination_config','batch_max_weight_kg','numeric'),
 ('coordination_config','config_version','text')
)
select e.*,format_type(a.atttypid,a.atttypmod) actual_type,a.attnotnull
from expected e left join pg_namespace n on n.nspname='public'
left join pg_class t on t.relnamespace=n.oid and t.relname=e.table_name
left join pg_attribute a on a.attrelid=t.oid and a.attname=e.column_name and a.attnum>0 and not a.attisdropped
where a.attname is null or format_type(a.atttypid,a.atttypmod)<>e.type_name
order by e.table_name,e.column_name;

-- Defaults/nullability used by inserts that intentionally omit columns in the
-- RPC bodies, including the intentional NULL listing expiry.
select c.table_name,c.column_name,c.column_default,c.is_nullable
from information_schema.columns c
where c.table_schema='public' and (c.table_name,c.column_name) in (
 ('hub_reservations','reservation_id'),('hub_reservations','reservation_status'),
 ('hub_reservations','reserved_at'),('hub_receipts','receipt_id'),
 ('hub_receipts','receipt_status'),('hub_receipts','received_at'),
 ('hub_inventory','inventory_status'),('hub_inventory','recorded_at'),
 ('hub_batches','batch_id'),('hub_batches','batch_status'),
 ('hub_batches','batch_weight_kg'),('hub_batches','batch_donation_count'),
 ('hub_batch_members','membership_status'),('listings','listing_id'),
 ('listings','listing_status'),('listings','listing_version'),
 ('listings','listing_expires_at'))
order by c.table_name,c.column_name;

-- All constraints and indexes involved in uniqueness, FK consistency, status,
-- capacity, append-only audit and cancellation idempotency.
select c.conrelid::regclass table_name,c.conname,c.contype,c.convalidated,
       pg_get_constraintdef(c.oid) definition
from pg_constraint c where c.conrelid in (
 'public.donation_cancellation_requests'::regclass,'public.hub_reservations'::regclass,
 'public.hub_receipts'::regclass,'public.hub_inventory'::regclass,
 'public.donations'::regclass,'public.listings'::regclass,'public.audit_events'::regclass)
order by 1,2;
select i.indrelid::regclass table_name,i.indexrelid::regclass index_name,
       i.indisunique,i.indisvalid,i.indisready,pg_get_indexdef(i.indexrelid) definition
from pg_index i where i.indrelid in (
 'public.donation_cancellation_requests'::regclass,'public.hub_reservations'::regclass,
 'public.hub_receipts'::regclass,'public.hub_inventory'::regclass,
 'public.listings'::regclass)
order by 1,2;
select 'BLOCKER: ux_active_reservation missing, invalid, not ready, or definition changed' blocker
where not exists(select 1 from pg_index i
 join pg_class idx on idx.oid=i.indexrelid
 where idx.oid=to_regclass('public.ux_active_reservation')
   and i.indrelid='public.hub_reservations'::regclass and i.indisunique
   and i.indisvalid and i.indisready and i.indpred is not null
   and i.indnkeyatts=1 and i.indnatts=1
   and i.indkey[0]=(select attnum from pg_attribute
       where attrelid='public.hub_reservations'::regclass and attname='donation_id')
   and pg_get_expr(i.indpred,i.indrelid) ilike '%reservation_status%ACTIVE%');

-- Cancellation request ID must remain globally unique and response shape valid.
select 'BLOCKER: cancellation request idempotency constraints missing/invalid' blocker
where not exists(select 1 from pg_constraint c
 where c.conrelid='public.donation_cancellation_requests'::regclass
   and c.contype in ('p','u') and c.convalidated
   and pg_get_constraintdef(c.oid) ilike '%(request_id)%')
 or not exists(select 1 from pg_constraint c
 where c.conrelid='public.donation_cancellation_requests'::regclass
   and c.contype='c' and c.convalidated
   and pg_get_constraintdef(c.oid) ilike '%jsonb_typeof(response)%');

-- RLS, policies and client table privileges on all protected operational rows.
select r.rolname,
       has_schema_privilege(r.rolname,'public','CREATE') public_create,
       has_schema_privilege(r.rolname,'extensions','CREATE') extensions_create
from pg_roles r where r.rolname in ('anon','authenticated','service_role')
order by r.rolname;
select c.oid::regclass table_name,c.relrowsecurity rls_enabled,c.relforcerowsecurity force_rls,
       has_table_privilege('authenticated',c.oid,'INSERT') auth_insert,
       has_table_privilege('authenticated',c.oid,'UPDATE') auth_update,
       has_table_privilege('anon',c.oid,'INSERT') anon_insert,
       has_table_privilege('anon',c.oid,'UPDATE') anon_update
from pg_class c where c.oid in (
 'public.donations'::regclass,'public.listings'::regclass,'public.hub_reservations'::regclass,
 'public.hub_receipts'::regclass,'public.hub_inventory'::regclass,
 'public.donation_cancellation_requests'::regclass,'public.audit_events'::regclass)
order by 1;
select schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check
from pg_policies where schemaname='public' and tablename in (
 'donations','listings','hub_reservations','hub_receipts','hub_inventory',
 'donation_cancellation_requests','audit_events') order by tablename,policyname;

-- Trigger definitions on every table these writers update, to reveal hidden
-- lock-taking or state-mutating triggers (including internal FK triggers).
select t.tgrelid::regclass table_name,t.tgname,t.tgisinternal,
       pg_get_triggerdef(t.oid) trigger_def,t.tgfoid::regprocedure trigger_function_identity,
       case when t.tgisinternal then null else pg_get_functiondef(t.tgfoid) end trigger_function
from pg_trigger t where t.tgrelid in (
 'public.donations'::regclass,'public.listings'::regclass,
 'public.hub_reservations'::regclass,'public.hub_receipts'::regclass,
 'public.hub_inventory'::regclass,'public.hub_batch_members'::regclass,
 'public.audit_events'::regclass) order by 1,2;

-- Read full bodies and privilege/config metadata for relevant deployed writers.
-- Inspect for lock order changes since the inventory; do not rely on names alone.
select p.oid::regprocedure identity,p.prosecdef,p.proconfig,p.proowner::regrole owner,
       has_function_privilege('authenticated',p.oid,'EXECUTE') authenticated_exec,
       has_function_privilege('anon',p.oid,'EXECUTE') anon_exec,
       pg_get_functiondef(p.oid) definition
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in (
 'cancel_donation','reserve_hub_capacity','confirm_hub_receipt',
 'publish_whole_donation_batch','start_pickup','complete_pickup',
 'claim_listing','recover_expired_claims','get_hub_dashboard') order by p.proname;

-- Data blockers: no automatic correction or reconciliation is performed.
select donation_id,count(*) active_count,array_agg(reservation_id order by reserved_at,reservation_id) ids
from public.hub_reservations where reservation_status='ACTIVE'
group by donation_id having count(*)>1;
select d.donation_id,d.collection_path,d.donation_status,
       (select count(*) from public.hub_reservations r where r.donation_id=d.donation_id) reservation_count,
       (select count(*) from public.hub_reservations r where r.donation_id=d.donation_id
         and r.reservation_status='ACTIVE') active_count,
       exists(select 1 from public.hub_reservations r where r.donation_id=d.donation_id
         and r.reservation_status in ('RELEASED','CONSUMED')) has_terminal_inconsistent_history,
       exists(select 1 from public.hub_reservations r where r.donation_id=d.donation_id
         and r.reservation_status='EXPIRED' and r.expires_at>statement_timestamp()) has_future_expired,
       exists(select 1 from public.hub_receipts hr where hr.donation_id=d.donation_id) has_receipt,
       exists(select 1 from public.hub_inventory hi where hi.donation_id=d.donation_id) has_inventory
from public.donations d where d.donation_status='HUB_ASSIGNED'
and (not exists(select 1 from public.hub_reservations r where r.donation_id=d.donation_id)
 or (select count(*) from public.hub_reservations r where r.donation_id=d.donation_id
     and r.reservation_status='ACTIVE')>1
 or exists(select 1 from public.hub_reservations r where r.donation_id=d.donation_id
     and r.reservation_status in ('RELEASED','CONSUMED'))
 or exists(select 1 from public.hub_reservations r where r.donation_id=d.donation_id
     and r.reservation_status='EXPIRED' and r.expires_at>statement_timestamp())
 or exists(select 1 from public.hub_receipts hr where hr.donation_id=d.donation_id)
 or exists(select 1 from public.hub_inventory hi where hi.donation_id=d.donation_id));
select r.donation_id,r.reservation_id,r.hub_id,r.expires_at
from public.hub_reservations r join public.donations d using(donation_id)
where r.reservation_status='ACTIVE' and r.expires_at<=statement_timestamp()
order by r.expires_at;

