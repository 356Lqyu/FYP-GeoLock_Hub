"""Permission-compatible Stage 3I proposal; filesystem only, never executes SQL.

Retains public-table fences. Locks precede the repeatable-read snapshot; the
supported cron API obtains the job-3 row lock and concurrent changes serialize
or abort. Advisory locking is cooperative, never a global cron-table fence.
"""
import argparse
import hashlib
import json
from pathlib import Path
import claim_recovery_live_activation_package as previous

BASE=previous.BASE
TOKEN='8b4a48ed-97e4-41a9-aa1f-b588ae850b4f'
KEY=(1936288105,3)
MARKED_COMMAND=BASE.COMMAND+' -- STAGE3I_ONE_USE_'+TOKEN
PERMISSIONS="""-- SELECT ONLY. DEV rcgyuwiidqvrgbxswhqj only.
SELECT statement_timestamp() AS checked_at,
 (SELECT jsonb_build_object('version',extversion,'owner',pg_get_userbyid(extowner))
   FROM pg_extension WHERE extname='pg_cron') AS pg_cron,
 (SELECT jsonb_build_object('superuser',rolsuper,'bypassrls',rolbypassrls,'inherit',rolinherit)
   FROM pg_roles WHERE rolname='postgres') AS postgres_role,
 (SELECT jsonb_build_object('owner',pg_get_userbyid(relowner),'acl',relacl::text,
   'rls',relrowsecurity) FROM pg_class WHERE oid='cron.job'::regclass) AS cron_relation,
 jsonb_build_object('SELECT',has_table_privilege('postgres','cron.job','SELECT'),
   'UPDATE',has_table_privilege('postgres','cron.job','UPDATE'),
   'DELETE',has_table_privilege('postgres','cron.job','DELETE'),
   'TRUNCATE',has_table_privilege('postgres','cron.job','TRUNCATE'),
   'MAINTAIN',has_table_privilege('postgres','cron.job','MAINTAIN'),
   'advisory_execute',has_function_privilege('postgres',
      'pg_catalog.pg_try_advisory_xact_lock(integer,integer)','EXECUTE')) AS privileges,
 (SELECT jsonb_build_object('owner',pg_get_userbyid(p.proowner),'security_definer',p.prosecdef,
   'acl',p.proacl::text,'language',l.lanname,
   'postgres_execute',has_function_privilege('postgres',p.oid,'EXECUTE'))
   FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang
   WHERE p.oid='cron.alter_job(bigint,text,text,text,text,boolean)'::regprocedure) AS supported_api;
"""
SCHEDULE_MONITOR="""
-- Advisory locking does NOT fence nonparticipants or extra schedules. Review ALL.
SELECT statement_timestamp() AS checked_at,count(*) AS recovery_schedule_count,
 coalesce(jsonb_agg(to_jsonb(j) ORDER BY jobid),'[]'::jsonb) AS recovery_schedules
FROM cron.job j WHERE command ~* '\\mrecover_expired_claims\\M';
"""


