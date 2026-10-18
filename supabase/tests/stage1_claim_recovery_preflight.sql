-- Read-only compatibility inventory for the proposed Stage 1 claim migration.
-- Run in the isolated development project before and after the migration.
-- Expected-new RPCs are reported as EXPECTED_BEFORE / PRESENT_AFTER, not as
-- baseline blockers. This file performs no writes.

select current_database() as database_name, current_user as current_role,
       session_user as session_role, version() as postgres_version;

select exists(select 1 from pg_extension where extname='pg_cron') as pg_cron_installed,
       to_regclass('cron.job') as cron_job_relation,
       to_regclass('cron.job_run_details') as cron_history_relation;

select exists(select 1 from pg_extension where extname='pg_cron') as pg_cron_installed,
       to_regclass('cron.job') as cron_job_relation,
       to_regclass('cron.job_run_details') as cron_history_relation;

select exists(select 1 from pg_extension where extname='pg_cron') as pg_cron_installed,
       to_regclass('cron.job') as cron_job_relation,
       to_regclass('cron.job_run_details') as cron_history_relation;

with expected(signature, expected_return, expected_security_definer) as (
  values
    ('public.recover_expired_claims(p_limit integer)','integer',true),
    ('public.start_pickup(p_claim uuid)','void',true),
    ('public.complete_pickup(p_claim uuid, p_handover_confirmed boolean)','void',true),
    ('public.assign_task_to_route(p_route uuid, p_task uuid, p_stop_order integer)','void',true),
    ('public.cancel_claim(p_claim uuid, p_request uuid)','jsonb',true),
    ('public.submit_claim_reconciliation(p_claim uuid, p_handover_confirmed boolean, p_request uuid)','jsonb',true),
    ('public.get_authorized_audit_events(p_entity_type text, p_entity_id uuid)','SETOF audit_events',true),
    ('public.get_my_reconciliation_cases()','TABLE(case_id uuid, claim_id uuid, listing_id uuid, donation_id uuid, source_type text, case_status text, opened_at timestamp with time zone)',true)
), actual as (
  select p.oid, n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' signature,
         pg_get_function_result(p.oid) return_type, p.prosecdef,
         p.proowner::regrole owner, p.proconfig,
         has_function_privilege('authenticated',p.oid,'EXECUTE') authenticated_execute,
         has_function_privilege('anon',p.oid,'EXECUTE') anon_execute,
         has_function_privilege('service_role',p.oid,'EXECUTE') service_execute,
         pg_get_functiondef(p.oid) definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' AND p.prokind IN ('f', 'p')
)
select e.signature,e.expected_return,
       coalesce(a.return_type,'(missing)') actual_return,
       case when a.oid is null and e.signature in (
           'public.cancel_claim(p_claim uuid, p_request uuid)',
           'public.submit_claim_reconciliation(p_claim uuid, p_handover_confirmed boolean, p_request uuid)',
           'public.get_authorized_audit_events(p_entity_type text, p_entity_id uuid)',
           'public.get_my_reconciliation_cases()') then 'EXPECTED_BEFORE_MIGRATION'
            when a.oid is null then 'BLOCKER_MISSING_BASE_FUNCTION'
            when a.return_type<>e.expected_return then 'BLOCKER_RETURN_MISMATCH'
            when a.prosecdef<>e.expected_security_definer then 'REVIEW_SECURITY_MODE'
            when a.owner::text<>'postgres' then 'REVIEW_OWNER'
            else 'PRESENT' end status,
       a.owner,a.proconfig,a.authenticated_execute,a.anon_execute,a.service_execute,
       a.definition
from expected e left join actual a using(signature)
order by e.signature;

-- Enumerate every current function that references route/task/lease state so
-- hidden route writers can be identified before the forward migration.
select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) arguments,
       p.proowner::regrole owner,p.prosecdef,p.proconfig,pg_get_functiondef(p.oid) definition
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' AND p.prokind IN ('f', 'p')
  and pg_get_functiondef(p.oid) ~* '(pickup_routes|pickup_route_stops|active_task_route_assignments|pickup_tasks|claim_leases)'
order by p.proname;

-- Required table columns, constraints, indexes, triggers, and DML grants.
select table_name,column_name,data_type,is_nullable,column_default
from information_schema.columns
where table_schema='public' and table_name in (
 'donation_claims','claim_leases','listings','pickup_tasks','pickup_routes',
 'pickup_route_stops','active_task_route_assignments','audit_events','donations',
 'hub_batch_members','hub_inventory','hub_batches')
order by table_name,ordinal_position;

select conrelid::regclass table_name,conname,contype,convalidated,pg_get_constraintdef(oid) definition
from pg_constraint
where connamespace='public'::regnamespace
  and conrelid::regclass::text in (
   'public.donation_claims','public.claim_leases','public.listings','public.pickup_tasks',
   'public.pickup_routes','public.pickup_route_stops','public.active_task_route_assignments',
   'public.audit_events','public.donations','public.hub_batch_members','public.hub_inventory')
order by 1,2;

select t.tgrelid::regclass table_name,t.tgname,pg_get_triggerdef(t.oid) definition,
       p.proname function_name,pg_get_functiondef(p.oid) function_definition
from pg_trigger t join pg_proc p on p.oid=t.tgfoid
where not t.tgisinternal and t.tgrelid::regclass::text like 'public.%'
  and t.tgrelid::regclass::text in (
    'public.donations','public.listings','public.donation_claims','public.claim_leases',
    'public.pickup_tasks','public.pickup_routes','public.pickup_route_stops',
    'public.active_task_route_assignments','public.hub_inventory','public.hub_batches')
order by 1,2;

select table_name,grantee,privilege_type,is_grantable
from information_schema.role_table_grants
where table_schema='public' and table_name in (
 'donation_claims','claim_leases','listings','pickup_tasks','pickup_routes',
 'pickup_route_stops','active_task_route_assignments','audit_events')
order by table_name,grantee,privilege_type;

-- Read-only data gates: duplicate active claim/lease and terminal DELIVERED rows.
select 'active_claims_per_listing' check_name,listing_id::text key,count(*) rows
from public.donation_claims where claim_status='ACTIVE' group by listing_id having count(*)>1
union all
select 'active_leases_per_claim',claim_id::text,count(*)
from public.claim_leases where lease_status='ACTIVE' group by claim_id having count(*)>1;
select count(*) as delivered_donations from public.donations where donation_status='DELIVERED';
