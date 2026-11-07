"""Stage 3G scripts in a NEW disposable loopback PostgreSQL ONLY.

Actual approved recovery and existing reduced lifecycle fixture. cron.alter_job
is an explicit transactional table-update double: NO real pg_cron scheduling,
Supabase cron privileges, network connections or DEV mutation are tested.
"""
from pathlib import Path
import argparse
import os
import shutil
import unittest
import claim_recovery_reconciliation_guard_isolated_test as guard

ROOT=Path(__file__).resolve().parents[2]
ACTIVATE=(ROOT/'supabase/tests/review-only/claim_recovery_canary_activation.sql').read_text(encoding='utf-8')
PAUSE=(ROOT/'supabase/tests/review-only/claim_recovery_pause.sql').read_text(encoding='utf-8')


class CanaryTests(guard.ReconciliationGuardTests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.query("""create function cron.alter_job(job_id bigint,schedule text default null,
          command text default null,database text default null,username text default null,
          active boolean default null) returns void language plpgsql as $$
          begin update cron.job j set schedule=coalesce($2,j.schedule),
            command=coalesce($3,j.command),database=coalesce($4,j.database),
            username=coalesce($5,j.username),active=coalesce($6,j.active)
            where j.jobid=$1; end $$;""")

    def setUp(self):
        super().setUp()
        self.query("""insert into cron.job_run_details(jobid,status,runid,start_time,end_time)
          values(1,'succeeded',1,now()-interval '1 minute',now()),
                (2,'succeeded',2,now()-interval '1 minute',now());""")

    def reject(self,error,sql=ACTIVATE):
        before=self.snapshot()
        self.query(sql,expect_error=error)
        self.assertEqual(before,self.snapshot())

    def test_canary_activate_pause_commit_without_business_changes(self):
        before=self.snapshot()
        self.query(ACTIVATE)
        self.assertEqual(self.query("select active and schedule='* * * * *' and command like '%recover_expired_claims(1);' from cron.job where jobid=3;"),'t')
        after=self.snapshot()
        self.assertEqual(before.pop('cron.job')[:2],after.pop('cron.job')[:2])
        self.assertEqual(before,after)
        self.assertEqual(self.query('select count(*) from cron.job_run_details where jobid=3;'),'0')
        self.query(PAUSE)
        self.assertEqual(self.query('select active from cron.job where jobid=3;'),'f')

    def test_canary_rejects_superseded_source(self):
        self.query(guard.automatic.base.recovery.routine('recover_expired_claims'))
        self.reject('APPROVED_CASE_GUARD_DEPLOYMENT_REQUIRED')

    def test_canary_rejects_backlog(self):
        self.fixture()
        self.reject('INITIAL_NOOP_CANARY_REQUIRES_EMPTY_BACKLOG')

    def test_canary_rejects_unresolved_case(self):
        f=self.fixture()
        self.case(f)
        self.query(f"update public.claim_leases set expires_at=clock_timestamp()+interval '1 day' where claim_id='{f['claim']}';")
        self.reject('INITIAL_CANARY_REQUIRES_NO_UNRESOLVED_CASES')

    def test_canary_rejects_failed_eligibility_worker(self):
        self.query("update cron.job_run_details set status='failed' where jobid=1;")
        self.reject('RECENT_HEALTHY_ELIGIBILITY_WORKERS_REQUIRED')

    def test_canary_rejects_wrong_identity(self):
        self.reject('CLEAN_POSTGRES_SESSION_REQUIRED',ACTIVATE.replace('BEGIN;','BEGIN;\nSET LOCAL ROLE service_role;',1))

    def test_canary_rejects_active_job_replay(self):
        self.query(ACTIVATE)
        self.reject('CRON_BASELINE_CHANGED')

    def test_canary_postcondition_failure_rolls_back_job_change(self):
        self.reject('CANARY_CRON_POSTCONDITION_FAILED',ACTIVATE.replace(
            'IF (SELECT jsonb_agg(to_jsonb(j) ORDER BY jobid) FROM cron.job j WHERE jobid IN(1,2))',
            'IF true OR (SELECT jsonb_agg(to_jsonb(j) ORDER BY jobid) FROM cron.job j WHERE jobid IN(1,2))'))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',action='store_true')
    parser.add_argument('--pg-bin',type=Path)
    args=parser.parse_args()
    if not args.run_isolated:
        parser.error('--run-isolated required; no external DSN accepted')
    CanaryTests.bins={n:str(args.pg_bin/(n+('.exe' if os.name=='nt' else ''))) if args.pg_bin else shutil.which(n)
        for n in ('initdb','pg_ctl','psql')}
    if any(not v or not Path(v).is_file() for v in CanaryTests.bins.values()):
        parser.error('initdb, pg_ctl and psql required')
    # Only new canary tests, not inherited 46 Stage 3F tests.
    suite=unittest.TestSuite(CanaryTests(n) for n in sorted(CanaryTests.__dict__) if n.startswith('test_canary_'))
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
