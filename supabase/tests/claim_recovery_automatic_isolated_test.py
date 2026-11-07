"""Stage 3E automatic recovery safety: NEW disposable loopback PostgreSQL ONLY.

No external DSN accepted. Actual approved recovery, lifecycle/listing triggers and
captured start/complete/cancel/claim/assign RPCs. Reduced schema, auth, cron tables
and road-eligibility/resolution doubles are explicit; no routing algorithm tested.
"""
from pathlib import Path
import argparse
from contextlib import contextmanager
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid

import claim_recovery_guarded_wrapper_isolated_test as base

ROOT = Path(__file__).resolve().parents[2]
OWNER = '11111111-1111-1111-1111-111111111111'
RPCS = (ROOT/'supabase/tests/fixtures/claim_recovery_automatic_live_rpcs.sql').read_text(encoding='utf-8')
PROPOSAL = ROOT/'supabase/tests/review-only/claim_recovery_open_case_guard.sql'


class AutomaticRecoveryTests(unittest.TestCase):
    run_process = base.GuardedWrapperTests.__dict__['run_process']
    query = base.GuardedWrapperTests.__dict__['query']
    cleanup_cluster = base.GuardedWrapperTests.__dict__['cleanup_cluster']
    snapshot = base.GuardedWrapperTests.snapshot
    fixture = base.recovery.RecoveryExpirationTests.fixture
    state = base.recovery.RecoveryExpirationTests.state
    recover = base.recovery.RecoveryExpirationTests.recover
    assert_released = base.recovery.RecoveryExpirationTests.assert_released
    assert_reconciliation = base.recovery.RecoveryExpirationTests.assert_reconciliation
    locked = base.recovery.RecoveryExpirationTests.locked

    @classmethod
    def setUpClass(cls):
        base.GuardedWrapperTests.setUpClass.__func__(cls)
        cls.query(f"""
          create table public.ngo_profiles(user_id uuid primary key,active_flag boolean,
            location_verified_at timestamptz,road_node_id text);
          insert into public.ngo_profiles values('{OWNER}',true,now(),'isolated-road-node');
          insert into public.user_profiles values('{OWNER}','NGO');
          alter table public.donation_claims add column ngo_user_id uuid default '{OWNER}';
          alter table public.donation_claims add column request_id uuid;
          alter table public.donation_claims alter column claim_id set default gen_random_uuid();
          alter table public.donation_claims alter column claim_status set default 'ACTIVE';
          alter table public.claim_leases alter column lease_id set default gen_random_uuid();
          alter table public.claim_leases alter column issued_at set default clock_timestamp();
          alter table public.claim_leases alter column lease_status set default 'ACTIVE';
          alter table public.pickup_tasks add column ngo_user_id uuid default '{OWNER}';
          alter table public.pickup_tasks add column pickup_road_node_id text;
          alter table public.pickup_tasks add column load_kg numeric default 20;
          alter table public.pickup_tasks alter column task_id set default gen_random_uuid();
          alter table public.pickup_tasks alter column task_status set default 'CONFIRMED';
          alter table public.listings add column listing_weight_kg numeric default 20;
          alter table public.audit_events add column request_id uuid;
          create table public.claim_requests(request_id uuid primary key,listing_id uuid,ngo_user_id uuid,
            request_digest text,outcome text,result_claim_id uuid,reason_code text,completed_at timestamptz);
          create table public.claim_cancellation_requests(request_id uuid primary key,claim_id uuid,
            actor_user_id uuid,request_fingerprint text,response jsonb,completed_at timestamptz);
          create table public.pickup_routes(route_id uuid primary key,ngo_user_id uuid,route_status text);
          alter table public.active_task_route_assignments add column route_id uuid;
          alter table public.pickup_route_stops add column route_id uuid;
          alter table public.pickup_route_stops add column ngo_user_id uuid;
          alter table public.pickup_route_stops add column stop_order integer;
          -- Explicit coordination-test double, NOT real road/security verification.
          create function public.geolock_ngo_listing_road_check(uuid,uuid) returns jsonb
            language sql as $$ select '{{"outcome":"ELIGIBLE"}}'::jsonb $$;
        """)
        cls.query(RPCS)

    def setUp(self):
        self.query("""drop trigger if exists auto_slow on public.claim_leases;
          drop trigger if exists auto_fail on public.audit_events;
          truncate public.claim_requests,public.claim_cancellation_requests,public.pickup_routes,
            public.listing_eligibility_refresh_jobs,public.ngo_listing_road_eligibility,cron.job,cron.job_run_details cascade;""")
        base.recovery.RecoveryExpirationTests.setUp(self)

    def ngo(self,sql,expect_error=None):
        return self.query(f"begin; set local request.jwt.claim.sub='{OWNER}'; {sql}; commit;",expect_error=expect_error)

    def many(self,count):
        statements=[]
        recorder=type('FixtureSQL',(),{'query':staticmethod(statements.append)})()
        for n in range(1,count+1):
            base.recovery.RecoveryExpirationTests.fixture(recorder,n=n)
        # stdin avoids Windows command-line length limits for 101 fixtures.
        args=[self.bins['psql'],'-X','--no-password','-h','127.0.0.1','-p',str(self.port),
              '-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-Atq','-f','-']
        self.run_process(args,input='\n'.join(statements))

    @contextmanager
    def background(self,sql,app='isolated-auto-worker',expect_error=None):
        output=tempfile.TemporaryFile(mode='w+',encoding='utf-8')
        args=[self.bins['psql'],'-X','--no-password','-h','127.0.0.1','-p',str(self.port),
              '-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-Atq','-c',sql]
        proc=subprocess.Popen(args,env=dict(self.env,PGAPPNAME=app),creationflags=self.flags,stdout=output,stderr=output)
        try:
            for _ in range(100):
                if self.query(f"select exists(select 1 from pg_stat_activity where application_name='{app}' and wait_event='PgSleep');")=='t':
                    break
                if proc.poll() is not None:
                    output.seek(0)
                    raise AssertionError(output.read())
                time.sleep(.02)
            else:
                self.fail('Background session never reached synchronized sleep')
            yield proc
        finally:
            proc.wait(timeout=15)
            output.seek(0)
            message=output.read()
            output.close()
            if expect_error:
                self.assertNotEqual(proc.returncode,0,message)
                self.assertIn(expect_error,message)
            else:
                self.assertEqual(proc.returncode,0,message)

    def slow_first(self):
        self.query(f"""create or replace function public.auto_slow() returns trigger language plpgsql as $$
          begin if new.lease_status='RELEASED' and new.claim_id='{base.recovery.ident(1,1)}'::uuid then
            perform pg_sleep(2); end if; return null; end $$;
          create trigger auto_slow after update on public.claim_leases for each row execute function public.auto_slow();""")

    def test_empty_and_repeated_completed_recovery_are_noops(self):
        self.assertEqual(self.recover(),'0')
        self.fixture()
        self.assertEqual(self.recover(),'1')
        before=self.snapshot()
        self.assertEqual(self.recover(),'0')
        self.assertEqual(self.snapshot(),before)

    def test_future_active_and_exact_boundary(self):
        f=self.fixture()
        self.query(f"update public.claim_leases set expires_at=clock_timestamp()+interval '1 hour' where claim_id='{f['claim']}';")
        self.assertEqual(self.recover(),'0')
        result=self.query(f"begin; update public.claim_leases set expires_at=statement_timestamp() where claim_id='{f['claim']}'; select public.recover_expired_claims(100); commit;")
        self.assertEqual(result,'1')
        self.assert_released()

    def test_configured_limit_100_then_remaining_one(self):
        self.many(101)
        self.assertEqual(self.query("set lock_timeout='5s'; set statement_timeout='50s'; select public.recover_expired_claims(100);"),'100')
        self.assertEqual(self.query("select count(*) from public.donation_claims where claim_status='RELEASED';"),'100')
        self.assertEqual(self.query("select count(*) from public.listing_eligibility_refresh_jobs;"),'100')
        self.assertEqual(self.query("select count(*) from public.audit_events where event_type='LEASE_RECOVERY';"),'100')
        self.assertEqual(self.recover(),'1')
        self.assertEqual(self.recover(),'0')

    def test_zero_negative_and_null_limit_semantics(self):
        self.many(4)
        self.assertEqual(self.recover(0),'1')
        self.assertEqual(self.recover(-10),'1')
        self.assertEqual(self.query('select public.recover_expired_claims(NULL);'),'2')
        self.assertEqual(self.recover(),'0')

    def test_mixed_safe_and_unsafe_direct_and_hub(self):
        self.fixture(1)
        self.fixture(2,hub=True)
        self.fixture(3,task='DISPATCHED')
        fourth=self.fixture(4,hub=True)
        self.query(f"update public.hub_inventory set inventory_status='RECONCILIATION_REQUIRED' where donation_id='{fourth['donation']}';")
        self.assertEqual(self.recover(),'4')
        self.assert_released(1)
        self.assert_released(2,members=3)
        self.assert_reconciliation(3)
        self.assert_reconciliation(4)
        self.assertEqual(self.query('select count(*) from public.listing_eligibility_refresh_jobs;'),'2')
        self.assertEqual(self.recover(),'0')

    def test_two_concurrent_recovery_calls_no_double_release(self):
        self.fixture(1); self.fixture(2)
        self.slow_first()
        with self.background("select public.recover_expired_claims(1);"):
            self.assertEqual(self.recover(1),'1')
        self.assert_released(1); self.assert_released(2)
        self.assertEqual(self.query("select count(*)=count(distinct claim_id) from public.audit_events where event_type='LEASE_RECOVERY';"),'t')

    def test_lease_extended_while_recovery_waits_is_rechecked(self):
        f=self.fixture()
        with self.background(f"begin; select 1 from public.claim_leases where lease_id='{f['lease']}' for update; update public.claim_leases set expires_at=clock_timestamp()+interval '1 hour' where lease_id='{f['lease']}'; select pg_sleep(2); commit;"):
            self.assertEqual(self.recover(),'0')
        self.assertEqual(self.state()['claim'],'ACTIVE')
        self.assertEqual(self.state()['audits'],0)

    def test_actual_start_before_expiry_then_recovery_never_reopens(self):
        f=self.fixture()
        self.query(f"update public.claim_leases set expires_at=clock_timestamp()+interval '500 milliseconds' where claim_id='{f['claim']}';")
        sql=f"begin; set local request.jwt.claim.sub='{OWNER}'; select public.start_pickup('{f['claim']}'); select pg_sleep(2); commit;"
        with self.background(sql):
            time.sleep(.55)
            self.assertEqual(self.recover(),'0')  # claim row locked by pickup
        self.assertEqual(self.recover(),'1')
        self.assertEqual(self.state()['donations'],['PICKUP_IN_PROGRESS'])
        self.assertEqual(self.state()['claim'],'RECONCILIATION_REQUIRED')
        self.assertEqual(self.state()['listing'],'CLAIMED')

    def test_actual_start_after_recovery_lock_rejects(self):
        f=self.fixture(); self.slow_first()
        with self.background('select public.recover_expired_claims(1);'):
            self.ngo(f"select public.start_pickup('{f['claim']}')",expect_error='NOT_ACTIVE_CLAIM_HOLDER')
        self.assert_released()

    def test_actual_route_assignment_crosses_expiry_then_reconciliation(self):
        f=self.fixture(); route=str(uuid.uuid4())
        self.query(f"insert into public.pickup_routes values('{route}','{OWNER}','DRAFT'); update public.claim_leases set expires_at=clock_timestamp()+interval '500 milliseconds' where claim_id='{f['claim']}';")
        with self.background(f"begin; set local request.jwt.claim.sub='{OWNER}'; select public.assign_task_to_route('{route}','{f['task']}',1); select pg_sleep(2); commit;"):
            time.sleep(.55)
            self.assertEqual(self.recover(),'1')
        self.assertEqual(self.state()['claim'],'RECONCILIATION_REQUIRED')
        self.assertEqual(self.state()['task'],'PLANNED')
        self.assertEqual(self.state()['listing'],'CLAIMED')

    def test_actual_cancel_before_expiry_then_recovery_no_duplicate(self):
        f=self.fixture()
        self.query(f"update public.claim_leases set expires_at=clock_timestamp()+interval '500 milliseconds' where claim_id='{f['claim']}';")
        with self.background(f"begin; set local request.jwt.claim.sub='{OWNER}'; select public.cancel_claim('{f['claim']}','{uuid.uuid4()}'); select pg_sleep(2); commit;"):
            time.sleep(.55)
            self.assertEqual(self.recover(),'0')
        self.assertEqual(self.recover(),'0')
        self.assertEqual(self.state()['claim_reason'],'NGO_CANCELLED_BEFORE_PICKUP')
        self.assertEqual(self.state()['recovery_audits'],0)

    def test_actual_cancel_after_recovery_rejects_without_second_release(self):
        f=self.fixture(); self.slow_first()
        with self.background('select public.recover_expired_claims(1);'):
            response=json.loads(self.ngo(f"select public.cancel_claim('{f['claim']}','{uuid.uuid4()}')"))
            self.assertEqual(response['outcome'],'REJECTED')
        self.assertEqual(self.state()['claim_reason'],'EXPIRED_SAFE_RELEASE')
        self.assertEqual(self.state()['recovery_audits'],1)

    def test_actual_concurrent_reclaim_has_one_winner_and_360_minute_lease(self):
        f=self.fixture(); self.recover()
        call=lambda: f"select public.claim_listing('{f['listing']}','{uuid.uuid4()}')"
        with self.background(f"begin; set local request.jwt.claim.sub='{OWNER}'; {call()}; select pg_sleep(2); commit;"):
            response=json.loads(self.ngo(call()))
        self.assertEqual(response['outcome'],'CONFLICT')
        self.assertEqual(self.query(f"select count(*) from public.donation_claims where listing_id='{f['listing']}' and claim_status='ACTIVE';"),'1')
        self.assertEqual(self.query(f"select bool_and(abs(extract(epoch from (le.expires_at-le.issued_at)))-21600<1) from public.claim_leases le join public.donation_claims c using(claim_id) where c.listing_id='{f['listing']}' and c.claim_status='ACTIVE';"),'t')
        self.assertEqual(self.recover(),'0')

    def test_actual_completed_claim_is_never_recovered(self):
        f=self.fixture()
        self.query(f"update public.claim_leases set expires_at=clock_timestamp()+interval '1 hour' where claim_id='{f['claim']}';")
        self.ngo(f"select public.start_pickup('{f['claim']}'); select public.complete_pickup('{f['claim']}',true)")
        self.assertEqual(self.recover(),'0')
        self.assertEqual(self.state()['claim'],'COMPLETED')
        self.assertEqual(self.state()['donations'],['COLLECTED'])

    def test_batch_failure_retries_without_partial_audits(self):
        self.fixture(1); second=self.fixture(2)
        self.query(f"""create or replace function public.auto_fail() returns trigger language plpgsql as $$
          begin if new.event_type='LEASE_RECOVERY' and new.claim_id='{second['claim']}'::uuid then
            raise exception 'INJECTED_PERSISTENT_AUDIT_ERROR'; end if; return new; end $$;
          create trigger auto_fail before insert on public.audit_events for each row execute function public.auto_fail();""")
        before=self.snapshot()
        for _ in range(2):
            self.recover(expect_error='INJECTED_PERSISTENT_AUDIT_ERROR')
            self.assertEqual(self.snapshot(),before)
        self.query('drop trigger auto_fail on public.audit_events;')
        self.assertEqual(self.recover(),'2')
        self.assert_released(1); self.assert_released(2)

    def test_retry_after_lock_timeout(self):
        f=self.fixture(); before=self.snapshot()
        with self.locked('donations','donation_id',f['donation']):
            self.query("set lock_timeout='100ms'; select public.recover_expired_claims(100);",expect_error='lock timeout')
            self.assertEqual(self.snapshot(),before)
        self.assertEqual(self.recover(),'1'); self.assert_released()

    def test_unauthorized_roles_cannot_invoke_even_with_forged_role_setting(self):
        self.fixture()
        for role in ('anon','authenticated'):
            self.query(f"set role {role}; set request.jwt.claim.role='service_role'; select public.recover_expired_claims(1);",expect_error='permission denied')
        self.assertEqual(self.state()['claim'],'ACTIVE')

    def test_reconciliation_pair_is_excluded(self):
        f=self.fixture()
        self.query(f"update public.donation_claims set claim_status='RECONCILIATION_REQUIRED' where claim_id='{f['claim']}'; update public.claim_leases set lease_status='RECONCILIATION_REQUIRED' where claim_id='{f['claim']}'; insert into public.claim_reconciliation_cases(claim_id,listing_id,source_type,case_status) values('{f['claim']}','{f['listing']}','DIRECT_DONATION','OPEN');")
        before=self.snapshot(); self.assertEqual(self.recover(),'0'); self.assertEqual(self.snapshot(),before)

    def test_characterize_active_pair_with_open_case_is_currently_reopened(self):
        # Confirmed anomaly-path probe, NOT a passing safety acceptance assertion.
        # Production FK/CHECK constraints do not prohibit this cross-table mismatch.
        for n,status in ((1,'OPEN'),(2,'MANUAL_REVIEW')):
            f=self.fixture(n)
            self.query(f"insert into public.claim_reconciliation_cases(claim_id,listing_id,source_type,case_status) values('{f['claim']}','{f['listing']}','DIRECT_DONATION','{status}');")
        self.assertEqual(self.recover(),'2')
        for n in (1,2):
            self.assertEqual(self.state(n)['claim'],'RELEASED')
            self.assertEqual(self.state(n)['donations'],['AVAILABLE'])
            self.assertEqual(self.state(n)['cases'],1)
        self.assertEqual(self.query("select count(*) from public.claim_reconciliation_cases where case_status in('OPEN','MANUAL_REVIEW');"),'2')

    def test_review_only_guard_preserves_open_cases_and_reconciles(self):
        before_acl=self.query("select proacl::text from pg_proc where oid='public.recover_expired_claims(integer)'::regprocedure;")
        self.apply_proposal()  # Full reviewed transaction, disposable clone ONLY.
        for n,status in ((1,'OPEN'),(2,'MANUAL_REVIEW')):
            f=self.fixture(n)
            self.query(f"insert into public.claim_reconciliation_cases(claim_id,listing_id,source_type,case_status) values('{f['claim']}','{f['listing']}','DIRECT_DONATION','{status}');")
        self.assertEqual(self.recover(),'2')
        self.assert_reconciliation(1); self.assert_reconciliation(2)
        self.assertEqual(self.query('select string_agg(case_status,\',\' order by claim_id) from public.claim_reconciliation_cases;'),'OPEN,MANUAL_REVIEW')
        self.assertEqual(self.recover(),'0')
        self.assertEqual(self.query('select count(*) from public.listing_eligibility_refresh_jobs;'),'0')
        self.assertEqual(self.query("select proacl::text from pg_proc where oid='public.recover_expired_claims(integer)'::regprocedure;"),before_acl)

    def test_review_only_guard_keeps_safe_direct_and_hub_recovery(self):
        self.apply_proposal()
        self.fixture(1); self.fixture(2,hub=True)
        self.assertEqual(self.recover(),'2')
        self.assert_released(1); self.assert_released(2,members=3)

    def proposal_cron_fixture(self):
        self.query("insert into cron.job values(3,'geolock-expired-claim-recovery','* * * * *','isolated-unused-command','postgres','postgres',false);")

    def apply_proposal(self):
        self.proposal_cron_fixture()
        self.query(PROPOSAL.read_text(encoding='utf-8'))
        source=(ROOT/'supabase/tests/fixtures/claim_recovery_open_case_proposal_function.sql').read_text(encoding='utf-8')
        tag=chr(36)+'function'+chr(36)
        self.assertEqual(self.query("select replace(prosrc,E'\\r\\n',E'\\n') from pg_proc where oid='public.recover_expired_claims(integer)'::regprocedure;").strip(),source.split(tag)[1].strip())

    def test_review_only_package_rejects_source_drift(self):
        self.proposal_cron_fixture()
        self.query(base.recovery.routine('recover_expired_claims'))
        before=self.query("select md5(prosrc) from pg_proc where oid='public.recover_expired_claims(integer)'::regprocedure;")
        self.query(PROPOSAL.read_text(encoding='utf-8'),expect_error='RECOVERY_SOURCE_OR_SECURITY_REVIEW_REQUIRED')
        self.assertEqual(self.query("select md5(prosrc) from pg_proc where oid='public.recover_expired_claims(integer)'::regprocedure;"),before)

    def test_review_only_package_rejects_acl_drift(self):
        self.proposal_cron_fixture()
        self.query('grant execute on function public.recover_expired_claims(integer) to authenticated;')
        self.query(PROPOSAL.read_text(encoding='utf-8'),expect_error='RECOVERY_SOURCE_OR_SECURITY_REVIEW_REQUIRED')
        self.assertEqual(self.query("select has_function_privilege('authenticated','public.recover_expired_claims(integer)','EXECUTE');"),'t')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',action='store_true')
    parser.add_argument('--pg-bin',type=Path)
    args=parser.parse_args()
    if not args.run_isolated:
        parser.error('--run-isolated required; no external connections supported')
    bins={n:str(args.pg_bin/(n+('.exe' if os.name=='nt' else ''))) if args.pg_bin else shutil.which(n)
          for n in ('initdb','pg_ctl','psql')}
    if any(not v or not Path(v).is_file() for v in bins.values()):
        parser.error('initdb, pg_ctl and psql required')
    AutomaticRecoveryTests.bins=bins
    unittest.main(argv=[__file__],verbosity=2)