def activation_template():
    sql=previous.activation_template().replace(previous.TOKEN,TOKEN)
    sql=sql.replace('BEGIN ISOLATION LEVEL READ COMMITTED;',
                    'BEGIN ISOLATION LEVEL REPEATABLE READ;',1)
    sql=sql.replace("current_setting('transaction_isolation')<>'read committed'",
                    "current_setting('transaction_isolation')<>'repeatable read'",1)
    locks='LOCK TABLE '+','.join('public.'+x for x in previous.TABLES)+' IN EXCLUSIVE MODE NOWAIT;'
    if sql.count(locks)!=1:
        raise ValueError('Reviewed public-lock fence drift')
    sql=sql.replace(' '+locks,' -- Public locks already held, before the transaction snapshot.',1)
    # PostgreSQL LOCK before the first SELECT/DML is essential with repeatable read.
    sql=sql.replace("SET LOCAL TimeZone='UTC';",
      "SET LOCAL TimeZone='UTC';\n"
      '-- Acquire business locks BEFORE DO/SELECT establishes the transaction snapshot.\n'
      '-- Review-only copies may momentarily lock, but never call cron before approval.\n'+locks,1)
    unsupported=""" -- Freeze cron configuration too: no competing activation or extra schedule.
 LOCK TABLE cron.job IN SHARE ROW EXCLUSIVE MODE NOWAIT;"""
    cooperative=""" -- Participating activation/admin wrappers only; arbitrary admin is NOT fenced.
 IF NOT pg_catalog.pg_try_advisory_xact_lock(1936288105,3) THEN
   RAISE EXCEPTION 'RECOVERY_ACTIVATION_PROTOCOL_BUSY'; END IF;
 IF (SELECT rolsuper FROM pg_roles WHERE rolname=current_user)
   OR NOT has_table_privilege(current_user,'cron.job','SELECT')
   OR NOT has_function_privilege(current_user,
     'cron.alter_job(bigint,text,text,text,text,boolean)','EXECUTE') THEN
   RAISE EXCEPTION 'EXPECTED_MANAGED_POSTGRES_PERMISSIONS_REQUIRED'; END IF;"""
    if sql.count(unsupported)!=1:
        raise ValueError('Unsupported cron lock location drift')
    sql=sql.replace(unsupported,cooperative,1)
    sql=sql.replace('v_worker_command constant text',
                    'v_job3_before jsonb; v_worker_command constant text',1)
    acquire=""" -- Supported no-op API UPDATE locks only job 3; never jobs 1/2.
 -- Under REPEATABLE READ, a job-3 change since this snapshot raises 40001.
 -- No temporary inactive state is published: both calls commit atomically.
 SELECT to_jsonb(cj) INTO v_job3_before FROM cron.job cj WHERE jobid=3;
 PERFORM cron.alter_job(3,active := false);
 IF v_job3_before IS DISTINCT FROM (SELECT to_jsonb(cj) FROM cron.job cj WHERE jobid=3)
   OR NOT EXISTS(SELECT 1 FROM cron.job cj WHERE jobid=3
      AND cj.xmin::text=(mod(pg_current_xact_id()::text::numeric,4294967296))::text)
   OR NOT EXISTS(SELECT 1 FROM pg_locks WHERE pid=pg_backend_pid()
      AND relation='cron.job'::regclass AND mode='RowExclusiveLock' AND granted) THEN
   RAISE EXCEPTION 'SUPPORTED_JOB3_ROW_LOCK_NOT_CONFIRMED'; END IF;
"""
    anchor=' v_activation_at:=clock_timestamp();'
    if sql.count(anchor)!=1:
        raise ValueError('Activation timestamp location drift')
    sql=sql.replace(anchor,acquire+anchor,1)
    return ('-- PERMISSION-COMPATIBLE REVIEW ONLY. Execution approval remains FALSE.\n'
      '-- No cron table/row LOCK statement; supported API row lock plus cooperative advisory lock.\n'+sql)


def artifacts(manifest):
    files=previous.artifacts(manifest)
    files['03_activate.sql']=BASE.render(activation_template(),manifest)
    files['02c_permissions.sql']=PERMISSIONS
    files['07_schedule_monitor.sql']=SCHEDULE_MONITOR
    # One SELECT result avoids SQL Editor hiding target evidence behind a later
    # result set. Keep the same original target/audit/queue/history evidence.
    first=files['04_monitor.sql'].split('FROM evidence;',1)[0]
    files['04_monitor.sql']=first+""",
 (SELECT count(*) FROM cron.job WHERE command ~* '\\mrecover_expired_claims\\M') AS recovery_schedule_count,
 (SELECT jsonb_agg(to_jsonb(cj) ORDER BY jobid) FROM cron.job cj
    WHERE command ~* '\\mrecover_expired_claims\\M') AS all_recovery_schedules,
 (SELECT jsonb_agg(jsonb_build_object('pid',pid,'role',usename,'state',state,
    'wait_event',wait_event,'blockers',pg_blocking_pids(pid))) FROM pg_stat_activity
    WHERE pid<>pg_backend_pid() AND xact_start IS NOT NULL
      AND backend_type='client backend') AS active_transactions,
 (SELECT jsonb_agg(to_jsonb(x) ORDER BY jobid) FROM
    (SELECT DISTINCT ON(jobid) jobid,status,start_time,end_time,return_message
     FROM cron.job_run_details WHERE jobid IN(1,2) ORDER BY jobid,runid DESC)x) AS eligibility_health
FROM evidence;
"""
    original='EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND NOT active) AS recovery_paused,'
    checked="EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND NOT active AND command='"+MARKED_COMMAND.replace("'","''")+"') AND (SELECT count(*) FROM cron.job WHERE command ~* '\\mrecover_expired_claims\\M')=1 AND (SELECT count(*) FROM cron.job WHERE jobid IN(1,2) AND active)=2 AS recovery_paused,"
    if files['05_verify.sql'].count(original)!=1:
        raise ValueError('Original verification pause predicate drift')
    files['05_verify.sql']=files['05_verify.sql'].replace(original,checked,1)
    return files


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,required=True)
    args=parser.parse_args()
    manifest=json.loads(args.manifest.read_text(encoding='utf-8'))
    if manifest.get('execution_approved') is not False:
        parser.error('This preparation CLI only renders execution_approved=false review copies')
    args.output_dir.mkdir(parents=True,exist_ok=False)
    sums=[]
    for name,sql in artifacts(manifest).items():
        data=sql.encode()
        (args.output_dir/name).write_bytes(data)
        sums.append(hashlib.sha256(data).hexdigest().upper()+'  '+name)
    (args.output_dir/'SHA256SUMS.txt').write_text('\n'.join(sums)+'\n',encoding='utf-8',newline='\n')
