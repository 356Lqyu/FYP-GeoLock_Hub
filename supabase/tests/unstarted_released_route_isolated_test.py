"""Fresh loopback PG17 only. Synthetic fixtures, real protected RPCs/guards.
Never accepts an existing database, DSN, Supabase credentials or remote host.
"""
import argparse
import json
import multiprocessing as mp
import os
from pathlib import Path
import unittest
from uuid import uuid4
import route_resolution_isolated_test as base

MIGRATION = 'supabase/migrations/20261104130000_unstarted_released_route_cancellation.sql'


class SafeCancellationTests(base.ResolutionTests):
    def setUp(self):
        super().setUp()
        self.reset_with_fix(self.unstarted_template)

    def reset_with_fix(self, template):
        self.reset_template(template)
        self.lane.apply(MIGRATION)

    def detail(self):
        return self.rpc('get_my_authorized_route', {'p_route': self.rid}, readonly=True)

    def cancel(self, who='ngo'):
        return self.rpc('cancel_my_unstarted_route', {'p_route': self.rid}, who=who)

    def release(self, stops=None):
        for stop in stops or self.stops:
            claim = stop['claim_id']
            self.lane.sql(f"UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '7 hours',expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{claim}';")
            self.seed_uncertain_claim(claim)  # synthetic pre-existing uncertainty
            self.rpc('defer_my_pickup_for_reconciliation', {'p_claim': claim, 'p_request': str(uuid4())})
            a = self.rpc('submit_claim_reconciliation', {'p_claim': claim, 'p_handover_confirmed': False, 'p_request': str(uuid4())})
            self.assertEqual(a['outcome'], 'AWAITING_COUNTERPART')
            b = self.rpc('submit_claim_reconciliation', {'p_claim': claim, 'p_handover_confirmed': False, 'p_request': str(uuid4())},
                         who='hub' if stop.get('source_type')=='HUB_BATCH' else 'donor')
            self.assertEqual(b['claim_status'], 'RELEASED')

    def history(self):
        return self.scalar(f"""SELECT jsonb_build_object(
          'items',(SELECT jsonb_agg(to_jsonb(i) ORDER BY ordinal) FROM routing_private.items i WHERE route_id='{self.rid}'),
          'stops',(SELECT jsonb_agg(to_jsonb(s) ORDER BY stop_order) FROM public.pickup_route_stops s WHERE route_id='{self.rid}'),
          'tasks',(SELECT jsonb_agg(to_jsonb(t) ORDER BY task_id) FROM public.pickup_tasks t JOIN routing_private.items i USING(task_id) WHERE i.route_id='{self.rid}'),
          'claims',(SELECT jsonb_agg(to_jsonb(c) ORDER BY claim_id) FROM public.donation_claims c JOIN public.pickup_tasks t USING(claim_id) JOIN routing_private.items i USING(task_id) WHERE i.route_id='{self.rid}'),
          'leases',(SELECT jsonb_agg(to_jsonb(le) ORDER BY lease_id) FROM public.claim_leases le JOIN public.pickup_tasks t USING(claim_id) JOIN routing_private.items i USING(task_id) WHERE i.route_id='{self.rid}'),
          'deferred',(SELECT jsonb_agg(to_jsonb(d) ORDER BY task_id) FROM routing_private.deferred_stops d WHERE route_id='{self.rid}'),
          'evidence',(SELECT jsonb_agg(to_jsonb(e) ORDER BY request_id) FROM public.claim_reconciliation_evidence e))""")

    def assert_ineligible(self):
        self.assertFalse(self.detail()['no_collection_cancellation_eligible'])
        with self.assertRaises(base.psycopg.Error):
            self.cancel()
        self.assertIsNone(self.scalar(f"SELECT closed_at FROM routing_private.bindings WHERE route_id='{self.rid}'"))

    def test_safe_01_two_party_release_cancel_retry_and_history(self):
        self.release()
        before = self.history()
        self.assertTrue(self.detail()['can_cancel'])
        self.assertFalse(self.detail()['can_close'])
        retries = self.race(self.cancel, self.cancel)
        self.assertTrue(all('result' in r for r in retries), retries)
        self.cancel()
        self.assertEqual(before, self.history())
        d = self.detail()
        self.assertEqual((d['route_status'], d['cancellation_outcome']), ('CANCELLED', 'NO_COLLECTION'))
        self.assertFalse(d['can_close']); self.assertFalse(d['can_cancel'])
        self.assertFalse(self.scalar(f"SELECT fleet_private.vehicle_has_hold('{self.vehicle_id}')"))
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.audit_events WHERE entity_id='{self.rid}' AND reason_code='ALL_MEMBERS_RELEASED_NO_COLLECTION'"), 1)
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.audit_events WHERE entity_id='{self.rid}' AND details->>'depot_return_confirmed'='true'"), 0)

    def test_safe_02_one_active_member_is_preserved(self):
        self.release([self.stops[0]])
        self.assertFalse(self.detail()['no_collection_cancellation_eligible'])
        self.assertTrue(self.detail()['can_cancel'])  # explicit cancellation only
        self.assertEqual(self.detail()['route_status'],'AUTHORISED')
        self.assertTrue(next(s for s in self.detail()['stops'] if s['claim_id']==self.stops[1]['claim_id'])['can_start'])

    def test_safe_03_ordinary_active_plan_cancel_unchanged(self):
        self.assertFalse(self.detail()['no_collection_cancellation_eligible'])
        self.assertTrue(self.detail()['can_cancel'])
        self.cancel()
        self.assertEqual(self.detail()['cancellation_outcome'],'UNSTARTED_PLAN_CANCELLED')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.pickup_tasks t JOIN routing_private.items i USING(task_id) WHERE i.route_id='{self.rid}' AND t.task_status='CONFIRMED'"), 2)

    def test_safe_04_started_no_collection_keeps_hold(self):
        self.rpc('start_pickup', {'p_claim': self.stops[0]['claim_id']})
        self.assert_ineligible()

    def test_safe_05_collected_mixed_closure_preserves_return_and_replay(self):
        self.release([self.stops[0]])
        self.rpc('start_pickup', {'p_claim': self.stops[1]['claim_id']})
        self.rpc('complete_pickup', {'p_claim': self.stops[1]['claim_id'], 'p_handover_confirmed': True})
        self.assertTrue(self.detail()['can_close'])
        self.assert_ineligible()
        args = {'p_route': self.rid, 'p_depot_return_confirmed': False, 'p_request': str(uuid4())}
        with self.assertRaisesRegex(base.psycopg.Error, 'DEPOT_RETURN_CONFIRMATION_REQUIRED'):
            self.rpc('close_my_resolved_route', args)
        args['p_depot_return_confirmed'] = True
        result = self.rpc('close_my_resolved_route', args)
        self.assertEqual(result, self.rpc('close_my_resolved_route', args))
        self.assertEqual(result['route_status'], 'ABANDONED')

    def test_safe_06_pending_and_conflicting_reconciliation(self):
        c = self.stops[0]['claim_id']; self.seed_uncertain_claim(c)
        self.rpc('defer_my_pickup_for_reconciliation', {'p_claim': c, 'p_request': str(uuid4())})
        self.rpc('submit_claim_reconciliation', {'p_claim': c, 'p_handover_confirmed': False, 'p_request': str(uuid4())})
        self.assert_ineligible()
        self.rpc('submit_claim_reconciliation', {'p_claim': c, 'p_handover_confirmed': True, 'p_request': str(uuid4())}, who='donor')
        self.assert_ineligible()

    def test_safe_07_missing_evidence_fails_closed(self):
        self.release()
        # Only the disposable superuser fixture can remove protected evidence.
        self.lane.sql('ALTER TABLE public.claim_reconciliation_evidence DISABLE TRIGGER coordination_evidence_immutable; DELETE FROM public.claim_reconciliation_evidence; ALTER TABLE public.claim_reconciliation_evidence ENABLE TRIGGER coordination_evidence_immutable;')
        self.assert_ineligible()
        self.assertFalse(self.detail()['can_close'])

    def test_safe_08_contradictory_start_audit_fails_closed(self):
        self.release()
        self.lane.sql(f"INSERT INTO public.audit_events(entity_type,entity_id,event_type,claim_id,outcome) VALUES('CLAIM','{self.stops[0]['claim_id']}','START_PICKUP','{self.stops[0]['claim_id']}','SUCCESS');")
        self.assert_ineligible()

    def test_safe_09_foreign_access_and_private_helpers(self):
        self.release(); before = self.history()
        with self.assertRaisesRegex(base.psycopg.Error, 'NOT_ROUTE_OWNER'):
            self.cancel('other')
        with self.assertRaises(base.psycopg.Error):
            self.rpc('get_my_authorized_route', {'p_route': self.rid}, who='other', readonly=True)
        self.assertEqual(before, self.history())
        self.assertFalse(self.scalar("SELECT has_function_privilege('authenticated','routing_private.can_cancel_released_unstarted(uuid)','EXECUTE')"))

    def test_safe_10_unstarted_mixed_close_rejects_true_assertion(self):
        self.release()
        with self.assertRaisesRegex(base.psycopg.Error, 'ROUTE_FINAL_OUTCOME_NOT_AUTHORIZED'):
            self.rpc('close_my_resolved_route', {'p_route': self.rid, 'p_depot_return_confirmed': True, 'p_request': str(uuid4())})
        self.assertEqual(self.detail()['route_status'], 'AUTHORISED')

    def test_safe_11_automatic_safe_expiry_and_three_way_race(self):
        self.lane.sql("UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '7 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE lease_status='ACTIVE';")
        results = self.race(lambda: self.scalar('SELECT public.recover_expired_claims(100)'), self.cancel,
                            lambda: self.rpc('start_pickup', {'p_claim': self.stops[0]['claim_id']}))
        self.assertFalse(any(r.get('result') for r in results if isinstance(r.get('result'), dict)))
        d = self.detail()
        if d['route_status'] != 'CANCELLED':
            self.assertTrue(d['no_collection_cancellation_eligible']); self.cancel()
        self.assertEqual(self.detail()['route_status'], 'CANCELLED')
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donation_claims WHERE claim_status='RELEASED'"), 2)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.pickup_tasks WHERE task_status='STALE'"), 2)

    def test_safe_12_reader_is_read_only_and_migration_drift_aborts(self):
        self.release(); before = self.history()
        self.assertTrue(self.detail()['no_collection_cancellation_eligible'])
        self.assertEqual(before, self.history())
        with self.assertRaisesRegex(AssertionError, 'SAFE_CANCELLATION_SOURCE_DRIFT'):
            self.lane.apply(MIGRATION)

    def test_safe_13_missing_lease_is_not_hidden_by_join(self):
        self.release()
        self.lane.sql(f"DELETE FROM public.claim_leases WHERE claim_id='{self.stops[0]['claim_id']}';")
        self.assert_ineligible()

    def test_safe_14_pending_route_case_protects_released_members(self):
        self.release()
        self.lane.sql(f"INSERT INTO resolution_private.cases(route_id,ngo_id,status,reason,manifest_digest) VALUES('{self.rid}','{base.auto.existing.NGO}','MANUAL_REVIEW','EXECUTION_BUDGET_EXCEEDED',resolution_private.manifest('{self.rid}'));")
        self.assert_ineligible()

    def test_safe_15_hub_no_handover_preserves_batched_goods(self):
        self.reset_with_fix(self.hub_unstarted_template)
        self.rid, self.stops, self.vehicle_id = self.hub_meta
        self.release()
        before = self.history()
        self.assertTrue(self.detail()['no_collection_cancellation_eligible'])
        self.cancel()
        self.assertEqual(before, self.history())
        self.assertEqual(self.scalar("SELECT count(*) FROM public.hub_inventory WHERE inventory_status='BATCHED'"), 3)
        self.assertFalse(self.scalar(f"SELECT fleet_private.vehicle_has_hold('{self.vehicle_id}')"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated', action='store_true', required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    args = parser.parse_args(); runtime = args.runtime.resolve()
    assert runtime.name.startswith('geolock-spatial-runtime-') and (runtime/'pgsql/bin/postgres.exe').is_file()
    for key in list(os.environ):
        if key.upper().startswith(('PG','GEOLOCK','SUPABASE')) or key.upper() in ('DATABASE_URL','DB_URL'):
            os.environ.pop(key, None)
    SafeCancellationTests.runtime = runtime
    suite = unittest.TestSuite(SafeCancellationTests(n) for n in sorted(dir(SafeCancellationTests)) if n.startswith('test_safe_'))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if hasattr(SafeCancellationTests, 'lane'):
        summary = dict(tests=result.testsRun, failures=len(result.failures), errors=len(result.errors),
                       passed=result.wasSuccessful(), dev_connections=0, scope='Disposable loopback PG17; synthetic auth/storage/cron')
        SafeCancellationTests.lane.save('safe-cancellation-result.json', summary)
        print(json.dumps({'evidence': str(SafeCancellationTests.out), **summary}))
    return not result.wasSuccessful()

if __name__ == '__main__':
    mp.freeze_support()
    raise SystemExit(main())
