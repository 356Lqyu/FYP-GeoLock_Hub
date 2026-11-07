"""Corrected proposed-only E2. Derived from the preserved original controller.
Same fixtures/scenario driver; only the reviewed forward lock patch is added."""
import argparse,csv,hashlib,json,os,re,subprocess,sys,time,traceback,uuid
from pathlib import Path
from datetime import timedelta
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from experiments.repro_benchmark import ROOT,DATA,sha,write,rows,csv_write,module,integrity,environment,clear_remote_env
import psycopg
from psycopg.conninfo import conninfo_to_dict
from experiments.e2_claiming import e2_runner as old

BIN=ROOT/'.tmp/geolock-spatial-runtime-safe-cancel/pgsql/bin'
PATCH=ROOT/'docs/investigations/e2-dev-compatible-lock/proposed_migration.sql'
CORRECTED_HASH='c8d324772b12c843fba231e7ea733914'

def connect(port,db,**kw):return psycopg.connect(host='127.0.0.1',port=port,dbname=db,user='postgres',connect_timeout=5,**kw)
def source_catalog(port,db):
    with connect(port,db) as c:
        return c.execute("SELECT jsonb_object_agg(p.oid::regprocedure::text,jsonb_build_object('md5',md5(replace(prosrc,chr(13),'')),'owner',proowner::regrole::text,'definer',prosecdef,'acl',proacl::text)) FROM pg_proc p WHERE p.oid IN(to_regprocedure('public.claim_listing(uuid,uuid)'),to_regprocedure('public.recover_expired_claims(integer)'),to_regprocedure('public.geolock_lock_listing_donations(uuid,text[])'))").fetchone()[0]

