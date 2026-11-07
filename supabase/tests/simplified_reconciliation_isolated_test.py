"""LOCAL fresh loopback PG17, real protected SQL, synthetic auth/storage/cron.
No existing database/DSN/remote target accepted. Not a formal E2/E4 experiment.
"""
import argparse
import json
import multiprocessing as mp
import os
from pathlib import Path
import unittest
from uuid import uuid4
import route_resolution_isolated_test as base

MIGRATION='supabase/migrations/20261104130000_unstarted_released_route_cancellation.sql'
NEW={'get_my_claim_coordination','submit_claim_reconciliation_v2','resolve_my_claim_reconciliation',
     'review_my_claim_reconciliation','get_my_coordination_receipt','confirm_my_route_depot_checkpoint'}

class CoordinationTests(base.ResolutionTests):
    def setUp(self):
        super().setUp()
        self.reset_template(self.unstarted_template)
        self.lane.apply(MIGRATION)

    def rpc(self,name,params=None,who='ngo',readonly=False):
        if name not in NEW:
            return super().rpc(name,params,who,readonly)
        with base.auto.connect(self.lane.port,self.db,'geolock_local_ngo_login') as conn:
            if readonly: conn.execute('BEGIN READ ONLY')
            conn.execute("SET LOCAL lock_timeout='4s'")
            conn.execute("SET LOCAL statement_timeout='12s'")
            conn.execute('SET LOCAL ROLE authenticated')
            actor={'ngo':base.auto.existing.NGO,'donor':base.auto.existing.DONOR,'hub':self.hub_actor,'other':base.auto.existing.uid('foreign-ngo')}[who]
            conn.execute("SELECT set_config('request.jwt.claim.sub',%s,true),set_config('request.jwt.claim.role','authenticated',true)",(actor,))
            params=params or {}; args=','.join(k+' => %s' for k in params)
            result=conn.execute('SELECT public.'+name+'('+args+')',list(params.values())).fetchone()[0]
            if readonly:
                self.assertEqual(conn.execute('SHOW transaction_read_only').fetchone()[0],'on');conn.rollback()
            return result

    def state(self,c,who='ngo'):
        return self.rpc('get_my_claim_coordination',{'p_claim':c},who,True)

    def vote(self,c,value,who='ngo',request=None):
        s=self.state(c,who)
        return self.rpc('submit_claim_reconciliation_v2',{'p_claim':c,'p_handover_confirmed':value,
            'p_expected_round':s['evidence_round'],'p_expected_version':s['evidence_version'],'p_request':request or str(uuid4())},who)

    def uncertain(self,stop,started=False):
        c=stop['claim_id']
        if started:self.rpc('start_pickup',{'p_claim':c})
        self.lane.sql(f"UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '7 hours',expires_at=clock_timestamp()-interval '1 second' WHERE claim_id='{c}';")
        self.seed_uncertain_claim(c)
        return c

    def detail(self):return self.rpc('get_my_authorized_route',{'p_route':self.rid},readonly=True)

    def test_coord_01_started_false_false_and_checkpoint(self):
        c=self.uncertain(self.stops[0],True)
        start=self.scalar(f"SELECT consumed_at FROM routing_private.items WHERE task_id='{self.stops[0]['task_id']}'")
        self.assertEqual(self.vote(c,False)['outcome'],'AWAITING_COUNTERPART')
        self.assertEqual(self.vote(c,False,'donor')['claim_status'],'RELEASED')
        self.assertEqual(self.scalar(f"SELECT consumed_at FROM routing_private.items WHERE task_id='{self.stops[0]['task_id']}'"),start)
        self.assertTrue(self.detail()['vehicle_checkpoint_required'])
        self.assertFalse(any(s['can_start'] for s in self.detail()['stops']))
        with self.assertRaises(base.psycopg.Error):self.rpc('start_pickup',{'p_claim':self.stops[1]['claim_id']})
        args={'p_route':self.rid,'p_confirmed':True,'p_request':str(uuid4())}
        self.assertEqual(self.rpc('confirm_my_route_depot_checkpoint',args),self.rpc('confirm_my_route_depot_checkpoint',args))
        self.assertFalse(self.detail()['vehicle_checkpoint_required'])
        self.assertTrue(next(s for s in self.detail()['stops'] if s['claim_id']==self.stops[1]['claim_id'])['can_start'])
        self.rpc('start_pickup',{'p_claim':self.stops[1]['claim_id']})

    def test_coord_02_started_true_true_keeps_vehicle(self):
        c=self.uncertain(self.stops[0],True)
        self.vote(c,True); self.assertEqual(self.vote(c,True,'donor')['claim_status'],'COMPLETED')
        self.assertEqual(self.state(c)['case_status'],'RESOLVED_COLLECTED')
        self.assertTrue(self.scalar(f"SELECT fleet_private.vehicle_has_hold('{self.vehicle_id}')"))

    def test_coord_03_mutual_review_rounds_and_old_receipts(self):
        c=self.uncertain(self.stops[0],True); old=str(uuid4())
        first=self.vote(c,True,request=old); self.vote(c,False,'donor')
        self.assertEqual(self.state(c)['blocker'],'PARTY_EVIDENCE_CONFLICT')
        args={'p_claim':c,'p_action':'REQUEST','p_expected_version':self.state(c)['evidence_version'],'p_request':str(uuid4())}
        self.rpc('review_my_claim_reconciliation',args)
        with self.assertRaisesRegex(base.psycopg.Error,'COUNTERPART_ACCEPTANCE_REQUIRED'):
            self.rpc('review_my_claim_reconciliation',{'p_claim':c,'p_action':'ACCEPT','p_expected_version':self.state(c)['evidence_version'],'p_request':str(uuid4())})
        self.rpc('review_my_claim_reconciliation',{'p_claim':c,'p_action':'ACCEPT','p_expected_version':self.state(c,'donor')['evidence_version'],'p_request':str(uuid4())},'donor')
        self.assertEqual(self.state(c)['evidence_round'],2)
        with self.assertRaisesRegex(base.psycopg.Error,'ROUND_AWARE_CLIENT_REQUIRED'):
            self.rpc('submit_claim_reconciliation',{'p_claim':c,'p_handover_confirmed':False,'p_request':str(uuid4())})
        self.vote(c,False); self.assertEqual(self.vote(c,False,'donor')['claim_status'],'RELEASED')
        self.assertEqual(self.rpc('submit_claim_reconciliation',{'p_claim':c,'p_handover_confirmed':True,'p_request':old}),first)
        self.assertEqual(self.scalar('SELECT count(*) FROM public.claim_reconciliation_evidence'),4)
        with self.assertRaisesRegex(AssertionError,'CLAIM_EVIDENCE_IMMUTABLE'):
            self.lane.sql('UPDATE public.claim_reconciliation_evidence SET handover_confirmed=false;')

    def test_coord_04_existing_matching_manual_case_resolve(self):
        c=self.uncertain(self.stops[0],True)
        # Synthetic pre-migration-style statements and immutable old responses.
        self.lane.sql(f"INSERT INTO public.claim_reconciliation_evidence(request_id,case_id,actor_user_id,handover_confirmed,response) SELECT gen_random_uuid(),case_id,u,false,'{{\"outcome\":\"RECONCILIATION_REQUIRED\"}}'::jsonb FROM public.claim_reconciliation_cases CROSS JOIN unnest(ARRAY['{base.auto.existing.NGO}'::uuid,'{base.auto.existing.DONOR}'::uuid]) u WHERE claim_id='{c}'; UPDATE public.claim_reconciliation_cases SET case_status='MANUAL_REVIEW',resolution_reason='NO_HANDOVER_CONFIRMED_AFTER_PICKUP_STARTED' WHERE claim_id='{c}';")
        self.assertTrue(self.state(c)['can_resolve'])
        req=str(uuid4());args={'p_claim':c,'p_request':req}
        r=self.rpc('resolve_my_claim_reconciliation',args);self.assertEqual(r['claim_status'],'RELEASED')
        self.assertEqual(r,self.rpc('resolve_my_claim_reconciliation',args))
        self.assertTrue(self.rpc('get_my_coordination_receipt',{'p_request':req},readonly=True)['found'])

    def test_coord_05_no_collection_abandoned_with_vehicle_confirmation(self):
        for index,s in enumerate(self.stops):
            c=self.uncertain(s,index==0);self.vote(c,False);self.vote(c,False,'donor')
        d=self.detail();self.assertEqual(d['closure_kind'],'NO_COLLECTION');self.assertTrue(d['can_close']);self.assertFalse(d['can_cancel'])
        args={'p_route':self.rid,'p_depot_return_confirmed':False,'p_request':str(uuid4())}
        with self.assertRaisesRegex(base.psycopg.Error,'DEPOT_RETURN_CONFIRMATION_REQUIRED'):self.rpc('close_my_resolved_route',args)
        args['p_depot_return_confirmed']=True
        r=self.rpc('close_my_resolved_route',args);self.assertEqual(r['outcome'],'NO_COLLECTION');self.assertEqual(r,self.rpc('close_my_resolved_route',args))
        self.assertEqual(self.detail()['route_status'],'ABANDONED')
        self.assertFalse(self.scalar(f"SELECT fleet_private.vehicle_has_hold('{self.vehicle_id}')"))

    def test_coord_06_released_history_reclaim_and_expired_listing_cancel(self):
        for s in self.stops:
            c=self.uncertain(s); self.vote(c,False);self.vote(c,False,'donor')
        lid=self.scalar(f"SELECT listing_id FROM public.pickup_tasks WHERE task_id='{self.stops[0]['task_id']}'")
        self.scalar('SELECT public.process_listing_eligibility_refresh_jobs()')
        reclaimed=self.rpc('claim_listing',{'p_listing':lid,'p_request':str(uuid4())})
        self.assertEqual(reclaimed['outcome'],'SUCCESS')
        self.lane.sql("UPDATE public.listings SET listing_expires_at=clock_timestamp()-interval '1 second';")
        self.assertTrue(self.detail()['can_cancel'])
        self.rpc('cancel_my_unstarted_route',{'p_route':self.rid})
        self.assertEqual(self.detail()['route_status'],'CANCELLED')
        self.assertEqual(self.scalar("SELECT count(*) FROM public.pickup_tasks WHERE task_status='STALE'"),2)
        self.assertEqual(self.scalar(f"SELECT claim_status FROM public.donation_claims WHERE claim_id='{reclaimed['claim_id']}'"),'ACTIVE')

    def test_coord_07_mixed_planned_released_cancel_no_resurrection(self):
        c=self.uncertain(self.stops[0]);self.vote(c,False);self.vote(c,False,'donor')
        self.assertTrue(self.detail()['can_cancel']);self.assertFalse(self.detail()['no_collection_cancellation_eligible'])
        self.rpc('cancel_my_unstarted_route',{'p_route':self.rid})
        self.assertEqual(self.scalar("SELECT count(*) FROM public.pickup_tasks WHERE task_status='STALE'"),1)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.pickup_tasks WHERE task_status='CONFIRMED'"),1)
        self.assertEqual(self.scalar('SELECT count(*) FROM routing_private.cancelled_stop_history'),2)

    def test_coord_08_ownership_versions_and_receipt_payload(self):
        c=self.uncertain(self.stops[0],True);s=self.state(c)
        with self.assertRaises(base.psycopg.Error):self.state(c,'other')
        req=str(uuid4());args={'p_claim':c,'p_handover_confirmed':False,'p_expected_round':1,'p_expected_version':s['evidence_version'],'p_request':req}
        r=self.rpc('submit_claim_reconciliation_v2',args);self.assertEqual(r,self.rpc('submit_claim_reconciliation_v2',args))
        with self.assertRaisesRegex(base.psycopg.Error,'REQUEST_PAYLOAD_CONFLICT'):self.rpc('submit_claim_reconciliation_v2',{**args,'p_handover_confirmed':True})
        with self.assertRaisesRegex(base.psycopg.Error,'CASE_VERSION_STALE'):self.rpc('submit_claim_reconciliation_v2',{**args,'p_request':str(uuid4())},'donor')

    def test_coord_09_concurrent_matching_resolution_once(self):
        c=self.uncertain(self.stops[0],True);self.vote(c,False)
        result=self.race(lambda:self.vote(c,False,'donor'),lambda:self.rpc('resolve_my_claim_reconciliation',{'p_claim':c,'p_request':str(uuid4())}))
        self.assertEqual(self.state(c)['case_status'],'RESOLVED_RELEASED')
        self.assertEqual(self.scalar(f"SELECT count(*) FROM public.audit_events WHERE claim_id='{c}' AND event_type='RECONCILIATION_RESOLVED'"),1)

    def test_coord_10_expired_listing_no_handover_does_not_fake_discovery(self):
        c=self.uncertain(self.stops[0],True)
        self.lane.sql(f"UPDATE public.listings SET listing_expires_at=clock_timestamp()-interval '1 second' WHERE listing_id=(SELECT listing_id FROM public.donation_claims WHERE claim_id='{c}');")
        self.vote(c,False);self.assertEqual(self.vote(c,False,'donor')['claim_status'],'RELEASED')
        self.assertEqual(self.scalar(f"SELECT listing_status FROM public.listings l JOIN public.donation_claims c USING(listing_id) WHERE c.claim_id='{c}'"),'CLOSED')

    def test_coord_11_hub_started_false_false_preserves_source_set(self):
        self.reset_template(self.hub_unstarted_template);self.lane.apply(MIGRATION)
        self.rid,self.stops,self.vehicle_id=self.hub_meta
        c=self.uncertain(self.stops[0],True);self.vote(c,False);self.assertEqual(self.vote(c,False,'hub')['claim_status'],'RELEASED')
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE collection_path='HUB_COLLECTION' AND donation_status='BATCHED'"),3)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.hub_inventory WHERE inventory_status='BATCHED'"),3)

    def test_coord_12_decline_and_stale_review_preserve_evidence(self):
        c=self.uncertain(self.stops[0],True);self.vote(c,True);self.vote(c,False,'donor')
        old=self.state(c);args={'p_claim':c,'p_action':'REQUEST','p_expected_version':old['evidence_version'],'p_request':str(uuid4())}
        self.rpc('review_my_claim_reconciliation',args)
        with self.assertRaisesRegex(base.psycopg.Error,'CASE_VERSION_STALE'):
            self.rpc('review_my_claim_reconciliation',{'p_claim':c,'p_action':'ACCEPT','p_expected_version':old['evidence_version'],'p_request':str(uuid4())},'donor')
        self.rpc('review_my_claim_reconciliation',{'p_claim':c,'p_action':'DECLINE','p_expected_version':self.state(c)['evidence_version'],'p_request':str(uuid4())},'donor')
        self.assertEqual(self.state(c)['evidence_round'],1)
        self.assertEqual(self.scalar('SELECT count(*) FROM public.claim_reconciliation_evidence'),2)

    def test_coord_13_recorded_collection_and_incidents_block_release(self):
        c=self.uncertain(self.stops[0],True)
        self.lane.sql(f"INSERT INTO public.audit_events(entity_type,entity_id,event_type,claim_id,outcome,resulting_state) VALUES('CLAIM','{c}','COMPLETE_PICKUP','{c}','SUCCESS','COLLECTED');")
        self.vote(c,False);r=self.vote(c,False,'donor')
        self.assertEqual(r['reason_code'],'RECORDED_COLLECTION_OR_SOURCE_CONFLICT')
        self.assertFalse(self.detail()['can_close'])
        with self.assertRaises(base.psycopg.Error):self.rpc('close_my_collected_route',{'p_route':self.rid,'p_depot_return_confirmed':True})

    def test_coord_14_collected_and_mixed_final_routes(self):
        c=self.uncertain(self.stops[0],True);self.vote(c,True);self.vote(c,True,'donor')
        self.rpc('start_pickup',{'p_claim':self.stops[1]['claim_id']})
        self.rpc('complete_pickup',{'p_claim':self.stops[1]['claim_id'],'p_handover_confirmed':True})
        self.assertEqual(self.detail()['closure_kind'],'COLLECTED')
        self.rpc('close_my_collected_route',{'p_route':self.rid,'p_depot_return_confirmed':True})
        self.assertEqual(self.detail()['route_status'],'COMPLETED')

    def test_coord_15_missing_lease_and_private_permit_denial(self):
        c=self.uncertain(self.stops[0],True)
        self.assertFalse(self.scalar("SELECT has_function_privilege('authenticated','routing_private.coord_decide(uuid,uuid)','EXECUTE')"))
        self.lane.sql(f"DELETE FROM public.claim_leases WHERE claim_id='{c}';")
        self.assertFalse(self.state(c)['can_resolve']);self.assertFalse(self.detail()['can_close'])

    def test_coord_16_review_context_change_cannot_be_accepted(self):
        c=self.uncertain(self.stops[0],True);self.vote(c,True);self.vote(c,False,'donor')
        self.rpc('review_my_claim_reconciliation',{'p_claim':c,'p_action':'REQUEST','p_expected_version':self.state(c)['evidence_version'],'p_request':str(uuid4())})
        self.lane.sql(f"UPDATE public.listings SET listing_version=listing_version+1 WHERE listing_id=(SELECT listing_id FROM public.donation_claims WHERE claim_id='{c}');")
        with self.assertRaisesRegex(base.psycopg.Error,'REVIEW_CONTEXT_CHANGED'):
            self.rpc('review_my_claim_reconciliation',{'p_claim':c,'p_action':'ACCEPT','p_expected_version':self.state(c,'donor')['evidence_version'],'p_request':str(uuid4())},'donor')

    def test_coord_17_checkpoint_racing_next_dispatch(self):
        c=self.uncertain(self.stops[0],True);self.vote(c,False);self.vote(c,False,'donor')
        self.race(lambda:self.rpc('confirm_my_route_depot_checkpoint',{'p_route':self.rid,'p_confirmed':True,'p_request':str(uuid4())}),
                  lambda:self.rpc('start_pickup',{'p_claim':self.stops[1]['claim_id']}))
        self.assertFalse(self.detail()['vehicle_checkpoint_required'])
        status=self.scalar(f"SELECT task_status FROM public.pickup_tasks WHERE task_id='{self.stops[1]['task_id']}'")
        self.assertIn(status,['PLANNED','DISPATCHED'])
        if status=='PLANNED':self.rpc('start_pickup',{'p_claim':self.stops[1]['claim_id']})

    def test_coord_18_closure_racing_released_pickup_preserves_history(self):
        for index,s in enumerate(self.stops):
            c=self.uncertain(s,index==0);self.vote(c,False);self.vote(c,False,'donor')
        before=self.scalar(f"SELECT jsonb_agg(to_jsonb(i) ORDER BY ordinal) FROM routing_private.items i WHERE route_id='{self.rid}'")
        result=self.race(lambda:self.rpc('close_my_resolved_route',{'p_route':self.rid,'p_depot_return_confirmed':True,'p_request':str(uuid4())}),
                         lambda:self.rpc('start_pickup',{'p_claim':self.stops[0]['claim_id']}))
        self.assertEqual(sum('result' in r for r in result),1)
        self.assertEqual(self.detail()['route_status'],'ABANDONED')
        after=self.scalar(f"SELECT jsonb_agg(to_jsonb(i) ORDER BY ordinal) FROM routing_private.items i WHERE route_id='{self.rid}'")
        for a,b in zip(before,after):
            self.assertEqual(a['consumed_at'],b['consumed_at']);self.assertEqual(a['collected_at'],b['collected_at'])

    def test_coord_19_changed_accepted_round_has_mutual_restart_path(self):
        c=self.uncertain(self.stops[0],True);self.vote(c,True);self.vote(c,False,'donor')
        self.rpc('review_my_claim_reconciliation',{'p_claim':c,'p_action':'REQUEST','p_expected_version':self.state(c)['evidence_version'],'p_request':str(uuid4())})
        self.rpc('review_my_claim_reconciliation',{'p_claim':c,'p_action':'ACCEPT','p_expected_version':self.state(c)['evidence_version'],'p_request':str(uuid4())},'donor')
        self.lane.sql(f"UPDATE public.listings SET listing_version=listing_version+1 WHERE listing_id=(SELECT listing_id FROM public.donation_claims WHERE claim_id='{c}');")
        state=self.state(c);self.assertFalse(state['can_submit']);self.assertTrue(state['can_request_review'])
        self.rpc('review_my_claim_reconciliation',{'p_claim':c,'p_action':'REQUEST','p_expected_version':state['evidence_version'],'p_request':str(uuid4())})
        self.rpc('review_my_claim_reconciliation',{'p_claim':c,'p_action':'ACCEPT','p_expected_version':self.state(c)['evidence_version'],'p_request':str(uuid4())},'donor')
        self.assertEqual(self.state(c)['evidence_round'],3)
        self.vote(c,False);self.assertEqual(self.vote(c,False,'donor')['claim_status'],'RELEASED')

    def test_coord_20_source_window_expired_release_keeps_listing_closed(self):
        c=self.uncertain(self.stops[0],True)
        self.lane.sql(f"UPDATE public.donations SET availability_end=clock_timestamp()-interval '1 second' WHERE donation_id=(SELECT donation_id FROM public.listings l JOIN public.donation_claims c USING(listing_id) WHERE c.claim_id='{c}');")
        self.vote(c,False);self.assertEqual(self.vote(c,False,'donor')['claim_status'],'RELEASED')
        self.assertEqual(self.scalar(f"SELECT listing_status FROM public.listings l JOIN public.donation_claims c USING(listing_id) WHERE c.claim_id='{c}'"),'CLOSED')

    def test_coord_21_route_incident_blocks_matching_no_handover(self):
        c=self.uncertain(self.stops[0],True)
        self.lane.sql(f"INSERT INTO resolution_private.cases(route_id,ngo_id,status,reason,manifest_digest) VALUES('{self.rid}','{base.auto.existing.NGO}','MANUAL_REVIEW','CUSTODY_INCIDENT',resolution_private.manifest('{self.rid}')); INSERT INTO resolution_private.incidents(case_id,task_id,actor_id,assertion,case_version) SELECT case_id,'{self.stops[0]['task_id']}','{base.auto.existing.DONOR}','UNKNOWN_CUSTODY',1 FROM resolution_private.cases WHERE route_id='{self.rid}';")
        self.vote(c,False);r=self.vote(c,False,'donor')
        self.assertEqual(r['reason_code'],'UNRESOLVED_CUSTODY_OR_INCIDENT');self.assertFalse(self.detail()['can_close'])

    def test_coord_22_hub_matching_handover_completes_all_members(self):
        self.reset_template(self.hub_unstarted_template);self.lane.apply(MIGRATION)
        self.rid,self.stops,self.vehicle_id=self.hub_meta
        c=self.uncertain(self.stops[0],True);self.vote(c,True);self.assertEqual(self.vote(c,True,'hub')['claim_status'],'COMPLETED')
        self.assertEqual(self.scalar("SELECT count(*) FROM public.hub_inventory WHERE inventory_status='COLLECTED'"),3)
        self.assertEqual(self.scalar("SELECT count(*) FROM public.donations WHERE collection_path='HUB_COLLECTION' AND donation_status='COLLECTED'"),3)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--run-isolated',action='store_true',required=True);p.add_argument('--runtime',type=Path,required=True);a=p.parse_args()
    runtime=a.runtime.resolve();assert runtime.name.startswith('geolock-spatial-runtime-') and (runtime/'pgsql/bin/postgres.exe').is_file()
    for k in list(os.environ):
        if k.upper().startswith(('PG','GEOLOCK','SUPABASE')) or k.upper() in('DATABASE_URL','DB_URL'):os.environ.pop(k,None)
    CoordinationTests.runtime=runtime
    result=unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(CoordinationTests(n) for n in sorted(dir(CoordinationTests)) if n.startswith('test_coord_')))
    summary=dict(tests=result.testsRun,failures=len(result.failures),errors=len(result.errors),passed=result.wasSuccessful(),dev_connections=0)
    if hasattr(CoordinationTests,'lane'):
        CoordinationTests.lane.save('coordination-result.json',summary);print(json.dumps({'evidence':str(CoordinationTests.out),**summary}))
    return not result.wasSuccessful()
if __name__=='__main__':mp.freeze_support();raise SystemExit(main())
