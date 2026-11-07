"""Locked live-state activation proposal, NEW disposable loopback PostgreSQL.

No recovery invocation. Real recovery definition installed for source guards;
cron.alter_job remains the explicit transactional table double. No real scheduler.
"""
from pathlib import Path
import argparse
import json
import os
import shutil
import unittest
import claim_recovery_e2e_isolated_test as fixture
import claim_recovery_live_activation_package as live


class LiveTests(fixture.E2ETests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.query("""alter database postgres set timezone='UTC';
          create table public.hub_reservations(reservation_id uuid primary key,donation_id uuid);
          create table public.hub_receipts(receipt_id uuid primary key,donation_id uuid);""")

    def setUp(self):
        super().setUp()
        self.query('truncate public.hub_reservations,public.hub_receipts;')

    def refresh_manifest(self):
        super().refresh_manifest()
        sql=self.sql('01_preflight.sql').rstrip().removesuffix(';')
        self.manifest['target_audit_md5']=self.query("select md5(coalesce(x.audits,'[]'::jsonb)::text) from ("+sql+") x;")

    def sql(self,name):
        m={**self.manifest,'timezone':'UTC','max_activation_seconds':300,
          'deadline_mode':'server_clock_immediately_before_activation',
          'activation_token':live.TOKEN,
          'operator_confirmation':self.manifest.get('operator_confirmation',live.CONFIRMATION),
          'execution_approved':self.manifest.get('execution_approved',True)}
        return live.artifacts(m)[name]

    def test_live_old_external_timestamp_is_replaced_by_real_locked_read(self):
        self.manifest['baseline_at']='2000-01-01T00:00:00+00'
        before=self.snapshot()
        receipt=json.loads(self.query(self.sql('03_activate.sql')))
        self.assertEqual(receipt['window_seconds'],300)
        self.assertEqual(self.query('select command from cron.job where jobid=3;'),live.MARKED_COMMAND)
        after=self.snapshot(); before.pop('cron.job'); after.pop('cron.job')
        self.assertEqual(before,after)
        self.pause()

    def test_live_committed_activation_cannot_replay_even_before_first_tick(self):
        self.query(self.sql('03_activate.sql')); self.pause()
        self.reject_activation('POST_CANARY_CRON_BASELINE_DRIFT')
        self.assertEqual(self.query('select count(*) from cron.job_run_details where jobid=3;'),'12')

    def test_live_explicit_approval_gate_rejects_review_only(self):
        self.manifest['execution_approved']=False
        self.reject_activation('EXPLICIT_EXECUTION_APPROVAL_AND_SUPERVISION_REQUIRED')

    def test_live_operator_phrase_gate_rejects(self):
        self.manifest['operator_confirmation']='REVIEW_ONLY'
        self.reject_activation('EXPLICIT_EXECUTION_APPROVAL_AND_SUPERVISION_REQUIRED')

    def test_live_changed_target_cannot_be_hidden_by_runtime_freshness(self):
        self.query(f"update public.pickup_tasks set task_status='PLANNED' where task_id='{self.f['task']}';")
        self.reject_activation('TARGET_OR_SNAPSHOT_CHANGED')

    def test_live_changed_unrelated_data_rejects(self):
        self.query("insert into public.donations values('33333333-3333-3333-3333-333333333333','HUB_COLLECTION','SUBMITTED',5,now(),'untouched',null);")
        self.reject_activation('TARGET_OR_SNAPSHOT_CHANGED')

    def test_live_route_phantom_rejects(self):
        self.query(f"insert into public.pickup_route_stops(task_id) values('{self.f['task']}');")
        self.refresh_manifest()
        self.reject_activation('SOLE_SAFE_CANDIDATE_REQUIRED')

    def test_live_custody_reservation_and_receipt_reject(self):
        for table,key in [('hub_reservations','reservation_id'),('hub_receipts','receipt_id')]:
            self.query(f"insert into public.{table}({key},donation_id) values(gen_random_uuid(),'{self.f['donation']}');")
            self.reject_activation('SOLE_SAFE_CANDIDATE_REQUIRED')
            self.query(f'truncate public.{table};')

    def test_live_existing_claim_row_locker_aborts_nowait(self):
        with self.locked('donation_claims','claim_id',self.f['claim']):
            self.reject_activation('could not obtain lock on relation')

    def test_live_concurrent_route_writer_aborts_nowait(self):
        with self.background(f"begin; insert into public.pickup_route_stops(task_id) values('{self.f['task']}'); select pg_sleep(2); commit;"):
            self.query(self.sql('03_activate.sql'),expect_error='could not obtain lock on relation')
        self.assertEqual(self.query('select active from cron.job where jobid=3;'),'f')

    def test_live_target_writer_cannot_invalidate_locked_read(self):
        sql=self.sql('03_activate.sql').replace(
          "v_manifest:=v_manifest||jsonb_build_object('baseline_at',clock_timestamp());",
          "v_manifest:=v_manifest||jsonb_build_object('baseline_at',clock_timestamp()); PERFORM pg_sleep(2);")
        with self.background(sql,app='isolated-live-activation'):
            self.query(f"set lock_timeout='100ms'; update public.claim_leases set expires_at=expires_at where lease_id='{self.f['lease']}';",expect_error='lock timeout')
        self.assertEqual(self.query('select active from cron.job where jobid=3;'),'t')
        self.pause()

    def test_live_failed_postcondition_rolls_back_marker_and_activation(self):
        before=self.snapshot()
        sql=self.sql('03_activate.sql').replace('IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND active',
          'IF true OR NOT EXISTS(SELECT 1 FROM cron.job WHERE jobid=3 AND active')
        self.query(sql,expect_error='ACTIVATION_POSTCONDITION_FAILED')
        self.assertEqual(before,self.snapshot())

    def test_live_timezone_normalized_transaction_locally(self):
        receipt=json.loads(self.query("set timezone='Asia/Kuala_Lumpur';"+self.sql('03_activate.sql')))
        self.assertEqual(receipt['window_seconds'],300)
        self.pause()

    def test_live_second_candidate_still_rejects(self):
        self.fixture(2); self.refresh_manifest()
        self.assertEqual(self.query("select count(*) from public.donation_claims where claim_status='ACTIVE';"),'2')
        self.reject_activation('SOLE_SAFE_CANDIDATE_REQUIRED')

    def test_live_source_drift_still_rejects(self):
        self.query(fixture.canary.guard.automatic.base.recovery.routine('recover_expired_claims'))
        self.reject_activation('SOURCE_OR_SECURITY_DRIFT')

    def test_live_unresolved_case_still_rejects(self):
        self.case(self.f,'MANUAL_REVIEW'); self.refresh_manifest()
        self.assertEqual(self.query("select count(*) from public.claim_reconciliation_cases where case_status='MANUAL_REVIEW';"),'1')
        self.reject_activation('SOLE_SAFE_CANDIDATE_REQUIRED')

    def test_live_concurrent_cron_configuration_writer_aborts_nowait(self):
        with self.background("begin; update cron.job set active=active where jobid=3; select pg_sleep(2); commit;"):
            self.query(self.sql('03_activate.sql'),expect_error='could not obtain lock on relation')
        self.assertEqual(self.query('select active from cron.job where jobid=3;'),'f')

    def test_live_target_audit_drift_rejects(self):
        self.manifest['target_audit_md5']='0'*32
        self.reject_activation('TARGET_AUDIT_HISTORY_CHANGED')

    def test_live_actual_recovery_simulated_tick_repeat_pause_and_verification(self):
        self.query(self.sql('03_activate.sql'))
        self.assertEqual(self.tick(),'1')
        before=self.snapshot()
        self.assertEqual(self.tick(),'0')
        self.assertEqual(before,self.snapshot())
        self.query("update public.listing_eligibility_refresh_jobs set job_status='COMPLETED';")
        self.pause()
        result=self.result()
        self.assertTrue(result['all_checks_pass'],result)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run-isolated',action='store_true')
    p.add_argument('--pg-bin',type=Path)
    a=p.parse_args()
    if not a.run_isolated:
        p.error('--run-isolated required; no external DSN supported')
    LiveTests.bins={n:str(a.pg_bin/(n+('.exe' if os.name=='nt' else ''))) if a.pg_bin else shutil.which(n)
      for n in ('initdb','pg_ctl','psql')}
    if any(not v or not Path(v).is_file() for v in LiveTests.bins.values()):
        p.error('initdb/pg_ctl/psql required')
    suite=unittest.TestSuite(LiveTests(n) for n in sorted(LiveTests.__dict__) if n.startswith('test_live_'))
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
