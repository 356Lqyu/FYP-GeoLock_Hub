"""Stage 3F: actual migration + patched recovery, NEW loopback PostgreSQL ONLY.

No external DSN/URL accepted. Reuses Stage 3E's real RPC source, real lifecycle
helpers/listing triggers, explicit auth/cron/road doubles and reduced schema.
"""
from pathlib import Path
import argparse
import json
import os
import shutil
import unittest

import claim_recovery_automatic_isolated_test as automatic

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = (ROOT/'supabase/migrations/20261030_fix_claim_recovery_unresolved_reconciliation.sql').read_text(encoding='utf-8')


class ReconciliationGuardTests(unittest.TestCase):
    run_process = automatic.AutomaticRecoveryTests.__dict__['run_process']
    query = automatic.AutomaticRecoveryTests.__dict__['query']
    cleanup_cluster = automatic.AutomaticRecoveryTests.__dict__['cleanup_cluster']
    snapshot = automatic.AutomaticRecoveryTests.snapshot
    fixture = automatic.AutomaticRecoveryTests.fixture
    state = automatic.AutomaticRecoveryTests.state
    recover = automatic.AutomaticRecoveryTests.recover
    assert_released = automatic.AutomaticRecoveryTests.assert_released
    assert_reconciliation = automatic.AutomaticRecoveryTests.assert_reconciliation
    locked = automatic.AutomaticRecoveryTests.locked
    background = automatic.AutomaticRecoveryTests.background
    ngo = automatic.AutomaticRecoveryTests.ngo
    slow_first = automatic.AutomaticRecoveryTests.slow_first
    many = automatic.AutomaticRecoveryTests.many

    @classmethod
    def setUpClass(cls):
        automatic.AutomaticRecoveryTests.setUpClass.__func__(cls)
        cls.query("""alter table public.claim_reconciliation_cases add column opened_at timestamptz default clock_timestamp();
          alter table public.claim_reconciliation_cases add column resolved_at timestamptz;
          alter table public.claim_reconciliation_cases add column resolution_reason text;
          alter table cron.job_run_details add column runid bigint;
          alter table cron.job_run_details add column start_time timestamptz;
          alter table cron.job_run_details add column end_time timestamptz;
          alter table cron.job_run_details add column return_message text;""")

    def reset_deployed(self):
        automatic.AutomaticRecoveryTests.setUp(self)
        self.query("""insert into cron.job values
          (1,'geolock-ngo-eligibility-refresh','* * * * *','fixture-ngo','postgres','postgres',true),
          (2,'geolock-listing-eligibility-refresh','* * * * *','fixture-listing','postgres','postgres',true),
          (3,'geolock-expired-claim-recovery','* * * * *',
           'set lock_timeout = ''5s''; set statement_timeout = ''50s''; select public.recover_expired_claims(100);',
           'postgres','postgres',false);""")

    def setUp(self):
        self.reset_deployed()
        self.query(MIGRATION)  # ENTIRE forward-only migration, including COMMIT.

    def case(self,f,status='OPEN'):
        self.query(f"""insert into public.claim_reconciliation_cases(
          claim_id,listing_id,donation_id,source_type,case_status,resolution_reason)
          values('{f['claim']}','{f['listing']}',{'NULL' if len(f['donations'])>1 else chr(39)+f['donation']+chr(39)},
            '{'HUB_BATCH' if len(f['donations'])>1 else 'DIRECT_DONATION'}','{status}','preserve-existing-case-evidence');""")
        return self.query(f"select to_jsonb(rc) from public.claim_reconciliation_cases rc where claim_id='{f['claim']}';")

    def test_open_manual_review_direct_hub_matrix_and_safe_candidates_continue(self):
        cases=[]
        for n,hub,status in ((1,False,'OPEN'),(2,False,'MANUAL_REVIEW'),(3,True,'OPEN'),(4,True,'MANUAL_REVIEW')):
            f=self.fixture(n,hub=hub)
            existing=self.case(f,status)
            cases.append((n,f,existing))
        self.fixture(5); self.fixture(6,hub=True)
        before=self.snapshot()
        self.assertEqual(self.recover(),'6')
        after=self.snapshot()
        for n,f,existing in cases:
            self.assert_reconciliation(n)
            self.assertEqual(self.state(n)['donations'],['CLAIMED']*len(f['donations']))
            self.assertEqual(self.state(n)['task'],'CONFIRMED')
            self.assertEqual(self.query(f"select to_jsonb(rc) from public.claim_reconciliation_cases rc where claim_id='{f['claim']}';"),existing)
            for table,key,values in (('listings','listing_id',[f['listing']]),('donations','donation_id',f['donations']),
                                     ('pickup_tasks','task_id',[f['task']])):
                self.assertEqual([x for x in before[table] if x[key] in values],
                                 [x for x in after[table] if x[key] in values])
            audit=json.loads(self.query(f"select to_jsonb(a) from public.audit_events a where claim_id='{f['claim']}';"))
            self.assertEqual((audit['event_type'],audit['previous_state'],audit['requested_state'],audit['resulting_state'],audit['outcome']),
                             ('LEASE_RECOVERY','ACTIVE','RECONCILIATION_REQUIRED','RECONCILIATION_REQUIRED','SUCCESS'))
            self.assertEqual(audit['reason_code'],'HANDOVER_OR_ROUTE_ACTIVITY_UNCERTAIN')
            self.assertEqual((audit['claim_id'],audit['lease_id']),(f['claim'],f['lease']))
        self.assert_released(5); self.assert_released(6,members=3)
        self.assertEqual(len(after['listing_eligibility_refresh_jobs']),2)
        self.assertEqual(before['cron.job'],after['cron.job'])
        self.assertEqual(self.recover(),'0')
        self.assertEqual(self.snapshot(),after)

    def test_unrelated_open_case_does_not_fence_another_listing(self):
        f=self.fixture(1); self.case(f,'OPEN')
        self.fixture(2)
        self.assertEqual(self.recover(),'2')
        self.assert_reconciliation(1); self.assert_released(2)

    def historical_case(self,f,status='MANUAL_REVIEW'):
        older='90000000-0000-0000-0000-'+f['claim'][-12:]
        self.query(f"""insert into public.donation_claims(claim_id,listing_id,claim_status,claimed_at,closed_at,close_reason)
          values('{older}','{f['listing']}','RELEASED',clock_timestamp()-interval '3 days',clock_timestamp()-interval '2 days','historical');
          insert into public.claim_reconciliation_cases(claim_id,listing_id,source_type,case_status)
            values('{older}','{f['listing']}','{'HUB_BATCH' if len(f['donations'])>1 else 'DIRECT_DONATION'}','{status}');""")
        return self.query(f"select to_jsonb(rc) from public.claim_reconciliation_cases rc where claim_id='{older}';")

    def test_characterize_claim_only_proposal_misses_shared_listing_review(self):
        # Stage 3E's preliminary proposal is tested ONLY in this disposable clone.
        self.query((ROOT/'supabase/tests/fixtures/claim_recovery_open_case_proposal_function.sql').read_text(encoding='utf-8'))
        f=self.fixture(); self.historical_case(f)
        self.assertEqual(self.recover(),'1')
        self.assertEqual(self.state()['claim'],'RELEASED')
        self.assertEqual(self.state()['listing'],'AVAILABLE')
        self.assertEqual(self.query('select case_status from public.claim_reconciliation_cases;'),'MANUAL_REVIEW')

    def test_shared_listing_historical_review_fences_direct_and_hub(self):
        for n,hub in ((1,False),(2,True)):
            f=self.fixture(n,hub=hub)
            before_case=self.historical_case(f)
            self.assertEqual(self.recover(),'1')
            self.assert_reconciliation(n)
            older='90000000-0000-0000-0000-'+f['claim'][-12:]
            self.assertEqual(self.query(f"select to_jsonb(rc) from public.claim_reconciliation_cases rc where claim_id='{older}';"),before_case)
            self.assertEqual(self.state(n)['donations'],['CLAIMED']*len(f['donations']))
        self.assertEqual(self.query('select count(*) from public.claim_reconciliation_cases;'),'4')
        self.assertEqual(self.query('select count(*) from public.listing_eligibility_refresh_jobs;'),'0')
        self.assertEqual(self.recover(),'0')

    def test_case_writer_claim_lock_serializes_and_worker_rechecks_after_commit(self):
        f=self.fixture()
        sql=f"""begin;
          select 1 from public.donation_claims where claim_id='{f['claim']}' for update;
          insert into public.claim_reconciliation_cases(claim_id,listing_id,source_type,case_status)
            values('{f['claim']}','{f['listing']}','DIRECT_DONATION','MANUAL_REVIEW');
          select pg_sleep(2); commit;"""
        # Fixture writer honors claim-first locking. It deliberately leaves the
        # inconsistent ACTIVE pair, emulating the anomaly this guard must fence.
        with self.background(sql):
            self.assertEqual(self.recover(),'0')
        self.assertEqual(self.recover(),'1')
        self.assert_reconciliation()
        self.assertEqual(self.query('select case_status from public.claim_reconciliation_cases;'),'MANUAL_REVIEW')

    def test_two_workers_reconcile_once_without_duplicate_cases_or_audits(self):
        one=self.fixture(1); two=self.fixture(2,hub=True)
        self.case(one,'OPEN'); self.case(two,'MANUAL_REVIEW')
        self.query(f"""create or replace function public.auto_slow() returns trigger language plpgsql as $$
          begin if new.claim_id='{one['claim']}'::uuid and new.lease_status='RECONCILIATION_REQUIRED' then
            perform pg_sleep(2); end if; return null; end $$;
          create trigger auto_slow after update on public.claim_leases for each row execute function public.auto_slow();""")
        with self.background('select public.recover_expired_claims(1);'):
            self.assertEqual(self.recover(1),'1')
        self.assert_reconciliation(1); self.assert_reconciliation(2)
        self.assertEqual(self.query('select count(*) from public.claim_reconciliation_cases;'),'2')
        self.assertEqual(self.query("select count(*)=count(distinct claim_id) from public.audit_events where event_type='LEASE_RECOVERY';"),'t')

    def test_later_failure_rolls_back_case_state_changes_then_retry_succeeds(self):
        one=self.fixture(1); two=self.fixture(2)
        self.case(one,'MANUAL_REVIEW')
        before=self.snapshot()
        self.query(f"""create or replace function public.auto_fail() returns trigger language plpgsql as $$
          begin if new.event_type='LEASE_RECOVERY' and new.claim_id='{two['claim']}'::uuid then
            raise exception 'INJECTED_LATER_AUDIT_FAILURE'; end if; return new; end $$;
          create trigger auto_fail before insert on public.audit_events for each row execute function public.auto_fail();""")
        self.recover(expect_error='INJECTED_LATER_AUDIT_FAILURE')
        self.assertEqual(self.snapshot(),before)
        self.query('drop trigger auto_fail on public.audit_events;')
        self.assertEqual(self.recover(),'2')
        self.assert_reconciliation(1); self.assert_released(2)

    def test_migration_and_repeat_invocation_preserve_three_completed_recoveries(self):
        # Seed exact original identities/versions with Stage 3B's fixture and the
        # deployed recovery. No recovery function or wrapper is run against DEV.
        automatic.base.GuardedWrapperTests.setUp(self)
        self.assertEqual(self.recover(),'3')
        self.query("update public.listing_eligibility_refresh_jobs set job_status='COMPLETED';")
        before=self.snapshot()
        self.query(MIGRATION)
        self.assertEqual(self.snapshot(),before)
        self.assertEqual(self.recover(),'0')
        self.assertEqual(self.snapshot(),before)
        self.assertEqual(self.query("select string_agg(listing_version::text||'/'||eligibility_generation::text,',' order by listing_version,eligibility_generation) from public.listings;"),'3/2,3/2,5/3')

    def test_migration_preserves_metadata_and_does_not_replay(self):
        data=json.loads(self.query("""select json_build_object('md5',md5(replace(prosrc,E'\\r\\n',E'\\n')),
          'args',pg_get_function_arguments(oid),'result',pg_get_function_result(oid),'owner',pg_get_userbyid(proowner),
          'definer',prosecdef,'config',proconfig,'acl',proacl::text) from pg_proc
          where oid='public.recover_expired_claims(integer)'::regprocedure;"""))
        self.assertEqual(data,dict(md5='5ff6d8719db9681aae6f444b89dfbaee',args='p_limit integer DEFAULT 100',result='integer',
          owner='postgres',definer=True,config=['search_path=pg_catalog, public, extensions, pg_temp'],
          acl='{postgres=X/postgres,service_role=X/postgres}'))
        self.query(MIGRATION,expect_error='RECOVERY_SOURCE_OR_SECURITY_REVIEW_REQUIRED')

    def test_postdeploy_queries_run_readonly_on_new_source_and_completed_records(self):
        automatic.base.GuardedWrapperTests.setUp(self)
        self.assertEqual(self.recover(),'3')
        self.query(MIGRATION)
        before=self.snapshot()
        sql=(ROOT/'supabase/tests/claim_recovery_reconciliation_guard_postdeploy.sql').read_text(encoding='utf-8')
        result=self.query('begin read only;\n'+sql+'\nrollback;')
        self.assertTrue(result.startswith('t\n'))  # expected_new_source_and_security
        self.assertIn('5ff6d8719db9681aae6f444b89dfbaee',result)
        last=result.splitlines()[-3:]
        self.assertEqual(len(last),3)
        self.assertTrue(all(line.split('|')[-1]=='t' for line in last),last)
        self.assertEqual(self.snapshot(),before)

    def test_source_drift_guard_rolls_back_without_overwriting(self):
        self.reset_deployed()
        self.query(automatic.base.recovery.routine('recover_expired_claims'))
        before=self.query("select md5(prosrc) from pg_proc where oid='public.recover_expired_claims(integer)'::regprocedure;")
        self.query(MIGRATION,expect_error='RECOVERY_SOURCE_OR_SECURITY_REVIEW_REQUIRED')
        self.assertEqual(self.query("select md5(prosrc) from pg_proc where oid='public.recover_expired_claims(integer)'::regprocedure;"),before)

    def test_acl_drift_guard_preserves_grant_option(self):
        self.reset_deployed()
        self.query('grant execute on function public.recover_expired_claims(integer) to service_role with grant option;')
        before=self.query("select proacl::text from pg_proc where oid='public.recover_expired_claims(integer)'::regprocedure;")
        self.query(MIGRATION,expect_error='RECOVERY_SOURCE_OR_SECURITY_REVIEW_REQUIRED')
        self.assertEqual(self.query("select proacl::text from pg_proc where oid='public.recover_expired_claims(integer)'::regprocedure;"),before)

    def test_cron_guard_does_not_change_active_job(self):
        self.reset_deployed(); self.query('update cron.job set active=true where jobid=3;')
        before=self.snapshot()
        self.query(MIGRATION,expect_error='PAUSED_UNUSED_RECOVERY_CRON_REQUIRED')
        self.assertEqual(self.snapshot(),before)
        self.assertEqual(self.query("select md5(replace(prosrc,E'\\r\\n',E'\\n')) from pg_proc where oid='public.recover_expired_claims(integer)'::regprocedure;"),'50110ff20115c4e5d46380e8e3f8b94c')

    def test_postcondition_failure_rolls_back_function_replacement(self):
        self.reset_deployed()
        variant=MIGRATION.replace('5ff6d8719db9681aae6f444b89dfbaee','00000000000000000000000000000000')
        self.query(variant,expect_error='RECOVERY_GUARD_POSTCONDITION_FAILED')
        self.assertEqual(self.query("select md5(replace(prosrc,E'\\r\\n',E'\\n')) from pg_proc where oid='public.recover_expired_claims(integer)'::regprocedure;"),'50110ff20115c4e5d46380e8e3f8b94c')


