"""Validate ONLY the current activation/monitor/pause wrappers, loopback PG only.

No scheduler is installed. No recovery is invoked. Business tables stay empty.
Models managed postgres with SELECT-only cron.job and owner-privileged API double.
"""
from pathlib import Path
import argparse
import json
import os
import socket
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor

import psycopg
import claim_card_expiry_isolated_test as runtime

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT/'supabase/tests/review-only/supervised_recovery_current'
REVIEW = (DEST/'01_activate_REVIEW_ONLY.sql').read_text(encoding='utf-8')
CONFIRM = 'I_CONFIRM_DEV_rcgyuwiidqvrgbxswhqj_SUPERVISE_AND_PAUSE_WITHIN_300_SECONDS'
APPROVED = REVIEW.replace("v_confirmation constant text := 'NOT_APPROVED';",
                          f"v_confirmation constant text := '{CONFIRM}';")
PAUSE = (ROOT/'supabase/tests/review-only/stage3i/phase2_permission_compatible_execution_approved_20261023/06_pause.sql').read_text(encoding='utf-8')
CATALOG = json.loads((ROOT/'supabase/tests/review-only/stage3j/function_catalog.json').read_text(encoding='utf-8'))
RECOVERY = next(f['definition'] for f in CATALOG['functions'] if f['identity']=='recover_expired_claims(integer)')
COMMAND = "set lock_timeout = '5s'; set statement_timeout = '50s'; select public.recover_expired_claims(1);"
MARKED = COMMAND+' -- STAGE3I_ONE_USE_8b4a48ed-97e4-41a9-aa1f-b588ae850b4f'
PUBLIC = ['donation_claims','claim_leases','listings','pickup_tasks','donations','hub_batches',
          'hub_batch_members','hub_inventory','active_task_route_assignments','pickup_route_stops',
          'claim_reconciliation_cases','hub_reservations','hub_receipts','coordination_config',
          'audit_events','listing_eligibility_refresh_jobs']


