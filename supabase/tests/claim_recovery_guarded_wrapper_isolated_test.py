"""Stage 3B: exact original and revised wrapper in a NEW disposable PostgreSQL.

No DSN/URL or existing server is accepted. Never connects to Supabase.
Actual patched recovery, six lifecycle dependencies, deployed listing triggers.
Reduced tables, auth/cron doubles and a fixed road-node resolver are explicit.
Fault injections exist ONLY in the disposable cluster or test-only SQL variants.
"""
from contextlib import contextmanager
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest

import claim_recovery_expiration_isolated_test as recovery

ROOT = Path(__file__).resolve().parents[2]
FIX = ROOT / 'supabase/tests/fixtures'
ORIGINAL = (FIX / 'claim_recovery_guarded_original.sql').read_text(encoding='utf-8')
FINAL = (FIX / 'claim_recovery_guarded_final.sql').read_text(encoding='utf-8')
TRIGGERS = (FIX / 'claim_recovery_guarded_live_triggers.sql').read_text(encoding='utf-8')
ROWS = [
    ('323ca3b3-7d7f-438e-8ed7-415f61b3a567','c845c9d7-edc8-4870-b32a-40e02d22469a',
     '2d06b504-d2dd-4121-8840-c8bf893f8a60','5ab67656-bd03-4e19-942f-59a2dd4e6f11',
     '8f0feb98-c97c-4047-91ab-251199b2d1b6','2026-10-22 00:08:43.922912+00',2),
    ('aa3cd6d2-e5b3-4369-a41f-ec9a0eaae716','364102f4-a020-44a8-8e7d-e2aa1bc3a3b7',
     'd7953dd2-7809-4cb4-87f3-52fc3294685b','3c32d1ae-ea3c-452c-8a76-9e05a0ad911a',
     'aaa3429b-4ded-4ae2-865c-784abe41466d','2026-10-22 00:31:43.636107+00',2),
    ('9a2ab42b-52c6-4c3a-99fb-b5c95d41e63f','f3a5e81d-bb3e-48c4-a317-b6987e88e0be',
     '16e5b6a1-475d-4c5a-9460-d4834dd5640f','0c8f21b4-2e87-466c-bc29-dc15c78f4a04',
     'a918031f-c786-4b5f-8823-86bc7a880a05','2026-10-22 01:31:05.383307+00',4),
]
TARGET, LEASE, LISTING, DONATION, TASK, *_ = ROWS[0]
TABLES = ('donation_claims','claim_leases','pickup_tasks','listings','donations',
          'audit_events','claim_reconciliation_cases','listing_eligibility_refresh_jobs',
          'ngo_listing_road_eligibility','active_task_route_assignments','pickup_route_stops','cron.job')


