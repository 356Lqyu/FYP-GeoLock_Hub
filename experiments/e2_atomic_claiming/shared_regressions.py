"""Additional disposable-SQL checks, separate from the frozen 275-case run."""
import hashlib
import json
from pathlib import Path
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
import psycopg
from psycopg.rows import dict_row
from experiments.repro_benchmark import write

def validate(port, db, bench, base, output):
    checks=[]; operations=[]
    def connect(**kw):
        return psycopg.connect(host='127.0.0.1',port=port,dbname='e2_proposed',user='postgres',connect_timeout=5,**kw)
    def check(name, passed, evidence=None):
        checks.append(dict(name=name,passed=bool(passed),evidence=evidence))
        write(output/'regressions.json',dict(checks=checks,operations=operations))
        assert passed, name
    scenario=next(s for s in bench.select(('CLAIM_COORDINATION',)) if base.worker_count(s['scenario_id'],None)==10)
    listing=bench.one(scenario['scenario_id'],'LISTING','CLAIMABLE_LISTING')
    ngo_ids=bench.ids(scenario['scenario_id'],'NGO','POTENTIAL_REQUESTER_UNASSESSED')
    actors=[str(db.ngo(bench,n)) for n in ngo_ids]
    # Frozen scenarios may repeat four actors across ten requests. Additional
    # regression-only NGOs share a verified frozen location to exercise ten
    # distinct accounts without modifying the benchmark dataset.
    while len(actors)<10:
        with db.conn.cursor() as cur:
            actor=db._user(cur,'SHARED-REGRESSION-NGO-'+str(len(actors)),'Local regression NGO','NGO')
            cur.execute("INSERT INTO public.ngo_profiles(user_id,ngo_name,operating_address,latitude,longitude,road_node_id,location_verified_at) SELECT %s,'Local regression NGO',operating_address,latitude,longitude,road_node_id,location_verified_at FROM public.ngo_profiles WHERE user_id=%s ON CONFLICT DO NOTHING",(actor,actors[0]))
        actors.append(str(actor))

    def fresh(label):return str(db.listing(bench,listing,'REGRESSION/'+label))
    def invoke(actor,lid,request=None,sql='public.claim_listing(%s,%s)',service=False):
        request=request or str(uuid.uuid4());start=time.perf_counter()
        try:
            with connect() as c:
                c.execute("SET LOCAL statement_timeout='15s'; SET LOCAL lock_timeout='10s'")
                c.execute('SET LOCAL ROLE service_role' if service else 'SET LOCAL ROLE authenticated')
                c.execute("SELECT set_config('request.jwt.claim.sub',%s,true),set_config('request.jwt.claim.role',%s,true)",(actor or '', 'service_role' if service else 'authenticated'))
                params=(lid,request) if not service else ()
                result=c.execute('SELECT '+sql,params).fetchone()[0]
            op=dict(actor=actor,listing=lid,request=request,result=result,sqlstate=None)
        except psycopg.Error as e:
            op=dict(actor=actor,listing=lid,request=request,result=None,sqlstate=e.sqlstate,message=str(e).splitlines()[0])
        op['latency_ms']=round((time.perf_counter()-start)*1000,3);operations.append(op)
        return op
    def race(calls):
        gate=threading.Barrier(len(calls))
        def wrapped(fn):gate.wait();return fn()
        with ThreadPoolExecutor(max_workers=len(calls)) as pool:return list(pool.map(wrapped,calls))
    def ownership(lid):
        with connect() as c:
            return c.execute("SELECT count(*),count(DISTINCT ngo_user_id) FROM public.donation_claims WHERE listing_id=%s AND claim_status IN ('ACTIVE','RECONCILIATION_REQUIRED')",(lid,)).fetchone()

    # Catalog evidence: listing keys, all triggers, grants and dependent functions.
    with connect(row_factory=dict_row) as c:
        write(output/'dependency_catalog.json',dict(
          indexes=c.execute("SELECT indexname,indexdef FROM pg_indexes WHERE schemaname='public' AND tablename='listings' ORDER BY indexname").fetchall(),
          foreign_keys=c.execute("SELECT conname,conrelid::regclass::text relation,pg_get_constraintdef(oid) definition FROM pg_constraint WHERE contype='f' AND confrelid='public.listings'::regclass ORDER BY conname").fetchall(),
          triggers=c.execute("SELECT tgrelid::regclass::text relation,tgname,pg_get_triggerdef(oid) definition FROM pg_trigger WHERE tgrelid IN ('public.listings'::regclass,'public.donation_claims'::regclass,'public.claim_leases'::regclass,'public.audit_events'::regclass) ORDER BY 1,2").fetchall(),
          functions=c.execute("SELECT oid::regprocedure::text signature,md5(replace(prosrc,chr(13),'')) hash,proowner::regrole::text owner,prosecdef,proacl::text,proconfig FROM pg_proc WHERE oid IN ('public.claim_listing(uuid,uuid)'::regprocedure,'public.recover_expired_claims(integer)'::regprocedure,'public.cancel_claim(uuid,uuid)'::regprocedure) ORDER BY 1").fetchall()))

    for n in (2,5,10):
        lid=fresh('contention-'+str(n))
        rr=race([lambda a=a:invoke(a,lid) for a in actors[:n]])
        check(f'{n} concurrent NGOs: one success, clean losing conflicts, one owner',
          sum(r['result'] and r['result'].get('outcome')=='SUCCESS' for r in rr)==1 and
          sum(r['result'] and r['result'].get('reason_code')=='CLAIM_CONFLICT' for r in rr)==n-1 and
          all(r['sqlstate'] is None for r in rr) and ownership(lid)==(1,1),rr)

    lid=fresh('replay');request=str(uuid.uuid4())
    first=invoke(actors[0],lid,request); replay=invoke(actors[0],lid,request)
    check('same UUID replay returns same claim without another ownership row',
      first['result']['outcome']=='SUCCESS' and replay['result'].get('replayed') is True and
      first['result']['claim_id']==replay['result']['claim_id'] and ownership(lid)==(1,1))
    different=invoke(actors[0],lid)
    check('different UUID does not create a second claim for existing holder',different['result']['reason_code']=='CLAIM_CONFLICT' and ownership(lid)==(1,1))
    other=fresh('different-payload');mismatch=invoke(actors[0],other,request)
    check('same UUID different listing returns audited rollback receipt',mismatch['result']['reason_code']=='IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD' and mismatch['result']['rollback_confirmed'] is True and ownership(other)==(0,0))
    stolen=invoke(actors[1],lid,request)
    check('another NGO cannot reuse a request UUID to gain ownership',stolen['result']['rollback_confirmed'] is True and ownership(lid)==(1,1))
    with connect() as c:
        audit_count=c.execute("SELECT count(*) FROM public.audit_events WHERE event_type='CLAIM_ATTEMPT' AND request_id=%s",(request,)).fetchone()[0]
    check('success replay preserves one claim-attempt audit',audit_count==1,audit_count)

    lid=fresh('concurrent-replay');request=str(uuid.uuid4())
    rr=race([lambda:invoke(actors[0],lid,request) for _ in range(5)])
    check('concurrent same UUID serialized and replayed',all(r['result'] and r['result']['outcome']=='SUCCESS' for r in rr) and len({r['result']['claim_id'] for r in rr})==1 and sum(r['result'].get('replayed') is False for r in rr)==1 and ownership(lid)==(1,1),rr)

    # Reproduce the previous exact FK statement boundary, with unchanged FK checks.
    lid=fresh('controlled-fk-interleaving'); conns=[]; requests=[str(uuid.uuid4()),str(uuid.uuid4())]
    try:
        for actor,request in zip(actors,requests):
            c=connect();conns.append(c)
            c.execute("SET LOCAL deadlock_timeout='1s'; SET LOCAL statement_timeout='10s'")
            c.execute("SELECT set_config('request.jwt.claim.sub',%s,true)",(actor,))
            c.execute('INSERT INTO public.claim_requests(request_id,listing_id,ngo_user_id,request_digest) VALUES(%s,%s,%s,md5(%s))',(request,lid,actor,lid+':'+actor))
        def controlled(i):
            start=time.perf_counter()
            try:
                r=conns[i].execute('SELECT public.claim_listing(%s,%s)',(lid,requests[i])).fetchone()[0]
                conns[i].commit()
                return dict(result=r,sqlstate=None,latency_ms=(time.perf_counter()-start)*1000)
            except psycopg.Error as e:
                conns[i].rollback();return dict(result=None,sqlstate=e.sqlstate)
        rr=race([lambda:controlled(0),lambda:controlled(1)])
        check('controlled FK key-share upgrade no longer deadlocks',sorted(r['result']['outcome'] for r in rr if r['result'])==['CONFLICT','SUCCESS'] and all(r['sqlstate'] is None for r in rr) and ownership(lid)==(1,1),rr)
    finally:
        for c in conns:c.close()

    for i in range(5):
        lid=fresh('cancellation-race-'+str(i)); claim=invoke(actors[0],lid)['result']['claim_id']
        rr=race([lambda:invoke(actors[0],claim,sql='public.cancel_claim(%s,%s)'),lambda:invoke(actors[1],lid)])
        check('concurrent cancellation/release and claim '+str(i),
          all(r['sqlstate'] is None and r['result'] and r['result'].get('outcome') in ('SUCCESS','CONFLICT') for r in rr) and ownership(lid)[0]<=1,rr)

    lid=fresh('recovery-race');claim=invoke(actors[0],lid)['result']['claim_id']
    with connect() as c:
        c.execute("UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '361 minutes',expires_at=clock_timestamp()-interval '1 minute' WHERE claim_id=%s",(claim,))
    rr=race([lambda:invoke(None,lid,sql='public.recover_expired_claims(500)',service=True),lambda:invoke(actors[1],lid)])
    with connect() as c: old=c.execute('SELECT claim_status FROM public.donation_claims WHERE claim_id=%s',(claim,)).fetchone()[0]
    check('concurrent recovery/release and claim preserves custody and uniqueness',all(r['sqlstate'] is None for r in rr) and old=='RELEASED' and ownership(lid)[0]<=1,rr)

    lid=fresh('active-lease');claim=invoke(actors[0],lid)['result']['claim_id']
    invoke(None,lid,sql='public.recover_expired_claims(500)',service=True)
    active=invoke(actors[1],lid)
    check('active lease retained under recovery and replacement rejected',active['result']['reason_code']=='CLAIM_CONFLICT' and ownership(lid)==(1,1))
    lid=fresh('expired-lease');claim=invoke(actors[0],lid)['result']['claim_id']
    with connect() as c:c.execute("UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '361 minutes',expires_at=clock_timestamp()-interval '1 minute' WHERE claim_id=%s",(claim,))
    recovered=invoke(None,lid,sql='public.recover_expired_claims(500)',service=True)
    replacement=invoke(actors[1],lid)
    check('expired lease recovered and replaceable',recovered['sqlstate'] is None and replacement['result']['outcome']=='SUCCESS' and ownership(lid)==(1,1))

    # Fault injection is only an extra test trigger on this disposable database.
    lid=fresh('rollback-receipt');request=str(uuid.uuid4())
    with connect() as c:
        c.execute("CREATE FUNCTION e2_benchmark.inject_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'LOCAL_FAULT_INJECTION'; END $$")
        c.execute(f"CREATE TRIGGER e2_fault BEFORE INSERT ON public.pickup_tasks FOR EACH ROW WHEN (NEW.listing_id='{lid}'::uuid) EXECUTE FUNCTION e2_benchmark.inject_failure()")
    failed=invoke(actors[0],lid,request)
    with connect() as c:
        c.execute('DROP TRIGGER e2_fault ON public.pickup_tasks; DROP FUNCTION e2_benchmark.inject_failure()')
        receipt=c.execute("SELECT details->>'sqlstate',details->>'rollback_confirmed' FROM public.operation_failure_events WHERE request_id=%s",(request,)).fetchone()
        state=c.execute('SELECT listing_status FROM public.listings WHERE listing_id=%s',(lid,)).fetchone()[0]
    check('fault rolls back claim/lease/task and persists trusted audit receipt',failed['result']['outcome']=='ERROR' and failed['result']['rollback_confirmed'] is True and receipt==('P0001','true') and ownership(lid)==(0,0) and state=='AVAILABLE',failed)
    retried=invoke(actors[0],lid,request)
    check('manual same UUID retry after confirmed rollback succeeds',retried['result']['outcome']=='SUCCESS' and ownership(lid)==(1,1))
    try:
        with connect() as c:
            c.execute('SET LOCAL ROLE authenticated')
            c.execute("UPDATE public.operation_failure_events SET reason_code='LOCAL_MUTATION_TEST' WHERE request_id=%s",(request,))
        immutable=False
    except psycopg.Error:immutable=True
    check('authenticated NGO cannot mutate failure receipts',immutable)

    lid=fresh('authorization')
    unauth=invoke(None,lid)
    check('unauthenticated claim denied',unauth['sqlstate']=='P0001' and ownership(lid)==(0,0),unauth)
    with connect() as c:c.execute('UPDATE public.ngo_profiles SET active_flag=false WHERE user_id=%s',(actors[0],))
    inactive=invoke(actors[0],lid)
    with connect() as c:c.execute('UPDATE public.ngo_profiles SET active_flag=true WHERE user_id=%s',(actors[0],))
    check('inactive NGO denied',inactive['sqlstate']=='P0001' and ownership(lid)==(0,0),inactive)
    with connect() as c:c.execute('UPDATE public.ngo_profiles SET location_verified_at=NULL WHERE user_id=%s',(actors[0],))
    unverified=invoke(actors[0],lid)
    with connect() as c:c.execute('UPDATE public.ngo_profiles SET location_verified_at=clock_timestamp() WHERE user_id=%s',(actors[0],))
    check('unverified location fails eligibility',unverified['result']['reason_code']=='ELIGIBILITY_UNDETERMINED' and ownership(lid)==(0,0),unverified)
    far=next(n for n in bench.ngos if bench.road_km(n,listing) is None or bench.road_km(n,listing)>20)
    outside=invoke(str(db.ngo(bench,far)),lid)
    check('actual frozen road adapter rejects outside/unroutable NGO',outside['result']['outcome']=='INELIGIBLE' and outside['result']['reason_code'] in ('OUTSIDE_GEOFENCE','ROUTE_UNAVAILABLE') and ownership(lid)==(0,0),outside)

    # Patch drift checks run in the original, uncorrected template DB only.
    patch=Path(__file__).resolve().parents[2]/'docs/investigations/e2-shared-lock-review/proposed_migration.sql'
    with psycopg.connect(host='127.0.0.1',port=port,dbname='postgres',user='postgres') as c:
        definition=c.execute("SELECT pg_get_functiondef('public.claim_listing(uuid,uuid)'::regprocedure)").fetchone()[0]
        drifted=definition.replace('AS $function$','AS $function$\n-- LOCAL SOURCE DRIFT TEST')
        c.execute(drifted)
        try:c.execute(patch.read_text())
        except psycopg.Error as e:
            drift_error=str(e).splitlines()[0];c.rollback()
        else:raise AssertionError('Drift guard accepted altered source')
        actual=c.execute("SELECT md5(replace(prosrc,chr(13),'')) FROM pg_proc WHERE oid='public.claim_listing(uuid,uuid)'::regprocedure").fetchone()[0]
    check('source drift raises and rolls back the transaction',drift_error.startswith('CALLER_SOURCE_OR_METADATA_DRIFT:') and actual=='2c1f60c876797c61b44b3cb43591bab8',drift_error)
    with connect() as c:
        try:c.execute(patch.read_text())
        except psycopg.Error as e:reapply=str(e).splitlines()[0];c.rollback()
        else:raise AssertionError('Patch unexpectedly accepted repeat application')
    check('already-corrected source fails safely on patch reapplication',reapply.startswith('CALLER_SOURCE_OR_METADATA_DRIFT:'))
    for label,drift_sql in [
      ('security-definer metadata', 'ALTER FUNCTION public.claim_listing(uuid,uuid) SECURITY INVOKER'),
      ('helper execute privileges', 'GRANT EXECUTE ON FUNCTION public.geolock_lock_listing_donations(uuid,text[]) TO authenticated')]:
        with psycopg.connect(host='127.0.0.1',port=port,dbname='postgres',user='postgres') as c:
            c.execute(drift_sql)
            try:c.execute(patch.read_text())
            except psycopg.Error as e:metadata_error=str(e).splitlines()[0];c.rollback()
            else:raise AssertionError('Metadata drift was accepted')
        check(label+' drift fails safely',metadata_error.startswith('CALLER_SOURCE_OR_METADATA_DRIFT:'),metadata_error)
    rollback=patch.with_name('rollback_patch.sql')
    with connect() as c:
        before=c.execute("SELECT oid::regprocedure::text,md5(replace(prosrc,chr(13),'')),proacl::text,proconfig FROM pg_proc WHERE oid IN ('public.claim_listing(uuid,uuid)'::regprocedure,'public.geolock_lock_listing_donations(uuid,text[])'::regprocedure) ORDER BY 1").fetchall()
        c.execute(rollback.read_text())
        c.execute(patch.read_text())
        after=c.execute("SELECT oid::regprocedure::text,md5(replace(prosrc,chr(13),'')),proacl::text,proconfig FROM pg_proc WHERE oid IN ('public.claim_listing(uuid,uuid)'::regprocedure,'public.geolock_lock_listing_donations(uuid,text[])'::regprocedure) ORDER BY 1").fetchall()
    check('guarded rollback and reapply preserve exact source and privileges',before==after)
    write(output/'regressions.json',dict(passed=all(r['passed'] for r in checks),checks=checks,operations=operations,
        scope='Additional diagnostic cases, not counted in 275 frozen scenarios',
        expected_errors='P0001 authorization, key-reuse, deliberate fault and drift tests are negative controls; not contention errors'))
