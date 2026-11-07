"""Stage 3D: two complete guarded transactions in a NEW loopback PostgreSQL.

No target DSN/URL accepted; no DEV access. Reuses Stage 3B's actual recovery,
lifecycle and listing triggers, reduced schema, auth/cron/road-resolver doubles.
Never alters a deployed migration or the approved recovery implementation.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import unittest

import claim_recovery_guarded_wrapper_isolated_test as prior

ROOT = Path(__file__).resolve().parents[2]
FIX = ROOT / 'supabase/tests/fixtures'
SQL = {
    1:(FIX/'claim_recovery_remaining_01_aa3cd6d2.sql').read_text(encoding='utf-8'),
    2:(FIX/'claim_recovery_remaining_02_9a2ab42b.sql').read_text(encoding='utf-8'),
}
ROWS = prior.ROWS
OLD = ROWS[0][0]
HISTORICAL = '10000000-0000-0000-0000-000000000001'


class RemainingRecoveryTests(unittest.TestCase):
    run_process = prior.GuardedWrapperTests.__dict__['run_process']
    query = prior.GuardedWrapperTests.__dict__['query']
    cleanup_cluster = prior.GuardedWrapperTests.__dict__['cleanup_cluster']
    snapshot = prior.GuardedWrapperTests.snapshot
    concurrent = prior.GuardedWrapperTests.concurrent
    slow_recovery = prior.GuardedWrapperTests.slow_recovery

    @classmethod
    def setUpClass(cls):
        prior.GuardedWrapperTests.setUpClass.__func__(cls)
        cls.query("""alter table cron.job_run_details add column runid bigint;
          alter table cron.job_run_details add column start_time timestamptz;
          alter table cron.job_run_details add column end_time timestamptz;
          alter table cron.job_run_details add column return_message text;
          create table public.hub_receipts(donation_id uuid);
          create table public.hub_reservations(donation_id uuid);""")

    def setUp(self):
        prior.GuardedWrapperTests.setUp(self)
        # Reproduce the committed Stage 3B outcome with its ACTUAL full wrapper.
        self.query(prior.FINAL)
        self.query(f"""
          update public.listing_eligibility_refresh_jobs set job_status='COMPLETED'
            where listing_id='{ROWS[0][2]}' and eligibility_generation=2;
          insert into public.ngo_listing_road_eligibility values('{ROWS[0][2]}','completed-stage3c-cache');
          -- Historical released claim sharing the last candidate's listing.
          -- Its linked listing legitimately changes when the CURRENT claim recovers;
          -- the historical claim/lease/task themselves must remain byte-for-byte.
          insert into public.donation_claims(claim_id,listing_id,claim_status,claimed_at,closed_at,close_reason)
            values('{HISTORICAL}','{ROWS[2][2]}','RELEASED','2026-10-19','2026-10-20','HISTORICAL');
          insert into public.claim_leases(lease_id,claim_id,lease_status,issued_at,expires_at,closed_at,release_reason)
            values('10000000-0000-0000-0000-000000000002','{HISTORICAL}','RELEASED',
              '2026-10-19','2026-10-19 06:00+00','2026-10-20','HISTORICAL');
          insert into public.pickup_tasks(task_id,claim_id,listing_id,task_status)
            values('10000000-0000-0000-0000-000000000003','{HISTORICAL}','{ROWS[2][2]}','STALE');
        """)
        self.initial = self.snapshot()
        self.phase = getattr(getattr(self,self._testMethodName),'phase',1)
        if self.phase == 2:
            self.execute_and_verify(1)

    def claim_bundle(self, state, index):
        c,le,l,d,t,*_ = ROWS[index]
        return {
            table:[x for x in state[table] if x[key] == value]
            for table,key,value in [('donation_claims','claim_id',c),('claim_leases','lease_id',le),
              ('pickup_tasks','task_id',t),('listings','listing_id',l),('donations','donation_id',d),
              ('audit_events','claim_id',c),('listing_eligibility_refresh_jobs','listing_id',l),
              ('ngo_listing_road_eligibility','listing_id',l)]
        }

    def execute_and_verify(self, phase):
        before = self.snapshot()
        self.query(SQL[phase])  # COMPLETE unchanged file including COMMIT.
        after = self.snapshot()
        c,le,l,d,t,_,version = ROWS[phase]
        for table,key,value,status,expected in (
            ('donation_claims','claim_id',c,'claim_status','RELEASED'),
            ('claim_leases','lease_id',le,'lease_status','RELEASED'),
            ('pickup_tasks','task_id',t,'task_status','STALE'),
            ('listings','listing_id',l,'listing_status','AVAILABLE'),
            ('donations','donation_id',d,'donation_status','AVAILABLE')):
            self.assertEqual(next(x[status] for x in after[table] if x[key]==value),expected)
        listing = next(x for x in after['listings'] if x['listing_id']==l)
        self.assertEqual((listing['listing_version'],listing['eligibility_generation']),
                         (version+1,2 if phase==1 else 3))
        for table,reason in [('donation_claims','close_reason'),('claim_leases','release_reason')]:
            row = next(x for x in after[table] if x['claim_id']==c)
            self.assertEqual(row[reason],'EXPIRED_SAFE_RELEASE')
            self.assertIsNotNone(row['closed_at'])
        events = [x for x in after['audit_events'] if x['claim_id']==c]
        self.assertEqual(len(events),2)
        self.assertEqual({x['event_type'] for x in events},{'LEASE_RECOVERY','DONATION_STATUS_CHANGED'})
        self.assertTrue(all(x['lease_id']==le and x['outcome']=='SUCCESS' for x in events))
        job = next(x for x in after['listing_eligibility_refresh_jobs'] if x['listing_id']==l)
        self.assertEqual(job['eligibility_generation'],2 if phase==1 else 3)
        self.assertNotIn(l,[x['listing_id'] for x in after['ngo_listing_road_eligibility']])
        self.assertEqual(after['claim_reconciliation_cases'],[])
        self.assertEqual(before['cron.job'],after['cron.job'])
        for other in {0,1,2}-{phase}:
            self.assertEqual(self.claim_bundle(before,other),self.claim_bundle(after,other))
        # Protect every non-target claim/lease/task, including the historical claim.
        for table in ('donation_claims','claim_leases','pickup_tasks'):
            self.assertEqual([x for x in before[table] if x['claim_id']!=c],
                             [x for x in after[table] if x['claim_id']!=c])
        self.assertEqual(self.claim_bundle(self.initial,0),self.claim_bundle(after,0))
        self.assert_verification(phase)
        return after

    def assert_verification(self,phase):
        sql = (FIX/f'claim_recovery_remaining_verify_{phase}.sql').read_text(encoding='utf-8')
        rows = self.query(sql).splitlines()
        self.assertEqual(len(rows),3)
        self.assertTrue(all(row.split('|')[-1]=='t' for row in rows),rows)

    def assert_abort(self,error,sql=None):
        before = self.snapshot()
        self.query(sql or SQL[self.phase],expect_error=error)
        self.assertEqual(self.snapshot(),before)

    def scenario(self,case):
        c,le,l,d,t,_,version = ROWS[self.phase]
        if case == 'full_commit':
            self.execute_and_verify(self.phase)
        elif case == 'wrong_role':
            self.assert_abort('CLEAN_POSTGRES_SESSION_REQUIRED','set role service_role;\n'+SQL[self.phase])
        elif case == 'source_drift':
            patched = prior.recovery.PATCH[prior.recovery.PATCH.index('CREATE OR REPLACE FUNCTION'):prior.recovery.PATCH.index('-- Fail atomically')]
            self.query(patched.replace('declare\n','-- isolated drift\ndeclare\n',1))
            self.assert_abort('RECOVERY_DEFINITION_OR_SECURITY_CHANGED')
        elif case == 'acl_drift':
            self.query('grant execute on function public.recover_expired_claims(integer) to authenticated;')
            self.assert_abort('RECOVERY_DEFINITION_OR_SECURITY_CHANGED')
        elif case == 'cron_active':
            self.query('update cron.job set active=true where jobid=3;')
            self.assert_abort('CRON_STATE_CHANGED')
        elif case == 'candidate_changed':
            self.query(f"update public.claim_leases set expires_at=clock_timestamp()+interval '1 day' where claim_id='{c}';")
            self.assert_abort('CANDIDATE_SET_OR_ORDER_CHANGED')
        elif case == 'new_older_candidate':
            prior.recovery.RecoveryExpirationTests.fixture(self,n=4)
            self.assert_abort('CANDIDATE_SET_OR_ORDER_CHANGED')
        elif case == 'task_changed':
            self.query(f"update public.pickup_tasks set task_status='PLANNED' where task_id='{t}';")
            self.assert_abort('TARGET_PRECONDITION_FAILED')
        elif case == 'version_changed':
            self.query(f"update public.listings set listing_version=listing_version+1 where listing_id='{l}';")
            self.assert_abort('TARGET_PRECONDITION_FAILED')
        elif case == 'prior_recovery_changed':
            self.query(f"update public.pickup_tasks set task_status='CONFIRMED' where claim_id='{OLD}';")
            self.assert_abort('PRIOR_RECOVERY_STATE_CHANGED')
        elif case == 'prior_audit_missing':
            self.query(f"delete from public.audit_events where claim_id='{OLD}' and event_type='LEASE_RECOVERY';")
            self.assert_abort('PRIOR_RECOVERY_STATE_CHANGED')
        elif case == 'unexpected_return':
            # Isolated test-only wrapper variant; actual recovery still called once.
            sql = SQL[self.phase].replace('v_count := public.recover_expired_claims(1);',
                'v_count := public.recover_expired_claims(1);\n  v_count := 0; -- injected return fault')
            self.assert_abort('EXPECTED_ONE_PROCESSED_CLAIM',sql)
        elif case == 'audit_failure':
            self.query("""create or replace function public.wrapper_audit() returns trigger language plpgsql as $$
              begin if new.event_type='LEASE_RECOVERY' then new.reason_code:='WRONG_REASON'; end if; return new; end $$;
              create trigger wrapper_audit before insert on public.audit_events for each row execute function public.wrapper_audit();""")
            self.assert_abort('AUDIT_POSTCONDITION_FAILED')
        elif case == 'missing_enqueue':
            self.query('alter table public.listings disable trigger trg_listing_road_eligibility;')
            self.assert_abort('ELIGIBILITY_REFRESH_NOT_ENQUEUED')
        elif case == 'deferred_failure':
            self.query("""create or replace function public.wrapper_deferred() returns trigger language plpgsql as $$
              begin raise exception 'INJECTED_DEFERRED_FAILURE'; end $$;
              create constraint trigger wrapper_deferred after update on public.donations
                deferrable initially deferred for each row execute function public.wrapper_deferred();""")
            self.assert_abort('INJECTED_DEFERRED_FAILURE')
        elif case == 'table_lock':
            with self.concurrent('begin; lock table public.donation_claims in row share mode; select pg_sleep(2); rollback;'):
                self.assert_abort('could not obtain lock on relation')
        elif case == 'enqueue_lock_timeout':
            generation = 2 if self.phase==1 else 3
            with self.concurrent(f"begin; insert into public.listing_eligibility_refresh_jobs(listing_id,eligibility_generation) values('{l}',{generation}); select pg_sleep(7); rollback;"):
                self.assert_abort('lock timeout')
        elif case == 'other_core_mutation':
            self.query(f"""create or replace function public.wrapper_audit() returns trigger language plpgsql as $$
              begin if new.event_type='LEASE_RECOVERY' then
                update public.pickup_tasks set route_snapshot='INJECTED' where claim_id='{HISTORICAL}';
              end if; return null; end $$;
              create trigger wrapper_audit after insert on public.audit_events for each row execute function public.wrapper_audit();""")
            self.assert_abort('OTHER_CLAIM_CORE_RECORDS_CHANGED')
        elif case == 'extra_protected_audit':
            self.query(f"""create or replace function public.wrapper_audit() returns trigger language plpgsql as $$
              begin if new.event_type='LEASE_RECOVERY' then
                insert into public.audit_events(claim_id,event_type) values('{OLD}','INJECTED_EXTRA_EVENT');
              end if; return null; end $$;
              create trigger wrapper_audit after insert on public.audit_events for each row execute function public.wrapper_audit();""")
            self.assert_abort('AUDIT_POSTCONDITION_FAILED')
        else:
            raise AssertionError(case)

    def test_sequential_full_commits_and_replay_rejection(self):
        first = self.execute_and_verify(1)
        second = self.execute_and_verify(2)
        self.assertEqual(self.claim_bundle(first,1),self.claim_bundle(second,1))
        self.assertEqual(self.claim_bundle(self.initial,0),self.claim_bundle(second,0))
        self.assertEqual(len(second['audit_events']),6)
        self.assert_abort('CANDIDATE_SET_OR_ORDER_CHANGED',SQL[1])
        self.assert_abort('CANDIDATE_SET_OR_ORDER_CHANGED',SQL[2])

    def test_second_cannot_run_before_first(self):
        self.assert_abort('CANDIDATE_SET_OR_ORDER_CHANGED',SQL[2])

    def test_readonly_preflight_and_initial_verification(self):
        self.assert_verification(0)
        sql = (FIX/'claim_recovery_remaining_preflight.sql').read_text(encoding='utf-8')
        result = self.query('begin read only;\n'+sql+'\nrollback;')
        self.assertIn('50110ff20115c4e5d46380e8e3f8b94c',result)

    def test_second_failure_preserves_first_commit(self):
        self.execute_and_verify(1)
        before = self.snapshot()
        self.query('alter table public.listings disable trigger trg_listing_road_eligibility;')
        self.assert_abort('ELIGIBILITY_REFRESH_NOT_ENQUEUED',SQL[2])
        self.assertEqual(self.snapshot(),before)

    def test_actual_dependency_fingerprints_and_unchanged_artifacts(self):
        fingerprints = json.loads(self.query("""select json_object_agg(proname,md5(replace(prosrc,E'\\r\\n',E'\\n')))
          from pg_proc where pronamespace='public'::regnamespace and proname in(
          'recover_expired_claims','geolock_lock_listing_donations','geolock_transition_listing_donations',
          'geolock_assert_donation_lifecycle','geolock_validate_donation_at_commit',
          'enforce_donation_transition','enforce_listing_transition',
          'geolock_prepare_listing_eligibility','geolock_listing_eligibility_trigger');"""))
        self.assertEqual(fingerprints,{
          'recover_expired_claims':'50110ff20115c4e5d46380e8e3f8b94c',
          'geolock_lock_listing_donations':'90816e7c6db3606dc8b6451a899d8036',
          'geolock_transition_listing_donations':'c7f2124b18d75e5af2d7785daeeaa890',
          'geolock_assert_donation_lifecycle':'3e7df59a90533e0708c51767889d930e',
          'geolock_validate_donation_at_commit':'8a6d5eb35e5c21705d2ec7c6900826db',
          'enforce_donation_transition':'c0cbbe68574ea42fafe9d2f60d08cff1',
          'enforce_listing_transition':'c65f4b675734d8c28816066ea9f05603',
          'geolock_prepare_listing_eligibility':'3c497b7081433cefc548ac8761347096',
          'geolock_listing_eligibility_trigger':'623342a706a4ca4e0a607fba4ffbf7e1'})
        for sql in SQL.values():
            self.assertEqual(sql.count('public.recover_expired_claims(1);'),1)
            self.assertIn('IN EXCLUSIVE MODE NOWAIT',sql)
            self.assertIn('SET CONSTRAINTS ALL IMMEDIATE;',sql)
            self.assertTrue(sql.rstrip().endswith('COMMIT;'))
            self.assertNotIn('cron.alter_job',sql)
            self.assertNotIn('CREATE OR REPLACE',sql)
        for relative,expected in {
          'supabase/migrations/20261029_fix_claim_recovery_listing_expiration_race.sql':'064b1e4cd5b5cd38e1f77b91364af5ed99221926455d5d64ae7a4b70c1c31e7d',
          'supabase/tests/fixtures/claim_recovery_guarded_final.sql':'2d4833146341d45ecb97829a7e72ac3f2c8908561dc658c0d7605e28342d3e02',
        }.items():
            self.assertEqual(hashlib.sha256((ROOT/relative).read_bytes()).hexdigest(),expected)


def make_case(phase,case):
    def run(self):
        self.scenario(case)
    run.phase = phase
    return run


for phase in (1,2):
    for case in ('full_commit','wrong_role','source_drift','acl_drift','cron_active','candidate_changed',
                 'new_older_candidate','task_changed','version_changed','prior_recovery_changed','prior_audit_missing','unexpected_return',
                 'audit_failure','missing_enqueue','deferred_failure','table_lock','enqueue_lock_timeout',
                 'other_core_mutation','extra_protected_audit'):
        setattr(RemainingRecoveryTests,f'test_step_{phase}_{case}',make_case(phase,case))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',action='store_true')
    parser.add_argument('--pg-bin',type=Path)
    args = parser.parse_args()
    if not args.run_isolated:
        parser.error('--run-isolated required; no external database is supported')
    bins = {n:str(args.pg_bin/(n+('.exe' if os.name=='nt' else ''))) if args.pg_bin else shutil.which(n)
            for n in ('initdb','pg_ctl','psql')}
    if any(not v or not Path(v).is_file() for v in bins.values()):
        parser.error('initdb, pg_ctl and psql required')
    RemainingRecoveryTests.bins = bins
    unittest.main(argv=[__file__],verbosity=2)
