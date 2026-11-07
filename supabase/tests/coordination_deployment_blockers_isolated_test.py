"""Focused blocker regressions. Fresh loopback PG only; no remote DSN accepted."""
import argparse
import json
import multiprocessing as mp
import os
from pathlib import Path
import unittest
from uuid import uuid4
import simplified_reconciliation_isolated_test as coord
base=coord.base

class BlockerTests(coord.CoordinationTests):
    def read_rpc(self,name,params,actor=None):
        with base.auto.connect(self.lane.port,self.db,'geolock_local_ngo_login') as conn:
            conn.execute('BEGIN READ ONLY')
            conn.execute('SET LOCAL ROLE authenticated')
            conn.execute("SELECT set_config('request.jwt.claim.sub',%s,true)",(base.auto.existing.NGO if actor is None else actor,))
            args=','.join(k+' => %s' for k in params)
            result=conn.execute('SELECT public.'+name+'('+args+')',list(params.values())).fetchone()[0]
            self.assertEqual(conn.execute('SHOW transaction_read_only').fetchone()[0],'on')
            conn.rollback()
            return result

    def assert_masked(self,stop):
        for key in ('pickup_address','pickup_latitude','pickup_longitude','pickup_road_node_id'):
            self.assertIsNone(stop[key],key)

    def test_blocker_01_full_reader_chain_and_claim_detail(self):
        c=self.stops[0]['claim_id']
        for name in ('get_my_authorized_route_pre_deferral','get_my_authorized_route'):
            active=self.read_rpc(name,{'p_route':self.rid})
            self.assertIsNotNone(active['stops'][0]['pickup_latitude'])
        self.assertIsNotNone(self.read_rpc('get_claimed_listing_detail',{'p_claim':c})['latitude'])
        self.uncertain(self.stops[0],True);self.vote(c,False);self.vote(c,False,'donor')
        for name in ('get_my_authorized_route_pre_deferral','get_my_authorized_route'):
            rows=self.read_rpc(name,{'p_route':self.rid})['stops']
            self.assert_masked(next(s for s in rows if s['claim_id']==c))
            self.assertIsNotNone(next(s for s in rows if s['claim_id']!=c)['pickup_latitude'])
        result=self.read_rpc('get_claimed_listing_detail',{'p_claim':c})
        for key in ('pickup_address','latitude','longitude'):self.assertIsNone(result[key])
        self.assertFalse(self.scalar("SELECT has_function_privilege('authenticated','public.get_my_authorized_route_pre_coordination(uuid)','EXECUTE')"))

    def test_blocker_02_expired_missing_and_foreign_authority(self):
        c=self.stops[0]['claim_id']
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{c}';")
        self.assert_masked(self.detail()['stops'][0])
        self.assertIsNone(self.read_rpc('get_claimed_listing_detail',{'p_claim':c})['latitude'])
        for actor in (base.auto.existing.uid('foreign-ngo'),''):
            for name,params in [('get_my_authorized_route',{'p_route':self.rid}),('get_my_authorized_route_pre_deferral',{'p_route':self.rid}),('get_claimed_listing_detail',{'p_claim':c})]:
                with self.assertRaises(base.psycopg.Error):self.read_rpc(name,params,actor)
        self.assertFalse(self.scalar("SELECT has_function_privilege('authenticated','routing_private.coord_location_allowed(uuid)','EXECUTE')"))
        self.assertFalse(self.scalar("SELECT has_function_privilege('anon','routing_private.coord_snapshot_for_client(jsonb)','EXECUTE')"))

    def test_blocker_03_snapshot_retry_filters_without_mutating_evidence(self):
        snapshot=self.scalar(f"SELECT snapshot_id FROM routing_private.candidates c JOIN routing_private.bindings b USING(candidate_id) WHERE b.route_id='{self.rid}'")
        original=self.scalar(f"SELECT to_jsonb(s) FROM routing_private.snapshots s WHERE snapshot_id='{snapshot}'")
        args={'p_request':str(original['request_id']),'p_policy':str(original['policy_id']),
              'p_vehicle_ids':original['body'].get('selected_vehicle_ids')}
        # This RPC serializes an advisory lock but writes nothing on retry; use a
        # normal local transaction because advisory-lock functions reject READ ONLY.
        def replay(actor=base.auto.existing.NGO):
            with base.auto.connect(self.lane.port,self.db,'geolock_local_ngo_login') as conn:
                conn.execute('SET LOCAL ROLE authenticated')
                conn.execute("SELECT set_config('request.jwt.claim.sub',%s,true)",(actor,))
                return conn.execute('SELECT public.begin_my_routing_snapshot(%s,%s,%s)',list(args.values())).fetchone()[0]
        active=replay();self.assertEqual(len(active['body']['observations']),2)
        self.lane.sql(f"UPDATE public.claim_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{self.stops[0]['claim_id']}';")
        filtered=replay();self.assertTrue(filtered['client_projection'])
        self.assertEqual(len(filtered['body']['observations']),1)
        self.assertEqual(filtered['body']['observations'][0]['claim']['claim_id'],self.stops[1]['claim_id'])
        self.assertEqual(original,self.scalar(f"SELECT to_jsonb(s) FROM routing_private.snapshots s WHERE snapshot_id='{snapshot}'"))
        with self.assertRaises(base.psycopg.Error):replay('')

    def test_blocker_04_fingerprints_and_reader_set_abort(self):
        for signature in ('routing_private.permit_reconciled_collection(uuid)','public.get_my_donation_claim_reconciliation(uuid)','public.get_my_authorized_route_pre_deferral(uuid)','public.begin_my_routing_snapshot(uuid,uuid,uuid[])'):
            self.reset_template(self.unstarted_template)
            definition=self.lane.sql(f"SELECT pg_get_functiondef('{signature}'::regprocedure);")
            definition=definition.replace('AS $function$', 'AS $function$\n-- SYNTHETIC DRIFT\n',1)
            self.lane.sql('',exact_bytes=definition.encode())
            with self.assertRaisesRegex(AssertionError,'COORDINATION_SOURCE_DRIFT'):self.lane.apply(coord.MIGRATION)
            self.assert_rolled_back()
        self.reset_template(self.unstarted_template)
        self.lane.sql('CREATE FUNCTION public.get_my_claim_cards_v2(integer) RETURNS integer LANGUAGE sql AS $$SELECT $1$$;')
        with self.assertRaisesRegex(AssertionError,'COORDINATION_READER_SET_DRIFT'):self.lane.apply(coord.MIGRATION)
        self.assert_rolled_back()

    def assert_rolled_back(self):
        self.assertEqual(self.scalar("SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='claim_reconciliation_cases' AND column_name='evidence_round'"),0)
        self.assertIsNone(self.scalar("SELECT to_regprocedure('routing_private.coord_location_allowed(uuid)')"))
        self.assertEqual(self.scalar("SELECT md5(replace(prosrc,chr(13),'')) FROM pg_proc WHERE oid='public.cancel_my_unstarted_route(uuid)'::regprocedure"),'25d5d50b727abd9cf94fd0b9c479e612')

    def test_blocker_05_late_reader_anchor_failure_rolls_back_everything(self):
        self.reset_template(self.unstarted_template)
        sql=(base.ROOT/coord.MIGRATION).read_text()
        needle="('public.get_my_donation_claim_reconciliation(uuid)',2)"
        self.assertEqual(sql.count(needle),1)
        with self.assertRaisesRegex(AssertionError,'COORDINATION_READER_ANCHOR_DRIFT'):
            self.lane.sql('',exact_bytes=sql.replace(needle,"('public.get_my_donation_claim_reconciliation(uuid)',3)").encode())
        self.assert_rolled_back()
        self.assertEqual(self.scalar("SELECT md5(replace(prosrc,chr(13),'')) FROM pg_proc WHERE oid='public.get_my_authorized_route_pre_deferral(uuid)'::regprocedure"),'df7eb088b25c083673b223f164b7dcfd')

    def test_blocker_06_hub_history_also_loses_claim_location(self):
        self.reset_template(self.hub_unstarted_template);self.lane.apply(coord.MIGRATION)
        self.rid,self.stops,self.vehicle_id=self.hub_meta
        c=self.uncertain(self.stops[0],True);self.vote(c,False);self.vote(c,False,'hub')
        self.assert_masked(self.detail()['stops'][0])
        self.assertIsNone(self.read_rpc('get_claimed_listing_detail',{'p_claim':c})['latitude'])

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--run-isolated',action='store_true',required=True);p.add_argument('--runtime',type=Path,required=True);a=p.parse_args()
    runtime=a.runtime.resolve();assert runtime.name.startswith('geolock-spatial-runtime-') and (runtime/'pgsql/bin/postgres.exe').is_file()
    for k in list(os.environ):
        if k.upper().startswith(('PG','GEOLOCK','SUPABASE')) or k.upper() in ('DATABASE_URL','DB_URL'):os.environ.pop(k,None)
    BlockerTests.runtime=runtime
    selected=[n for n in sorted(dir(BlockerTests)) if n.startswith('test_blocker_')]
    selected+=['test_coord_02_started_true_true_keeps_vehicle','test_coord_03_mutual_review_rounds_and_old_receipts','test_coord_14_collected_and_mixed_final_routes']
    result=unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(BlockerTests(n) for n in selected))
    summary=dict(tests=result.testsRun,failures=len(result.failures),errors=len(result.errors),passed=result.wasSuccessful(),dev_connections=0)
    if hasattr(BlockerTests,'lane'):BlockerTests.lane.save('deployment-blockers-result.json',summary);print(json.dumps({'evidence':str(BlockerTests.out),**summary}))
    return not result.wasSuccessful()
if __name__=='__main__':mp.freeze_support();raise SystemExit(main())