def run(output,only=None,focused_only=False):
    clear_remote_env();verified=integrity()
    output=Path(output).resolve();assert output.is_relative_to(ROOT/'experiments/e2_atomic_claiming/results')
    output.mkdir(parents=True,exist_ok=False);runtime=output/'runtime';runtime.mkdir();evidence=runtime/'schema-evidence';evidence.mkdir()
    # Reuse the existing full-schema builder. It initializes a NEW marked path
    # with its own random loopback port; no existing DSN/server can be supplied.
    cls=None;port=None
    source_files=[Path(__file__),ROOT/'experiments/repro_benchmark.py',ROOT/'experiments/e2_claiming/e2_runner.py']
    source_files += [ROOT/'experiments/e2_atomic_claiming/dev_acl_regressions.py',ROOT/'experiments/e2_atomic_claiming/dev_acl_custody_tests.py',PATCH]
    source_files+=list((ROOT/'supabase/migrations').glob('*.sql'))+list((ROOT/'docs/stage8/stage-a/forward-migrations').glob('*.sql'))
    manifest=dict(status='STARTING',integrity=verified,environment=environment(),source_sha256={str(p.relative_to(ROOT)):sha(p) for p in source_files},
      comparisons='Same cluster/input order/concurrency; original teammate V3 schema versus current full GeoLock schema. Schema/lifecycle differences are explicit validity threats.',
      synthetic_auth_storage=True,eligibility='Actual frozen matrix lookup adapter; not a fresh pgRouting graph recomputation',dev_connections=0,method_runs=1)
    write(output/'manifest.json',manifest)
    try:
        cls,observed=old.bootstrap_from_current_isolated_fixture(runtime,evidence,BIN)
        port=cls.port;write(runtime/'local-marker.json',dict(port=port,data=str(runtime/'data'),target='NEW LOOPBACK ONLY'))
        with connect(port,'postgres') as c:
            # The older reusable fixture intentionally omits this later reader.
            # Install its exact source/ACL block, not the pg_cron scheduling code.
            reader=(ROOT/'supabase/migrations/20261028_claim_card_expiry_and_paused_recovery.sql').read_text(encoding='utf-8')
            reader=reader[reader.index('create function public.get_my_claim_cards_v2()'):reader.index('-- Reject unexpected default-privilege recipients')]
            c.execute(reader)
        with connect(port,'postgres') as c:
            c.execute((ROOT/'supabase/migrations/20261104130000_unstarted_released_route_cancellation.sql').read_text(encoding='utf-8'))
        with connect(port,'postgres') as c:
            c.execute((PATCH.parent/'acl-fixture.sql').read_text())
            before=c.execute("SELECT jsonb_object_agg(oid::regprocedure::text,to_jsonb(p)) FROM pg_proc p WHERE pronamespace IN ('public'::regnamespace,'routing_private'::regnamespace,'resolution_private'::regnamespace)").fetchone()[0]
            try:c.execute((ROOT/'docs/investigations/e2-shared-lock-review/proposed_migration.sql').read_text())
            except psycopg.Error as err:
                rejection=str(err).splitlines()[0];c.rollback()
            else:raise AssertionError('Original candidate accepted DEV ACLs')
        # The rejected transaction also rolled back its setup; install fixture ACLs durably.
        with connect(port,'postgres') as c:c.execute((PATCH.parent/'acl-fixture.sql').read_text())
        write(output/'original_candidate_rejection.json',dict(error=rejection,expected=True))
        with connect(port,'postgres',autocommit=True) as c:
            c.execute('CREATE DATABASE e2_proposed TEMPLATE postgres')
        with connect(port,'e2_proposed') as c:
            c.execute(PATCH.read_text(encoding='utf-8'))
        manifest['correction_patch_sha256']=sha(PATCH)
        (output/'applied_candidate.sql').write_bytes(PATCH.read_bytes())
        manifest['function_catalog']={'e2_proposed':source_catalog(port,'e2_proposed')}
        expected=manifest['function_catalog']['e2_proposed']
        assert expected['claim_listing(uuid,uuid)']['md5']==CORRECTED_HASH
        assert expected['recover_expired_claims(integer)']['md5']==old.RECOVERY_HASH
        with connect(port,'e2_proposed') as c:
            c.execute("CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$SELECT coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid$$")
            c.execute("CREATE SCHEMA e2_benchmark; CREATE TABLE e2_benchmark.road_costs(a text,b text,km double precision);")
            with c.cursor().copy('COPY e2_benchmark.road_costs FROM STDIN') as cp:
                for r in rows(DATA/'road_distance_matrix.csv'):
                    if r['route_available_flag']=='1':cp.write_row((r['from_node_id'],r['to_node_id'],float(r['road_distance_km'])))
            c.execute('CREATE INDEX ON e2_benchmark.road_costs(a,b)')
            c.execute("CREATE OR REPLACE FUNCTION public.geolock_ngo_listing_road_check(p_ngo uuid,p_listing uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ SELECT jsonb_build_object('outcome',CASE WHEN r.km IS NULL THEN 'ROUTE_UNAVAILABLE' WHEN r.km>20 THEN 'OUTSIDE_GEOFENCE' ELSE 'ELIGIBLE' END,'road_distance_km',r.km) FROM public.ngo_profiles n CROSS JOIN public.listings l LEFT JOIN e2_benchmark.road_costs r ON r.a=n.road_node_id AND r.b=l.pickup_road_node_id WHERE n.user_id=p_ngo AND l.listing_id=p_listing $$")
            c.execute('GRANT USAGE ON SCHEMA public TO authenticated,service_role')
        base=module('protected_claim_without_lease_recovery');bench=base.Benchmark(DATA)
        class ProposedDatabase(base.Database):
            def listing(self,bench,listing_id,instance,opened_ago=timedelta(0)):
                bl=bench.listings[listing_id];donation=bench.donations[bl['donation_id']];donor=bench.donors[donation['donor_id']]
                lifetime=base.parse_time(bl['listing_expires_at'])-base.parse_time(bl['created_at'])
                request=self.uid('CREATE',instance)
                with self.conn.cursor() as cur:
                    actor=self._user(cur,donation['donor_id'],donation['donor_id'],'DONOR')
                    cur.execute('INSERT INTO public.donor_profiles(user_id) VALUES(%s) ON CONFLICT DO NOTHING',(actor,))
                    image=f'{actor}/pending/{request}/{self.uid("IMAGE",instance)}.jpg'
                    cur.execute("INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('geolock-donation-images',%s,'{\"size\":100,\"mimetype\":\"image/jpeg\"}')",(image,))
                    cur.execute("SELECT set_config('request.jwt.claim.sub',%s,false)",(str(actor),))
                    items=json.dumps([dict(category_id=old.CATEGORY,item_name=donation['category'],quantity=1,unit_weight_kg=float(bl['listing_weight_kg']),item_condition='GOOD')])
                    photos=json.dumps([dict(storage_path=image,content_type='image/jpeg',size_bytes=100,display_order=1)])
                    did=cur.execute('SELECT public.create_donation_with_images(%s,%s,%s,%s,%s,%s,%s::jsonb,%s,%s::jsonb)',(request,'E2 '+bl['donation_id'],'Frozen benchmark fixture','Benchmark pickup',float(donor['latitude']),float(donor['longitude']),items,'102',photos)).fetchone()[0]
                    opened=cur.execute('SELECT clock_timestamp()-%s',(opened_ago,)).fetchone()[0]
                    cur.execute('UPDATE public.donations SET latitude=%s,longitude=%s,pickup_road_node_id=%s,availability_start=%s,availability_end=%s WHERE donation_id=%s',(float(donor['latitude']),float(donor['longitude']),donor['road_node_id'],opened,opened+lifetime,did))
                    lid=cur.execute('UPDATE public.listings SET pickup_latitude=%s,pickup_longitude=%s,pickup_road_node_id=%s,created_at=%s,listing_expires_at=%s WHERE donation_id=%s RETURNING listing_id',(float(donor['latitude']),float(donor['longitude']),bl['pickup_road_node_id'],opened,opened+lifetime,did)).fetchone()[0]
                    cur.execute("SELECT set_config('request.jwt.claim.sub','',false)")
                return lid
            def prior_claim(self,sid,lid,holder,ago):
                request=self.uid('PRIOR',sid)
                batch=[dict(scenario_id=sid,listing_id='prior',workers=1,request_no=0,ngo_id='holder',ngo_uuid=holder,road_distance_km=0,listing_uuid=lid,request_uuid=request)]
                result=base.send_together(dsn_proposed,batch,base.CALL)[0]
                assert result['outcome']=='SUCCESS',result
                claim=result['claim_id']
                with self.conn.cursor() as cur:
                    cur.execute("UPDATE public.claim_leases SET issued_at=clock_timestamp()-%s,expires_at=clock_timestamp()-%s+interval '360 minutes' WHERE claim_id=%s",(ago,ago,claim))
                return uuid.UUID(str(claim))
        dsn_proposed=f'host=127.0.0.1 port={port} dbname=e2_proposed user=postgres'
        db=ProposedDatabase(dsn_proposed,output.name+'-actual');records=[];requests=[];failures=[];committed=[]
        from experiments.e2_atomic_claiming.dev_acl_regressions import validate
        validate(port,db,bench,base,output)
        if focused_only:
            write(output/'focused_completion.json',dict(passed=True,remote_connections=0))
            db.conn.close()
            return
        custody=ROOT/'docs/investigations/e2-dev-compatible-lock/custody-tests.json'
        assert json.loads(custody.read_text())['passed'], 'Custody regressions must pass before formal benchmark'
        chosen=bench.select(('CLAIM_COORDINATION','LEASE_RECOVERY','LEASE_ACTIVE_VERIFICATION'))
        if only:chosen=[s for s in chosen if s['scenario_id'] in only.split(',')]
        for i,scenario in enumerate(chosen,1):
            sid= scenario['scenario_id'];kind=scenario['scenario_type'];listing_id=bench.one(sid,'LISTING','CLAIMABLE_LISTING')
            try:
                if kind=='CLAIM_COORDINATION':
                    lid=db.listing(bench,listing_id,sid);ngos=bench.ids(sid,'NGO','POTENTIAL_REQUESTER_UNASSESSED');workers=base.worker_count(sid,None)
                    batch=[dict(scenario_id=sid,listing_id=listing_id,workers=workers,request_no=n+1,ngo_id=ngos[n%len(ngos)],ngo_uuid=db.ngo(bench,ngos[n%len(ngos)]),road_distance_km=bench.road_km(ngos[n%len(ngos)],listing_id),listing_uuid=lid,request_uuid=db.uid('REQUEST',sid+'/'+str(n))) for n in range(workers)]
                    done=base.send_together(dsn_proposed,batch,base.CALL);stored,status=db.claims_on(lid)
                    rr=base.trial_row(sid,listing_id,workers,done,[r for r in stored if r[2] in ('ACTIVE','RECONCILIATION_REQUIRED')],status)
                else:
                    state=bench.claim_states[sid];prior=bench.one(sid,'NGO','PRIOR_CLAIMANT');second=bench.one(sid,'NGO','POTENTIAL_REPLACEMENT_CLAIMANT')
                    ago=base.parse_time(state['replay_at'])-base.parse_time(bench.listings[listing_id]['created_at'])
                    lid=db.listing(bench,listing_id,sid,ago);cid=db.prior_claim(sid,lid,db.ngo(bench,prior),ago)
                    began=time.perf_counter()
                    with connect(port,'e2_proposed') as c:
                        c.execute('SET LOCAL ROLE service_role');c.execute("SELECT set_config('request.jwt.claim.role','service_role',true),set_config('request.jwt.claim.sub','',true)")
                        recovered=c.execute('SELECT public.recover_expired_claims(500)').fetchone()[0]
                    recovery_ms=(time.perf_counter()-began)*1000
                    item=dict(scenario_id=sid,listing_id=listing_id,workers=1,request_no=1,ngo_id=second,ngo_uuid=db.ngo(bench,second),road_distance_km=bench.road_km(second,listing_id),listing_uuid=lid,request_uuid=db.uid('REQUEST',sid+'/replacement'))
                    done=base.send_together(dsn_proposed,[item],base.CALL);stored,status=db.claims_on(lid);prior_state=next(r[2] for r in stored if str(r[0])==str(cid))
                    rr=dict(scenario_id=sid,case='lease expired' if state['input_state']=='EXPIRED' else 'lease still running',listing_id=listing_id,first_ngo=prior,second_ngo=second,
                      second_ngo_answer=done[0]['outcome'],second_ngo_reason=done[0]['reason_code'],second_ngo_got_listing=base.yes(done[0]['outcome']=='SUCCESS'),first_claim_still_active=base.yes(prior_state=='ACTIVE'),
                      active_claims_after=sum(r[2] in ('ACTIVE','RECONCILIATION_REQUIRED') for r in stored),listing_status_after=status,second_ngo_response_ms=done[0]['latency_ms'],recovery_affected_rows=recovered,recovery_ms=recovery_ms)
                records.append(rr);requests.extend(done)
                committed.append(dict(scenario_id=sid,listing_uuid=str(lid),listing_status=status,claims=[dict(claim_id=str(r[0]),ngo_uuid=str(r[1]),claim_status=r[2]) for r in stored],active_owner_count=len({str(r[1]) for r in stored if r[2] in ('ACTIVE','RECONCILIATION_REQUIRED')})))
            except Exception as e:
                failures.append(dict(scenario_id=sid,stage='fixture_or_execution',error=type(e).__name__,sqlstate=getattr(e,'sqlstate',None),message=str(e).splitlines()[0]));print('E2 failure',sid,type(e).__name__,getattr(e,'sqlstate',None),flush=True)
            csv_write(output/'proposed_results_per_scenario.csv',records);write(output/'proposed_requests.json',requests);write(output/'failures.json',failures);write(output/'proposed_committed_states.json',committed)
            if i%10==0:print(f'E2 proposed {i}/{len(chosen)}',flush=True)
        with connect(port,'e2_proposed') as c:
            audits=c.execute("SELECT request_id,reason_code,details->>'sqlstate' sqlstate,details->>'rollback_confirmed' rollback_confirmed FROM public.operation_failure_events").fetchall()
        benchmark_ids={str(r['request_uuid']) for r in requests}
        csv_write(output/'database_errors.csv',[dict(request_id=str(r[0]),reason_code=r[1],sqlstate=r[2],rollback_confirmed=r[3]) for r in audits if str(r[0]) in benchmark_ids])
        write(output/'all_failure_audits.json',[dict(request_id=str(r[0]),reason_code=r[1],sqlstate=r[2],rollback_confirmed=r[3],benchmark_request=str(r[0]) in benchmark_ids) for r in audits])
        db.conn.close();manifest.update(status='EXECUTED',postgresql=observed,baseline_runs='Reused existing preserved baseline results; proposed only in this run',proposed_results=len(records),proposed_failures=len(failures),function_sources_unchanged=source_catalog(port,'e2_proposed')==manifest['function_catalog']['e2_proposed'])
        write(output/'manifest.json',manifest);write(output/'completion.json',dict(executed=True,planned_proposed=len(chosen),completed_proposed=len(records),failures=len(failures),remote_connections=0))
    finally:
        if cls is not None:
            proc=subprocess.run([str(BIN/'pg_ctl.exe'),'-D',str(runtime/'data'),'-m','fast','-w','-t','30','stop'],capture_output=True,text=True)
            write(output/'cluster-stop.json',dict(stopped=proc.returncode==0,port=port,remote_connections=0))
        # Retain the disposable data/evidence; never recursively delete a path.

if __name__=='__main__':
    if sys.flags.optimize:raise SystemExit('Optimized Python is unsupported: validation assertions must remain enabled.')
    p=argparse.ArgumentParser();p.add_argument('--output',required=True);p.add_argument('--scenario');p.add_argument('--focused-only',action='store_true');a=p.parse_args();run(a.output,a.scenario,a.focused_only)