# Re-execute established safety/concurrency tests on the NEW migration body.
# Do not inherit old-source reproductions or Stage 3E proposal deployment tests.
for name in (
    'test_empty_and_repeated_completed_recovery_are_noops','test_future_active_and_exact_boundary',
    'test_configured_limit_100_then_remaining_one','test_zero_negative_and_null_limit_semantics',
    'test_mixed_safe_and_unsafe_direct_and_hub','test_two_concurrent_recovery_calls_no_double_release',
    'test_lease_extended_while_recovery_waits_is_rechecked','test_actual_start_before_expiry_then_recovery_never_reopens',
    'test_actual_start_after_recovery_lock_rejects','test_actual_route_assignment_crosses_expiry_then_reconciliation',
    'test_actual_cancel_before_expiry_then_recovery_no_duplicate','test_actual_cancel_after_recovery_rejects_without_second_release',
    'test_actual_concurrent_reclaim_has_one_winner_and_360_minute_lease','test_actual_completed_claim_is_never_recovered',
    'test_batch_failure_retries_without_partial_audits','test_retry_after_lock_timeout',
    'test_unauthorized_roles_cannot_invoke_even_with_forged_role_setting','test_reconciliation_pair_is_excluded'):
    setattr(ReconciliationGuardTests,name,getattr(automatic.AutomaticRecoveryTests,name))

for name in (
    'test_direct_valid_deadline_and_null_deadline_release',
    'test_expired_listing_before_recovery_requires_reconciliation',
    'test_boundary_crossed_while_waiting_for_direct_donation_lock',
    'test_boundary_crossed_while_waiting_for_hub_batch_lock',
    'test_late_expiration_after_decision_rolls_back_instead_of_skipping_restore',
    'test_whole_hub_batch_restores_all_members_and_keeps_inventory',
    'test_route_assignment_and_route_stop_require_reconciliation',
    'test_planned_and_dispatched_pickups_never_reopen',
    'test_uncertain_inventory_and_existing_manual_review_case_are_preserved',
    'test_second_candidate_audit_failure_rolls_back_entire_batch',
    'test_bounded_batch_and_skip_locked_claim',
    'test_lock_timeout_on_second_candidate_rolls_back_earlier_release',
    'test_statement_timeout_rolls_back_release_and_audits',
    'test_owner_signature_search_path_grants_and_audit_outcomes'):
    setattr(ReconciliationGuardTests,'test_persisted_'+name[5:],
            getattr(automatic.base.recovery.RecoveryExpirationTests,name))


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
    ReconciliationGuardTests.bins=bins
    unittest.main(argv=[__file__],verbosity=2)