class GuardedWrapperTests(unittest.TestCase):
    run_process = recovery.RecoveryExpirationTests.__dict__['run_process']
    query = recovery.RecoveryExpirationTests.__dict__['query']
    cleanup_cluster = recovery.RecoveryExpirationTests.__dict__['cleanup_cluster']

    @classmethod
    def setUpClass(cls):
        recovery.RecoveryExpirationTests.setUpClass.__func__(cls)
        cls.query("""
          create schema cron;
          create table cron.job(jobid bigint primary key,jobname text,schedule text,command text,
            username text,database text,active boolean);
          create table cron.job_run_details(jobid bigint,status text);
          alter table public.listings add column eligibility_generation bigint not null default 1;
          alter table public.listings add column pickup_latitude double precision default 3;
          alter table public.listings add column pickup_longitude double precision default 101;
          alter table public.listings add column pickup_road_node_id text;
          create table public.road_network_coverage(network_snapshot_id text,active_flag boolean,
            dataset_kind text,approved_at timestamptz,max_snap_distance_m integer);
          insert into public.road_network_coverage values('isolated-fixed-snapshot',true,'OPERATIONAL',now(),500);
          -- Explicit double: NO routing algorithm executes in these tests.
          create function public.geolock_resolve_road_node(double precision,double precision)
            returns table(node_id text,snap_distance_m double precision,snapshot_id text)
            language sql as $$ select 'isolated-road-node'::text,10::double precision,'isolated-fixed-snapshot'::text $$;
          create table public.ngo_listing_road_eligibility(listing_id uuid,fixture_payload text);
          create table public.listing_eligibility_refresh_jobs(listing_id uuid,eligibility_generation bigint,
            expected_road_node_id text,expected_snapshot_id text,job_status text default 'PENDING',
            unique(listing_id,eligibility_generation));
          -- Allow identity-negative tests without weakening the real wrapper guard.
          create or replace function auth.uid() returns uuid language sql stable as
            $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
          grant usage on schema auth to service_role;
        """)
        cls.query(TRIGGERS)
        cls.query("""
          create trigger zz_listing_eligibility_generation before insert or update on public.listings
            for each row execute function public.geolock_prepare_listing_eligibility();
          create trigger trg_listing_road_eligibility after insert or update on public.listings
            for each row execute function public.geolock_listing_eligibility_trigger();
        """)

    def setUp(self):
        self.query("""
          drop trigger if exists wrapper_slow on public.claim_leases;
          drop trigger if exists wrapper_audit on public.audit_events;
          drop trigger if exists wrapper_deferred on public.donations;
          drop trigger if exists wrapper_task_change on public.pickup_tasks;
          alter table public.listings enable trigger trg_listing_road_eligibility;
          truncate cron.job,cron.job_run_details,public.listing_eligibility_refresh_jobs,
            public.ngo_listing_road_eligibility;
        """)
        recovery.RecoveryExpirationTests.setUp(self)
        self.query("""
          insert into cron.job values
          (1,'geolock-ngo-eligibility-refresh','* * * * *','fixture-ngo','postgres','postgres',true),
          (2,'geolock-listing-eligibility-refresh','* * * * *','fixture-listing','postgres','postgres',true),
          (3,'geolock-expired-claim-recovery','* * * * *',
           'set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(100);',
           'postgres','postgres',false);
        """)
        sql = ['begin;']
        for c, le, l, d, t, expiry, version in ROWS:
            sql += [
                f"insert into public.donations(donation_id,collection_path,donation_status,total_weight_kg) values('{d}','DIRECT_PICKUP','CLAIMED',50);",
                f"insert into public.listings(listing_id,source_type,donation_id,listing_status,listing_version) values('{l}','DIRECT_DONATION','{d}','CLAIMED',{version});",
                f"insert into public.donation_claims(claim_id,listing_id,claim_status) values('{c}','{l}','ACTIVE');",
                f"insert into public.claim_leases(lease_id,claim_id,lease_status,issued_at,expires_at) values('{le}','{c}','ACTIVE','{expiry}'::timestamptz-interval '360 minutes','{expiry}');",
                f"insert into public.pickup_tasks(task_id,claim_id,listing_id,task_status) values('{t}','{c}','{l}','CONFIRMED');",
                f"insert into public.ngo_listing_road_eligibility values('{l}','cache-before-recovery');",
            ]
        # Reproduce the third listing's actual generation without invoking recovery.
        sql += ["alter table public.listings disable trigger zz_listing_eligibility_generation;",
                f"update public.listings set eligibility_generation=2 where listing_id='{ROWS[2][2]}';",
                "alter table public.listings enable trigger zz_listing_eligibility_generation;", 'commit;']
        self.query('\n'.join(sql))

    def snapshot(self):
        parts = []
        for name in TABLES:
            table = name if '.' in name else 'public.' + name
            parts.append(f"'{name}',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]'::jsonb) from {table} x)")
        return json.loads(self.query('select jsonb_build_object(' + ','.join(parts) + ');'))

    def assert_abort(self, error, sql=FINAL):
        before = self.snapshot()
        self.query(sql, expect_error=error)
        # A NEW connection proves no uncommitted changes survived disconnection.
        self.assertEqual(self.snapshot(), before)

    def assert_success(self, sql=FINAL):
        before = self.snapshot()
        self.query(sql)
        after = self.snapshot()
        for c, *_ in ROWS[1:]:
            for table in ('donation_claims','claim_leases','pickup_tasks'):
                self.assertEqual([x for x in before[table] if x['claim_id'] == c],
                                 [x for x in after[table] if x['claim_id'] == c])
        for index in (1,2):
            for table, key, value in [('listings','listing_id',ROWS[index][2]),('donations','donation_id',ROWS[index][3])]:
                self.assertEqual([x for x in before[table] if x[key] == value], [x for x in after[table] if x[key] == value])
        expected = [('donation_claims','claim_id',TARGET,'claim_status','RELEASED'),
                    ('claim_leases','lease_id',LEASE,'lease_status','RELEASED'),
                    ('pickup_tasks','task_id',TASK,'task_status','STALE'),
                    ('listings','listing_id',LISTING,'listing_status','AVAILABLE'),
                    ('donations','donation_id',DONATION,'donation_status','AVAILABLE')]
        for table,key,value,status,result in expected:
            self.assertEqual(next(x[status] for x in after[table] if x[key] == value),result)
        self.assertEqual(len(after['audit_events']),2)
        self.assertEqual({x['event_type'] for x in after['audit_events']},{'LEASE_RECOVERY','DONATION_STATUS_CHANGED'})
        self.assertEqual(after['claim_reconciliation_cases'],[])
        self.assertEqual(len(after['listing_eligibility_refresh_jobs']),1)
        job = after['listing_eligibility_refresh_jobs'][0]
        self.assertEqual((job['listing_id'],job['eligibility_generation'],job['job_status']),(LISTING,2,'PENDING'))
        self.assertNotIn(LISTING,[x['listing_id'] for x in after['ngo_listing_road_eligibility']])
        self.assertEqual(before['cron.job'],after['cron.job'])

    @contextmanager
    def concurrent(self, sql, app='isolated-wrapper-concurrent'):
        output = tempfile.TemporaryFile(mode='w+',encoding='utf-8')
        args = [self.bins['psql'],'-X','--no-password','-h','127.0.0.1','-p',str(self.port),
                '-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-Atq','-c',sql]
        proc = subprocess.Popen(args,env=dict(self.env,PGAPPNAME=app),creationflags=self.flags,stdout=output,stderr=output)
        try:
            for _ in range(100):
                if self.query(f"select exists(select 1 from pg_stat_activity where application_name='{app}' and wait_event='PgSleep');") == 't':
                    break
                if proc.poll() is not None:
                    raise AssertionError('Concurrent session ended before synchronization')
                time.sleep(.02)
            else:
                raise AssertionError('Concurrent session did not reach synchronized sleep')
            yield proc
        finally:
            proc.wait(timeout=20)
            output.seek(0)
            message = output.read()
            output.close()
            if proc.returncode and 'AUDIT_POSTCONDITION_FAILED' not in message:
                self.fail(message)

    def slow_recovery(self):
        self.query("""create or replace function public.wrapper_slow() returns trigger language plpgsql as $$
          begin if new.lease_status='RELEASED' then perform pg_sleep(2); end if; return null; end $$;
          create trigger wrapper_slow after update on public.claim_leases for each row execute function public.wrapper_slow();""")

    def test_01_exact_original_full_transaction_commits_target_only(self):
        self.assert_success(ORIGINAL)

    def test_02_exact_revised_full_transaction_commits_target_only(self):
        self.assert_success()

    def test_wrong_current_role(self):
        self.assert_abort('CLEAN_POSTGRES_SESSION_REQUIRED','set role service_role;\n'+FINAL)

    def test_wrong_session_identity(self):
        self.assert_abort('CLEAN_POSTGRES_SESSION_REQUIRED','set session authorization service_role;\n'+FINAL)

    def test_authenticated_jwt_in_postgres_session(self):
        self.assert_abort('CLEAN_POSTGRES_SESSION_REQUIRED',"set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';\n"+FINAL)

    def test_source_drift(self):
        patched = recovery.PATCH[recovery.PATCH.index('CREATE OR REPLACE FUNCTION'):recovery.PATCH.index('-- Fail atomically')]
        self.query(patched.replace('declare\n','-- isolated fingerprint fault\ndeclare\n',1))
        self.assert_abort('RECOVERY_DEFINITION_OR_SECURITY_CHANGED')

    def test_acl_drift(self):
        self.query('grant execute on function public.recover_expired_claims(integer) to authenticated;')
        self.assert_abort('RECOVERY_DEFINITION_OR_SECURITY_CHANGED')

    def test_recovery_cron_active(self):
        self.query('update cron.job set active=true where jobid=3;')
        self.assert_abort('CRON_STATE_CHANGED')

    def test_recovery_cron_execution_history(self):
        self.query("insert into cron.job_run_details values(3,'succeeded');")
        self.assert_abort('CRON_STATE_CHANGED')

    def test_candidate_order_changed(self):
        self.query(f"update public.claim_leases set issued_at=issued_at-interval '1 day',expires_at=expires_at-interval '1 day' where claim_id='{ROWS[1][0]}';")
        self.assert_abort('CANDIDATE_SET_OR_ORDER_CHANGED')

    def test_target_precondition_changed(self):
        self.query(f"update public.pickup_tasks set task_status='PLANNED' where task_id='{TASK}';")
        self.assert_abort('TARGET_PRECONDITION_FAILED')

    def test_unexpected_result_fault_injection_after_real_call(self):
        # Test-only wrapper variant: real recovery still executes with limit 1.
        sql = FINAL.replace('v_count := public.recover_expired_claims(1);',
                            'v_count := public.recover_expired_claims(1);\n  v_count := 0; -- isolated injected return fault')
        self.assertNotEqual(sql,FINAL)
        self.assert_abort('EXPECTED_ONE_PROCESSED_CLAIM',sql)

    def test_audit_payload_failure_rolls_back(self):
        self.query("""create or replace function public.wrapper_audit() returns trigger language plpgsql as $$
          begin if new.event_type='LEASE_RECOVERY' then new.reason_code:='INJECTED_WRONG_REASON'; end if; return new; end $$;
          create trigger wrapper_audit before insert on public.audit_events for each row execute function public.wrapper_audit();""")
        self.assert_abort('AUDIT_POSTCONDITION_FAILED')

    def test_duplicate_target_audit_rolls_back(self):
        self.query("""create or replace function public.wrapper_audit() returns trigger language plpgsql as $$
          begin if new.event_type='LEASE_RECOVERY' then
            insert into public.audit_events(claim_id,event_type) values(new.claim_id,'INJECTED_EXTRA_TARGET_AUDIT');
          end if; return null; end $$;
          create trigger wrapper_audit after insert on public.audit_events for each row execute function public.wrapper_audit();""")
        self.assert_abort('AUDIT_POSTCONDITION_FAILED')

    def test_missing_eligibility_job_rolls_back(self):
        self.query('alter table public.listings disable trigger trg_listing_road_eligibility;')
        self.assert_abort('ELIGIBILITY_REFRESH_NOT_ENQUEUED')

    def test_other_claim_linked_record_change_rolls_back(self):
        self.query(f"""create or replace function public.wrapper_audit() returns trigger language plpgsql as $$
          begin if new.event_type='LEASE_RECOVERY' then
            update public.pickup_tasks set task_status='STALE' where task_id='{ROWS[1][4]}';
          end if; return null; end $$;
          create trigger wrapper_audit after insert on public.audit_events for each row execute function public.wrapper_audit();""")
        self.assert_abort('OTHER_CLAIMS_CHANGED')

    def test_extra_other_candidate_audit_rolls_back(self):
        self.query(f"""create or replace function public.wrapper_audit() returns trigger language plpgsql as $$
          begin if new.event_type='LEASE_RECOVERY' then
            insert into public.audit_events(claim_id,event_type) values('{ROWS[1][0]}','INJECTED_OTHER_CANDIDATE_EVENT');
          end if; return null; end $$;
          create trigger wrapper_audit after insert on public.audit_events for each row execute function public.wrapper_audit();""")
        self.assert_abort('AUDIT_POSTCONDITION_FAILED')

    def test_commit_after_assertion_error_cannot_commit_recovery(self):
        before = self.snapshot()
        sql = FINAL.replace('v_count := public.recover_expired_claims(1);',
                            'v_count := public.recover_expired_claims(1);\n  v_count := 0; -- injected return fault')
        args = [self.bins['psql'],'-X','--no-password','-h','127.0.0.1','-p',str(self.port),
                '-U','postgres','-d','postgres','-v','ON_ERROR_STOP=0','-f','-']
        result = self.run_process(args,input=sql)
        self.assertIn('EXPECTED_ONE_PROCESSED_CLAIM',result)
        self.assertIn('ROLLBACK',result)
        self.assertEqual(self.snapshot(),before)

    def test_deferred_constraint_failure_rolls_back(self):
        self.query("""create or replace function public.wrapper_deferred() returns trigger language plpgsql as $$
          begin raise exception 'INJECTED_DEFERRED_FAILURE'; end $$;
          create constraint trigger wrapper_deferred after update on public.donations
            deferrable initially deferred for each row execute function public.wrapper_deferred();""")
        self.assert_abort('INJECTED_DEFERRED_FAILURE')

    def test_claim_table_nowait_conflict(self):
        with self.concurrent('begin; lock table public.donation_claims in row share mode; select pg_sleep(2); rollback;'):
            self.assert_abort('could not obtain lock on relation')

    def test_lease_table_nowait_conflict(self):
        with self.concurrent('begin; lock table public.claim_leases in row share mode; select pg_sleep(2); rollback;'):
            self.assert_abort('could not obtain lock on relation')

    def test_target_listing_row_nowait_conflict(self):
        with self.concurrent(f"begin; select 1 from public.listings where listing_id='{LISTING}' for update; select pg_sleep(2); rollback;"):
            self.assert_abort('could not obtain lock on row')

    def test_lock_timeout_after_recovery_updates_rolls_back(self):
        # Unique-key conflict in real enqueue trigger, after release/task changes.
        sql = f"begin; insert into public.listing_eligibility_refresh_jobs(listing_id,eligibility_generation) values('{LISTING}',2); select pg_sleep(7); rollback;"
        with self.concurrent(sql):
            self.assert_abort('lock timeout')

    def test_statement_timeout_rolls_back(self):
        self.slow_recovery()
        sql = FINAL.replace("statement_timeout = '50s'","statement_timeout = '100ms'")
        self.assert_abort('statement timeout',sql)

    def test_original_global_audit_count_rejects_unrelated_concurrent_insert(self):
        self.slow_recovery()
        before = self.snapshot()
        with self.concurrent(ORIGINAL,app='isolated-wrapper-original') as proc:
            self.query("insert into public.audit_events(event_type) values('UNRELATED_CONCURRENT_EVENT');")
        self.assertNotEqual(proc.returncode,0)
        after = self.snapshot()
        self.assertEqual(len(after['audit_events']),1)
        before.pop('audit_events'); after.pop('audit_events')
        self.assertEqual(after,before)

    def test_revised_scoped_audit_allows_unrelated_concurrent_insert(self):
        self.slow_recovery()
        with self.concurrent(FINAL,app='isolated-wrapper-final') as proc:
            self.query("insert into public.audit_events(event_type) values('UNRELATED_CONCURRENT_EVENT');")
        self.assertEqual(proc.returncode,0)
        self.assertEqual(self.query("select count(*) from public.audit_events where claim_id is not null;"),'2')
        self.assertEqual(self.query(f"select claim_status from public.donation_claims where claim_id='{TARGET}';"),'RELEASED')

    def test_snapshot_field_change_is_not_silently_accepted(self):
        self.query("""create or replace function public.wrapper_task_change() returns trigger language plpgsql as $$
          begin new.route_snapshot:='INJECTED_CHANGED_SNAPSHOT'; return new; end $$;
          create trigger wrapper_task_change before update on public.pickup_tasks for each row execute function public.wrapper_task_change();""")
        self.assert_abort('TARGET_POSTCONDITION_FAILED')

    def test_final_has_only_audit_scope_changes(self):
        scope = """a.claim_id=ANY(v_expected)
       OR a.lease_id=v_lease
       OR (a.entity_type='CLAIM' AND a.entity_id=ANY(v_expected))
       OR (a.entity_type='DONATION' AND a.entity_id=v_donation)
       OR a.details->>'listing_id'=v_listing::text"""
        expected = ORIGINAL.replace('  FROM public.audit_events;\n\n  v_count :=',
            '  FROM public.audit_events a\n  WHERE '+scope+';\n\n  v_count :=')
        expected = expected.replace('  WHERE NOT(a.event_id=ANY(v_events_before));',
            '  WHERE NOT(a.event_id=ANY(v_events_before))\n    AND ('+scope+');')
        self.assertEqual(FINAL,expected)
        self.assertEqual(FINAL.count('public.recover_expired_claims(1);'),1)
        self.assertEqual(ORIGINAL.count('public.recover_expired_claims(1);'),1)
        self.assertTrue(FINAL.rstrip().endswith('COMMIT;'))
        self.assertNotIn('cron.alter_job',FINAL)
        self.assertNotIn('CREATE OR REPLACE FUNCTION',FINAL)
        self.assertEqual(hashlib.sha256((ROOT/'supabase/migrations/20261029_fix_claim_recovery_listing_expiration_race.sql').read_bytes()).hexdigest(),
                         '064b1e4cd5b5cd38e1f77b91364af5ed99221926455d5d64ae7a4b70c1c31e7d')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',action='store_true')
    parser.add_argument('--pg-bin',type=Path)
    args = parser.parse_args()
    if not args.run_isolated:
        parser.error('--run-isolated is required; no external connection is supported')
    bins = {n:str(args.pg_bin/(n+('.exe' if os.name=='nt' else ''))) if args.pg_bin else shutil.which(n)
            for n in ('initdb','pg_ctl','psql')}
    if any(not v or not Path(v).is_file() for v in bins.values()):
        parser.error('initdb, pg_ctl and psql are required')
    GuardedWrapperTests.bins = bins
    unittest.main(argv=[__file__],verbosity=2)
