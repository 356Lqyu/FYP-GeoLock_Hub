"""NEW local PostgreSQL only: non-superuser postgres / SELECT-only cron.job.

No external DSN. Actual recovery is retained. cron.alter_job is an explicit
owner-privileged SQL double for pg_cron's internal C privilege switch, not real
pg_cron. Setup uses fixture_admin; ALL activation, pause and tick calls use a
real login as the demoted postgres role (current_user=session_user=postgres).
"""
from pathlib import Path
import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest
import claim_recovery_live_activation_isolated_test as prior
import claim_recovery_permission_activation_package as package


class PermissionTests(prior.LiveTests):
    role_ready=False

    @classmethod
    def query_as(cls,role,sql,expect_error=None):
        args=[cls.bins['psql'],'-X','--no-password','-h','127.0.0.1','-p',str(cls.port),
              '-U',role,'-d','postgres','-v','ON_ERROR_STOP=1','-Atq','-c',sql]
        try:
            result=cls.run_process(args)
        except RuntimeError as exc:
            if expect_error and expect_error in str(exc):
                return str(exc)
            raise
        if expect_error:
            raise AssertionError(f'Expected {expect_error}, got {result}')
        return result

    @classmethod
    def query(cls,sql,expect_error=None):
        # ONLY fixture setup/admin DML needs elevation. Tests of denied operations
        # use query_as explicitly. Activation contains no direct cron DML.
        admin=cls.role_ready and (
          re.match(r'(?is)^\s*(?:insert\s+into|update)\s+cron\.',sql)
          or re.search(r'(?is)\btruncate\s+[^;]*\bcron\.',sql))
        # Restrict setup routing: never elevate a transaction/DO/activation.
        if sql.lstrip().startswith('--') or 'DO $stage3i$' in sql:
            admin=False
        return cls.query_as('fixture_admin' if admin else 'postgres',sql,expect_error)

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.query("""create role fixture_admin login superuser;
          create role supabase_admin nologin superuser;
          alter schema cron owner to supabase_admin;
          alter table cron.job owner to supabase_admin;
          alter table cron.job_run_details owner to supabase_admin;
          grant usage on schema cron to postgres;
          revoke all on cron.job,cron.job_run_details from public,postgres;
          grant select on cron.job,cron.job_run_details to public;
          grant select on cron.job,cron.job_run_details to postgres with grant option;
          alter table cron.job enable row level security;
          create policy cron_job_policy on cron.job using(username=current_user);
          grant pg_read_all_stats to postgres;
          create or replace function cron.alter_job(job_id bigint,schedule text default null,
            command text default null,database text default null,username text default null,
            active boolean default null) returns void language plpgsql security definer
            set search_path=pg_catalog,pg_temp as $$
          begin
            update cron.job j set schedule=coalesce($2,j.schedule),command=coalesce($3,j.command),
              database=coalesce($4,j.database),username=coalesce($5,j.username),active=coalesce($6,j.active)
              where j.jobid=$1 and j.username=session_user;
            if not found then raise exception 'Job missing or not owned'; end if;
          end $$;
          alter function cron.alter_job(bigint,text,text,text,text,boolean) owner to supabase_admin;
          revoke all on function cron.alter_job(bigint,text,text,text,text,boolean) from public;
          grant execute on function cron.alter_job(bigint,text,text,text,text,boolean) to postgres;
        """)
        # PostgreSQL forbids demoting bootstrap OID 10. Rename it instead and
        # create a distinct managed postgres LOGIN with the observed DEV flags.
        cls.query_as('fixture_admin',"""
          alter role postgres rename to fixture_bootstrap;
          create role postgres login nosuperuser bypassrls inherit createrole createdb;
          alter database postgres owner to postgres;
          alter schema auth owner to postgres;
          alter schema extensions owner to postgres;
          do $$ declare r record; begin
            for r in select c.oid::regclass as identity from pg_class c
              join pg_namespace n on n.oid=c.relnamespace
              where n.nspname='public' and c.relkind in('r','p') loop
              execute format('alter table %s owner to postgres',r.identity);
            end loop;
            for r in select p.oid::regprocedure as identity from pg_proc p
              join pg_namespace n on n.oid=p.pronamespace
              where n.nspname in('public','auth') loop
              execute format('alter function %s owner to postgres',r.identity);
            end loop;
          end $$;
          grant usage on schema cron to postgres;
          grant select on cron.job,cron.job_run_details to postgres with grant option;
          grant execute on function cron.alter_job(bigint,text,text,text,text,boolean) to postgres;
          grant pg_read_all_stats to postgres;
        """)
        cls.role_ready=True

    def sql(self,name):
        m={**self.manifest,'timezone':'UTC','max_activation_seconds':300,
           'deadline_mode':'server_clock_immediately_before_activation',
           'activation_token':package.TOKEN,
           'operator_confirmation':self.manifest.get('operator_confirmation',prior.live.CONFIRMATION),
           'execution_approved':self.manifest.get('execution_approved',True)}
        return package.artifacts(m)[name]

    def tick(self):
        # Simulated scheduler executes the EXACT stored marked command, locally.
        result=self.query_as('postgres',self.query('select command from cron.job where jobid=3;'))
        self.query_as('fixture_admin',"""insert into cron.job_run_details(jobid,status,runid,start_time,end_time)
          select 3,'succeeded',coalesce(max(runid),3137)+1,now(),now() from cron.job_run_details;""")
        return result

    def staged_snapshot_check(self,split,concurrent_sql,expected_error):
        """Pause the client between utility statements WITHOUT a snapshotting SELECT."""
        sql=self.sql('03_activate.sql')
        prefix,suffix=sql.split(split,1)
        app='isolated-permission-snapshot'
        with tempfile.TemporaryFile(mode='w+',encoding='utf-8') as output:
            args=[self.bins['psql'],'-X','--no-password','-h','127.0.0.1','-p',str(self.port),
              '-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-Atq','-f','-']
            proc=subprocess.Popen(args,env=dict(self.env,PGAPPNAME=app),creationflags=self.flags,
              stdin=subprocess.PIPE,stdout=output,stderr=output,text=True)
            try:
                proc.stdin.write(prefix+'\n');proc.stdin.flush()
                for _ in range(100):
                    state=self.query_as('fixture_admin',f"select state||'/'||(backend_xmin is null)::text from pg_stat_activity where application_name='{app}';")
                    if state=='idle in transaction/true':
                        break
                    if proc.poll() is not None:
                        self.fail('Staged client exited before snapshot check')
                    time.sleep(.02)
                else:
                    self.fail('A utility statement unexpectedly established the RR snapshot: '+state)
                self.query_as('fixture_admin',concurrent_sql)
                proc.stdin.write(split+suffix);proc.stdin.close()
                proc.wait(timeout=20)
                output.seek(0);message=output.read()
                self.assertNotEqual(proc.returncode,0,message)
                self.assertIn(expected_error,message)
            finally:
                if proc.poll() is None:
                    proc.kill();proc.wait(timeout=10)
        self.assertEqual(self.query('select active from cron.job where jobid=3;'),'f')

    def test_permission_identity_and_exact_cron_privilege_boundary(self):
        self.assertEqual(self.query("select current_user||'/'||session_user||'/'||rolsuper||'/'||rolbypassrls from pg_roles where rolname=current_user;"),
                         'postgres/postgres/false/true')
        self.assertEqual(self.query("select has_table_privilege('cron.job','SELECT') and not has_table_privilege('cron.job','INSERT') and not has_table_privilege('cron.job','UPDATE') and not has_table_privilege('cron.job','MAINTAIN') and not has_table_privilege('cron.job','TRUNCATE') and not has_table_privilege('cron.job','DELETE');"),'t')
        self.assertEqual(self.query("select pg_get_userbyid(relowner)||'/'||relrowsecurity from pg_class where oid='cron.job'::regclass;"),'supabase_admin/true')
        self.query_as('postgres','begin; lock table cron.job in share row exclusive mode nowait; commit;',
                      expect_error='permission denied for table job')
        self.query_as('postgres','update cron.job set active=true where jobid=3;',
                      expect_error='permission denied for table job')
        self.query_as('postgres','select * from cron.job where jobid=3 for update;',
                      expect_error='permission denied for table job')
        self.assertEqual(self.query("select has_function_privilege('cron.alter_job(bigint,text,text,text,text,boolean)','EXECUTE');"),'t')

    def test_permission_old_wrapper_reproduces_42501(self):
        manifest={**self.manifest,'timezone':'UTC','max_activation_seconds':300,
          'deadline_mode':'server_clock_immediately_before_activation','activation_token':prior.live.TOKEN,
          'operator_confirmation':prior.live.CONFIRMATION,'execution_approved':True}
        before=self.snapshot()
        self.query_as('postgres',prior.live.artifacts(manifest)['03_activate.sql'],
                      expect_error='permission denied for table job')
        self.assertEqual(before,self.snapshot())

    def test_live_old_external_timestamp_is_replaced_by_real_locked_read(self):
        self.manifest['baseline_at']='2000-01-01T00:00:00+00'
        before=self.snapshot()
        receipt=json.loads(self.query(self.sql('03_activate.sql')))
        self.assertEqual(receipt['window_seconds'],300)
        self.assertEqual(self.query('select command from cron.job where jobid=3;'),package.MARKED_COMMAND)
        after=self.snapshot();before.pop('cron.job');after.pop('cron.job')
        self.assertEqual(before,after)
        self.pause()

    def test_live_concurrent_cron_configuration_writer_aborts_nowait(self):
        # Nonparticipant changes job 3 AFTER our RR snapshot but BEFORE API lock.
        sql=self.sql('03_activate.sql').replace(' PERFORM cron.alter_job(3,active := false);',
          ' PERFORM pg_sleep(2); PERFORM cron.alter_job(3,active := false);',1)
        before=self.snapshot();before.pop('cron.job')
        with self.background(sql,expect_error='could not serialize access due to concurrent update'):
            self.query_as('postgres',"select cron.alter_job(3,command:='concurrent-admin-change');")
        self.assertEqual(self.query('select active from cron.job where jobid=3;'),'f')
        self.assertEqual(self.query('select command from cron.job where jobid=3;'),'concurrent-admin-change')
        after=self.snapshot();after.pop('cron.job');self.assertEqual(before,after)

    def test_permission_supported_api_retains_job3_row_lock(self):
        sql=self.sql('03_activate.sql').replace(' v_activation_at:=clock_timestamp();',
          ' PERFORM pg_sleep(2); v_activation_at:=clock_timestamp();',1)
        with self.background(sql):
            self.query_as('postgres',"set lock_timeout='100ms'; select cron.alter_job(3,active:=true);",
                          expect_error='lock timeout')
        self.assertEqual(self.query('select active from cron.job where jobid=3;'),'t')
        self.pause()

    def test_permission_cooperative_advisory_contender_rejected(self):
        with self.background('begin; select pg_advisory_xact_lock(1936288105,3); select pg_sleep(2); commit;'):
            self.reject_activation('RECOVERY_ACTIVATION_PROTOCOL_BUSY')

    def test_permission_pause_does_not_wait_for_advisory_protocol(self):
        with self.background('begin; select pg_advisory_xact_lock(1936288105,3); select pg_sleep(2); commit;'):
            self.pause()
        self.assertEqual(self.query('select active from cron.job where jobid=3;'),'f')

    def test_permission_false_copy_never_calls_supported_api(self):
        self.manifest['execution_approved']=False
        self.reject_activation('EXPLICIT_EXECUTION_APPROVAL_AND_SUPERVISION_REQUIRED')
        self.assertEqual(self.query('select active from cron.job where jobid=3;'),'f')

    def test_permission_noop_and_activation_are_both_rolled_back(self):
        sql=self.sql('03_activate.sql').replace(' v_activation_at:=clock_timestamp();',
          " RAISE EXCEPTION 'AFTER_SUPPORTED_LOCK_TEST'; v_activation_at:=clock_timestamp();",1)
        before=self.query('select xmin::text from cron.job where jobid=3;')
        self.query_as('postgres',sql,expect_error='AFTER_SUPPORTED_LOCK_TEST')
        self.assertEqual(self.query('select xmin::text from cron.job where jobid=3;'),before)
        self.assertEqual(self.query('select active from cron.job where jobid=3;'),'f')

    def test_permission_nonparticipant_new_job_is_not_globally_fenced(self):
        # Intentional LIMITATION test, not a claimed safety guarantee.
        sql=self.sql('03_activate.sql').replace(' v_activation_at:=clock_timestamp();',
          ' PERFORM pg_sleep(2); v_activation_at:=clock_timestamp();',1)
        with self.background(sql):
            self.query_as('fixture_admin',"insert into cron.job values(4,'nonparticipant','* * * * *','select public.recover_expired_claims(1);','postgres','postgres',false);")
        self.assertEqual(self.query('select count(*) from cron.job where jobid=4;'),'1')
        self.pause()

    def test_permission_first_business_snapshot_is_after_public_locks(self):
        self.staged_snapshot_check('LOCK TABLE public.donation_claims,',
          f"update public.pickup_tasks set task_status='PLANNED' where task_id='{self.f['task']}';",
          'TARGET_OR_SNAPSHOT_CHANGED')

    def test_permission_cron_change_committed_before_first_snapshot_is_seen(self):
        self.staged_snapshot_check('DO $stage3i$',
          "update cron.job set command='changed-before-snapshot' where jobid=3;",
          'POST_CANARY_CRON_BASELINE_DRIFT')

    def test_permission_monitor_is_one_complete_read_only_result(self):
        result=self.json_row('04_monitor.sql')
        self.assertEqual(result['claim']['claim_status'],'ACTIVE')
        self.assertEqual(result['recovery_schedule_count'],1)
        self.assertEqual(result['all_recovery_schedules'][0]['jobid'],3)
        self.assertEqual([x['jobid'] for x in result['eligibility_health']],[1,2])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',action='store_true')
    parser.add_argument('--pg-bin',type=Path)
    args=parser.parse_args()
    if not args.run_isolated:
        parser.error('--run-isolated required; no external DSN accepted')
    PermissionTests.bins={n:str(args.pg_bin/(n+('.exe' if os.name=='nt' else ''))) if args.pg_bin else shutil.which(n)
      for n in ('initdb','pg_ctl','psql')}
    if any(not p or not Path(p).is_file() for p in PermissionTests.bins.values()):
        parser.error('initdb/pg_ctl/psql required')
    names=sorted(n for n in dir(PermissionTests) if n.startswith(('test_live_','test_permission_')))
    result=unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(PermissionTests(n) for n in names))
    raise SystemExit(not result.wasSuccessful())
