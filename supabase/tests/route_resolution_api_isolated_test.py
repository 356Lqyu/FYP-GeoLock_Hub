"""LOCAL-only real-SQL adapter bridge, reusing the disposable PG17 resolution lane.

No live DSN/profile accepted. Synthetic auth/Storage/cron are not hosted parity.
"""
import argparse
import json
import multiprocessing as mp
import os
import secrets
import tempfile
from pathlib import Path
import unittest
from uuid import uuid4

import route_resolution_isolated_test as base
from backend.routing.integration.route_resolution import ResolutionApi, RestrictedResolutionApi


class BridgeTests(base.ResolutionTests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.lane.hashes[str(Path(__file__).relative_to(base.ROOT)).replace('\\','/')]=base.auto.assembly.digest(Path(__file__))

    def bridge(self, source):
        if source=='hub':
            self.use_hub()
            self.lane.sql("UPDATE public.donations SET donation_status='BATCHED' WHERE donation_status='PICKUP_IN_PROGRESS';",expected='INVALID_DONATION_TRANSITION')
        test=self
        class ParticipantSession:
            def __init__(self,who):self.who=who
            def rpc(self,name,params):
                return test.rpc(name,params,who=self.who,readonly=name.startswith(('get_','list_')))
        ngo=ResolutionApi(ParticipantSession('ngo'),enabled=True)
        party=ResolutionApi(ParticipantSession(source),enabled=True)
        operator=RestrictedResolutionApi(lambda name,params:test.rpc(name,params,who='resolver',readonly=name.startswith('get_')),enabled=True)
        request=str(uuid4())
        reported=ngo.report(self.rid,'VEHICLE_FAILURE',request)
        self.case=reported['case_id']
        self.assertEqual(ngo.receipt(request)['outcome'],'FOUND')
        self.assertEqual(len(party.list_cases()['cases']),1)
        for stop in self.stops:
            ngo.evidence(self.case,stop['task_id'],base.NO,ngo.read(self.rid)['version'],str(uuid4()))
            party.evidence(self.case,stop['task_id'],base.NO,party.read(self.rid)['version'],str(uuid4()))
        ngo.evidence(self.case,None,base.RETURN,ngo.read(self.rid)['version'],str(uuid4()))
        self.assertEqual(operator.read(self.case)['case']['case_id'],self.case)
        receipt=operator.finalize(self.case,ngo.read(self.rid)['version'],str(uuid4()))
        self.assertEqual(receipt['route_status'],'ABANDONED')
        party_id=self.hub_actor if source=='hub' else base.auto.existing.DONOR
        party_role='HUB_ADMIN' if source=='hub' else 'DONOR'
        for identity,role in [(base.auto.existing.NGO,'NGO'),(party_id,party_role)]:
            self.assertGreater(self.scalar("SELECT count(*) FROM public.audit_events WHERE event_type='ROUTE_RESOLUTION_EVIDENCE_SUBMITTED' AND details->>'case_id'='"+self.case+"' AND actor_user_id='"+identity+"' AND actor_role='"+role+"' AND details->>'operator_principal' IS NULL"),0)
        incident_request=str(uuid4())
        ngo.incident(self.case,self.stops[0]['task_id'],'UNKNOWN_CUSTODY',incident_request)
        self.assertEqual(ngo.receipt(incident_request)['result']['status'],'INCIDENT_RECORDED')
        self.assertEqual(self.scalar('SELECT route_status FROM public.pickup_routes'),'ABANDONED')
        self.assertFalse(self.scalar("SELECT fleet_private.vehicle_has_hold('"+self.vehicle_id+"')"))
        self.lane.save('resolution-api-'+source+'-result.json',{'scope':'DISPOSABLE SQL, synthetic authenticated principals; not hosted PostgREST','route_id':self.rid,'case_id':self.case,'route_status':receipt['route_status'],'report_request':request,'incident_request':incident_request,'dev_connections':0})

    def test_api_direct(self):self.bridge('donor')
    def test_api_hub(self):self.bridge('hub')

    def test_resolver_session_cannot_spoof_audit_actor(self):
        self.report();self.consent()
        version=self.read()['version'];request=str(uuid4())
        contexts=[{'request.jwt.claim.sub':base.auto.existing.NGO},
            {'request.jwt.claim.sub':'invalid-uuid'},
            {'request.jwt.claims':json.dumps({'sub':base.auto.existing.NGO,'role':'authenticated'})},
            {'request.jwt.claims':'{}'},{'request.jwt.claims':'invalid-json'},
            {'request.jwt.claim.sub':'','request.jwt.claims':json.dumps({'sub':base.auto.existing.NGO})},
            {'request.jwt.claim.role':'authenticated'}]
        before=self.resolution_state_digest()
        # A case lock proves mixed contexts are rejected before trying to lock it.
        blocker=base.auto.connect(self.lane.port,self.db,'postgres')
        blocker.execute('SELECT 1 FROM resolution_private.cases WHERE case_id=%s FOR UPDATE',(self.case,))
        try:
            for context in contexts:
                with self.subTest(context_fields=list(context)):
                    self.reject_context(context,'SELECT public.finalize_route_resolution(%s,%s,%s)',(self.case,version,request))
                    self.reject_context(context,'SELECT public.get_route_resolution_for_operator(%s)',(self.case,))
                    self.reject_context(context,'SELECT public.get_my_route_resolution_receipt(%s)',(request,))
                    self.reject_context(context,'SELECT public.register_route_test_provenance(%s,%s,%s,%s,%s::uuid[],%s)',(str(uuid4()),'a'*64,base.auto.existing.NGO,self.vehicle_id,[s['claim_id'] for s in self.stops],str(uuid4())))
        finally:blocker.rollback();blocker.close()
        self.assertEqual(self.resolution_state_digest(),before)
        self.assertEqual(self.rpc('get_my_route_resolution_receipt',{'p_request':request},who='resolver',readonly=True)['outcome'],'NOT_FOUND')
        result=self.finalize(request=request,version=version)
        with base.auto.connect(self.lane.port,self.db,'postgres') as conn:
            rows=conn.execute("SELECT actor_user_id::text,actor_role,details->>'operator_principal',details->>'operator_label',event_type FROM public.audit_events WHERE request_id=%s",(request,)).fetchall()
        self.assertGreaterEqual(len(rows),6)
        self.assertIn('DONATION_STATUS_CHANGED',[r[4] for r in rows])
        for actor,role,principal,label,event in rows:
            self.assertIsNone(actor,event);self.assertEqual(role,'SYSTEM',event)
            self.assertEqual(principal,'geolock_local_resolver',event)
            self.assertEqual(label,'LOCAL SYNTHETIC OPERATOR',event)
        committed=self.resolution_state_digest()
        for context in contexts:
            # Existing committed receipts cannot be replayed or read with mixed identity.
            self.reject_context(context,'SELECT public.finalize_route_resolution(%s,%s,%s)',(self.case,version,request))
            self.reject_context(context,'SELECT public.get_my_route_resolution_receipt(%s)',(request,))
        self.assertEqual(self.resolution_state_digest(),committed)
        self.assertEqual(self.rpc('get_my_route_resolution_receipt',{'p_request':request},who='resolver',readonly=True)['result'],result)
        for who,identity,role in [('ngo',base.auto.existing.NGO,'NGO'),('donor',base.auto.existing.DONOR,'DONOR')]:
            self.assertGreater(self.scalar("SELECT count(*) FROM public.audit_events WHERE event_type='ROUTE_RESOLUTION_EVIDENCE_SUBMITTED' AND actor_user_id='"+identity+"' AND actor_role='"+role+"' AND details->>'operator_principal' IS NULL"),0)
        observed={'scope':'DISPOSABLE PG17 ONLY','expected_operator_principal':'geolock_local_resolver',
            'mixed_context_variants_rejected':len(contexts),'prelock_rejection':True,'replay_bypass':False,
            'route_and_donation_audits_verified':len(rows),'participant_jwt_attribution_preserved':True,
            'protected_finalization_result':result['route_status'],'dev_connections':0}
        self.lane.save('resolution-operator-identity-correction.json',observed)

    def reject_context(self,context,sql,params):
        with base.auto.connect(self.lane.port,self.db,'geolock_local_resolver') as conn:
            conn.execute("SET LOCAL statement_timeout='600ms'")
            for key,value in context.items():conn.execute('SELECT set_config(%s,%s,true)',(key,value))
            with self.assertRaisesRegex(base.psycopg.Error,'RESOLVER_JWT_CONTEXT_FORBIDDEN'):
                conn.execute(sql,params)
            conn.rollback()

    def test_real_commit_response_loss_reconciles_without_write_retry(self):
        test=self;calls=[]
        class LoseOnce:
            def rpc(self,name,params):
                calls.append(name)
                value=test.rpc(name,params,readonly=name.startswith(('get_','list_')))
                if name=='report_my_route_interruption':raise TimeoutError('LOCAL reply lost after committed RPC')
                return value
        api=ResolutionApi(LoseOnce(),enabled=True);request=str(uuid4())
        with self.assertRaises(TimeoutError):api.report(self.rid,'VEHICLE_FAILURE',request)
        before=self.resolution_state_digest()
        receipt=api.receipt(request)
        self.assertEqual(receipt['outcome'],'FOUND');self.assertEqual(receipt['result']['route_id'],self.rid)
        self.assertEqual(calls,['report_my_route_interruption','get_my_route_resolution_receipt'])
        self.assertEqual(self.resolution_state_digest(),before)
        self.assertEqual(self.scalar('SELECT count(*) FROM resolution_private.cases'),1)
        self.lane.save('resolution-real-lost-reply.json',{'request':request,'outcome':'FOUND','writes':1,'read_reconciliation':1,'automatic_retries':0,'dev_connections':0})

    def test_unrelated_authorized_route_assignment_is_preserved(self):
        # A separate NGO's genuine planner/validator/authorization path, not a
        # copied public route row, supplies the independent assignment/hold.
        donor=base.auto.existing.DONOR
        request=str(uuid4());photo=f'{donor}/pending/{request}/{uuid4()}.jpg'
        items=json.dumps([{'category_id':base.auto.existing.uid('category'),'item_name':'LOCAL INDEPENDENT FOOD','quantity':1,'unit_weight_kg':20}])
        images=json.dumps([{'storage_path':photo,'content_type':'image/jpeg','size_bytes':100}])
        donation=self.lane.sql(f"SET request.jwt.claim.sub='{donor}'; SET request.jwt.claim.role='authenticated'; INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('geolock-donation-images','{photo}','{{\"size\":100,\"mimetype\":\"image/jpeg\"}}'); SELECT public.create_donation_with_images('{request}','LOCAL INDEPENDENT','SYNTHETIC ONLY','LOCAL',3.01,101.01,'{items}'::jsonb,'102','{images}'::jsonb);")
        listing=self.lane.sql(f"SELECT listing_id FROM public.listings WHERE donation_id='{donation}';")
        self.lane.sql('SELECT public.process_listing_eligibility_refresh_jobs();')
        other=base.auto.Session(self.lane.port,self.db,base.auto.existing.uid('foreign-ngo'))
        self.assertEqual(other.rpc('claim_listing',{'p_listing':listing,'p_request':str(uuid4())})['outcome'],'SUCCESS')
        vehicle=other.rpc('register_my_vehicle',{'p_request_id':str(uuid4()),'p_label':'LOCAL INDEPENDENT','p_vehicle_type':'VAN','p_capacity_kg':100,'p_fixed_cost_rm':10,'p_distance_cost_rm_per_km':1,'p_max_route_duration_min':60,'p_available':True})
        policy=self.scalar('SELECT policy_id::text FROM routing_private.policies LIMIT 1')
        graph=self.scalar('SELECT graph_id::text FROM routing_private.graphs LIMIT 1')
        plan_request=str(uuid4())
        snapshot=other.rpc('begin_my_routing_snapshot',{'p_request':plan_request,'p_policy':policy,'p_vehicle_ids':[vehicle['vehicle_id']]})
        token=secrets.token_urlsafe(32);parent,child=mp.get_context('spawn').Pipe(duplex=False)
        process=mp.get_context('spawn').Process(target=base.auto.validator_process,args=(self.lane.port,self.db,token,child),daemon=True)
        process.start();child.close()
        try:
            self.assertTrue(parent.poll(20));info=parent.recv()
            with tempfile.TemporaryDirectory(prefix='geolock-resolution-other-') as temp:
                worker=base.auto.RoutingWorker(base.auto.worker_rpc(self.lane.port,self.db,'geolock_planner'),
                    base.auto.GraphCache(base.auto.worker_rpc(self.lane.port,self.db,'geolock_graph_worker'),graph,Path(temp)/'graphs'),
                    base.auto.RemoteValidator('http://127.0.0.1:'+str(info['port']),token),base.auto.Journal(Path(temp)/'journal'))
                result=worker.plan_and_authorize(other,snapshot['snapshot_id'],plan_request)
            rid=result['authorization']['route_ids'][0]
        finally:
            parent.close();process.terminate();process.join(10)
        queries=[f"SELECT to_jsonb(t) FROM public.pickup_routes t WHERE route_id='{rid}'",
            f"SELECT to_jsonb(t) FROM routing_private.bindings t WHERE route_id='{rid}'",
            f"SELECT jsonb_agg(to_jsonb(t) ORDER BY task_id) FROM public.active_task_route_assignments t WHERE route_id='{rid}'"]
        before=[self.scalar(q) for q in queries]
        self.report();self.consent();self.finalize()
        self.assertEqual([self.scalar(q) for q in queries],before)
        self.assertTrue(self.scalar("SELECT fleet_private.vehicle_has_hold('"+vehicle['vehicle_id']+"')"))
        self.assertTrue(other.rpc('get_my_authorized_route',{'p_route':rid})['authorization_confirmed'])
        self.lane.save('resolution-cross-ngo-preservation.json',{'resolved_route':self.rid,'unrelated_authorized_route':rid,'unrelated_assignments_preserved':True,'unrelated_vehicle_hold_preserved':True,'dev_connections':0})


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',required=True,action='store_true')
    parser.add_argument('--runtime',required=True,type=Path)
    parser.add_argument('--operator-context-check',action='store_true',help='Run only the audit-identity security regression.')
    args=parser.parse_args()
    runtime=args.runtime.resolve()
    assert runtime.name.startswith('geolock-spatial-runtime-') and (runtime/'pgsql/bin/postgres.exe').is_file()
    for key in list(os.environ):
        if key.upper().startswith(('PG','GEOLOCK','SUPABASE')) or key.upper() in ('DATABASE_URL','DB_URL'):os.environ.pop(key,None)
    BridgeTests.runtime=runtime
    # Select bridge/isolation tests only, not the inherited 70-scenario suite.
    names=('test_resolver_session_cannot_spoof_audit_actor',) if args.operator_context_check else ('test_api_direct','test_api_hub','test_unrelated_authorized_route_assignment_is_preserved','test_resolver_session_cannot_spoof_audit_actor','test_real_commit_response_loss_reconciles_without_write_retry')
    result=unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(BridgeTests(name) for name in names))
    summary={'status':'PASS' if result.wasSuccessful() else 'FAIL','tests':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'dev_connections':0}
    if hasattr(BridgeTests,'lane'):
        BridgeTests.lane.save('resolution-api-bridge-summary.json',summary)
        print(json.dumps({'evidence':str(BridgeTests.out),**summary},indent=2))
    return not result.wasSuccessful()


if __name__=='__main__':
    mp.freeze_support()
    raise SystemExit(main())
