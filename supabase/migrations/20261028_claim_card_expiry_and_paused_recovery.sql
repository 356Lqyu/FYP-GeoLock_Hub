-- DEV preparation only: rcgyuwiidqvrgbxswhqj. Do not deploy without approval.
-- Requires the deployed 20261027 persisted lifecycle and pg_cron.
-- Run the complete file as postgres. The new worker is deliberately PAUSED.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

do $preflight$
begin
  if current_user <> 'postgres' or session_user <> 'postgres' then
    raise exception 'POSTGRES_SESSION_REQUIRED';
  end if;
  if not exists(select 1 from pg_catalog.pg_extension where extname='pg_cron') then
    raise exception 'PG_CRON_REQUIRED';
  end if;
  if exists(select 1 from pg_catalog.pg_proc
    where pronamespace='public'::regnamespace and proname='get_my_claim_cards_v2') then
    raise exception 'CLAIM_CARDS_V2_ALREADY_EXISTS_REVIEW_REQUIRED';
  end if;
  if not exists(select 1 from pg_catalog.pg_proc
    where oid=pg_catalog.to_regprocedure('public.get_my_claim_cards()')
      and proowner='postgres'::regrole and prosecdef
      and proconfig @> array['search_path=pg_catalog, public, pg_temp'])
    or not exists(select 1 from pg_catalog.pg_proc
    where oid=pg_catalog.to_regprocedure('public.recover_expired_claims(integer)')
      and proowner='postgres'::regrole and prosecdef
      and proconfig @> array['search_path=pg_catalog, public, extensions, pg_temp'])
    or pg_catalog.to_regprocedure('public.geolock_lock_listing_donations(uuid,text[])') is null
    or pg_catalog.to_regprocedure('public.geolock_transition_listing_donations(uuid,text,text)') is null then
    raise exception 'DEPLOYED_LIFECYCLE_FUNCTION_REVIEW_REQUIRED';
  end if;
  if pg_catalog.has_function_privilege('anon','public.recover_expired_claims(integer)','EXECUTE')
    or pg_catalog.has_function_privilege('authenticated','public.recover_expired_claims(integer)','EXECUTE') then
    raise exception 'RECOVERY_MUST_REMAIN_PROTECTED';
  end if;
  if not exists(select 1 from public.coordination_config
    where singleton and claim_lease_minutes=360) then
    raise exception 'CLAIM_LEASE_CONFIGURATION_REVIEW_REQUIRED';
  end if;
end;
$preflight$;

-- Preserve all 12 v1 columns, ordering, NGO ownership and photo authorization
-- by calling the existing reader. Never call a recovery/writer from this RPC.
-- Expiry fields describe the deadline even on historical rows; only the
-- ACTIVE/ACTIVE pair sets lease_recovery_pending. No persisted status changes.
create function public.get_my_claim_cards_v2()
returns table(
  claim_id uuid, listing_id uuid, claim_status text, claimed_at timestamptz,
  lease_id uuid, lease_status text, lease_expires_at timestamptz,
  task_status text, source_type text, listing_weight_kg numeric,
  title text, primary_image_path text,
  server_now timestamptz, lease_is_expired boolean, lease_recovery_pending boolean
)
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $claim_cards_v2$
declare
  v_now constant timestamptz := statement_timestamp();
begin
  if auth.uid() is null or not exists(select 1 from public.ngo_profiles n
    where n.user_id=auth.uid() and n.active_flag) then
    raise exception 'ACTIVE_NGO_ONLY';
  end if;
  return query
  select c.claim_id,c.listing_id,c.claim_status,c.claimed_at,
    c.lease_id,c.lease_status,c.lease_expires_at,c.task_status,
    c.source_type,c.listing_weight_kg,c.title,c.primary_image_path,
    v_now,
    c.lease_expires_at <= v_now,
    coalesce(c.claim_status='ACTIVE' and c.lease_status='ACTIVE'
      and c.lease_expires_at <= v_now,false)
  from public.get_my_claim_cards() c
  order by c.claimed_at desc;
end;
$claim_cards_v2$;

alter function public.get_my_claim_cards_v2() owner to postgres;
revoke all on function public.get_my_claim_cards_v2() from public,anon,authenticated,service_role;
grant execute on function public.get_my_claim_cards_v2() to authenticated,service_role;

-- Reject unexpected default-privilege recipients rather than widening access.
do $rpc_acl$
begin
  if exists(select 1 from pg_catalog.pg_proc p,
    lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a
    where p.oid='public.get_my_claim_cards_v2()'::regprocedure
      and (a.grantee not in ('postgres'::regrole,'authenticated'::regrole,'service_role'::regrole)
        or a.is_grantable)) then
    raise exception 'CLAIM_CARDS_V2_UNEXPECTED_EXECUTE_ACL';
  end if;
end;
$rpc_acl$;

-- cron.schedule runs in this database as its invoking postgres session role.
-- This satisfies recovery's session_user guard; no client recovery grants.
-- The existing algorithm owns all locking, lifecycle transitions and auditing.
-- 100 claims/run; one-minute cadence; bounded waits/work; no exception swallowing.
-- Creating then pausing in ONE transaction prevents a committed active window.
do $recovery_cron$
declare
  v_job record;
  v_job_id bigint;
  v_name constant text := 'geolock-expired-claim-recovery';
  v_schedule constant text := '* * * * *';
  v_command constant text := 'set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(100);';
begin
  -- Also catch differently named direct schedules for the same worker.
  if exists(select 1 from cron.job j
    where j.command ~* '\mrecover_expired_claims\M'
      and j.jobname is distinct from v_name) then
    raise exception 'OTHER_CLAIM_RECOVERY_JOB_REVIEW_REQUIRED';
  end if;
  if (select count(*) from cron.job j where j.jobname=v_name)>1 then
    raise exception 'DUPLICATE_CLAIM_RECOVERY_JOBS';
  end if;
  select j.* into v_job from cron.job j where j.jobname=v_name;
  if found then
    if v_job.schedule is distinct from v_schedule or v_job.command is distinct from v_command
      or v_job.username is distinct from 'postgres'
      or v_job.database is distinct from current_database()
      or v_job.active is distinct from false then
      raise exception 'EXISTING_CLAIM_RECOVERY_JOB_MISMATCH';
    end if;
    -- An exact, paused job is reusable; never reactivate or rewrite it.
  else
    v_job_id := cron.schedule(v_name,v_schedule,v_command);
    perform cron.alter_job(v_job_id,active := false);
  end if;
  if (select count(*) from cron.job j where j.jobname=v_name
    and j.schedule=v_schedule and j.command=v_command and j.username='postgres'
    and j.database=current_database() and not j.active)<>1 then
    raise exception 'CLAIM_RECOVERY_JOB_POSTCONDITION_FAILED';
  end if;
end;
$recovery_cron$;

notify pgrst, 'reload schema';
commit;
