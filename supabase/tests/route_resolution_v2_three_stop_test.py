"""Focused LOCAL disposable V2-shape regression; no existing DSN/profile accepted.

Uses the established loopback PG17 harness, real protected RPCs and validator.
Auth/Storage/cron adapters and all custody statements are synthetic test facts.
"""
import argparse
import hashlib
import json
import multiprocessing as mp
import os
from pathlib import Path
import secrets
import tempfile
import unittest
from uuid import uuid4

import route_resolution_isolated_test as base

auto = base.auto
PIN = 'a9fe7713fe2ffd65816743b52abd43695d63d1ecbb45fd216983c4a952eca557'
DONOR_B = auto.existing.uid('v2-focused-donor-b')


class V2ThreeStopTests(base.ResolutionTests):
    # The reused helper constructs its whole participant map eagerly; this lane
    # never invokes a HUB operation, but must provide its inert map entry.
    hub_actor = auto.existing.uid('unused-v2-focused-hub')

    @classmethod
    def setUpClass(cls):
        assert auto.assembly.digest(base.ROOT / base.MIGRATION) == PIN
        auto.AutomaticTests.setUpClass.__func__(cls)
        cls.lane.hashes[base.MIGRATION] = PIN
        cls.lane.hashes[base.PER_STOP] = auto.assembly.digest(base.ROOT / base.PER_STOP)
        cls.lane.hashes[base.DONOR_READ] = auto.assembly.digest(base.ROOT / base.DONOR_READ)
        cls.lane.hashes[str(Path(__file__).relative_to(base.ROOT)).replace('\\', '/')] = auto.assembly.digest(Path(__file__))
        cls.lane.hashes[base.RECEIPT] = auto.assembly.digest(base.ROOT / base.RECEIPT)
        cls.lane.apply(base.RECEIPT)
        cls.lane.apply(base.MIGRATION)
        cls.lane.apply(base.DONOR_READ)
        cls.lane.apply(base.PER_STOP)
        assert cls.lane.sql('SELECT enabled FROM resolution_private.config;') == 'f'
        cls.lane.sql("""CREATE ROLE geolock_local_resolver LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
          GRANT geolock_route_resolver TO geolock_local_resolver;
          INSERT INTO resolution_private.operators VALUES('geolock_local_resolver','LOCAL V2 SYNTHETIC RESOLVER',true);
          UPDATE resolution_private.config SET enabled=true;""")
        fixture = cls()
        auto.AutomaticTests.setUp(fixture)
        try:
            # An independent real protected completion/closure, not a forged status.
            fixture.prepare()
            fixture.authorize()
            cls.v3_route = fixture.rid
            cls.v3_vehicle = fixture.vehicle['vehicle_id']
            v3 = fixture.session.rpc('get_my_authorized_route', {'p_route': cls.v3_route})
            fixture.session.rpc('start_pickup', {'p_claim': v3['stops'][0]['claim_id']})
            fixture.session.rpc('complete_pickup', {'p_claim': v3['stops'][0]['claim_id'], 'p_handover_confirmed': True})
            fixture.session.rpc('close_my_collected_route', {'p_route': cls.v3_route, 'p_depot_return_confirmed': True})
            fixture.lane.sql(f"INSERT INTO auth.users(id,email) VALUES('{DONOR_B}','v2-source-b@local.invalid'); INSERT INTO public.user_profiles(user_id,full_name,role) VALUES('{DONOR_B}','LOCAL DONOR B','DONOR'); INSERT INTO public.donor_profiles(user_id) VALUES('{DONOR_B}');")
            cls.source_by_claim = {}
            for title, weight, donor in [('SYNTHETIC V2 A', 15, auto.existing.DONOR), ('SYNTHETIC V2 B', 12, auto.existing.DONOR), ('SYNTHETIC V2 C', 50, DONOR_B)]:
                request = str(uuid4())
                photo = f'{donor}/pending/{request}/{uuid4()}.jpg'
                items = json.dumps([dict(category_id=auto.existing.uid('category'), item_name=title, quantity=1, unit_weight_kg=weight)])
                images = json.dumps([dict(storage_path=photo, content_type='image/jpeg', size_bytes=100)])
                did = fixture.lane.sql(f"SET request.jwt.claim.sub='{donor}'; SET request.jwt.claim.role='authenticated'; INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('geolock-donation-images','{photo}','{{\"size\":100,\"mimetype\":\"image/jpeg\"}}'); SELECT public.create_donation_with_images('{request}','{title}','SYNTHETIC','LOCAL',3.01,101.01,'{items}'::jsonb,'102','{images}'::jsonb);")
                lid = fixture.lane.sql(f"SELECT listing_id FROM public.listings WHERE donation_id='{did}';")
                fixture.lane.sql('SELECT public.process_listing_eligibility_refresh_jobs();')
                claim = fixture.session.rpc('claim_listing', {'p_listing': lid, 'p_request': str(uuid4())})
                assert claim['outcome'] == 'SUCCESS'
                cls.source_by_claim[claim['claim_id']] = donor
            vehicle = fixture.session.rpc('register_my_vehicle', {'p_request_id': str(uuid4()), 'p_label': 'LOCAL V2 THREE STOP', 'p_vehicle_type': 'VAN', 'p_capacity_kg': 500, 'p_fixed_cost_rm': 10, 'p_distance_cost_rm_per_km': 1, 'p_max_route_duration_min': 60, 'p_available': True})
            cls.vehicle_id = vehicle['vehicle_id']
            policy = fixture.snapshot['policy_id']
            request = str(uuid4())
            snap = fixture.session.rpc('begin_my_routing_snapshot', {'p_request': request, 'p_policy': policy, 'p_vehicle_ids': [cls.vehicle_id]})
            result = fixture.worker.plan_and_authorize(fixture.session, snap['snapshot_id'], request)
            cls.rid = result['authorization']['route_ids'][0]
            detail = fixture.session.rpc('get_my_authorized_route', {'p_route': cls.rid})
            assert len(detail['stops']) == 3, 'EXACT_THREE_FIXTURE_NOT_AUTHORIZED'
            cls.stops = detail['stops']
            cls.v2_unstarted_template = 'v2_three_unstarted_' + uuid4().hex
            fixture.lane.sql('CREATE DATABASE ' + cls.v2_unstarted_template + ' TEMPLATE ' + fixture.db + ';', db='postgres')
            fixture.session.rpc('start_pickup', {'p_claim': cls.stops[0]['claim_id']})
            ids = ','.join("'" + s['claim_id'] + "'" for s in cls.stops)
            fixture.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id IN({ids}); SELECT public.recover_expired_claims(100);")
            cls.template = 'v2_exact_template_' + uuid4().hex
            cls.lane.sql('CREATE DATABASE ' + cls.template + ' TEMPLATE ' + fixture.db + ';', db='postgres')
            cls.lane.save('v2-three-stop-fixture.json', dict(scope='ISOLATED SYNTHETIC ONLY', source_by_claim=cls.source_by_claim, route_id=cls.rid, stops=cls.stops, unrelated_completed_v3=cls.v3_route, vehicle_id=cls.vehicle_id, migration_sha256=PIN))
        finally:
            fixture.doCleanups()
        cls.lane.db = 'postgres'

    def setUp(self):
        super().setUp()
        self.v3_before = self.v3_digest()
        self.addCleanup(lambda: self.assertEqual(self.v3_digest(), self.v3_before, 'UNRELATED_V3_CHANGED'))
        self.assertEqual(self.scalar(f"SELECT route_status FROM public.pickup_routes WHERE route_id='{self.v3_route}'"), 'COMPLETED')
        self.assertIsNotNone(self.scalar(f"SELECT closed_at FROM routing_private.bindings WHERE route_id='{self.v3_route}'"))
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='{self.v3_route}'"), 0)
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.audit_events WHERE entity_id='{self.v3_route}' AND event_type='CLOSE_COLLECTED_ROUTE' AND outcome='SUCCESS'"), 1)
        self.assertEqual(self.scalar(f"SELECT jsonb_agg(t.task_status ORDER BY i.ordinal) FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) WHERE i.route_id='{self.rid}'"), ['DISPATCHED', 'PLANNED', 'PLANNED'])
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.claim_reconciliation_cases WHERE claim_id IN(SELECT claim_id FROM public.pickup_tasks WHERE task_id IN(SELECT task_id FROM routing_private.items WHERE route_id='{self.rid}')) AND case_status='OPEN'"), 3)
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.claim_leases WHERE claim_id IN(SELECT claim_id FROM public.pickup_tasks WHERE task_id IN(SELECT task_id FROM routing_private.items WHERE route_id='{self.rid}')) AND lease_status='RECONCILIATION_REQUIRED' AND expires_at<clock_timestamp()"), 3)
        self.assert_holds()
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.pickup_tasks t JOIN routing_private.items i USING(task_id) JOIN public.listings l ON l.listing_id=t.listing_id JOIN public.donations d ON d.donation_id=l.donation_id WHERE i.route_id='{self.rid}' AND (l.listing_expires_at IS NULL OR l.listing_expires_at>clock_timestamp()) AND (d.availability_end IS NULL OR d.availability_end>clock_timestamp())"), 3)

    def rpc(self, name, params=None, who='ngo', readonly=False):
        if who != 'donor_b':
            return super().rpc(name, params, who, readonly)
        assert name in {'get_my_route_resolution','submit_route_resolution_evidence','get_my_route_resolution_receipt'}
        with auto.connect(self.lane.port, self.db, 'geolock_local_ngo_login') as conn:
            if readonly:
                conn.execute('BEGIN READ ONLY')
            conn.execute('SET LOCAL ROLE authenticated')
            conn.execute("SELECT set_config('request.jwt.claim.sub',%s,true),set_config('request.jwt.claim.role','authenticated',true)", (DONOR_B,))
            params = params or {}
            args = ','.join(k + ' => %s' for k in params)
            value = conn.execute('SELECT public.' + name + '(' + args + ')', list(params.values())).fetchone()[0]
            if readonly:
                conn.rollback()
            return value

    def source(self, stop):
        return 'donor_b' if self.source_by_claim[stop['claim_id']] == DONOR_B else 'donor'

    def consent(self, vehicle=True):
        for stop in self.stops:
            self.evidence(stop['task_id'], base.NO)
            self.evidence(stop['task_id'], base.NO, self.source(stop))
        if vehicle:
            self.evidence(None, base.RETURN)

    def v3_digest(self):
        r = self.v3_route
        return self.scalar(f"""SELECT md5(jsonb_build_object(
          'route',(SELECT to_jsonb(x) FROM public.pickup_routes x WHERE route_id='{r}'),
          'binding',(SELECT to_jsonb(x) FROM routing_private.bindings x WHERE route_id='{r}'),
          'vehicle',(SELECT to_jsonb(x) FROM public.vehicles x WHERE vehicle_id='{self.v3_vehicle}'),
          'items',(SELECT jsonb_agg(to_jsonb(x) ORDER BY ordinal) FROM routing_private.items x WHERE route_id='{r}'),
          'stops',(SELECT jsonb_agg(to_jsonb(x) ORDER BY stop_order) FROM public.pickup_route_stops x WHERE route_id='{r}'),
          'assignments',(SELECT jsonb_agg(to_jsonb(x) ORDER BY task_id) FROM public.active_task_route_assignments x WHERE route_id='{r}'),
          'audits',(SELECT jsonb_agg(to_jsonb(a) ORDER BY event_id) FROM public.audit_events a WHERE a.entity_id='{r}' OR a.claim_id IN(SELECT t.claim_id FROM public.pickup_tasks t JOIN routing_private.items i USING(task_id) WHERE i.route_id='{r}')),
          'snapshots',(SELECT jsonb_agg(to_jsonb(x) ORDER BY snapshot_id) FROM routing_private.snapshots x),
          'candidates',(SELECT jsonb_agg(to_jsonb(x) ORDER BY candidate_id) FROM routing_private.candidates x),
          'validations',(SELECT jsonb_agg(to_jsonb(x) ORDER BY candidate_id) FROM routing_private.validations x),
          'receipts',(SELECT jsonb_agg(to_jsonb(x) ORDER BY request_id) FROM routing_private.requests x)
          )::text)""")

    def assert_holds(self):
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='{self.rid}'"), 3)
        self.assertEqual(self.scalar(f"SELECT route_status FROM public.pickup_routes WHERE route_id='{self.rid}'"), 'IN_PROGRESS')
        self.assertIsNone(self.scalar(f"SELECT closed_at FROM routing_private.bindings WHERE route_id='{self.rid}'"))
        self.assertTrue(self.scalar(f"SELECT fleet_private.vehicle_has_hold('{self.vehicle_id}')"))

    def assert_success(self):
        self.assertEqual(self.scalar(f"SELECT route_status FROM public.pickup_routes WHERE route_id='{self.rid}'"), 'ABANDONED')
        self.assertIsNotNone(self.scalar(f"SELECT closed_at FROM routing_private.bindings WHERE route_id='{self.rid}'"))
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='{self.rid}'"), 0)
        self.assertFalse(self.scalar(f"SELECT fleet_private.vehicle_has_hold('{self.vehicle_id}')"))
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.pickup_tasks t JOIN routing_private.items i USING(task_id) JOIN public.donation_claims c USING(claim_id) JOIN public.claim_leases le USING(claim_id) JOIN public.listings l ON l.listing_id=t.listing_id JOIN public.donations d ON d.donation_id=l.donation_id JOIN public.claim_reconciliation_cases rc ON rc.claim_id=c.claim_id WHERE i.route_id='{self.rid}' AND t.task_status='STALE' AND c.claim_status='RELEASED' AND le.lease_status='RELEASED' AND l.listing_status='AVAILABLE' AND d.donation_status='AVAILABLE' AND rc.case_status='RESOLVED_RELEASED' AND i.released_at IS NOT NULL"), 3)
        self.assertEqual(self.v3_digest(), self.v3_before)

    def test_v2_01_success_all_states_and_audit(self):
        expires = self.scalar('SELECT jsonb_agg(expires_at ORDER BY claim_id) FROM public.claim_leases')
        self.report(); self.consent(); result = self.finalize(); self.assert_success()
        self.assertEqual(result['route_status'], 'ABANDONED')
        self.assertEqual(self.scalar('SELECT jsonb_agg(expires_at ORDER BY claim_id) FROM public.claim_leases'), expires)
        events = self.scalar(f"SELECT jsonb_agg(jsonb_build_object('event_type',event_type,'actor',actor_user_id,'role',actor_role,'principal',details->>'operator_principal') ORDER BY event_id) FROM public.audit_events WHERE entity_id='{self.rid}' AND event_type IN('CLAIM_RESOLVED_NO_HANDOVER','ROUTE_ASSIGNMENTS_RELEASED','ROUTE_ABANDONED_RECONCILED')")
        self.assertEqual(len(events), 5)
        for e in events:
            self.assertIsNone(e['actor']); self.assertEqual(e['role'], 'SYSTEM'); self.assertEqual(e['principal'], 'geolock_local_resolver')
        self.lane.save('v2-focused-success.json', dict(result=result, audit=events, v3_digest=self.v3_digest(), old_deadlines_preserved=True))

    def test_v2_02_third_item_failure_rolls_back_first_two(self):
        self.report(); self.consent(); before = self.resolution_state_digest()
        third = self.stops[2]['claim_id']
        self.lane.sql(f"""CREATE FUNCTION public.local_third_item_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
          IF NEW.claim_id='{third}' AND NEW.claim_status='RELEASED' THEN
            IF (SELECT count(*) FROM public.donation_claims WHERE claim_status='RELEASED')<>2 THEN RAISE EXCEPTION 'FAULT_WAS_NOT_AFTER_TWO_RELEASES'; END IF;
            RAISE EXCEPTION 'LOCAL_THIRD_ITEM_AFTER_TWO_RELEASES';
          END IF; RETURN NEW; END $$;
          CREATE TRIGGER local_third_item_fault BEFORE UPDATE ON public.donation_claims FOR EACH ROW EXECUTE FUNCTION public.local_third_item_fault();""")
        with self.assertRaisesRegex(base.psycopg.Error, 'LOCAL_THIRD_ITEM_AFTER_TWO_RELEASES'):
            self.finalize()
        self.assertEqual(self.resolution_state_digest(), before); self.assert_holds()
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.releases'), 0)
        self.lane.save('v2-focused-third-item-rollback.json', dict(before=before, after=self.resolution_state_digest(), all_three_assignments_retained=True, failure_reached_after_two_releases=True))

    def test_v2_03_cross_donor_rejected_without_writes(self):
        self.report(); target = next(s for s in self.stops if self.source(s) == 'donor_b')
        before = self.resolution_state_digest()
        with self.assertRaises(base.psycopg.Error):
            self.evidence(target['task_id'], base.NO, 'donor')
        self.assertEqual(self.resolution_state_digest(), before); self.assert_holds()

    def test_v2_04_unknown_custody_prevents_release(self):
        self.report(); self.consent(); self.evidence(self.stops[0]['task_id'], 'UNKNOWN_CUSTODY')
        before = self.resolution_state_digest()
        with self.assertRaisesRegex(base.psycopg.Error, 'MATCHING_TWO_PARTY'):
            self.finalize()
        self.assertEqual(self.resolution_state_digest(), before); self.assert_holds()

    def test_v2_05_conflicting_custody_prevents_release(self):
        self.report(); self.consent()
        first = self.stops[0]
        self.evidence(first['task_id'], 'HANDOVER_TO_NGO_CONFIRMED', self.source(first))
        before = self.resolution_state_digest()
        with self.assertRaises(base.psycopg.Error):
            self.finalize()
        self.assertEqual(self.resolution_state_digest(), before); self.assert_holds()

    def unsafe(self, donation=False):
        third = self.stops[2]['claim_id']
        if donation:
            self.lane.sql(f"UPDATE public.donations SET availability_end=clock_timestamp()-interval '1 second' WHERE donation_id=(SELECT l.donation_id FROM public.listings l JOIN public.donation_claims c USING(listing_id) WHERE c.claim_id='{third}');")
        else:
            self.lane.sql(f"UPDATE public.listings SET listing_expires_at=clock_timestamp()-interval '1 second' WHERE listing_id=(SELECT listing_id FROM public.donation_claims WHERE claim_id='{third}');")
        self.report(); self.consent(); result = self.finalize()
        self.assertEqual(result['status'], 'MANUAL_REVIEW'); self.assertEqual(result['reason'], 'UNSAFE_LISTING_VALIDITY'); self.assert_holds()
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.releases'), 0)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donation_claims WHERE claim_status='RELEASED'"), 0)

    def test_v2_06_expired_listing_blocks_entire_route(self):
        self.unsafe()

    def test_v2_07_unsafe_donation_window_blocks_entire_route(self):
        self.unsafe(donation=True)

    def test_v2_08_idempotent_report_evidence_and_finalization(self):
        request = str(uuid4()); first = self.report(request); self.assertEqual(self.report(request), first)
        stop = self.stops[0]; version = self.read()['version']; er = str(uuid4())
        reply = self.evidence(stop['task_id'], base.NO, request=er, version=version)
        self.assertEqual(self.evidence(stop['task_id'], base.NO, request=er, version=version), reply)
        for s in self.stops:
            if s != stop: self.evidence(s['task_id'], base.NO)
            self.evidence(s['task_id'], base.NO, self.source(s))
        self.evidence(None, base.RETURN)
        fr = str(uuid4()); version = self.read()['version']; result = self.finalize(fr, version); self.assert_success()
        before = self.resolution_state_digest(); self.assertEqual(self.finalize(fr, version), result)
        self.assertEqual(self.resolution_state_digest(), before)
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.audit_events WHERE entity_id='{self.rid}' AND event_type='ROUTE_ABANDONED_RECONCILED'"), 1)

    def test_v2_09_resolver_jwt_cannot_replay_or_write(self):
        self.report(); self.consent(); request = str(uuid4()); version = self.read()['version']; self.finalize(request, version)
        before = self.resolution_state_digest()
        with auto.connect(self.lane.port, self.db, 'geolock_local_resolver') as conn:
            conn.execute("SELECT set_config('request.jwt.claims',%s,true)", (json.dumps({'sub': auto.existing.NGO}),))
            with self.assertRaisesRegex(base.psycopg.Error, 'RESOLVER_JWT_CONTEXT_FORBIDDEN'):
                conn.execute('SELECT public.finalize_route_resolution(%s,%s,%s)', (self.case, version, request))
            conn.rollback()
        self.assertEqual(self.resolution_state_digest(), before)

    def test_v2_10_missing_vehicle_accountability_blocks_release(self):
        self.report(); self.consent(vehicle=False); before = self.resolution_state_digest()
        with self.assertRaisesRegex(base.psycopg.Error, 'VEHICLE_ACCOUNTABILITY_REQUIRED'):
            self.finalize()
        self.assertEqual(self.resolution_state_digest(), before); self.assert_holds()

    def test_v2_11_expired_middle_stop_is_deferred_and_last_valid_pickup_continues(self):
        self.reset_template(self.v2_unstarted_template)
        first, middle, last = self.stops
        self.rpc('start_pickup', {'p_claim': first['claim_id']})
        self.rpc('complete_pickup', {'p_claim': first['claim_id'], 'p_handover_confirmed': True})
        self.lane.sql(f"UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '7 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE claim_id='{middle['claim_id']}'; SELECT public.recover_expired_claims(100);")
        expired = self.rpc('get_my_authorized_route', {'p_route': self.rid})
        self.assertTrue(next(s for s in expired['stops'] if s['task_id']==middle['task_id'])['can_defer'])
        self.rpc('defer_my_pickup_for_reconciliation', {'p_claim': middle['claim_id'], 'p_request': str(uuid4())})
        ready = self.rpc('get_my_authorized_route', {'p_route': self.rid})
        self.assertEqual(ready['next_executable_task_id'], last['task_id'])
        self.assertTrue(next(s for s in ready['stops'] if s['task_id']==last['task_id'])['can_start'])
        self.rpc('start_pickup', {'p_claim': last['claim_id']})
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{last['task_id']}'"), 'DISPATCHED')

    def test_v2_12_expired_last_stop_defers_after_prior_pickups(self):
        self.reset_template(self.v2_unstarted_template)
        first, middle, last = self.stops
        for stop in (first, middle):
            self.rpc('start_pickup', {'p_claim': stop['claim_id']})
            self.rpc('complete_pickup', {'p_claim': stop['claim_id'], 'p_handover_confirmed': True})
        self.lane.sql(f"UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '7 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE claim_id='{last['claim_id']}'; SELECT public.recover_expired_claims(100);")
        expired = self.rpc('get_my_authorized_route', {'p_route': self.rid})
        last_state = next(s for s in expired['stops'] if s['task_id']==last['task_id'])
        self.assertTrue(last_state['can_defer'])
        self.rpc('defer_my_pickup_for_reconciliation', {'p_claim': last['claim_id'], 'p_request': str(uuid4())})
        awaiting = self.rpc('get_my_authorized_route', {'p_route': self.rid})
        self.assertTrue(awaiting['awaiting_individual_reconciliation'])
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='{self.rid}'"), 3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated', action='store_true', required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    assert runtime.name.startswith('geolock-spatial-runtime-') and (runtime/'pgsql/bin/postgres.exe').is_file()
    assert auto.assembly.digest(base.ROOT/base.MIGRATION) == PIN
    for key in list(os.environ):
        if key.upper().startswith(('PG','GEOLOCK','SUPABASE')) or key.upper() in ('DATABASE_URL','DB_URL'):
            os.environ.pop(key,None)
    V2ThreeStopTests.runtime = runtime
    suite = unittest.TestSuite(V2ThreeStopTests(name) for name in unittest.defaultTestLoader.getTestCaseNames(V2ThreeStopTests) if name.startswith('test_v2_'))
    result = unittest.TextTestRunner(verbosity=2, failfast=True).run(suite)
    summary = dict(status='PASS' if result.wasSuccessful() else 'FAIL', tests=result.testsRun, failures=len(result.failures), errors=len(result.errors), dev_connections=0, migration_sha256=auto.assembly.digest(base.ROOT/base.MIGRATION), scope='DISPOSABLE LOCAL SYNTHETIC ONLY; no hosted parity claim')
    if hasattr(V2ThreeStopTests,'lane'):
        V2ThreeStopTests.lane.save('v2-focused-result.json',summary)
        print(json.dumps(dict(evidence=str(V2ThreeStopTests.out),**summary),indent=2))
    return not result.wasSuccessful()


if __name__ == '__main__':
    mp.freeze_support()
    raise SystemExit(main())