class ActivationTests(unittest.TestCase):
    run_process = runtime.IsolatedClaimCardTests.__dict__['run_process']
    cleanup_cluster = runtime.IsolatedClaimCardTests.__dict__['cleanup_cluster']

    @classmethod
    def query_as(cls, role, query, error=None):
        args=[cls.bins['psql'],'-X','--no-password','-h','127.0.0.1','-p',str(cls.port),
              '-U',role,'-d','postgres','-v','ON_ERROR_STOP=1','-Atq','-f','-']
        try:
            value=cls.run_process(args,input=query)
        except RuntimeError as exc:
            if error and error in str(exc):
                return str(exc)
            raise
        if error:
            raise AssertionError('Expected rejection: '+error)
        return value

    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory(prefix='geolock-wrapper-only-')
        cls.folder=Path(cls.tmp.name);cls.data=cls.folder/'data'
        cls.env={k:v for k,v in os.environ.items() if not k.upper().startswith('PG')}
        cls.env.update(PGCONNECT_TIMEOUT='3',PGPASSFILE=str(cls.folder/'no-password'))
        cls.flags=getattr(__import__('subprocess'),'CREATE_NO_WINDOW',0) if os.name=='nt' else 0
        cls.addClassCleanup(cls.cleanup_cluster)
        cls.run_process([cls.bins['initdb'],'-D',str(cls.data),'-U','fixture_admin','-A','trust','--no-locale','--encoding=UTF8'])
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));cls.port=sock.getsockname()[1]
        cls.run_process([cls.bins['pg_ctl'],'-D',str(cls.data),'-l',str(cls.folder/'server.log'),
                         '-w','-t','20','-o',f'-h 127.0.0.1 -p {cls.port}','start'])
        cls.query_as('fixture_admin',"""
          create role postgres login nosuperuser bypassrls inherit createrole createdb;
          create role supabase_admin nologin superuser;
          create role service_role; create role anon;
          alter database postgres owner to postgres;
          create schema auth authorization postgres;
          create schema extensions authorization postgres;
          create function auth.uid() returns uuid language sql as $$select null::uuid$$;
          create function auth.role() returns text language sql as $$select null::text$$;
          create table public.donation_claims(claim_id uuid,listing_id uuid,claim_status text,close_reason text);
          create table public.claim_leases(lease_id uuid,claim_id uuid,lease_status text,release_reason text,expires_at timestamptz);
          create table public.listings(listing_id uuid,listing_status text);
          create table public.pickup_tasks(claim_id uuid,task_status text);
          create table public.claim_reconciliation_cases(case_id uuid,claim_id uuid,listing_id uuid,case_status text,opened_at timestamptz);
          create table public.coordination_config(singleton boolean,claim_lease_minutes integer);
          create table public.audit_events(event_id uuid,claim_id uuid,lease_id uuid,event_type text,
            occurred_at timestamptz,outcome text,resulting_state text,reason_code text,previous_state text);
          create schema cron authorization supabase_admin;
          create table cron.job(jobid bigint primary key,jobname text,schedule text,command text,username text,
            database text,nodename text default 'localhost',nodeport int default 5432,active boolean);
          create table cron.job_run_details(runid bigint primary key,jobid bigint,status text,start_time timestamptz,
            end_time timestamptz,return_message text);
          create table cron.api_calls(jobid bigint,active boolean);
          alter table cron.job owner to supabase_admin;
          alter table cron.job_run_details owner to supabase_admin;
          alter table cron.api_calls owner to supabase_admin;
          grant usage on schema cron to postgres;
          grant select on cron.job,cron.job_run_details to postgres with grant option;
          alter table cron.job enable row level security;
          create policy owned_job on cron.job using(username=current_user);
          grant pg_read_all_stats to postgres;
        """)
        for name in PUBLIC:
            cls.query_as('fixture_admin',f'create table if not exists public.{name}(id uuid); alter table public.{name} owner to postgres;')
        cls.install_recovery()
        cls.install_api()

    @classmethod
    def install_recovery(cls):
        # Create the exact approved source for catalog comparison; NEVER invoke it.
        cls.query_as('fixture_admin',RECOVERY+""";
          alter function public.recover_expired_claims(integer) owner to postgres;
          revoke all on function public.recover_expired_claims(integer) from public,anon,service_role;
          grant execute on function public.recover_expired_claims(integer) to postgres,service_role;
        """)

    @classmethod
    def install_api(cls):
        # API behavior double only: native pg_cron C module is not installed/run.
        cls.query_as('fixture_admin',"""
          create or replace function cron.alter_job(job_id bigint,schedule text default null,
            command text default null,database text default null,username text default null,
            active boolean default null) returns void language plpgsql security definer
            set search_path=pg_catalog,pg_temp as $$
          begin
            update cron.job j set schedule=coalesce($2,j.schedule),command=coalesce($3,j.command),
              database=coalesce($4,j.database),username=coalesce($5,j.username),active=coalesce($6,j.active)
              where j.jobid=$1 and j.username=session_user;
            if not found then raise exception 'JOB_NOT_OWNED'; end if;
            insert into cron.api_calls values($1,$6);
          end $$;
          alter function cron.alter_job(bigint,text,text,text,text,boolean) owner to supabase_admin;
          revoke all on function cron.alter_job(bigint,text,text,text,text,boolean) from public;
          grant execute on function cron.alter_job(bigint,text,text,text,text,boolean) to postgres;
        """)

    def setUp(self):
        self.install_api();self.install_recovery()
        self.query_as('fixture_admin',"truncate cron.job,cron.job_run_details,cron.api_calls,public.coordination_config;")
        with self.connect('fixture_admin') as conn:
            conn.execute("insert into cron.job(jobid,jobname,schedule,command,username,database,active) values"
                         "(1,'geolock-ngo-eligibility-refresh','* * * * *',%s,'postgres','postgres',true),"
                         "(2,'geolock-listing-eligibility-refresh','* * * * *',%s,'postgres','postgres',true),"
                         "(3,'geolock-expired-claim-recovery','* * * * *',%s,'postgres','postgres',false)",
                         ("set statement_timeout = '10min'; select public.process_ngo_eligibility_refresh_jobs();",
                          "set statement_timeout = '10min'; select public.process_listing_eligibility_refresh_jobs();",MARKED))
            conn.execute("insert into cron.job_run_details select n,3,'succeeded',now()-interval '1 hour',now()-interval '1 hour','1 row' from generate_series(1,17)n")
            conn.execute("insert into cron.job_run_details values(18,1,'succeeded',now(),now(),'1 row'),(19,2,'succeeded',now(),now(),'1 row')")
            conn.execute("insert into public.coordination_config values(true,360)")

    @classmethod
    def connect(cls, role='postgres'):
        return psycopg.connect(host='127.0.0.1',port=cls.port,user=role,dbname='postgres',connect_timeout=3)

    def snapshot(self):
        return json.loads(self.query_as('fixture_admin',"""select json_build_object(
          'jobs',(select json_agg(j order by jobid) from cron.job j),
          'history',(select json_agg(r order by runid) from cron.job_run_details r),
          'calls',(select coalesce(json_agg(a),'[]'::json) from cron.api_calls a),
          'source',(select md5(replace(prosrc,E'\\r\\n',E'\\n')) from pg_proc
            where oid='public.recover_expired_claims(integer)'::regprocedure));"""))

    def reject(self, error, source=APPROVED):
        before=self.snapshot()
        self.query_as('postgres',source,error)
        self.assertEqual(before,self.snapshot())

    def test_marked_command_full_commit_changes_only_active_then_pause(self):
        before=self.snapshot()
        receipt=json.loads(self.query_as('postgres',APPROVED))
        after=self.snapshot()
        expected=json.loads(json.dumps(before));expected['jobs'][2]['active']=True
        expected['calls']=[{'jobid':3,'active':False},{'jobid':3,'active':True}]
        self.assertEqual(after,expected)
        self.assertEqual(after['jobs'][2]['command'],MARKED)
        self.assertEqual(receipt['maximum_seconds'],300)
        from datetime import datetime
        self.assertEqual((datetime.fromisoformat(receipt['pause_deadline_utc'])-
                          datetime.fromisoformat(receipt['activation_statement_utc'])).total_seconds(),300)
        self.query_as('postgres',PAUSE)
        paused=self.snapshot();self.assertFalse(paused['jobs'][2]['active'])
        self.assertEqual(paused['jobs'],before['jobs'])

    def test_plain_command_preserved(self):
        with self.connect('fixture_admin') as c:c.execute('update cron.job set command=%s where jobid=3',(COMMAND,))
        self.query_as('postgres',APPROVED)
        self.assertEqual(self.snapshot()['jobs'][2]['command'],COMMAND)

    def test_review_copy_blocks_before_api(self):
        self.reject('FINAL_APPROVAL_DEV_PROJECT_AND_PRESENT_OPERATOR_REQUIRED',REVIEW)

    def test_real_managed_role_cannot_lock_or_update_cron_table(self):
        self.assertEqual(self.query_as('postgres',"select current_user||'/'||session_user||'/'||rolsuper||'/'||rolbypassrls from pg_roles where rolname=current_user"),
                         'postgres/postgres/false/true')
        self.query_as('postgres','begin; lock table cron.job in share row exclusive mode nowait; commit;', 'permission denied')
        self.query_as('postgres','update cron.job set active=true where jobid=3;', 'permission denied')
        self.query_as('postgres','select * from cron.job for update;', 'permission denied')

    def test_wrong_session_identity_rejected(self):
        before=self.snapshot();self.query_as('fixture_admin',APPROVED,'CLEAN_POSTGRES_SESSION_REQUIRED')
        self.assertEqual(before,self.snapshot())

    def test_source_drift_rejected(self):
        self.query_as('fixture_admin',RECOVERY.replace('end;','end; -- isolated drift',1))
        self.reject('SOURCE_OR_SECURITY_DRIFT')

    def test_acl_drift_rejected(self):
        self.query_as('fixture_admin','grant execute on function public.recover_expired_claims(integer) to anon;')
        self.reject('SOURCE_OR_SECURITY_DRIFT')

    def test_changed_job_command_rejected(self):
        with self.connect('fixture_admin') as c:c.execute("update cron.job set command='select 1;' where jobid=3")
        self.reject('RECOVERY_JOB_CONFIGURATION_DRIFT')

    def test_already_active_rejected(self):
        with self.connect('fixture_admin') as c:c.execute('update cron.job set active=true where jobid=3')
        self.reject('RECOVERY_JOB_CONFIGURATION_DRIFT')

    def test_failed_history_rejected(self):
        with self.connect('fixture_admin') as c:c.execute("update cron.job_run_details set status='failed' where runid=1")
        self.reject('RECOVERY_HISTORY_OR_ACTIVE_EXECUTION_REQUIRES_REVIEW')

    def test_unfinished_history_rejected(self):
        with self.connect('fixture_admin') as c:c.execute('update cron.job_run_details set end_time=null where runid=1')
        self.reject('RECOVERY_HISTORY_OR_ACTIVE_EXECUTION_REQUIRES_REVIEW')

    def test_unhealthy_worker_rejected(self):
        with self.connect('fixture_admin') as c:c.execute("update cron.job_run_details set end_time=now()-interval '20 minutes' where jobid=1")
        self.reject('ELIGIBILITY_WORKER_HEALTH_OR_CONFIGURATION_CHANGED')

    def test_api_permission_revoked_rejected(self):
        self.query_as('fixture_admin','revoke execute on function cron.alter_job(bigint,text,text,text,text,boolean) from postgres;')
        self.reject('SUPPORTED_CRON_API_PERMISSIONS_REQUIRED')

    def test_exception_after_enable_rolls_back_both_api_calls(self):
        source=APPROVED.replace(" PERFORM set_config('geolock.supervised_receipt',",
                                  " RAISE EXCEPTION 'INJECTED_AFTER_ENABLE'; PERFORM set_config('geolock.supervised_receipt',",1)
        self.reject('INJECTED_AFTER_ENABLE',source)

    def test_monitor_compiles_readonly(self):
        self.query_as('postgres','begin read only;\n'+(DEST/'02_monitor.sql').read_text(encoding='utf-8')+'\nrollback;')

    def background_wrapper(self, source, app):
        def run():
            try:
                with self.connect() as conn:
                    conn.execute("select set_config('application_name',%s,false)",(app,));conn.commit()
                    conn.execute(source)
                return None
            except psycopg.Error as error:
                return error.sqlstate
        pool=ThreadPoolExecutor(max_workers=1)
        future=pool.submit(run)
        for _ in range(100):
            with self.connect('fixture_admin') as conn:
                waiting=conn.execute("select exists(select 1 from pg_stat_activity where application_name=%s and wait_event='PgSleep')",(app,)).fetchone()[0]
            if waiting:return pool,future
            if future.done():break
            time.sleep(.02)
        pool.shutdown(wait=True)
        self.fail('Background wrapper did not reach its isolated synchronization point')

    def test_concurrent_cron_change_aborts_serializable_snapshot(self):
        source=APPROVED.replace(' PERFORM cron.alter_job(3,active := false);',
                                ' PERFORM pg_sleep(1); PERFORM cron.alter_job(3,active := false);',1)
        pool,future=self.background_wrapper(source,'isolated-wrapper-before-api')
        try:
            with self.connect() as conn:
                conn.execute("select cron.alter_job(3,command:='concurrent-isolated-change')")
            self.assertEqual(future.result(timeout=10),'40001')
        finally:
            pool.shutdown(wait=True)
        self.assertFalse(self.snapshot()['jobs'][2]['active'])
        self.assertEqual(self.snapshot()['jobs'][2]['command'],'concurrent-isolated-change')
        self.assertEqual(self.snapshot()['calls'],[{'jobid':3,'active':None}])

    def test_supported_api_holds_job3_row_lock_until_commit(self):
        source=APPROVED.replace(' v_at:=clock_timestamp();', ' PERFORM pg_sleep(1); v_at:=clock_timestamp();',1)
        pool,future=self.background_wrapper(source,'isolated-wrapper-after-api')
        try:
            with self.connect() as conn:
                conn.execute("set local lock_timeout='100ms'")
                with self.assertRaises(psycopg.errors.LockNotAvailable):
                    conn.execute('select cron.alter_job(3,active:=false)')
                conn.rollback()
            self.assertIsNone(future.result(timeout=10))
        finally:
            pool.shutdown(wait=True)
        self.assertTrue(self.snapshot()['jobs'][2]['active'])

    def test_business_lock_conflict_stops_before_api(self):
        with self.connect() as conn:
            conn.execute('lock table public.coordination_config in row exclusive mode')
            self.reject('could not obtain lock')
            conn.rollback()

    def test_empty_business_tables_remain_empty(self):
        self.query_as('postgres',APPROVED);self.query_as('postgres',PAUSE)
        for table in PUBLIC:
            if table!='coordination_config':
                self.assertEqual(self.query_as('postgres',f'select count(*) from public.{table};'),'0',table)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',action='store_true')
    parser.add_argument('--pg-bin',type=Path,required=True)
    args=parser.parse_args()
    if not args.run_isolated:parser.error('--run-isolated required; no external DSN supported')
    bins={n:str(args.pg_bin/(n+('.exe' if os.name=='nt' else ''))) for n in ('initdb','pg_ctl','psql')}
    if any(not Path(p).is_file() for p in bins.values()):parser.error('Local PostgreSQL executables required')
    ActivationTests.bins=bins
    unittest.main(argv=[__file__],verbosity=2)
