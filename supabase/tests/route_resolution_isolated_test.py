"""LOCAL PostgreSQL17 only. Synthetic auth/Storage/cron, real protected SQL.

Creates a new loopback cluster; never accepts a DSN/profile/existing database.
Uses a small SYNTHETIC graph and independent validator process for the template.
No Supabase access, real fixture creation, graph cache change or scheduler activation.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import multiprocessing as mp
import os
from pathlib import Path
import sys
import time
import unittest
from uuid import uuid4

import automatic_routing_isolated_test as auto
import psycopg
from psycopg.rows import dict_row

ROOT = auto.ROOT
MIGRATION = 'docs/stage8/stage-a/forward-migrations/20261106_route_interruption_resolution.sql'
PER_STOP = 'docs/stage8/stage-a/forward-migrations/20261108_per_stop_reconciliation.sql'
CLAIM_SCOPED = 'docs/stage8/stage-a/forward-migrations/20261109_claim_scoped_reconciliation.sql'
DONOR_READ = 'docs/stage8/stage-a/forward-migrations/20261107_donor_route_resolution_read.sql'
RECEIPT = 'docs/stage8/stage-a/forward-migrations/20261105_routing_receipt_readonly.sql'
NO = 'NO_HANDOVER_SOURCE_RETAINS_GOODS'
RETURN = 'VEHICLE_RETURNED_TO_NGO_CONTROL'


class ResolutionTests(unittest.TestCase):
    runtime = None
    prepare = auto.AutomaticTests.prepare
    authorize = auto.AutomaticTests.authorize
    stop = classmethod(auto.AutomaticTests.stop.__func__)

    @classmethod
    def setUpClass(cls):
        auto.AutomaticTests.setUpClass.__func__(cls)
        cls.lane.hashes[MIGRATION] = auto.assembly.digest(ROOT / MIGRATION)
        cls.lane.hashes[PER_STOP] = auto.assembly.digest(ROOT / PER_STOP)
        cls.lane.hashes[CLAIM_SCOPED] = auto.assembly.digest(ROOT / CLAIM_SCOPED)
        cls.lane.hashes[DONOR_READ] = auto.assembly.digest(ROOT / DONOR_READ)
        cls.lane.hashes[str(Path(__file__).relative_to(ROOT)).replace('\\','/')] = auto.assembly.digest(Path(__file__))
        cls.lane.hashes[RECEIPT] = auto.assembly.digest(ROOT / RECEIPT)
        # Historical receipt migration requires database name postgres. Apply it
        # to the fresh template database before creating per-scenario clones.
        cls.lane.apply(RECEIPT)
        baseline_sql = "SELECT coalesce(jsonb_object_agg(oid::regprocedure::text, jsonb_build_object('md5',md5(replace(prosrc,E'\\r\\n',E'\\n')),'owner',proowner::regrole::text,'definer',prosecdef,'volatility',provolatile,'config',proconfig,'acl',proacl::text)),'{}') FROM pg_proc WHERE pronamespace IN ('public'::regnamespace,'routing_private'::regnamespace,'fleet_private'::regnamespace);"
        before = cls.lane.js(baseline_sql)
        cls.pristine_template = 'resolution_pristine_' + uuid4().hex
        cls.lane.sql('CREATE DATABASE '+cls.pristine_template+' TEMPLATE postgres;')
        cls.lane.apply(MIGRATION)
        after = cls.lane.js(baseline_sql)
        changed = [key for key in before if before[key] != after.get(key)]
        assert sorted(changed) == ['enforce_donation_transition()', 'fleet_private.route_vehicle_guard()'], changed
        cls.lane.save('resolution-function-preservation.json', {'changed': changed,
            'preserved': len(before)-len(changed), 'before': before, 'after': after})
        cls.lane.save('resolution-function-fingerprints.json', after)
        cls.lane.apply(DONOR_READ)
        cls.lane.apply(PER_STOP)
        stage8_functions = cls.lane.js(baseline_sql)
        cls.lane.save('phase2d-stage8-through-20261108-functions.json', {
            'scope': 'DISPOSABLE LOCAL CANONICAL FUNCTIONS THROUGH 20261108; source line endings normalized for comparison',
            'functions': stage8_functions,
        })
        cls.claim_scoped_pristine_template = 'claim_scoped_pristine_' + uuid4().hex
        cls.lane.sql('CREATE DATABASE '+cls.claim_scoped_pristine_template+' TEMPLATE postgres;')
        # DEV's catalog contains CRLF PL/pgSQL bodies. Recreate all four
        # migration-patched routines with representative CRLF pg_get_functiondef
        # input, then verify the migration still applies and leaves valid bodies.
        for signature in (
            'public.recover_expired_claims(integer)',
            'public.defer_my_pickup_for_reconciliation(uuid,uuid)',
            'public.get_my_authorized_route(uuid)',
            'public.report_my_route_interruption(uuid,text,uuid)',
        ):
            definition = cls.lane.sql(f"SELECT pg_get_functiondef('{signature}'::regprocedure);")
            crlf_definition = definition.replace('\r\n', '\n').replace('\n', '\r\n')
            cls.lane.sql('', exact_bytes=crlf_definition.encode('utf-8'))
            has_crlf = cls.lane.sql(
                f"SELECT position(chr(13)||chr(10) IN prosrc)>0 FROM pg_proc WHERE oid='{signature}'::regprocedure;")
            assert has_crlf == 't', (signature, 'CRLF fixture was not retained by PostgreSQL')
        cls.lane.apply(CLAIM_SCOPED)
        for signature in (
            'public.recover_expired_claims(integer)',
            'public.defer_my_pickup_for_reconciliation(uuid,uuid)',
            'public.get_my_authorized_route(uuid)',
            'public.report_my_route_interruption(uuid,text,uuid)',
        ):
            valid = cls.lane.sql(
                f"SELECT pg_get_functiondef('{signature}'::regprocedure) LIKE '%AS $function$%' AND "
                f"prosrc IS NOT NULL AND length(prosrc)>0 AND position(chr(13) IN prosrc)=0 "
                f"FROM pg_proc WHERE oid='{signature}'::regprocedure;")
            assert valid == 't', (signature, 'patched routine definition is invalid')
        assert cls.lane.sql('SELECT enabled FROM resolution_private.config;') == 'f'
        cls.lane.sql("""CREATE ROLE geolock_local_resolver LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
          GRANT geolock_route_resolver TO geolock_local_resolver;
          INSERT INTO resolution_private.operators VALUES('geolock_local_resolver','LOCAL SYNTHETIC OPERATOR',true);
          UPDATE resolution_private.config SET enabled=true;""")
        # This object's cleanups stop only the synthetic validator and its fresh DB.
        fixture = cls()
        auto.AutomaticTests.setUp(fixture)
        try:
            fixture.prepare(two=True)
            fixture.authorize()
            before = fixture.session.rpc('get_my_authorized_route', {'p_route': fixture.rid})
            cls.unstarted_template = 'resolution_unstarted_' + uuid4().hex
            cls.lane.sql('CREATE DATABASE ' + cls.unstarted_template + ' TEMPLATE ' + fixture.db + ';', db='postgres')
            fixture.session.rpc('start_pickup', {'p_claim': before['stops'][0]['claim_id']})
            cls.rid = fixture.rid
            cls.stops = before['stops']
            cls.vehicle_id = fixture.vehicle['vehicle_id']
            cls.template = 'resolution_template_' + uuid4().hex
            cls.lane.sql('CREATE DATABASE ' + cls.template + ' TEMPLATE ' + fixture.db + ';', db='postgres')
        finally:
            fixture.doCleanups()
        three = cls()
        auto.AutomaticTests.setUp(three)
        try:
            three.prepare(two=True, three=True)
            three.authorize()
            detail = three.session.rpc('get_my_authorized_route', {'p_route': three.rid})
            cls.three_unstarted_template = 'resolution_three_unstarted_' + uuid4().hex
            cls.lane.sql('CREATE DATABASE ' + cls.three_unstarted_template + ' TEMPLATE ' + three.db + ';', db='postgres')
            cls.three_rid = three.rid
            cls.three_stops = detail['stops']
            cls.three_vehicle_id = three.vehicle['vehicle_id']
        finally:
            three.doCleanups()
        hub = cls()
        auto.AutomaticTests.setUp(hub)
        try:
            cls.hub_actor = str(uuid4())
            hub.seed_hub()
            hub.prepare(two=False)
            hub.authorize()
            detail = hub.session.rpc('get_my_authorized_route', {'p_route': hub.rid})
            cls.hub_unstarted_template = 'resolution_hub_unstarted_' + uuid4().hex
            cls.lane.sql('CREATE DATABASE ' + cls.hub_unstarted_template + ' TEMPLATE ' + hub.db + ';', db='postgres')
            hub.session.rpc('start_pickup', {'p_claim': detail['stops'][0]['claim_id']})
            cls.hub_meta = (hub.rid, detail['stops'], hub.vehicle['vehicle_id'])
            cls.hub_template = 'resolution_hub_' + uuid4().hex
            cls.lane.sql('CREATE DATABASE ' + cls.hub_template + ' TEMPLATE ' + hub.db + ';', db='postgres')
        finally:
            hub.doCleanups()
        cls.lane.db = 'postgres'
        cls.lane.save('resolution-baseline.json', {'scope': 'DISPOSABLE SYNTHETIC ONLY',
            'migration_sha256': auto.assembly.digest(ROOT / MIGRATION), 'route_id': cls.rid,
            'recovery_md5': cls.lane.sql("SELECT md5(replace(prosrc,E'\\r\\n',E'\\n')) FROM pg_proc WHERE oid='public.recover_expired_claims(integer)'::regprocedure;", db=cls.template)})

    def setUp(self):
        self.db = 'resolution_test_' + uuid4().hex
        self.lane.sql('CREATE DATABASE ' + self.db + ' TEMPLATE ' + self.template + ';', db='postgres')
        self.lane.db = self.db
        self.addCleanup(self.drop)

    def drop(self):
        self.lane.db = 'postgres'
        self.lane.sql('DROP DATABASE ' + self.db + ' WITH (FORCE);')

    def seed_hub(self):
        actor, hid, bid, lid = self.hub_actor, str(uuid4()), str(uuid4()), str(uuid4())
        sql = [f"""INSERT INTO auth.users(id,email) VALUES('{actor}','hub@local.invalid');
          INSERT INTO public.user_profiles(user_id,full_name,role) VALUES('{actor}','LOCAL HUB','HUB_ADMIN');
          INSERT INTO public.hub_admin_profiles(user_id) VALUES('{actor}');
          INSERT INTO public.community_hubs(hub_id,admin_user_id,hub_name,address_text,latitude,longitude,road_node_id,capacity_kg)
          VALUES('{hid}','{actor}','LOCAL SYNTHETIC HUB','LOCAL',3.01,101.01,'102',100);
          INSERT INTO public.hub_batches(batch_id,hub_id,batch_category_id,batch_status,batch_weight_kg,batch_donation_count,created_by)
          VALUES('{bid}','{hid}','{auto.existing.uid('category')}','DRAFT',15,3,'{actor}');"""]
        for _ in range(3):
            did = str(uuid4())
            reservation = str(uuid4())
            photo = f'{auto.existing.DONOR}/pending/{uuid4()}/{uuid4()}.jpg'
            sql.append(f"""INSERT INTO public.donations(donation_id,donor_user_id,title,collection_path,donation_status,pickup_road_node_id,total_weight_kg,latitude,longitude)
              VALUES('{did}','{auto.existing.DONOR}','LOCAL SYNTHETIC HUB MEMBER','HUB_COLLECTION','BATCHED','102',5,3.01,101.01);
              INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('geolock-donation-images','{photo}','{{"size":100,"mimetype":"image/jpeg"}}');
              INSERT INTO public.donation_images(donation_id,owner_user_id,storage_path,content_type,size_bytes,is_primary,display_order)
              VALUES('{did}','{auto.existing.DONOR}','{photo}','image/jpeg',100,true,1);
              INSERT INTO public.hub_reservations(reservation_id,donation_id,hub_id,reserved_weight_kg,reservation_status,expires_at)
              VALUES('{reservation}','{did}','{hid}',5,'CONSUMED',now()+interval '8 hours');
              INSERT INTO public.hub_receipts(reservation_id,donation_id,hub_id,received_by,received_weight_kg)
              VALUES('{reservation}','{did}','{hid}','{actor}',5);
              INSERT INTO public.hub_inventory(donation_id,hub_id,inventory_status) VALUES('{did}','{hid}','BATCHED');
              INSERT INTO public.hub_batch_members(batch_id,hub_id,donation_id,membership_status) VALUES('{bid}','{hid}','{did}','ACTIVE');""")
        sql.append(f"""UPDATE public.hub_batches SET batch_status='PUBLISHED' WHERE batch_id='{bid}';
          INSERT INTO public.listings(listing_id,source_type,batch_id,listing_status,listing_weight_kg,pickup_road_node_id,pickup_latitude,pickup_longitude)
          VALUES('{lid}','HUB_BATCH','{bid}','AVAILABLE',15,'102',3.01,101.01);
          SELECT public.process_listing_eligibility_refresh_jobs();""")
        self.lane.sql('BEGIN;\n'+'\n'.join(sql)+'\nCOMMIT;')
        self.listing = lid

    def reset_template(self, template):
        self.lane.sql('DROP DATABASE ' + self.db + ' WITH (FORCE);', db='postgres')
        self.lane.sql('CREATE DATABASE ' + self.db + ' TEMPLATE ' + template + ';', db='postgres')
        self.lane.db = self.db

    def use_hub(self):
        self.reset_template(self.hub_template)
        self.rid, self.stops, self.vehicle_id = self.hub_meta

    def rpc(self, name, params=None, who='ngo', readonly=False):
        allowed = {'report_my_route_interruption', 'submit_route_resolution_evidence',
          'get_my_route_resolution', 'get_my_route_resolution_receipt', 'finalize_route_resolution',
          'get_route_resolution_for_operator', 'register_route_test_provenance',
          'get_my_authorized_route', 'start_pickup', 'complete_pickup', 'close_my_collected_route',
          'cancel_my_unstarted_route', 'submit_claim_reconciliation',
          'defer_my_pickup_for_reconciliation', 'close_my_resolved_route',
          'get_my_mixed_route_close_receipt', 'get_my_deferred_pickup_receipt',
          'get_my_donation_claim_reconciliation', 'get_my_claim_reconciliation_receipt'}
        allowed.update({'list_my_route_resolution_cases','report_route_resolution_incident',
            'claim_listing','set_my_vehicle_availability','register_my_vehicle'})
        assert name in allowed
        login = 'geolock_local_resolver' if who == 'resolver' else 'geolock_local_ngo_login'
        with auto.connect(self.lane.port, self.db, login) as conn:
            if readonly:
                conn.execute('BEGIN READ ONLY')
            conn.execute("SET LOCAL lock_timeout='4s'")
            conn.execute("SET LOCAL statement_timeout='12s'")
            if who != 'resolver':
                conn.execute('SET LOCAL ROLE ' + ('anon' if who == 'anon' else 'authenticated'))
                uid = {'ngo': auto.existing.NGO, 'donor': auto.existing.DONOR, 'hub': self.hub_actor, 'other': auto.existing.uid('foreign-ngo'), 'anon': ''}[who]
                conn.execute("SELECT set_config('request.jwt.claim.sub',%s,true),set_config('request.jwt.claim.role',%s,true)", (uid, 'anon' if who == 'anon' else 'authenticated'))
            params = params or {}
            args = ','.join(k + ' => %s' + ('::uuid[]' if k == 'p_claims' else '') for k in params)
            result = conn.execute('SELECT public.' + name + '(' + args + ')', list(params.values())).fetchone()[0]
            if readonly:
                self.assertEqual(conn.execute('SHOW transaction_read_only').fetchone()[0], 'on')
                conn.rollback()
            return result

    def report(self, request=None):
        # Legacy-path tests install a historical case before exercising its
        # read/evidence/restricted-resolver compatibility after migration.
        if not self.scalar(f"SELECT EXISTS(SELECT 1 FROM resolution_private.cases WHERE route_id='{self.rid}')"):
            self.seed_legacy_route_case()
        r = self.rpc('report_my_route_interruption', {'p_route': self.rid,
            'p_reason': 'EXECUTION_BUDGET_EXCEEDED', 'p_request': request or str(uuid4())})
        self.case = r['case_id']
        return r

    def seed_legacy_route_case(self):
        """Install a synthetic pre-existing route case for compatibility tests."""
        self.lane.sql(f"""INSERT INTO resolution_private.cases(route_id,ngo_id,status,reason,manifest_digest)
          SELECT b.route_id,b.ngo_id,'AWAITING_EVIDENCE','EXECUTION_BUDGET_EXCEEDED',resolution_private.manifest(b.route_id)
          FROM routing_private.bindings b WHERE b.route_id='{self.rid}';
          UPDATE public.donation_claims c SET claim_status='RECONCILIATION_REQUIRED'
            WHERE EXISTS(SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
              WHERE i.route_id='{self.rid}' AND i.collected_at IS NULL AND t.claim_id=c.claim_id);
          UPDATE public.claim_leases le SET lease_status='RECONCILIATION_REQUIRED'
            WHERE EXISTS(SELECT 1 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
              WHERE i.route_id='{self.rid}' AND i.collected_at IS NULL AND t.claim_id=le.claim_id);
          INSERT INTO resolution_private.items(case_id,task_id,claim_id,source_actor,source_role,initial_class,observation_digest)
          SELECT c.case_id,i.task_id,t.claim_id,
            CASE WHEN l.source_type='DIRECT_DONATION' THEN d.donor_user_id ELSE h.admin_user_id END,
            CASE WHEN l.source_type='DIRECT_DONATION' THEN 'DONOR' ELSE 'HUB_ADMIN' END,
            CASE WHEN i.collected_at IS NOT NULL THEN 'COLLECTED' WHEN i.consumed_at IS NOT NULL THEN 'DISPATCHED' ELSE 'NEVER_STARTED' END,
            routing_private.task_digest(routing_private.observe_task(i.task_id))
          FROM resolution_private.cases c JOIN routing_private.items i ON i.route_id=c.route_id
          JOIN public.pickup_tasks t USING(task_id) JOIN public.listings l USING(listing_id)
          LEFT JOIN public.donations d ON d.donation_id=l.donation_id
          LEFT JOIN public.hub_batches hb ON hb.batch_id=l.batch_id
          LEFT JOIN public.community_hubs h ON h.hub_id=hb.hub_id
          WHERE c.route_id='{self.rid}';
          INSERT INTO public.claim_reconciliation_cases(claim_id,listing_id,donation_id,source_type,case_status)
          SELECT dc.claim_id,l.listing_id,l.donation_id,l.source_type,'OPEN'
          FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
          JOIN public.donation_claims dc ON dc.claim_id=t.claim_id
          JOIN public.listings l ON l.listing_id=dc.listing_id
          WHERE i.route_id='{self.rid}' AND i.collected_at IS NULL
            AND NOT EXISTS(SELECT 1 FROM public.claim_reconciliation_cases rc WHERE rc.claim_id=dc.claim_id);""")

    def seed_uncertain_claim(self, claim_id):
        self.lane.sql(f"""UPDATE public.donation_claims SET claim_status='RECONCILIATION_REQUIRED' WHERE claim_id='{claim_id}';
          UPDATE public.claim_leases SET lease_status='RECONCILIATION_REQUIRED' WHERE claim_id='{claim_id}';
          INSERT INTO public.claim_reconciliation_cases(claim_id,listing_id,donation_id,source_type,case_status)
          SELECT c.claim_id,l.listing_id,l.donation_id,l.source_type,'OPEN'
          FROM public.donation_claims c JOIN public.listings l USING(listing_id)
          WHERE c.claim_id='{claim_id}' AND NOT EXISTS
            (SELECT 1 FROM public.claim_reconciliation_cases rc WHERE rc.claim_id=c.claim_id);""")

    def read(self, who='ngo'):
        return self.rpc('get_my_route_resolution', {'p_route': self.rid}, who=who, readonly=True)

    def evidence(self, task, assertion, who='ngo', request=None, version=None):
        return self.rpc('submit_route_resolution_evidence', {'p_case': self.case,
            'p_task': task, 'p_assertion': assertion,
            'p_version': self.read(who)['version'] if version is None else version,
            'p_request': request or str(uuid4())}, who=who)

    def consent(self):
        for stop in self.stops:
            self.evidence(stop['task_id'], NO)
            self.evidence(stop['task_id'], NO, 'donor')
        self.evidence(None, RETURN)

    def finalize(self, request=None, version=None, who='resolver'):
        return self.rpc('finalize_route_resolution', {'p_case': self.case,
            'p_version': self.read()['version'] if version is None else version,
            'p_request': request or str(uuid4())}, who=who)

    def scalar(self, sql):
        with auto.connect(self.lane.port, self.db, 'postgres') as conn:
            return conn.execute(sql).fetchone()[0]

    def stop_state(self, stop):
        with auto.connect(self.lane.port, self.db, 'postgres') as conn:
            return conn.execute(f"""SELECT jsonb_build_object(
              'claim',c.claim_status,'lease',le.lease_status,'listing',l.listing_status,
              'donation',d.donation_status,'task',t.task_status,
              'assigned',EXISTS(SELECT 1 FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id),
              'item_released',i.released_at IS NOT NULL,'item_consumed',i.consumed_at IS NOT NULL,
              'item_collected',i.collected_at IS NOT NULL,'deferred',ds.status,
              'route',r.route_status,'binding_closed',b.closed_at IS NOT NULL,
              'vehicle_hold',fleet_private.vehicle_has_hold(b.vehicle_id),'reconciliation',rc.case_status
            ) FROM public.pickup_tasks t JOIN public.donation_claims c ON c.claim_id=t.claim_id
            JOIN public.claim_leases le ON le.claim_id=c.claim_id JOIN public.listings l ON l.listing_id=t.listing_id
            JOIN public.donations d ON d.donation_id=l.donation_id
            JOIN routing_private.items i ON i.task_id=t.task_id
            JOIN public.pickup_routes r ON r.route_id=i.route_id
            JOIN routing_private.bindings b ON b.route_id=i.route_id
            LEFT JOIN routing_private.deferred_stops ds ON ds.route_id=i.route_id AND ds.task_id=i.task_id
            LEFT JOIN public.claim_reconciliation_cases rc ON rc.claim_id=c.claim_id
            WHERE t.task_id='{stop['task_id']}';""").fetchone()[0]

    def resolution_state_digest(self):
        tables=['resolution_private.cases','resolution_private.items','resolution_private.requests','resolution_private.releases','resolution_private.permits','resolution_private.finalizations','public.pickup_tasks','public.donations','public.donation_claims','public.claim_leases','public.listings','public.claim_reconciliation_cases','public.active_task_route_assignments','public.audit_events','routing_private.items','routing_private.bindings','public.pickup_routes']
        parts=["(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]') FROM "+table+" t)" for table in tables]
        return self.scalar('SELECT md5(jsonb_build_array('+','.join(parts)+')::text)')

    def assert_holds(self):
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='{self.rid}'"), 2)
        self.assertIn(self.scalar(f"SELECT route_status FROM public.pickup_routes WHERE route_id='{self.rid}'"), ['AUTHORISED','IN_PROGRESS'])
        self.assertIsNone(self.scalar(f"SELECT closed_at FROM routing_private.bindings WHERE route_id='{self.rid}'"))
        self.assertTrue(self.scalar(f"SELECT fleet_private.vehicle_has_hold('{self.vehicle_id}')"))

    def race(self, *operations):
        from threading import Barrier
        ready = Barrier(len(operations))
        def run(operation):
            ready.wait(timeout=5)
            try: return {'result': operation()}
            except psycopg.Error as error:
                return {'error': error.diag.message_primary, 'sqlstate': error.sqlstate}
        with ThreadPoolExecutor(len(operations)) as pool:
            results = list(pool.map(run, operations))
        self.assertFalse(any(r.get('sqlstate') in ['40P01','55P03','57014'] for r in results), results)
        self.lane.save(self._testMethodName+'-race.json', results)
        return results

    def test_01_full_guarded_direct_release(self):
        expiry = self.scalar('SELECT jsonb_agg(expires_at ORDER BY claim_id) FROM public.claim_leases')
        self.report(); self.consent()
        result = self.finalize()
        self.assertEqual(result['route_status'], 'ABANDONED')
        self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'), 0)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.pickup_tasks WHERE task_status='STALE'"), 2)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donation_claims WHERE claim_status='RELEASED'"), 2)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE donation_status='AVAILABLE'"), 2)
        self.assertEqual(self.scalar('SELECT jsonb_agg(expires_at ORDER BY claim_id) FROM public.claim_leases'), expiry)
        self.assertFalse(self.scalar("SELECT fleet_private.vehicle_has_hold('" + self.vehicle_id + "')"))
        self.lane.save('resolution-success.json', result)

    def test_02_disabled_by_default_guard(self):
        self.lane.sql('UPDATE resolution_private.config SET enabled=false;')
        with self.assertRaisesRegex(psycopg.Error, 'ROUTE_RESOLUTION_DISABLED'): self.report()

    def test_03_report_fences_existing_writes(self):
        self.report()
        with self.assertRaises(psycopg.Error):
            self.rpc('complete_pickup', {'p_claim': self.stops[0]['claim_id'], 'p_handover_confirmed': True})
        with self.assertRaises(psycopg.Error): self.rpc('start_pickup', {'p_claim': self.stops[1]['claim_id']})
        self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'), 2)

    def test_04_missing_counterparty_cannot_finalize(self):
        self.report()
        self.evidence(self.stops[0]['task_id'], NO); self.evidence(None, RETURN)
        with self.assertRaisesRegex(psycopg.Error, 'MATCHING_TWO_PARTY'): self.finalize()

    def test_05_operator_only(self):
        self.report(); self.consent()
        for who in ['ngo', 'donor', 'other', 'anon']:
            with self.assertRaises(psycopg.Error): self.finalize(who=who)

    def test_06_report_and_finalization_replay(self):
        req = str(uuid4()); first = self.report(req); self.assertEqual(self.report(req), first)
        self.consent(); version = self.read()['version']; request = str(uuid4())
        a = self.finalize(request, version); b = self.finalize(request, version)
        self.assertEqual(a, b)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.audit_events WHERE event_type='ROUTE_ABANDONED_RECONCILED'"), 1)

    def test_07_expired_listing_retains_review(self):
        self.lane.sql("UPDATE public.listings SET listing_expires_at=clock_timestamp()-interval '1 second';")
        self.report(); self.consent(); r = self.finalize()
        self.assertEqual(r['status'], 'MANUAL_REVIEW')
        self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'), 2)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE donation_status='AVAILABLE'"), 0)

    def test_08_unpermitted_reverse_edge_denied(self):
        self.lane.sql("UPDATE public.donations SET donation_status='AVAILABLE' WHERE donation_status='PICKUP_IN_PROGRESS';", expected='INVALID_DONATION_TRANSITION')

    def test_09_full_guarded_hub_member_release(self):
        self.use_hub(); self.report()
        self.evidence(self.stops[0]['task_id'], NO)
        self.evidence(self.stops[0]['task_id'], NO, 'hub')
        self.evidence(None, RETURN)
        self.assertEqual(self.finalize()['route_status'], 'ABANDONED')
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE collection_path='HUB_COLLECTION' AND donation_status='BATCHED'"), 3)

    def test_10_hub_wrong_source_participant_rejected(self):
        self.use_hub(); self.report()
        with self.assertRaises(psycopg.Error): self.evidence(self.stops[0]['task_id'], NO, 'donor')

    def test_11_evidence_version_and_payload_conflicts(self):
        self.report(); v = self.read()['version']; req = str(uuid4())
        original = self.evidence(self.stops[0]['task_id'], NO, request=req, version=v)
        self.assertEqual(self.evidence(self.stops[0]['task_id'], NO, request=req, version=v), original)
        with self.assertRaisesRegex(psycopg.Error, 'REQUEST_PAYLOAD_CONFLICT'):
            self.evidence(self.stops[0]['task_id'], 'UNKNOWN_CUSTODY', request=req, version=v)
        with self.assertRaisesRegex(psycopg.Error, 'CASE_VERSION_STALE'):
            self.evidence(self.stops[1]['task_id'], NO, version=v)

    def test_12_amendment_invalidates_finalization_version(self):
        self.report(); self.consent(); version = self.read()['version']
        self.evidence(self.stops[0]['task_id'], 'UNKNOWN_CUSTODY')
        with self.assertRaisesRegex(psycopg.Error, 'CASE_VERSION_STALE'): self.finalize(version=version)
        with self.assertRaisesRegex(psycopg.Error, 'MATCHING_TWO_PARTY'): self.finalize()

    def test_13_missing_vehicle_accountability(self):
        self.report()
        for stop in self.stops:
            self.evidence(stop['task_id'], NO); self.evidence(stop['task_id'], NO, 'donor')
        with self.assertRaisesRegex(psycopg.Error, 'VEHICLE_ACCOUNTABILITY'): self.finalize()

    def test_14_never_started_false_collection_denied(self):
        self.report()
        with self.assertRaisesRegex(psycopg.Error, 'NEVER_STARTED_HANDOVER'):
            self.evidence(self.stops[1]['task_id'], 'HANDOVER_TO_NGO_CONFIRMED')

    def test_15_no_ordinary_cancel_or_close_after_report(self):
        self.report()
        with self.assertRaises(psycopg.Error): self.rpc('cancel_my_unstarted_route', {'p_route': self.rid})
        with self.assertRaises(psycopg.Error): self.rpc('close_my_collected_route', {'p_route': self.rid, 'p_depot_return_confirmed': True})

    def test_16_readonly_scoping_and_no_writes(self):
        self.report(); before = self.scalar('SELECT count(*) FROM public.audit_events')
        self.assertEqual(self.read(), self.read())
        for who in ['other', 'anon']:
            with self.assertRaises(psycopg.Error): self.read(who)
        self.assertEqual(self.scalar('SELECT count(*) FROM public.audit_events'), before)

    def test_17_cross_actor_receipt_not_found(self):
        request = str(uuid4()); self.report(request)
        owner = self.rpc('get_my_route_resolution_receipt', {'p_request': request}, readonly=True)
        self.assertEqual(owner['outcome'], 'FOUND')
        self.assertEqual(self.rpc('get_my_route_resolution_receipt', {'p_request': request}, who='donor', readonly=True)['outcome'], 'NOT_FOUND')

    def test_18_expired_leases_use_reconciliation_without_extension(self):
        self.lane.sql("UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second';")
        before = self.scalar('SELECT jsonb_agg(expires_at ORDER BY claim_id) FROM public.claim_leases')
        self.report(); self.consent(); self.finalize()
        self.assertEqual(self.scalar('SELECT jsonb_agg(expires_at ORDER BY claim_id) FROM public.claim_leases'), before)

    def test_19_recovery_does_not_convert_into_a_new_route_case(self):
        self.lane.sql("UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second'; SELECT public.recover_expired_claims(10);")
        count = self.scalar('SELECT count(*) FROM public.claim_reconciliation_cases')
        with self.assertRaisesRegex(psycopg.Error, 'NEW_ROUTE_INTERRUPTION_REPORTS_RETIRED'):
            self.rpc('report_my_route_interruption', {'p_route': self.rid,
                'p_reason': 'EXECUTION_BUDGET_EXCEEDED', 'p_request': str(uuid4())})
        self.assertEqual(self.scalar('SELECT count(*) FROM public.claim_reconciliation_cases'), count)
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.cases'), 0)

    def test_20_report_then_recovery_is_noop(self):
        before = self.scalar("SELECT md5(replace(prosrc,E'\\r\\n',E'\\n')) FROM pg_proc WHERE oid='public.recover_expired_claims(integer)'::regprocedure")
        self.report()
        self.assertEqual(self.scalar('SELECT public.recover_expired_claims(10)'), 0)
        self.assertEqual(self.scalar("SELECT md5(replace(prosrc,E'\\r\\n',E'\\n')) FROM pg_proc WHERE oid='public.recover_expired_claims(integer)'::regprocedure"), before)

    def test_21_concurrent_new_route_reports_are_rejected_without_cases(self):
        params = {'p_route': self.rid, 'p_reason': 'EXECUTION_BUDGET_EXCEEDED',
                  'p_request': str(uuid4())}
        results = self.race(
            lambda: self.rpc('report_my_route_interruption', params),
            lambda: self.rpc('report_my_route_interruption', params),
        )
        self.assertTrue(all(row.get('error') == 'NEW_ROUTE_INTERRUPTION_REPORTS_RETIRED'
                            for row in results), results)
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.cases'), 0)
        self.assertEqual(self.scalar('SELECT count(*) FROM public.claim_reconciliation_cases'), 0)

    def test_22_concurrent_same_finalization_has_one_result(self):
        self.report(); self.consent(); v = self.read()['version']; req = str(uuid4())
        with ThreadPoolExecutor(2) as pool:
            values = list(pool.map(lambda _: self.finalize(req, v), range(2)))
        self.assertEqual(values[0], values[1])
        self.assertEqual(self.scalar("SELECT count(*) FROM public.audit_events WHERE event_type='ROUTE_ABANDONED_RECONCILED'"), 1)

    def test_23_required_audit_and_receipt_failures_rollback(self):
        self.report(); self.consent()
        for event in ['DONATION_STATUS_CHANGED', 'CLAIM_RESOLVED_NO_HANDOVER', 'ROUTE_ASSIGNMENTS_RELEASED', 'ROUTE_ABANDONED_RECONCILED']:
            self.lane.sql(f"CREATE FUNCTION public.resolution_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.event_type='{event}' THEN RAISE EXCEPTION 'LOCAL_REQUIRED_AUDIT_FAILURE'; END IF; RETURN NEW; END $$; CREATE TRIGGER resolution_fault BEFORE INSERT ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.resolution_fault();")
            with self.assertRaisesRegex(psycopg.Error, 'LOCAL_REQUIRED_AUDIT_FAILURE'): self.finalize()
            self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'), 2)
            self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE donation_status='AVAILABLE'"), 0)
            self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.permits'), 0)
            self.lane.sql('DROP TRIGGER resolution_fault ON public.audit_events; DROP FUNCTION public.resolution_fault();')
        self.lane.sql("CREATE FUNCTION public.receipt_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.operation='FINALIZE' THEN RAISE EXCEPTION 'LOCAL_REQUIRED_RECEIPT_FAILURE'; END IF; RETURN NEW; END $$; CREATE TRIGGER receipt_fault BEFORE INSERT ON resolution_private.requests FOR EACH ROW EXECUTE FUNCTION public.receipt_fault();")
        with self.assertRaisesRegex(psycopg.Error, 'LOCAL_REQUIRED_RECEIPT_FAILURE'): self.finalize()
        self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'), 2)

    def test_24_vehicle_and_manifest_drift_fail_closed(self):
        self.report(); self.consent()
        self.lane.sql("UPDATE resolution_private.cases SET manifest_digest='untrusted';")
        with self.assertRaisesRegex(psycopg.Error, 'RESOLUTION_BINDING_DRIFT'): self.finalize()

    def test_25_abandoned_is_immutable_and_history_retained(self):
        self.report(); self.consent(); self.finalize()
        self.lane.sql("UPDATE public.pickup_routes SET route_status='IN_PROGRESS';", expected='ROUTE_TERMINAL_STATE_IMMUTABLE')
        self.lane.sql('DELETE FROM public.pickup_routes;', expected='TERMINAL_ROUTE_HISTORY_IMMUTABLE')
        self.assertEqual(self.scalar('SELECT count(*) FROM public.pickup_route_stops'), 2)
        with self.assertRaisesRegex(psycopg.Error, 'TERMINAL_RESOLUTION_IMMUTABLE'):
            self.evidence(self.stops[0]['task_id'], 'UNKNOWN_CUSTODY')

    def test_26_effective_permission_matrix(self):
        roles = ['anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator','geolock_route_resolver']
        with auto.connect(self.lane.port,self.db,'postgres') as conn:
            with conn.cursor(row_factory=dict_row) as cur:
                rows = cur.execute("SELECT p.oid::regprocedure::text AS signature,r.rolname,has_function_privilege(r.oid,p.oid,'EXECUTE') AS execute FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace CROSS JOIN pg_roles r WHERE r.rolname=ANY(%s) AND (n.nspname='resolution_private' OR (n.nspname='public' AND p.proname IN('report_my_route_interruption','submit_route_resolution_evidence','get_my_route_resolution','get_my_route_resolution_receipt','get_route_resolution_for_operator','finalize_route_resolution','register_route_test_provenance','list_my_route_resolution_cases','report_route_resolution_incident'))) ORDER BY 1,2",(roles,)).fetchall()
        for row in rows:
            sig,role = row['signature'],row['rolname']
            allowed = not sig.startswith('resolution_private.') and ((role=='authenticated' and sig.split('(')[0] in ['report_my_route_interruption','submit_route_resolution_evidence','get_my_route_resolution','get_my_route_resolution_receipt','list_my_route_resolution_cases','report_route_resolution_incident']) or (role=='geolock_route_resolver' and sig.split('(')[0] in ['finalize_route_resolution','register_route_test_provenance','get_route_resolution_for_operator','get_my_route_resolution_receipt']))
            self.assertEqual(row['execute'],allowed, row)
        self.lane.save('resolution-effective-permissions.json',rows)

    def test_27_source_drift_and_collection_conflict(self):
        self.report(); self.consent()
        self.lane.sql("UPDATE public.donations SET pickup_address='LOCAL changed';")
        # Addresses are presentation-only in observe_task; change an authority input.
        self.lane.sql('UPDATE public.donations SET total_weight_kg=total_weight_kg+1;')
        with self.assertRaisesRegex(psycopg.Error,'CUSTODY_OR_OBSERVATION_CONFLICT'): self.finalize()

    def test_28_immutable_evidence_and_receipts(self):
        self.report(); self.evidence(self.stops[0]['task_id'],NO)
        for table in ['evidence','requests']:
            self.lane.sql('DELETE FROM resolution_private.'+table+';',expected='RESOLUTION_HISTORY_IMMUTABLE')

    def test_29_registered_synthetic_audit_labels(self):
        run = str(uuid4())
        self.rpc('register_route_test_provenance',{'p_run':run,'p_manifest':'a'*64,'p_ngo':auto.existing.NGO,'p_vehicle':self.vehicle_id,'p_claims':[s['claim_id'] for s in self.stops],'p_request':str(uuid4())},who='resolver')
        self.report();self.consent();self.finalize()
        self.assertEqual(self.scalar("SELECT count(*) FROM public.audit_events WHERE event_type='ROUTE_ABANDONED_RECONCILED' AND details->>'simulation'='true' AND details->>'test_run_id'='"+run+"'"),1)
        self.lane.save('resolution-synthetic-run.json',{'test_run_id':run,'manifest_digest':'a'*64})

    def test_30_mixed_test_route_rejected(self):
        self.rpc('register_route_test_provenance',{'p_run':str(uuid4()),'p_manifest':'a'*64,'p_ngo':auto.existing.NGO,'p_vehicle':self.vehicle_id,'p_claims':[self.stops[0]['claim_id']],'p_request':str(uuid4())},who='resolver')
        with self.assertRaisesRegex(psycopg.Error,'MIXED_SYNTHETIC_ROUTE_FORBIDDEN'):self.report()

    def test_31_no_direct_permit_or_client_flag(self):
        for role in ['authenticated','service_role','geolock_route_resolver']:
            self.lane.sql('SET ROLE '+role+'; SELECT * FROM resolution_private.permits;',expected='permission denied')
        self.lane.sql("SET route_resolution.permit='true'; UPDATE public.donations SET donation_status='AVAILABLE' WHERE donation_status='PICKUP_IN_PROGRESS';",expected='INVALID_DONATION_TRANSITION')

    def test_32_missing_receipt_and_operator_readonly(self):
        self.report()
        self.assertEqual(self.rpc('get_my_route_resolution_receipt',{'p_request':str(uuid4())},readonly=True)['outcome'],'NOT_FOUND')
        self.assertEqual(self.rpc('get_route_resolution_for_operator',{'p_case':self.case},who='resolver',readonly=True)['case']['case_id'],self.case)

    def test_33_unstarted_report_rejected(self):
        self.reset_template(self.unstarted_template)
        with self.assertRaisesRegex(psycopg.Error,'STARTED_OPEN_ROUTE_REQUIRED'):self.report()

    def test_34_collected_records_retained(self):
        self.rpc('complete_pickup',{'p_claim':self.stops[0]['claim_id'],'p_handover_confirmed':True})
        self.rpc('start_pickup',{'p_claim':self.stops[1]['claim_id']})
        stamp=self.scalar("SELECT collected_at FROM routing_private.items WHERE task_id='"+self.stops[0]['task_id']+"'")
        self.report()
        self.evidence(self.stops[1]['task_id'],NO);self.evidence(self.stops[1]['task_id'],NO,'donor');self.evidence(None,RETURN)
        self.finalize()
        self.assertEqual(self.scalar("SELECT collected_at FROM routing_private.items WHERE task_id='"+self.stops[0]['task_id']+"'"),stamp)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE donation_status='COLLECTED'"),1)
        self.lane.sql("UPDATE public.donations SET donation_status='AVAILABLE' WHERE donation_status='COLLECTED';",expected='INVALID_DONATION_TRANSITION')

    def test_35_legitimate_two_party_collection_does_not_close_route(self):
        self.report()
        for who in ['ngo','donor']:self.evidence(self.stops[0]['task_id'],'HANDOVER_TO_NGO_CONFIRMED',who)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.pickup_tasks WHERE task_status='COLLECTED'"),1)
        self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'),2)

    def test_36_replay_checks_current_grants_and_operator_mapping(self):
        request=str(uuid4());self.report(request)
        self.consent();version=self.read()['version'];final_request=str(uuid4());self.finalize(final_request,version)
        self.lane.sql('REVOKE EXECUTE ON FUNCTION public.get_my_route_resolution_receipt(uuid) FROM authenticated;')
        with self.assertRaises(psycopg.Error):self.rpc('get_my_route_resolution_receipt',{'p_request':request},readonly=True)
        self.lane.sql('UPDATE resolution_private.operators SET active=false;')
        with self.assertRaisesRegex(psycopg.Error,'RESTRICTED_RESOLVER_REQUIRED'):
            self.rpc('get_my_route_resolution_receipt',{'p_request':final_request},who='resolver',readonly=True)

    def test_37_hub_member_drift_is_not_partially_released(self):
        self.use_hub();self.report();self.evidence(self.stops[0]['task_id'],NO);self.evidence(self.stops[0]['task_id'],NO,'hub');self.evidence(None,RETURN)
        self.lane.sql('UPDATE public.hub_batches SET batch_donation_count=batch_donation_count+1;',expected='PUBLISHED_BATCH_IMMUTABLE')
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE donation_status='PICKUP_IN_PROGRESS'"),3)

    def test_38_mixed_hub_custody_is_not_released(self):
        self.use_hub();self.report();self.evidence(self.stops[0]['task_id'],NO);self.evidence(self.stops[0]['task_id'],NO,'hub');self.evidence(None,RETURN)
        self.lane.sql("UPDATE public.donations SET donation_status='COLLECTED' WHERE donation_id=(SELECT donation_id FROM public.donations WHERE collection_path='HUB_COLLECTION' LIMIT 1);",expected='BATCH_DONATION_SET_INCONSISTENT')
        self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'),1)

    def test_39_participant_inbox_is_scoped_and_readonly(self):
        self.report()
        for who, count in [('ngo',1),('donor',1),('other',0)]:
            result=self.rpc('list_my_route_resolution_cases',who=who,readonly=True)
            self.assertEqual(len(result['cases']),count)
        with self.assertRaises(psycopg.Error):self.rpc('list_my_route_resolution_cases',who='anon',readonly=True)

    def test_40_terminal_incident_no_state_resurrection(self):
        self.report();self.consent();self.finalize()
        version=self.read()['version'];req=str(uuid4())
        args={'p_case':self.case,'p_task':self.stops[0]['task_id'],'p_assertion':'UNKNOWN_CUSTODY','p_request':req}
        a=self.rpc('report_route_resolution_incident',args,who='donor')
        self.assertEqual(a,self.rpc('report_route_resolution_incident',args,who='donor'))
        self.assertEqual(self.read()['version'],version)
        self.assertEqual(self.scalar('SELECT route_status FROM public.pickup_routes'),'ABANDONED')
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.incidents'),1)
        self.lane.sql('DELETE FROM resolution_private.incidents;',expected='RESOLUTION_HISTORY_IMMUTABLE')
        with self.assertRaises(psycopg.Error):self.rpc('report_route_resolution_incident',args,who='other')

    def test_41_migration_replay_is_atomic(self):
        before=self.scalar('SELECT count(*) FROM pg_proc')
        self.lane.sql('',expected='FLEET_GUARD_BASELINE_DRIFT',exact_bytes=(ROOT/MIGRATION).read_bytes())
        self.assertEqual(self.scalar('SELECT count(*) FROM pg_proc'),before)

    def test_42_failed_install_rolls_back_and_drift_guard(self):
        self.reset_template(self.pristine_template)
        fault=(ROOT/MIGRATION).read_bytes().replace(b'CREATE SCHEMA resolution_private AUTHORIZATION postgres;',b"CREATE SCHEMA resolution_private AUTHORIZATION postgres; DO $$ BEGIN RAISE EXCEPTION 'LOCAL_INSTALL_FAULT'; END $$;")
        self.lane.sql('',expected='LOCAL_INSTALL_FAULT',exact_bytes=fault)
        self.assertIsNone(self.scalar("SELECT to_regnamespace('resolution_private')"))
        self.lane.sql("CREATE OR REPLACE FUNCTION public.recover_expired_claims(p_limit integer DEFAULT 100) RETURNS integer LANGUAGE sql AS $$ SELECT 0 $$;")
        self.lane.sql('',expected='RECOVERY_BASELINE_DRIFT',exact_bytes=(ROOT/MIGRATION).read_bytes())
        self.assertIsNone(self.scalar("SELECT to_regnamespace('resolution_private')"))

    def test_43_report_vs_completion(self):
        results=self.race(lambda:self.report(),lambda:self.rpc('complete_pickup',{'p_claim':self.stops[0]['claim_id'],'p_handover_confirmed':True}))
        self.assertIn('result',results[0])
        collected=self.scalar("SELECT task_status='COLLECTED' FROM public.pickup_tasks WHERE task_id='"+self.stops[0]['task_id']+"'")
        self.assertEqual(collected,'result' in results[1])
        self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'),2)

    def test_44_report_vs_next_start(self):
        self.rpc('complete_pickup',{'p_claim':self.stops[0]['claim_id'],'p_handover_confirmed':True})
        results=self.race(lambda:self.report(),lambda:self.rpc('start_pickup',{'p_claim':self.stops[1]['claim_id']}))
        self.assertIn('result',results[0])
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donation_claims WHERE claim_status='RECONCILIATION_REQUIRED'"),1)
        self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'),2)

    def test_45_report_vs_expired_recovery(self):
        self.lane.sql("UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second';")
        self.race(lambda:self.report(),lambda:self.scalar('SELECT public.recover_expired_claims(10)'))
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donation_claims WHERE claim_status='RECONCILIATION_REQUIRED'"),2)
        self.assertEqual(self.scalar('SELECT count(*) FROM public.claim_reconciliation_cases'),2)

    def test_46_finalize_vs_amendment(self):
        self.report();self.consent();v=self.read()['version']
        results=self.race(lambda:self.finalize(version=v),lambda:self.evidence(self.stops[0]['task_id'],'UNKNOWN_CUSTODY',version=v))
        if 'result' in results[0]:
            self.assertIn('error',results[1]);self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'),0)
        else:
            self.assertIn('result',results[1]);self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'),2)

    def test_47_finalize_vs_recovery_and_vehicle_edit(self):
        self.report();self.consent()
        results=self.race(lambda:self.finalize(),lambda:self.scalar('SELECT public.recover_expired_claims(10)'))
        self.assertIn('result',results[0]);self.assertEqual(results[1]['result'],0)
        self.assertFalse(self.scalar("SELECT fleet_private.vehicle_has_hold('"+self.vehicle_id+"')"))

    def test_48_new_claims_compete_after_release(self):
        self.report();self.consent();self.finalize()
        self.lane.sql('SELECT public.process_listing_eligibility_refresh_jobs();')
        listing=self.scalar("SELECT listing_id::text FROM public.pickup_tasks WHERE task_id='"+self.stops[0]['task_id']+"'")
        old={s['claim_id'] for s in self.stops}
        admission=self.scalar('SELECT clock_timestamp()')
        results=self.race(lambda:self.rpc('claim_listing',{'p_listing':listing,'p_request':str(uuid4())}),lambda:self.rpc('claim_listing',{'p_listing':listing,'p_request':str(uuid4())},who='other'))
        winners=[r['result'] for r in results if r.get('result',{}).get('outcome')=='SUCCESS']
        self.assertEqual(len(winners),1,results)
        self.assertNotIn(winners[0]['claim_id'],old)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donation_claims WHERE claim_status='ACTIVE'"),1)
        with auto.connect(self.lane.port,self.db,'postgres') as conn:
            issued,expires=conn.execute('SELECT issued_at,expires_at FROM public.claim_leases WHERE claim_id=%s',(winners[0]['claim_id'],)).fetchone()
        self.assertGreaterEqual(issued,admission)
        self.assertAlmostEqual((expires-issued).total_seconds(),360*60,delta=1)
        self.lane.save('resolution-new-claim-lease.json',{'old_claim_ids':sorted(old),'new_claim_id':winners[0]['claim_id'],'issued_at':issued.isoformat(),'expires_at':expires.isoformat(),'duration_minutes':(expires-issued).total_seconds()/60})

    def test_49_another_route_hold_and_history_preserved(self):
        other=self.rpc('register_my_vehicle',{'p_request_id':str(uuid4()),'p_label':'UNRELATED LOCAL','p_vehicle_type':'VAN','p_capacity_kg':100,'p_fixed_cost_rm':10,'p_distance_cost_rm_per_km':1,'p_max_route_duration_min':60,'p_available':True})['vehicle_id']
        unrelated=str(uuid4())
        # Seed an unrelated DRAFT hold only. This is not simulated authorization.
        self.lane.sql(f"INSERT INTO public.pickup_routes SELECT (jsonb_populate_record(NULL::public.pickup_routes,to_jsonb(r)||jsonb_build_object('route_id','{unrelated}','vehicle_id','{other}','route_status','DRAFT'))).* FROM public.pickup_routes r WHERE route_id='{self.rid}';")
        before=self.scalar("SELECT to_jsonb(v) FROM public.vehicles v WHERE vehicle_id='"+other+"'")
        counts=self.scalar("SELECT jsonb_build_array((SELECT count(*) FROM routing_private.snapshots),(SELECT count(*) FROM routing_private.candidates),(SELECT count(*) FROM routing_private.validations),(SELECT count(*) FROM routing_private.matrices),(SELECT count(*) FROM public.pickup_route_stops))")
        self.report();self.consent();self.finalize()
        self.assertEqual(self.scalar("SELECT to_jsonb(v) FROM public.vehicles v WHERE vehicle_id='"+other+"'"),before)
        self.assertTrue(self.scalar("SELECT fleet_private.vehicle_has_hold('"+other+"')"))
        self.assertEqual(self.scalar("SELECT jsonb_build_array((SELECT count(*) FROM routing_private.snapshots),(SELECT count(*) FROM routing_private.candidates),(SELECT count(*) FROM routing_private.validations),(SELECT count(*) FROM routing_private.matrices),(SELECT count(*) FROM public.pickup_route_stops))"),counts)

    def test_50_every_private_table_and_column_is_denied(self):
        for role in ['anon','authenticated','service_role','geolock_route_resolver','geolock_planner','geolock_validator','geolock_graph_worker']:
            self.assertEqual(self.scalar("SELECT count(*) FROM pg_class t WHERE relnamespace='resolution_private'::regnamespace AND relkind IN('r','p') AND (has_table_privilege('"+role+"',t.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_any_column_privilege('"+role+"',t.oid,'SELECT,INSERT,UPDATE,REFERENCES'))"),0)

    def test_51_privileged_helper_without_finalizer_denied(self):
        self.report();self.consent()
        listing=self.scalar("SELECT listing_id::text FROM public.pickup_tasks WHERE task_id='"+self.stops[0]['task_id']+"'")
        self.lane.sql("SELECT public.geolock_transition_listing_donations('"+listing+"','PICKUP_IN_PROGRESS','AVAILABLE','"+self.stops[0]['claim_id']+"','"+str(uuid4())+"','NOT_FINALIZER');",expected='INVALID_DONATION_TRANSITION')

    def test_52_vehicle_drift_retains_all_holds(self):
        self.report();self.consent()
        self.lane.sql('UPDATE public.vehicles SET vehicle_version=vehicle_version+1;',expected='VEHICLE_METADATA_MANAGED')
        self.lane.sql("UPDATE public.vehicles SET vehicle_label='UNSAFE EDIT';",expected='VEHICLE_HAS_ACTIVE_ROUTE')
        self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'),2)

    def test_53_hub_mid_member_failure_is_atomic(self):
        self.use_hub();self.report();self.evidence(self.stops[0]['task_id'],NO);self.evidence(self.stops[0]['task_id'],NO,'hub');self.evidence(None,RETURN)
        self.lane.sql("CREATE FUNCTION public.hub_member_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.event_type='DONATION_STATUS_CHANGED' AND (SELECT count(*) FROM public.donations WHERE collection_path='HUB_COLLECTION' AND donation_status='BATCHED')=2 THEN RAISE EXCEPTION 'LOCAL_SECOND_MEMBER_FAILURE'; END IF; RETURN NEW; END $$; CREATE TRIGGER hub_member_fault BEFORE INSERT ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.hub_member_fault();")
        with self.assertRaisesRegex(psycopg.Error,'LOCAL_SECOND_MEMBER_FAILURE'):self.finalize()
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE collection_path='HUB_COLLECTION' AND donation_status='PICKUP_IN_PROGRESS'"),3)
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.releases'),0)

    def test_54_collected_commit_survives_later_finalizer_failure(self):
        self.rpc('complete_pickup',{'p_claim':self.stops[0]['claim_id'],'p_handover_confirmed':True})
        self.report();self.evidence(self.stops[1]['task_id'],NO);self.evidence(self.stops[1]['task_id'],NO,'donor');self.evidence(None,RETURN)
        self.lane.sql("CREATE FUNCTION public.final_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'LOCAL_FINAL_FAILURE'; END $$; CREATE TRIGGER final_fault BEFORE INSERT ON resolution_private.finalizations FOR EACH ROW EXECUTE FUNCTION public.final_fault();")
        with self.assertRaisesRegex(psycopg.Error,'LOCAL_FINAL_FAILURE'):self.finalize()
        self.assertEqual(self.scalar("SELECT count(*) FROM public.pickup_tasks WHERE task_status='COLLECTED'"),1)
        self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'),2)

    def test_55_normal_pickup_and_depot_return_regression(self):
        for stop in self.stops:
            if stop != self.stops[0]:self.rpc('start_pickup',{'p_claim':stop['claim_id']})
            self.rpc('complete_pickup',{'p_claim':stop['claim_id'],'p_handover_confirmed':True})
        self.rpc('close_my_collected_route',{'p_route':self.rid,'p_depot_return_confirmed':True})
        self.assertEqual(self.scalar('SELECT route_status FROM public.pickup_routes'),'COMPLETED')
        self.assertFalse(self.scalar("SELECT fleet_private.vehicle_has_hold('"+self.vehicle_id+"')"))

    def test_56_normal_unstarted_cancellation_regression(self):
        self.reset_template(self.unstarted_template)
        self.rpc('cancel_my_unstarted_route',{'p_route':self.rid})
        self.assertEqual(self.scalar('SELECT route_status FROM public.pickup_routes'),'CANCELLED')

    def test_57_no_client_provenance_or_deadline_bypass(self):
        self.lane.sql("INSERT INTO public.audit_events(actor_role,entity_type,entity_id,event_type,outcome,details) VALUES('SYSTEM','ROUTE','"+self.rid+"','LOCAL','SUCCESS','{\"simulation\":true}');",expected='CLIENT_TEST_PROVENANCE_FORBIDDEN')
        self.lane.sql("UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second';")
        with self.assertRaises(psycopg.Error):self.rpc('complete_pickup',{'p_claim':self.stops[0]['claim_id'],'p_handover_confirmed':True})

    def test_58_source_sees_only_its_own_items(self):
        source=str(uuid4());self.lane.sql(f"INSERT INTO auth.users(id,email) VALUES('{source}','otherdonor@local.invalid'); INSERT INTO public.user_profiles(user_id,full_name,role) VALUES('{source}','OTHER DONOR','DONOR'); INSERT INTO public.donor_profiles(user_id) VALUES('{source}'); UPDATE public.donations SET donor_user_id='{source}' WHERE donation_id=(SELECT donation_id FROM public.listings WHERE listing_id=(SELECT listing_id FROM public.pickup_tasks WHERE task_id='{self.stops[1]['task_id']}'));")
        self.report();self.assertEqual(len(self.read('donor')['items']),1)
        with self.assertRaises(psycopg.Error):self.evidence(self.stops[1]['task_id'],NO,'donor')

    def test_59_finalization_write_phase_faults_all_rollback(self):
        self.report();self.consent()
        before=self.resolution_state_digest()
        for schema,table,event in [('resolution_private','releases','INSERT'),('resolution_private','permits','INSERT'),('resolution_private','finalizations','INSERT'),('public','pickup_tasks','UPDATE'),('public','donation_claims','UPDATE'),('public','claim_leases','UPDATE'),('public','listings','UPDATE'),('public','claim_reconciliation_cases','UPDATE'),('public','active_task_route_assignments','DELETE'),('routing_private','items','UPDATE'),('routing_private','bindings','UPDATE'),('resolution_private','cases','UPDATE'),('public','pickup_routes','UPDATE')]:
            self.lane.sql(f"CREATE FUNCTION public.phase_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'LOCAL_PHASE_FAULT'; END $$; CREATE TRIGGER phase_fault BEFORE {event} ON {schema}.{table} FOR EACH ROW EXECUTE FUNCTION public.phase_fault();")
            with self.assertRaisesRegex(psycopg.Error,'LOCAL_PHASE_FAULT'):self.finalize()
            self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'),2)
            self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.releases'),0)
            self.assertEqual(self.resolution_state_digest(),before)
            self.lane.sql(f'DROP TRIGGER phase_fault ON {schema}.{table}; DROP FUNCTION public.phase_fault();')

    def test_60_function_metadata_and_security(self):
        rows=self.lane.js("SELECT jsonb_agg(jsonb_build_object('signature',p.oid::regprocedure::text,'body_md5',md5(replace(p.prosrc,E'\\r\\n',E'\\n')),'owner',p.proowner::regrole::text,'stable',p.provolatile='s','security_definer',p.prosecdef,'config',p.proconfig,'acl',p.proacl::text) ORDER BY p.oid::regprocedure::text) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='resolution_private' OR (n.nspname='public' AND p.proname IN('report_my_route_interruption','submit_route_resolution_evidence','get_my_route_resolution','get_my_route_resolution_receipt','get_route_resolution_for_operator','finalize_route_resolution','register_route_test_provenance','list_my_route_resolution_cases','report_route_resolution_incident','enforce_donation_transition')) OR (n.nspname='fleet_private' AND p.proname='route_vehicle_guard');")
        for row in rows:
            self.assertEqual(row['owner'],'postgres')
            if row['signature'].split('(')[0] in ['get_my_route_resolution','get_my_route_resolution_receipt','list_my_route_resolution_cases','get_route_resolution_for_operator']:self.assertTrue(row['stable'])
            if row['security_definer']:self.assertEqual(row['config'],['search_path=pg_catalog, pg_temp'])
        self.lane.save('resolution-reviewed-function-metadata.json',rows)

    def test_61_explicit_and_automatic_departure_regression(self):
        # Execute the existing regression unchanged against this new migration.
        fixture=type(self)();auto.AutomaticTests.setUp(fixture)
        try:auto.AutomaticTests.test_explicit_departure_preserved_and_past_rejected(fixture)
        finally:fixture.doCleanups();self.lane.db=self.db
        # The direct/hub templates were separately authorized with NULL departure.
        self.assertEqual(self.scalar('SELECT count(*) FROM routing_private.bindings'),1)

    def test_62_wrong_owner_absent_and_terminal_report(self):
        args={'p_route':self.rid,'p_reason':'VEHICLE_FAILURE','p_request':str(uuid4())}
        for who in ['donor','other','anon']:
            with self.assertRaises(psycopg.Error):self.rpc('report_my_route_interruption',args,who=who)
        with self.assertRaises(psycopg.Error):self.rpc('report_my_route_interruption',{**args,'p_route':str(uuid4())})
        self.report();self.consent();self.finalize()
        with self.assertRaisesRegex(psycopg.Error,'STARTED_OPEN_ROUTE_REQUIRED'):self.rpc('report_my_route_interruption',args)

    def test_63_finalize_vs_report_and_vehicle_edit(self):
        self.report();self.consent();v=self.read()['version']
        results=self.race(lambda:self.finalize(version=v),lambda:self.rpc('set_my_vehicle_availability',{'p_vehicle_id':self.vehicle_id,'p_expected_version':1,'p_available':False}),lambda:self.report())
        self.assertIn('result',results[0]);self.assertEqual(self.scalar("SELECT route_status FROM public.pickup_routes"),'ABANDONED')

    def test_64_report_vs_legacy_reconciliation_preserves_holds(self):
        self.seed_legacy_route_case()
        self.race(lambda:self.report(),lambda:self.rpc('submit_claim_reconciliation',{'p_claim':self.stops[0]['claim_id'],'p_handover_confirmed':False,'p_request':str(uuid4())}))
        self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'),2)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donation_claims WHERE claim_status='RELEASED'"),0)

    def test_65_finalize_vs_legacy_handover_never_falsely_releases(self):
        self.seed_legacy_route_case()
        self.report();self.consent();v=self.read()['version']
        results=self.race(lambda:self.finalize(version=v),lambda:self.rpc('submit_claim_reconciliation',{'p_claim':self.stops[0]['claim_id'],'p_handover_confirmed':True,'p_request':str(uuid4())}))
        if 'result' in results[0]:
            self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE donation_status='COLLECTED'"),0)
        else:
            self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'),2)
            self.assertEqual(self.scalar("SELECT count(*) FROM public.donation_claims WHERE claim_status='RELEASED'"),0)

    def test_66_registered_simulated_collection_and_return_labels(self):
        run=str(uuid4());self.rpc('register_route_test_provenance',{'p_run':run,'p_manifest':'b'*64,'p_ngo':auto.existing.NGO,'p_vehicle':self.vehicle_id,'p_claims':[s['claim_id'] for s in self.stops],'p_request':str(uuid4())},who='resolver')
        self.rpc('complete_pickup',{'p_claim':self.stops[0]['claim_id'],'p_handover_confirmed':True})
        self.report();self.evidence(self.stops[1]['task_id'],NO);self.evidence(self.stops[1]['task_id'],NO,'donor');self.evidence(None,RETURN);self.finalize()
        self.assertGreater(self.scalar("SELECT count(*) FROM public.audit_events WHERE event_type='DONATION_STATUS_CHANGED' AND resulting_state='COLLECTED' AND details->>'simulation'='true' AND details->>'test_run_id'='"+run+"'"),0)
        self.assertTrue(self.read()['simulation'])

    def test_67_hub_unsafe_listing_stays_manual_review(self):
        self.use_hub();self.lane.sql("UPDATE public.listings SET listing_expires_at=clock_timestamp()-interval '1 second' WHERE source_type='HUB_BATCH';")
        self.report();self.evidence(self.stops[0]['task_id'],NO);self.evidence(self.stops[0]['task_id'],NO,'hub');self.evidence(None,RETURN)
        self.assertEqual(self.finalize()['status'],'MANUAL_REVIEW')
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE collection_path='HUB_COLLECTION' AND donation_status='PICKUP_IN_PROGRESS'"),3)
        self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'),1)

    def test_68_abandoned_protected_display_preserves_original_itinerary(self):
        before=self.rpc('get_my_authorized_route',{'p_route':self.rid})
        self.report();self.consent();self.finalize()
        after=self.rpc('get_my_authorized_route',{'p_route':self.rid})
        for key in ['depot','vehicle_id','total_distance_km','total_duration_min']:
            self.assertEqual(after.get(key),before.get(key),key)
        self.assertEqual([s['task_id'] for s in before['stops']],[s['task_id'] for s in after['stops']])
        self.assertFalse(after['authorization_confirmed'])
        self.assertFalse(after['can_close'])
        self.assertFalse(any(s['can_start'] or s['can_complete'] for s in after['stops']))

    def test_69_old_transaction_permit_cannot_authorize_privileged_wrapper(self):
        self.report();self.consent()
        self.lane.sql(f"INSERT INTO resolution_private.permits VALUES('{self.stops[0]['task_id']}','{self.case}',pg_current_xact_id()); CREATE FUNCTION public.local_nonfinalizer() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ BEGIN UPDATE public.donations SET donation_status='AVAILABLE' WHERE donation_status='PICKUP_IN_PROGRESS'; END $$; GRANT EXECUTE ON FUNCTION public.local_nonfinalizer() TO geolock_route_resolver;")
        with auto.connect(self.lane.port,self.db,'geolock_local_resolver') as conn:
            with self.assertRaisesRegex(psycopg.Error,'INVALID_DONATION_TRANSITION'):
                conn.execute('SELECT public.local_nonfinalizer()')
            conn.rollback()
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE donation_status='PICKUP_IN_PROGRESS'"),1)

    def test_70_conflicting_parties_explicitly_require_manual_review(self):
        self.report();self.evidence(self.stops[0]['task_id'],'HANDOVER_TO_NGO_CONFIRMED')
        self.evidence(self.stops[0]['task_id'],NO,'donor')
        self.assertEqual(self.read()['status'],'MANUAL_REVIEW')
        self.assertEqual(self.scalar('SELECT count(*) FROM public.active_task_route_assignments'),2)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donation_claims WHERE claim_status='RELEASED'"),0)

    def test_71_report_preserves_all_lease_and_execution_timestamps(self):
        query="""SELECT jsonb_build_object(
          'leases',(SELECT jsonb_agg(jsonb_build_object('id',lease_id,'issued',issued_at,'expires',expires_at,'closed',closed_at) ORDER BY lease_id) FROM public.claim_leases),
          'claims',(SELECT jsonb_agg(jsonb_build_object('id',claim_id,'claimed',claimed_at,'closed',closed_at) ORDER BY claim_id) FROM public.donation_claims),
          'bindings',(SELECT jsonb_agg(jsonb_build_object('id',route_id,'departure',departure_at,'started',started_at,'closed',closed_at) ORDER BY route_id) FROM routing_private.bindings),
          'items',(SELECT jsonb_agg(jsonb_build_object('id',task_id,'consumed',consumed_at,'collected',collected_at,'released',released_at) ORDER BY task_id) FROM routing_private.items))"""
        before=self.scalar(query);self.report();self.assertEqual(self.scalar(query),before)
        self.lane.save('resolution-report-timestamps.json',{'all_fields_unchanged':True,'timestamps':before})

    def test_72_missing_or_inconsistent_case_item_fails_closed(self):
        self.report();self.consent()
        self.lane.sql(f"DELETE FROM resolution_private.items WHERE case_id='{self.case}' AND task_id='{self.stops[1]['task_id']}';")
        before=self.resolution_state_digest()
        with self.assertRaises(psycopg.Error):self.finalize()
        self.assertEqual(self.resolution_state_digest(),before)
        self.reset_template(self.template);self.report();self.consent()
        self.lane.sql(f"UPDATE resolution_private.items SET claim_id='{self.stops[1]['claim_id']}' WHERE case_id='{self.case}' AND task_id='{self.stops[0]['task_id']}';")
        before=self.resolution_state_digest()
        with self.assertRaises(psycopg.Error):self.finalize()
        self.assertEqual(self.resolution_state_digest(),before)

    def test_73_self_counterparty_and_revoked_sql_access(self):
        self.report();self.consent()
        self.lane.sql(f"UPDATE resolution_private.items SET source_actor='{auto.existing.NGO}' WHERE case_id='{self.case}';")
        before=self.resolution_state_digest()
        with self.assertRaisesRegex(psycopg.Error,'SOURCE_PARTICIPANT_DRIFT'):self.finalize()
        self.assertEqual(self.resolution_state_digest(),before)
        self.reset_template(self.template);req=str(uuid4());self.report(req)
        self.lane.sql('REVOKE EXECUTE ON FUNCTION public.get_my_route_resolution(uuid),public.get_my_route_resolution_receipt(uuid),public.submit_route_resolution_evidence(uuid,uuid,text,bigint,uuid),public.report_my_route_interruption(uuid,text,uuid) FROM authenticated;')
        for who in ['ngo','donor']:
            with self.assertRaises(psycopg.Error):self.read(who)
            with self.assertRaises(psycopg.Error):self.rpc('get_my_route_resolution_receipt',{'p_request':req},who=who,readonly=True)
            with self.assertRaises(psycopg.Error):self.rpc('submit_route_resolution_evidence',{'p_case':self.case,'p_task':self.stops[0]['task_id'],'p_assertion':NO,'p_version':1,'p_request':str(uuid4())},who=who)

    def test_74_terminal_consumers_and_unchanged_recovery(self):
        self.report();self.consent();self.finalize()
        before=self.resolution_state_digest()
        self.assertEqual(self.scalar('SELECT public.recover_expired_claims(100)'),0)
        self.assertEqual(self.resolution_state_digest(),before)
        detail=self.rpc('get_my_authorized_route',{'p_route':self.rid})
        self.assertFalse(detail['authorization_confirmed']);self.assertFalse(detail['can_close'])
        for name,args in [('start_pickup',{'p_claim':self.stops[0]['claim_id']}),('complete_pickup',{'p_claim':self.stops[0]['claim_id'],'p_handover_confirmed':True}),('close_my_collected_route',{'p_route':self.rid,'p_depot_return_confirmed':True}),('cancel_my_unstarted_route',{'p_route':self.rid})]:
            with self.assertRaises(psycopg.Error):self.rpc(name,args)
        self.assertFalse(self.scalar("SELECT fleet_private.vehicle_has_hold('"+self.vehicle_id+"')"))
        inventory=self.lane.js("SELECT jsonb_agg(jsonb_build_object('signature',p.oid::regprocedure::text,'md5',md5(replace(prosrc,E'\\r\\n',E'\\n')),'explicit_abandoned',prosrc LIKE '%ABANDONED%') ORDER BY p.oid::regprocedure::text) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN('public','routing_private','fleet_private') AND prosrc LIKE '%route_status%';")
        self.lane.save('resolution-terminal-consumers.json',{'functions':inventory,'review':'Fleet guard explicitly recognizes ABANDONED; positive active-state gates reject it; legacy conservative route-evidence predicates remain unchanged and skip RELEASED claims. Normal completion/cancel, protected reads, claim reuse and cross-NGO holds tested separately.','recovery_unchanged':True})

    def test_75_expired_unstarted_stop_is_released_and_next_stop_is_authorized(self):
        self.reset_template(self.unstarted_template)
        first, second = self.stops
        self.lane.sql(f"UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '7 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE claim_id='{first['claim_id']}'; SELECT public.recover_expired_claims(100);")
        before=self.rpc('get_my_authorized_route',{'p_route':self.rid})
        executable=next(s for s in before['stops'] if s['task_id']==second['task_id'])
        self.assertTrue(executable['can_start'])
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"),'RELEASED')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"),'STALE')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='{self.rid}'"),1)
        self.rpc('start_pickup',{'p_claim':second['claim_id']})
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{second['task_id']}'"),'DISPATCHED')

    def test_76_individual_no_handover_releases_only_deferred_stop_and_mixed_close_is_idempotent(self):
        self.reset_template(self.unstarted_template)
        first, second = self.stops
        self.seed_uncertain_claim(first['claim_id'])
        defer_request=str(uuid4())
        self.rpc('defer_my_pickup_for_reconciliation',{'p_claim':first['claim_id'],'p_request':defer_request})
        self.rpc('start_pickup',{'p_claim':second['claim_id']})
        self.rpc('complete_pickup',{'p_claim':second['claim_id'],'p_handover_confirmed':True})
        with self.assertRaisesRegex(psycopg.Error,'ROUTE_HAS_UNRESOLVED_TASKS'):
            self.rpc('close_my_collected_route',{'p_route':self.rid,'p_depot_return_confirmed':True})
        detail=self.rpc('get_my_authorized_route',{'p_route':self.rid})
        self.assertTrue(detail['awaiting_individual_reconciliation'])
        ngo_request=str(uuid4());donor_request=str(uuid4())
        first_evidence=self.rpc('submit_claim_reconciliation',{'p_claim':first['claim_id'],'p_handover_confirmed':False,'p_request':ngo_request})
        self.assertEqual(first_evidence['outcome'],'AWAITING_COUNTERPART')
        result=self.rpc('submit_claim_reconciliation',{'p_claim':first['claim_id'],'p_handover_confirmed':False,'p_request':donor_request},who='donor')
        self.assertEqual(result['outcome'],'SUCCESS')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"),'STALE')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE task_id='{first['task_id']}'"),0)
        self.assertEqual(self.scalar(f"SELECT status FROM routing_private.deferred_stops WHERE task_id='{first['task_id']}'"),'RESOLVED_UNCOLLECTED')
        self.assertEqual(self.scalar(f"SELECT donation_status FROM public.donations WHERE donation_id=(SELECT donation_id FROM public.listings WHERE listing_id=(SELECT listing_id FROM public.donation_claims WHERE claim_id='{first['claim_id']}'))"),'AVAILABLE')
        ready=self.rpc('get_my_authorized_route',{'p_route':self.rid})
        self.assertTrue(ready['can_close']);self.assertEqual(ready['closure_outcome'],'ABANDONED')
        request=str(uuid4())
        missing=self.rpc('get_my_mixed_route_close_receipt',{'p_request':request},readonly=True)
        self.assertFalse(missing['found'])
        closed=self.rpc('close_my_resolved_route',{'p_route':self.rid,'p_depot_return_confirmed':True,'p_request':request})
        self.assertEqual(closed['route_status'],'ABANDONED')
        receipt=self.rpc('get_my_mixed_route_close_receipt',{'p_request':request},readonly=True)
        self.assertTrue(receipt['found']);self.assertEqual(receipt['result'],closed)
        self.assertEqual(self.scalar('SELECT route_status FROM public.pickup_routes WHERE route_id=\''+self.rid+'\''),'ABANDONED')

    def test_77_dispatched_pickup_cannot_be_deferred_across_uncertain_custody(self):
        self.reset_template(self.template)
        first,second=self.stops
        with self.assertRaisesRegex(psycopg.Error,'PICKUP_CUSTODY_REQUIRES_RECONCILIATION'):
            self.rpc('defer_my_pickup_for_reconciliation',{'p_claim':first['claim_id'],'p_request':str(uuid4())})
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"),'DISPATCHED')
        self.assertEqual(self.scalar("SELECT count(*) FROM routing_private.deferred_stops WHERE route_id='"+self.rid+"'"),0)
        self.assert_holds()

    def test_78_whole_route_interruption_cannot_be_deferred_stop_by_stop(self):
        self.reset_template(self.template)
        self.report()
        stop=self.stops[1]
        with self.assertRaisesRegex(psycopg.Error,'WHOLE_ROUTE_INTERRUPTION_REQUIRES_RECONCILIATION'):
            self.rpc('defer_my_pickup_for_reconciliation',{'p_claim':stop['claim_id'],'p_request':str(uuid4())})
        self.assertEqual(self.scalar("SELECT count(*) FROM resolution_private.cases WHERE route_id='"+self.rid+"' AND status='AWAITING_EVIDENCE'"),1)
        self.assertEqual(self.scalar("SELECT count(*) FROM routing_private.deferred_stops WHERE route_id='"+self.rid+"'"),0)

    def test_79_foreign_ngo_cannot_defer_owned_stop(self):
        self.reset_template(self.template)
        stop=self.stops[1]
        with self.assertRaises(psycopg.Error):
            self.rpc('defer_my_pickup_for_reconciliation',{'p_claim':stop['claim_id'],'p_request':str(uuid4())},who='other')
        self.assertEqual(self.scalar("SELECT count(*) FROM routing_private.deferred_stops WHERE route_id='"+self.rid+"'"),0)

    def test_80_hub_batch_deferral_preserves_the_atomic_task_and_inventory(self):
        self.reset_template(self.hub_unstarted_template)
        self.rid,self.stops,self.vehicle_id=self.hub_meta
        stop=self.stops[0]
        self.seed_uncertain_claim(stop['claim_id'])
        self.rpc('defer_my_pickup_for_reconciliation',{'p_claim':stop['claim_id'],'p_request':str(uuid4())})
        self.assertEqual(self.scalar(f"SELECT count(*) FROM routing_private.items WHERE route_id='{self.rid}'"),1)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.hub_batch_members WHERE membership_status='ACTIVE'"),3)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.hub_inventory WHERE inventory_status='BATCHED'"),3)
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{stop['task_id']}'"),'PLANNED')
        with self.assertRaisesRegex(psycopg.Error,'RECONCILIATION_PARTICIPANT_ONLY'):
            self.rpc('submit_claim_reconciliation',{'p_claim':stop['claim_id'],'p_handover_confirmed':False,'p_request':str(uuid4())},who='donor')
        ngo_result=self.rpc('submit_claim_reconciliation',{'p_claim':stop['claim_id'],'p_handover_confirmed':False,'p_request':str(uuid4())})
        self.assertEqual(ngo_result['outcome'],'AWAITING_COUNTERPART')
        hub_result=self.rpc('submit_claim_reconciliation',{'p_claim':stop['claim_id'],'p_handover_confirmed':False,'p_request':str(uuid4())},who='hub')
        self.assertEqual(hub_result['outcome'],'SUCCESS')
        self.assertEqual(self.scalar("SELECT count(*) FROM public.hub_batch_members WHERE membership_status='ACTIVE'"),3)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.hub_inventory WHERE inventory_status='BATCHED'"),3)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE donation_status='BATCHED'"),3)

    def test_81_recovered_pre_pickup_expiry_is_safely_released(self):
        self.reset_template(self.unstarted_template)
        first=self.stops[0]
        self.lane.sql(f"UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '7 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE claim_id='{first['claim_id']}';")
        expired=self.rpc('get_my_authorized_route',{'p_route':self.rid})
        stop=next(s for s in expired['stops'] if s['task_id']==first['task_id'])
        self.assertFalse(stop['needs_reconciliation']);self.assertFalse(stop['can_defer'])
        self.assertTrue(stop['lease_expired_pending_recovery'])
        with self.assertRaisesRegex(psycopg.Error,'CLAIM_RECONCILIATION_NOT_READY'):
            self.rpc('defer_my_pickup_for_reconciliation',{'p_claim':first['claim_id'],'p_request':str(uuid4())})
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"),'ACTIVE')
        self.lane.sql('SELECT public.recover_expired_claims(100);')
        ready=self.rpc('get_my_authorized_route',{'p_route':self.rid})
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"),'RELEASED')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"),'STALE')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.claim_reconciliation_cases WHERE claim_id='{first['claim_id']}'"),0)
        self.assertTrue(next(s for s in ready['stops'] if s['task_id']==self.stops[1]['task_id'])['can_start'])

    def test_83_direct_donor_reader_is_owned_and_donation_scoped(self):
        self.reset_template(self.unstarted_template)
        first=self.stops[0]
        self.seed_uncertain_claim(first['claim_id'])
        self.rpc('defer_my_pickup_for_reconciliation',{'p_claim':first['claim_id'],'p_request':str(uuid4())})
        donation=self.scalar(f"SELECT donation_id FROM public.listings WHERE listing_id=(SELECT listing_id FROM public.donation_claims WHERE claim_id='{first['claim_id']}')")
        read=self.rpc('get_my_donation_claim_reconciliation',{'p_donation':donation},who='donor',readonly=True)
        self.assertEqual(read['contract'],'geolock.donor-claim-reconciliation.v1')
        row=next(r for r in read['contexts'] if r['claim_id']==first['claim_id'])
        self.assertTrue(row['can_submit_evidence']);self.assertEqual(row['task_id'],first['task_id'])
        self.assertEqual(row['source_type'],'DIRECT_DONATION')
        with self.assertRaises(psycopg.Error):
            self.rpc('get_my_donation_claim_reconciliation',{'p_donation':donation},who='other',readonly=True)

    def test_84_donor_claim_receipt_is_private_to_evidence_participants(self):
        self.reset_template(self.unstarted_template)
        first=self.stops[0]
        self.seed_uncertain_claim(first['claim_id'])
        self.rpc('defer_my_pickup_for_reconciliation',{'p_claim':first['claim_id'],'p_request':str(uuid4())})
        req=str(uuid4())
        self.rpc('submit_claim_reconciliation',{'p_claim':first['claim_id'],'p_handover_confirmed':False,'p_request':req})
        self.rpc('submit_claim_reconciliation',{'p_claim':first['claim_id'],'p_handover_confirmed':False,'p_request':str(uuid4())},who='donor')
        receipt=self.rpc('get_my_claim_reconciliation_receipt',{'p_request':req},who='ngo',readonly=True)
        self.assertTrue(receipt['found']);self.assertEqual(receipt['claim_id'],first['claim_id'])
        denied=self.rpc('get_my_claim_reconciliation_receipt',{'p_request':req},who='other',readonly=True)
        self.assertFalse(denied['found'])

    def test_85_deferred_pickup_receipt_is_request_scoped_and_linearizable(self):
        self.reset_template(self.unstarted_template)
        first=self.stops[0]
        self.seed_uncertain_claim(first['claim_id'])
        request=str(uuid4())
        before=self.rpc('get_my_deferred_pickup_receipt',{'p_request':request},readonly=True)
        self.assertFalse(before['found'])
        result=self.rpc('defer_my_pickup_for_reconciliation',{'p_claim':first['claim_id'],'p_request':request})
        after=self.rpc('get_my_deferred_pickup_receipt',{'p_request':request},readonly=True)
        self.assertTrue(after['found']);self.assertEqual(after['result'],result)
        self.assertEqual(after['task_id'],first['task_id']);self.assertEqual(after['route_id'],self.rid)
        self.assertEqual(self.rpc('defer_my_pickup_for_reconciliation',{'p_claim':first['claim_id'],'p_request':request}),result)
        foreign=self.rpc('get_my_deferred_pickup_receipt',{'p_request':request},who='other',readonly=True)
        self.assertFalse(foreign['found'])

    def test_90_expiry_releases_unstarted_active_route_stop_and_preserves_vehicle_close(self):
        self.reset_template(self.unstarted_template)
        first, second = self.stops
        self.lane.sql(f"UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '7 hours',expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{first['claim_id']}'; SELECT public.recover_expired_claims(100);")
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"),'RELEASED')
        self.assertEqual(self.scalar(f"SELECT l.listing_status FROM public.listings l JOIN public.pickup_tasks t USING(listing_id) WHERE t.task_id='{first['task_id']}'"),'AVAILABLE')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"),'STALE')
        self.assertEqual(self.scalar(f"SELECT status FROM routing_private.deferred_stops WHERE task_id='{first['task_id']}'"),'RESOLVED_UNCOLLECTED')
        self.assertEqual(self.scalar(f"SELECT released_at IS NOT NULL AND consumed_at IS NULL FROM routing_private.items WHERE task_id='{first['task_id']}'"),True)
        self.assertEqual(self.scalar('SELECT count(*) FROM public.claim_reconciliation_cases'),0)
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.cases'),0)
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE task_id='{second['task_id']}'"),1)
        route=self.rpc('get_my_authorized_route',{'p_route':self.rid})
        self.assertTrue(next(x for x in route['stops'] if x['task_id']==second['task_id'])['can_start'])
        self.rpc('start_pickup',{'p_claim':second['claim_id']})
        self.rpc('complete_pickup',{'p_claim':second['claim_id'],'p_handover_confirmed':True})
        with self.assertRaisesRegex(psycopg.Error,'DEPOT_RETURN_CONFIRMATION_REQUIRED'):
            self.rpc('close_my_resolved_route',{'p_route':self.rid,'p_depot_return_confirmed':False,'p_request':str(uuid4())})
        closed=self.rpc('close_my_resolved_route',{'p_route':self.rid,'p_depot_return_confirmed':True,'p_request':str(uuid4())})
        self.assertEqual(closed['route_status'],'ABANDONED')
        self.assertEqual(self.scalar(f"SELECT route_status FROM public.pickup_routes WHERE route_id='{self.rid}'"),'ABANDONED')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='{self.rid}'"),0)

    def test_91_dispatched_expiry_and_matching_not_collected_stay_held(self):
        self.reset_template(self.template)
        first=self.stops[0]
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{first['claim_id']}'; SELECT public.recover_expired_claims(100);")
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"),'RECONCILIATION_REQUIRED')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"),'DISPATCHED')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE task_id='{first['task_id']}'"),1)
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.cases'),0)
        self.assertEqual(self.scalar(f"SELECT fleet_private.vehicle_has_hold('{self.vehicle_id}')"),True)

    def test_95_manual_stop_deferral_can_continue_after_another_pickup_started(self):
        self.reset_template(self.unstarted_template)
        first, second = self.stops
        self.rpc('start_pickup',{'p_claim':first['claim_id']})
        self.lane.sql(f"""UPDATE public.donation_claims SET claim_status='RECONCILIATION_REQUIRED' WHERE claim_id='{second['claim_id']}';
          UPDATE public.claim_leases SET lease_status='RECONCILIATION_REQUIRED' WHERE claim_id='{second['claim_id']}';
          INSERT INTO public.claim_reconciliation_cases(claim_id,listing_id,donation_id,source_type,case_status)
          SELECT c.claim_id,l.listing_id,l.donation_id,l.source_type,'OPEN' FROM public.donation_claims c JOIN public.listings l USING(listing_id) WHERE c.claim_id='{second['claim_id']}';""")
        route=self.rpc('get_my_authorized_route',{'p_route':self.rid})
        self.assertTrue(next(x for x in route['stops'] if x['task_id']==second['task_id'])['can_defer'])
        self.rpc('defer_my_pickup_for_reconciliation',{'p_claim':second['claim_id'],'p_request':str(uuid4())})
        self.rpc('complete_pickup',{'p_claim':first['claim_id'],'p_handover_confirmed':True})
        a=self.rpc('submit_claim_reconciliation',{'p_claim':second['claim_id'],'p_handover_confirmed':False,'p_request':str(uuid4())})
        b=self.rpc('submit_claim_reconciliation',{'p_claim':second['claim_id'],'p_handover_confirmed':False,'p_request':str(uuid4())},who='donor')
        self.assertEqual(a['outcome'],'AWAITING_COUNTERPART')
        self.assertEqual(b['outcome'],'SUCCESS')
        route=self.rpc('get_my_authorized_route',{'p_route':self.rid})
        self.assertTrue(route['can_close'])
        closed=self.rpc('close_my_resolved_route',{'p_route':self.rid,'p_depot_return_confirmed':True,'p_request':str(uuid4())})
        self.assertEqual(closed['route_status'],'ABANDONED')

    def test_96_safe_expiry_keeps_hub_batch_membership_atomic(self):
        self.reset_template(self.hub_unstarted_template)
        route, stops, vehicle = self.hub_meta
        first=stops[0]
        self.rid=route;self.vehicle_id=vehicle
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{first['claim_id']}'; SELECT public.recover_expired_claims(100);")
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"),'RELEASED')
        self.assertEqual(self.scalar(f"SELECT l.listing_status FROM public.listings l JOIN public.pickup_tasks t USING(listing_id) WHERE t.task_id='{first['task_id']}'"),'AVAILABLE')
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE collection_path='HUB_COLLECTION' AND donation_status='BATCHED'"),3)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.hub_batch_members WHERE membership_status='ACTIVE'"),3)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.hub_inventory WHERE inventory_status='BATCHED'"),3)
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.donation_claims WHERE claim_id='{first['claim_id']}' AND claim_status='ACTIVE'"),0)
        self.assertEqual(self.scalar('SELECT count(*) FROM public.claim_reconciliation_cases'),0)

    def test_97_conflicting_started_claim_evidence_never_changes_custody(self):
        self.reset_template(self.template)
        first=self.stops[0]
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{first['claim_id']}'; SELECT public.recover_expired_claims(100);")
        ngo_request=str(uuid4()); donor_request=str(uuid4())
        a=self.rpc('submit_claim_reconciliation',{'p_claim':first['claim_id'],'p_handover_confirmed':True,'p_request':ngo_request})
        b=self.rpc('submit_claim_reconciliation',{'p_claim':first['claim_id'],'p_handover_confirmed':False,'p_request':donor_request},who='donor')
        self.assertEqual(a['outcome'],'AWAITING_COUNTERPART')
        self.assertEqual(b['outcome'],'RECONCILIATION_REQUIRED')
        self.assertEqual(self.scalar(f"SELECT case_status FROM public.claim_reconciliation_cases WHERE claim_id='{first['claim_id']}'"),'MANUAL_REVIEW')
        self.assertEqual(self.scalar(f"SELECT d.donation_status FROM public.donations d JOIN public.listings l USING(donation_id) JOIN public.pickup_tasks t USING(listing_id) WHERE t.task_id='{first['task_id']}'"),'PICKUP_IN_PROGRESS')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"),'DISPATCHED')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE task_id='{first['task_id']}'"),1)
        replay=self.rpc('submit_claim_reconciliation',{'p_claim':first['claim_id'],'p_handover_confirmed':True,'p_request':ngo_request})
        self.assertEqual(replay,a)
        changed=self.rpc('submit_claim_reconciliation',{'p_claim':first['claim_id'],'p_handover_confirmed':False,'p_request':ngo_request})
        self.assertEqual(changed['reason_code'],'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD')
        self.assertEqual(self.scalar(f"SELECT case_status FROM public.claim_reconciliation_cases WHERE claim_id='{first['claim_id']}'"),'MANUAL_REVIEW')
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"),'RECONCILIATION_REQUIRED')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE task_id='{first['task_id']}'"),1)
        self.assertEqual(self.scalar(f"SELECT fleet_private.vehicle_has_hold('{self.vehicle_id}')"),True)

    def test_92_matching_collected_evidence_preserves_collection_and_closes_with_return(self):
        self.reset_template(self.template)
        first,second=self.stops
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{first['claim_id']}'; SELECT public.recover_expired_claims(100);")
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"),'RECONCILIATION_REQUIRED')
        one=self.rpc('submit_claim_reconciliation',{'p_claim':first['claim_id'],'p_handover_confirmed':True,'p_request':str(uuid4())})
        self.assertEqual(one['outcome'],'AWAITING_COUNTERPART')
        two=self.rpc('submit_claim_reconciliation',{'p_claim':first['claim_id'],'p_handover_confirmed':True,'p_request':str(uuid4())},who='donor')
        self.assertEqual(two['outcome'],'SUCCESS')
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"),'COMPLETED')
        donation=self.scalar(f"SELECT l.donation_id FROM public.listings l JOIN public.pickup_tasks t USING(listing_id) WHERE t.task_id='{first['task_id']}'")
        self.assertEqual(self.scalar(f"SELECT donation_status FROM public.donations WHERE donation_id='{donation}'"),'COLLECTED')
        self.assertEqual(self.scalar(f"SELECT collected_at IS NOT NULL FROM routing_private.items WHERE task_id='{first['task_id']}'"),True)
        self.assertTrue(self.scalar(f"SELECT fleet_private.vehicle_has_hold('{self.vehicle_id}')"))
        self.rpc('start_pickup',{'p_claim':second['claim_id']})
        self.rpc('complete_pickup',{'p_claim':second['claim_id'],'p_handover_confirmed':True})
        self.rpc('close_my_collected_route',{'p_route':self.rid,'p_depot_return_confirmed':True})
        self.assertFalse(self.scalar(f"SELECT fleet_private.vehicle_has_hold('{self.vehicle_id}')"))

    def test_98_expiry_after_confirmed_collection_preserves_completed_outcome(self):
        self.reset_template(self.unstarted_template)
        first, second=self.stops
        self.rpc('start_pickup',{'p_claim':first['claim_id']})
        self.rpc('complete_pickup',{'p_claim':first['claim_id'],'p_handover_confirmed':True})
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{first['claim_id']}'; SELECT public.recover_expired_claims(100);")
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"),'COMPLETED')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"),'COLLECTED')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.claim_reconciliation_cases WHERE claim_id='{first['claim_id']}'"),0)
        self.rpc('start_pickup',{'p_claim':second['claim_id']})
        self.rpc('complete_pickup',{'p_claim':second['claim_id'],'p_handover_confirmed':True})
        self.rpc('close_my_collected_route',{'p_route':self.rid,'p_depot_return_confirmed':True})

    def test_99_expired_hub_listing_stays_unclaimable_and_batch_state_is_atomic(self):
        self.reset_template(self.hub_unstarted_template)
        route, stops, vehicle = self.hub_meta
        first = stops[0]
        self.rid = route
        self.vehicle_id = vehicle
        self.lane.sql(f"""UPDATE public.listings SET listing_expires_at=clock_timestamp()-interval '1 second'
          WHERE listing_id=(SELECT listing_id FROM public.pickup_tasks WHERE claim_id='{first['claim_id']}');
          UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second'
          WHERE claim_id='{first['claim_id']}';
          SELECT public.recover_expired_claims(100);""")
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"),'RELEASED')
        self.assertEqual(self.scalar(f"SELECT listing_status FROM public.listings WHERE listing_id=(SELECT listing_id FROM public.pickup_tasks WHERE claim_id='{first['claim_id']}')"),'AVAILABLE')
        self.assertTrue(self.scalar(f"SELECT listing_expires_at<=clock_timestamp() FROM public.listings WHERE listing_id=(SELECT listing_id FROM public.pickup_tasks WHERE claim_id='{first['claim_id']}')"))
        self.assertEqual(self.scalar("SELECT count(*) FROM public.listings l WHERE l.listing_status='AVAILABLE' AND l.listing_expires_at<=clock_timestamp() AND EXISTS(SELECT 1 FROM public.donation_claims c WHERE c.listing_id=l.listing_id AND c.claim_status='RELEASED')"),1)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE collection_path='HUB_COLLECTION' AND donation_status='BATCHED'"),3)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.hub_inventory WHERE inventory_status='BATCHED'"),3)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.hub_batch_members WHERE membership_status='ACTIVE'"),3)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.claim_reconciliation_cases"),0)
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='{route}'"),len(stops)-1)
        listing_id = self.scalar(f"SELECT listing_id FROM public.pickup_tasks WHERE claim_id='{first['claim_id']}'")
        retry = self.rpc('claim_listing', {'p_listing': listing_id, 'p_request': str(uuid4())})
        self.assertEqual(retry['reason_code'],'LISTING_EXPIRED')
        self.assertNotEqual(retry['outcome'],'SUCCESS')

    def test_100_unexpected_route_failure_aborts_recovery(self):
        self.reset_template(self.unstarted_template)
        first = self.stops[0]
        self.lane.sql("""CREATE OR REPLACE FUNCTION routing_private.check_remaining(p_route uuid,p_next uuid,p_now timestamptz)
          RETURNS void LANGUAGE plpgsql AS $$ BEGIN
            RAISE EXCEPTION USING ERRCODE='22000', MESSAGE='INJECTED_UNEXPECTED_ROUTE_FAILURE';
          END $$;""")
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{first['claim_id']}';")
        with auto.connect(self.lane.port, self.db, 'postgres') as conn:
            with self.assertRaisesRegex(psycopg.Error, 'INJECTED_UNEXPECTED_ROUTE_FAILURE'):
                conn.execute('SELECT public.recover_expired_claims(100);')
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"),'ACTIVE')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"),'PLANNED')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM routing_private.deferred_stops WHERE task_id='{first['task_id']}'"),0)

    def test_101_duplicate_source_anchor_fails_closed(self):
        self.reset_template(self.claim_scoped_pristine_template)
        definition=self.lane.sql("SELECT pg_get_functiondef('public.recover_expired_claims(integer)'::regprocedure);")
        anchor="for update of c skip locked\n    limit greatest(1,least(coalesce(p_limit,100),1000))"
        self.assertEqual(definition.count(anchor),1)
        duplicate="  PERFORM '"+anchor+"';\n"
        altered=definition.replace('begin\n','begin\n'+duplicate,1)
        self.assertNotEqual(altered,definition,'duplicate source anchor fixture was not inserted')
        self.lane.sql('',exact_bytes=altered.encode('utf-8'))
        self.lane.sql('',expected='RECOVERY_CANDIDATE_LOCK_SOURCE_DRIFT',exact_bytes=(ROOT/CLAIM_SCOPED).read_bytes())
        self.assertIsNone(self.scalar("SELECT to_regprocedure('routing_private.release_expired_unstarted_stop(uuid,uuid,uuid,uuid)')"))
        self.assertTrue(self.scalar("SELECT position('PERFORM' IN prosrc)>0 FROM pg_proc WHERE oid='public.recover_expired_claims(integer)'::regprocedure"))

    def test_102_three_stop_route_releases_expired_planned_claim_during_other_dispatch(self):
        self.reset_template(self.three_unstarted_template)
        self.rid = self.three_rid
        self.vehicle_id = self.three_vehicle_id
        first, expired, remaining = self.three_stops
        self.rpc('start_pickup', {'p_claim': first['claim_id']})
        self.lane.sql(f"""UPDATE public.claim_leases
          SET issued_at=clock_timestamp()-interval '7 hours',expires_at=clock_timestamp()-interval '1 second'
          WHERE claim_id='{expired['claim_id']}';""")
        recovered = self.scalar('SELECT public.recover_expired_claims(100);')
        self.assertEqual(recovered, 1)

        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"), 'ACTIVE')
        self.assertEqual(self.scalar(f"SELECT lease_status FROM public.claim_leases WHERE claim_id='{first['claim_id']}'"), 'ACTIVE')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"), 'DISPATCHED')
        self.assertTrue(self.scalar(f"SELECT consumed_at IS NOT NULL AND collected_at IS NULL FROM routing_private.items WHERE task_id='{first['task_id']}'"))
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{expired['claim_id']}'"), 'RELEASED')
        self.assertEqual(self.scalar(f"SELECT lease_status FROM public.claim_leases WHERE claim_id='{expired['claim_id']}'"), 'RELEASED')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{expired['task_id']}'"), 'STALE')
        self.assertEqual(self.scalar(f"SELECT status FROM routing_private.deferred_stops WHERE task_id='{expired['task_id']}'"), 'RESOLVED_UNCOLLECTED')
        self.assertTrue(self.scalar(f"SELECT released_at IS NOT NULL AND consumed_at IS NULL AND collected_at IS NULL FROM routing_private.items WHERE task_id='{expired['task_id']}'"))
        self.assertEqual(self.scalar(f"SELECT l.listing_status FROM public.listings l JOIN public.pickup_tasks t USING(listing_id) WHERE t.task_id='{expired['task_id']}'"), 'AVAILABLE')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE task_id='{expired['task_id']}'"), 0)
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE task_id='{first['task_id']}'"), 1)
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE task_id='{remaining['task_id']}'"), 1)
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{remaining['claim_id']}'"), 'ACTIVE')
        self.assertEqual(self.scalar(f"SELECT lease_status FROM public.claim_leases WHERE claim_id='{remaining['claim_id']}'"), 'ACTIVE')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{remaining['task_id']}'"), 'PLANNED')
        self.assertEqual(self.scalar(f"SELECT route_status FROM public.pickup_routes WHERE route_id='{self.rid}'"), 'IN_PROGRESS')
        self.assertIsNone(self.scalar(f"SELECT closed_at FROM routing_private.bindings WHERE route_id='{self.rid}'"))
        self.assertEqual(self.scalar('SELECT count(*) FROM public.claim_reconciliation_cases'), 0)

        self.rpc('complete_pickup', {'p_claim': first['claim_id'], 'p_handover_confirmed': True})
        route = self.rpc('get_my_authorized_route', {'p_route': self.rid})
        remaining_view = next(stop for stop in route['stops'] if stop['task_id'] == remaining['task_id'])
        self.assertTrue(remaining_view['can_start'])
        self.rpc('start_pickup', {'p_claim': remaining['claim_id']})
        self.rpc('complete_pickup', {'p_claim': remaining['claim_id'], 'p_handover_confirmed': True})
        closed = self.rpc('close_my_resolved_route', {
            'p_route': self.rid, 'p_depot_return_confirmed': True, 'p_request': str(uuid4())})
        self.assertEqual(closed['route_status'], 'ABANDONED')
        self.assertEqual(self.scalar(f"SELECT route_status FROM public.pickup_routes WHERE route_id='{self.rid}'"), 'ABANDONED')
        self.assertIsNotNone(self.scalar(f"SELECT closed_at FROM routing_private.bindings WHERE route_id='{self.rid}'"))
        self.assertFalse(self.scalar(f"SELECT fleet_private.vehicle_has_hold('{self.vehicle_id}')"))

    def test_103_expiry_versus_start_serializes_to_release_or_reconciliation(self):
        self.reset_template(self.three_unstarted_template)
        self.rid = self.three_rid
        self.vehicle_id = self.three_vehicle_id
        first, second, third = self.three_stops
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()+interval '12 hours' WHERE claim_id='{first['claim_id']}';")
        results = self.race(
            lambda: self.rpc('start_pickup', {'p_claim': first['claim_id']}),
            lambda: self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{first['claim_id']}';"),
        )
        self.assertEqual(len(results), 2, results)
        self.assertTrue(all('result' in row or 'error' in row for row in results), results)
        self.lane.sql('SELECT public.recover_expired_claims(100);')
        task_status = self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'")
        claim_status = self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'")
        if task_status == 'DISPATCHED':
            self.assertEqual(claim_status, 'RECONCILIATION_REQUIRED')
            self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE task_id='{first['task_id']}'"), 1)
            self.assertEqual(self.scalar(f"SELECT case_status FROM public.claim_reconciliation_cases WHERE claim_id='{first['claim_id']}'"), 'OPEN')
        else:
            self.assertEqual(task_status, 'STALE')
            self.assertEqual(claim_status, 'RELEASED')
            self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE task_id='{first['task_id']}'"), 0)
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{second['claim_id']}'"), 'ACTIVE')
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{third['claim_id']}'"), 'ACTIVE')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{third['task_id']}'"), 'PLANNED')

    def test_104_legacy_route_case_keeps_its_claims_on_existing_resolution_path(self):
        self.reset_template(self.unstarted_template)
        first, second = self.stops
        self.seed_legacy_route_case()
        before_items = self.scalar('SELECT count(*) FROM resolution_private.items')
        before_evidence = self.scalar('SELECT count(*) FROM resolution_private.evidence')
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{second['claim_id']}';")
        self.assertEqual(self.scalar('SELECT public.recover_expired_claims(100);'), 0)
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{second['claim_id']}'"), 'RECONCILIATION_REQUIRED')
        self.assertEqual(self.scalar(f"SELECT lease_status FROM public.claim_leases WHERE claim_id='{second['claim_id']}'"), 'RECONCILIATION_REQUIRED')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{second['task_id']}'"), 'PLANNED')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='{self.rid}'"), 2)
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.cases WHERE status IN (\'AWAITING_EVIDENCE\',\'MANUAL_REVIEW\')'), 1)
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.items'), before_items)
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.evidence'), before_evidence)

    def test_105_all_three_planned_expire_before_route_starts_and_close_safely(self):
        self.reset_template(self.three_unstarted_template)
        self.rid=self.three_rid; self.vehicle_id=self.three_vehicle_id
        first,second,third=self.three_stops
        self.lane.sql("UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second';")
        self.assertEqual(self.scalar('SELECT public.recover_expired_claims(100);'),3)
        for stop in (first,second,third):
            self.assertEqual(self.stop_state(stop),{
                'claim':'RELEASED','lease':'RELEASED','listing':'AVAILABLE','donation':'AVAILABLE',
                'task':'STALE','assigned':False,'item_released':True,'item_consumed':False,
                'item_collected':False,'deferred':'RESOLVED_UNCOLLECTED','route':'AUTHORISED',
                'binding_closed':False,'vehicle_hold':True,'reconciliation':None})
        self.assertEqual(self.scalar(f"SELECT count(*) FROM routing_private.items WHERE route_id='{self.rid}' AND released_at IS NULL AND collected_at IS NULL"),0)
        self.assertTrue(self.rpc('get_my_authorized_route',{'p_route':self.rid})['can_close'])
        with self.assertRaisesRegex(psycopg.Error,'DEPOT_RETURN_CONFIRMATION_REQUIRED'):
            self.rpc('close_my_resolved_route',{'p_route':self.rid,'p_depot_return_confirmed':False,'p_request':str(uuid4())})
        closed=self.rpc('close_my_resolved_route',{'p_route':self.rid,'p_depot_return_confirmed':True,'p_request':str(uuid4())})
        self.assertEqual(closed['route_status'],'ABANDONED')
        for stop in (first,second,third):
            state=self.stop_state(stop)
            self.assertEqual(state['route'],'ABANDONED')
            self.assertTrue(state['binding_closed'])
            self.assertFalse(state['vehicle_hold'])
            self.assertFalse(state['assigned'])
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='{self.rid}'"),0)

    def test_106_dispatched_expiry_holds_only_that_claim_while_other_expired_planned_release(self):
        self.reset_template(self.three_unstarted_template)
        self.rid=self.three_rid; self.vehicle_id=self.three_vehicle_id
        first,second,third=self.three_stops
        self.rpc('start_pickup',{'p_claim':first['claim_id']})
        self.lane.sql("UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second';")
        self.assertEqual(self.scalar('SELECT public.recover_expired_claims(100);'),3)
        self.assertEqual(self.stop_state(first),{
            'claim':'RECONCILIATION_REQUIRED','lease':'RECONCILIATION_REQUIRED','listing':'CLAIMED',
            'donation':'PICKUP_IN_PROGRESS','task':'DISPATCHED','assigned':True,'item_released':False,
            'item_consumed':True,'item_collected':False,'deferred':None,'route':'IN_PROGRESS',
            'binding_closed':False,'vehicle_hold':True,'reconciliation':'OPEN'})
        for stop in (second,third):
            self.assertEqual(self.stop_state(stop),{
                'claim':'RELEASED','lease':'RELEASED','listing':'AVAILABLE','donation':'AVAILABLE',
                'task':'STALE','assigned':False,'item_released':True,'item_consumed':False,
                'item_collected':False,'deferred':'RESOLVED_UNCOLLECTED','route':'IN_PROGRESS',
                'binding_closed':False,'vehicle_hold':True,'reconciliation':None})
        with self.assertRaisesRegex(psycopg.Error,'ROUTE_HAS_UNRESOLVED_TASKS'):
            self.rpc('close_my_resolved_route',{'p_route':self.rid,'p_depot_return_confirmed':True,'p_request':str(uuid4())})
        self.assertIsNone(self.scalar(f"SELECT closed_at FROM routing_private.bindings WHERE route_id='{self.rid}'"))

    def test_107_collected_first_stop_survives_expiry_of_other_two_planned_stops(self):
        self.reset_template(self.three_unstarted_template)
        self.rid=self.three_rid; self.vehicle_id=self.three_vehicle_id
        first,second,third=self.three_stops
        self.rpc('start_pickup',{'p_claim':first['claim_id']})
        self.rpc('complete_pickup',{'p_claim':first['claim_id'],'p_handover_confirmed':True})
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id IN('{second['claim_id']}','{third['claim_id']}');")
        self.assertEqual(self.scalar('SELECT public.recover_expired_claims(100);'),2)
        self.assertEqual(self.stop_state(first),{
            'claim':'COMPLETED','lease':'COMPLETED','listing':'CLOSED','donation':'COLLECTED',
            'task':'COLLECTED','assigned':True,'item_released':False,'item_consumed':True,
            'item_collected':True,'deferred':None,'route':'IN_PROGRESS','binding_closed':False,
            'vehicle_hold':True,'reconciliation':None})
        for stop in (second,third):
            self.assertEqual(self.stop_state(stop),{
                'claim':'RELEASED','lease':'RELEASED','listing':'AVAILABLE','donation':'AVAILABLE',
                'task':'STALE','assigned':False,'item_released':True,'item_consumed':False,
                'item_collected':False,'deferred':'RESOLVED_UNCOLLECTED','route':'IN_PROGRESS',
                'binding_closed':False,'vehicle_hold':True,'reconciliation':None})
        with self.assertRaisesRegex(psycopg.Error,'DEPOT_RETURN_CONFIRMATION_REQUIRED'):
            self.rpc('close_my_resolved_route',{'p_route':self.rid,'p_depot_return_confirmed':False,'p_request':str(uuid4())})
        closed=self.rpc('close_my_resolved_route',{'p_route':self.rid,'p_depot_return_confirmed':True,'p_request':str(uuid4())})
        self.assertEqual(closed['route_status'],'ABANDONED')
        for stop in (first,second,third):
            state=self.stop_state(stop)
            self.assertEqual(state['route'],'ABANDONED')
            self.assertTrue(state['binding_closed'])
            self.assertFalse(state['vehicle_hold'])
            self.assertFalse(state['assigned'])
            self.assertTrue(state['item_released'])
        self.assertEqual(self.stop_state(first)['donation'],'COLLECTED')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='{self.rid}'"),0)

    def test_108_last_remaining_planned_stop_can_expire_and_route_closes_with_return(self):
        self.reset_template(self.three_unstarted_template)
        self.rid=self.three_rid; self.vehicle_id=self.three_vehicle_id
        first,second,third=self.three_stops
        self.rpc('start_pickup',{'p_claim':first['claim_id']})
        self.rpc('complete_pickup',{'p_claim':first['claim_id'],'p_handover_confirmed':True})
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{second['claim_id']}';")
        self.assertEqual(self.scalar('SELECT public.recover_expired_claims(100);'),1)
        view=self.rpc('get_my_authorized_route',{'p_route':self.rid})
        self.assertTrue(next(row for row in view['stops'] if row['task_id']==third['task_id'])['can_start'])
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{third['claim_id']}';")
        self.assertEqual(self.scalar('SELECT public.recover_expired_claims(100);'),1)
        for stop in (first,second,third):
            state=self.stop_state(stop)
            self.assertTrue(state['deferred'] is None if stop is first else state['deferred']=='RESOLVED_UNCOLLECTED')
            self.assertEqual(state['route'],'IN_PROGRESS')
            self.assertFalse(state['binding_closed'])
            self.assertTrue(state['vehicle_hold'])
        self.assertEqual(self.scalar(f"SELECT count(*) FROM routing_private.items WHERE route_id='{self.rid}' AND released_at IS NULL AND collected_at IS NULL"),0)
        self.assertTrue(self.rpc('get_my_authorized_route',{'p_route':self.rid})['can_close'])
        with self.assertRaisesRegex(psycopg.Error,'DEPOT_RETURN_CONFIRMATION_REQUIRED'):
            self.rpc('close_my_resolved_route',{'p_route':self.rid,'p_depot_return_confirmed':False,'p_request':str(uuid4())})
        closed=self.rpc('close_my_resolved_route',{'p_route':self.rid,'p_depot_return_confirmed':True,'p_request':str(uuid4())})
        self.assertEqual(closed['route_status'],'ABANDONED')
        for stop in (first,second,third):
            state=self.stop_state(stop)
            self.assertEqual(state['route'],'ABANDONED')
            self.assertTrue(state['binding_closed'])
            self.assertFalse(state['vehicle_hold'])
            self.assertFalse(state['assigned'])
            self.assertTrue(state['item_released'])
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='{self.rid}'"),0)

    def test_109_recovery_scheduler_processes_expired_claims_across_invocations(self):
        self.reset_template(self.three_unstarted_template)
        self.rid=self.three_rid; self.vehicle_id=self.three_vehicle_id
        stops=self.three_stops
        self.lane.sql("UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second';")
        released=set()
        for _ in range(3):
            before={stop['task_id']:self.stop_state(stop) for stop in stops}
            self.assertEqual(self.scalar('SELECT public.recover_expired_claims(1);'),1)
            after={stop['task_id']:self.stop_state(stop) for stop in stops}
            newly_released=[task_id for task_id in before
                if before[task_id]['claim']=='ACTIVE' and after[task_id]['claim']=='RELEASED']
            self.assertEqual(len(newly_released),1,after)
            released.add(newly_released[0])
            state=after[newly_released[0]]
            self.assertEqual(state['claim'],'RELEASED')
            self.assertEqual(state['lease'],'RELEASED')
            self.assertEqual(state['listing'],'AVAILABLE')
            self.assertEqual(state['donation'],'AVAILABLE')
            self.assertEqual(state['task'],'STALE')
            self.assertFalse(state['assigned'])
            self.assertTrue(state['item_released'])
            self.assertEqual(state['deferred'],'RESOLVED_UNCOLLECTED')
            self.assertIsNone(state['reconciliation'])
            self.assertEqual(state['route'],'AUTHORISED')
            self.assertFalse(state['binding_closed'])
            self.assertTrue(state['vehicle_hold'])
            for pending in stops:
                waiting=after[pending['task_id']]
                if pending['task_id'] in released: continue
                self.assertEqual(waiting['claim'],'ACTIVE')
                self.assertEqual(waiting['lease'],'ACTIVE')
                self.assertEqual(waiting['task'],'PLANNED')
                self.assertTrue(waiting['assigned'])
                self.assertIsNone(waiting['deferred'])
                self.assertIsNone(waiting['reconciliation'])
        self.assertEqual(self.scalar('SELECT public.recover_expired_claims(1);'),0)
        self.assertEqual(len(released),3)
        self.assertEqual(self.scalar(f"SELECT route_status FROM public.pickup_routes WHERE route_id='{self.rid}'"),'AUTHORISED')
        self.assertIsNone(self.scalar(f"SELECT closed_at FROM routing_private.bindings WHERE route_id='{self.rid}'"))
        self.assertTrue(self.scalar(f"SELECT fleet_private.vehicle_has_hold('{self.vehicle_id}')"))

    def test_93_completion_and_recovery_race_never_releases_dispatched_custody(self):
        self.reset_template(self.template)
        first=self.stops[0]
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()+interval '20 milliseconds' WHERE claim_id='{first['claim_id']}';")
        results=self.race(
            lambda:self.rpc('complete_pickup',{'p_claim':first['claim_id'],'p_handover_confirmed':True}),
            lambda:(time.sleep(.03),self.lane.sql('SELECT public.recover_expired_claims(100);'))[1],
        )
        claim=self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'")
        self.assertIn(claim,{'COMPLETED','RECONCILIATION_REQUIRED'})
        self.assertNotEqual(claim,'RELEASED')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.donation_claims WHERE claim_id='{first['claim_id']}' AND claim_status='ACTIVE'"),0)
        if claim=='COMPLETED':
            self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"),'COLLECTED')
        else:
            self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"),'DISPATCHED')
            self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE task_id='{first['task_id']}'"),1)

    def test_94_new_route_interruptions_are_rejected_but_legacy_rpc_is_retained(self):
        self.reset_template(self.unstarted_template)
        first=self.stops[0]
        self.rpc('start_pickup',{'p_claim':first['claim_id']})
        before=self.scalar('SELECT count(*) FROM resolution_private.cases')
        with self.assertRaisesRegex(psycopg.Error,'NEW_ROUTE_INTERRUPTION_REPORTS_RETIRED'):
            self.rpc('report_my_route_interruption',{'p_route':self.rid,
              'p_reason':'EXECUTION_BUDGET_EXCEEDED','p_request':str(uuid4())})
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.cases'),before)
        self.assertTrue(self.scalar("SELECT has_function_privilege('authenticated','public.report_my_route_interruption(uuid,text,uuid)','EXECUTE')"))

    def test_82_expired_pickup_racing_defer_and_start_waits_for_safe_recovery(self):
        self.reset_template(self.unstarted_template)
        first=self.stops[0]
        self.lane.sql(f"UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '7 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE claim_id='{first['claim_id']}';")
        results=self.race(
            lambda:self.rpc('defer_my_pickup_for_reconciliation',{'p_claim':first['claim_id'],'p_request':str(uuid4())}),
            lambda:self.rpc('start_pickup',{'p_claim':first['claim_id']}),
        )
        self.assertFalse(any('result' in row for row in results),results)
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"),'PLANNED')
        self.lane.sql('SELECT public.recover_expired_claims(100);')
        self.assertEqual(self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{first['task_id']}'"),'STALE')
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{first['claim_id']}'"),'RELEASED')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.active_task_route_assignments WHERE route_id='{self.rid}'"),1)
        self.assertEqual(self.scalar('SELECT count(*) FROM public.claim_reconciliation_cases'),0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated', action='store_true', required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--start-at', type=int, default=1, help='Local debug subset; default runs every acceptance scenario.')
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    assert runtime.name.startswith('geolock-spatial-runtime-') and (runtime/'pgsql/bin/postgres.exe').is_file()
    for key in list(os.environ):
        if key.upper().startswith(('PG', 'GEOLOCK', 'SUPABASE')) or key.upper() in ('DATABASE_URL', 'DB_URL'):
            os.environ.pop(key, None)
    ResolutionTests.runtime = runtime
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(ResolutionTests)
    suite=unittest.TestSuite(case for case in suite if int(case._testMethodName.split('_')[1])>=args.start_at)
    result = unittest.TextTestRunner(verbosity=2, failfast=True).run(suite)
    summary = {'status': 'PASS' if result.wasSuccessful() else 'FAIL', 'tests': result.testsRun,
        'failures': len(result.failures), 'errors': len(result.errors), 'dev_connections': 0,
        'scope': 'Disposable PG17 SQL; local auth/Storage/cron adapters, not hosted Supabase parity',
        'start_at':args.start_at}
    if hasattr(ResolutionTests, 'lane'):
        ResolutionTests.lane.save('resolution-test-result.json', summary)
        print(json.dumps({'evidence': str(ResolutionTests.out), **summary}, indent=2))
    return not result.wasSuccessful()


if __name__ == '__main__':
    mp.freeze_support()
    raise SystemExit(main())
