"""One new loopback cluster; unchanged claim body, FK lock interleaving evidence.

Not a benchmark rerun. Never opens the original result database or a remote DSN.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from experiments.e2_claiming import e2_runner as old
from experiments.repro_benchmark import clear_remote_env, write
import psycopg
from psycopg.rows import dict_row

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / '.tmp/geolock-spatial-runtime-safe-cancel/pgsql/bin'
OUT = ROOT / 'docs/investigations/e2-shared-lock-review/original-reproduction'
RUNTIME = ROOT / '.tmp/e2-shared-lock-original-20261105-01'

def main():
    clear_remote_env()
    RUNTIME.mkdir(exist_ok=False)
    OUT.mkdir(parents=True,exist_ok=False)
    schema = RUNTIME / 'schema-evidence'; schema.mkdir()
    cls = None
    connections = []
    def connect(**kw):
        return psycopg.connect(host='127.0.0.1', port=cls.port,
                              dbname='postgres', user='postgres', connect_timeout=5, **kw)
    try:
        cls, observed = old.bootstrap_from_current_isolated_fixture(RUNTIME, schema, BIN)
        with connect() as c:
            c.execute('CREATE ROLE e2_worker LOGIN; GRANT authenticated TO e2_worker;')
            reader = (ROOT/'supabase/migrations/20261028_claim_card_expiry_and_paused_recovery.sql').read_text()
            c.execute(reader[reader.index('create function public.get_my_claim_cards_v2()'):reader.index('-- Reject unexpected default-privilege recipients')])
            c.execute((ROOT/'supabase/migrations/20261104130000_unstarted_released_route_cancellation.sql').read_text())
        with connect(row_factory=dict_row) as c:
            definition = c.execute("SELECT md5(replace(prosrc,chr(13),'')) hash,pg_get_functiondef(oid) source FROM pg_proc WHERE oid='public.claim_listing(uuid,uuid)'::regprocedure").fetchone()
            assert definition['hash'] == old.CLAIM_HASH
            write(OUT/'claim-source.json', definition)
            functions=c.execute("""SELECT p.oid::regprocedure::text signature,n.nspname schema,p.proname name,
              md5(replace(p.prosrc,chr(13),'')) hash,p.prosrc source,pg_get_functiondef(p.oid) definition,
              p.proowner::regrole::text owner,p.prosecdef,p.proacl::text,p.proconfig
              FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
              WHERE n.nspname IN ('public','routing_private','resolution_private') AND p.prokind='f'
              ORDER BY 1""").fetchall()
            write(OUT/'function-catalog.json',functions)

            triggers = c.execute("""SELECT t.tgrelid::regclass::text relation,t.tgname,t.tgisinternal,
              pg_get_triggerdef(t.oid) definition, p.proname function_name
              FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
              WHERE t.tgrelid IN ('public.claim_requests'::regclass,'public.listings'::regclass,
                'public.donation_claims'::regclass,'public.claim_leases'::regclass,
                'public.donations'::regclass,'public.audit_events'::regclass)
              ORDER BY 1,2""").fetchall()
            write(OUT/'triggers.json',triggers)
            write(OUT/'foreign-keys.json',c.execute("""SELECT conrelid::regclass::text relation,
              conname,pg_get_constraintdef(oid) definition FROM pg_constraint
              WHERE contype='f' AND (confrelid='public.listings'::regclass
                OR conrelid IN ('public.claim_requests'::regclass,'public.claim_leases'::regclass))
              ORDER BY 1,2""").fetchall())
        meta={'port':cls.port}
        fixture = old.create_listing(meta,'postgres','deadlock-review','diagnostic','fk-lock-upgrade')
        lid=fixture['listing_id']
        with connect() as c:
            actors=[str(r[0]) for r in c.execute('SELECT user_id FROM public.ngo_profiles WHERE active_flag ORDER BY user_id LIMIT 2')]
        assert len(actors)==2
        requests=[str(uuid.uuid4()),str(uuid.uuid4())]
        # Pause at the exact statement boundary reached inside claim_listing:
        # each transaction has inserted its own request and holds its listing FK lock.
        for actor,request in zip(actors,requests):
            c=connect(); connections.append(c)
            c.execute("SET LOCAL deadlock_timeout='2s'; SET LOCAL statement_timeout='15s'")
            c.execute("SELECT set_config('request.jwt.claim.sub',%s,true)",(actor,))
            c.execute("""INSERT INTO public.claim_requests(request_id,listing_id,ngo_user_id,request_digest)
              VALUES(%s,%s,%s,md5(%s))""",(request,lid,actor,lid+':'+actor))
        results=[None,None]; barrier=threading.Barrier(3)
        def invoke(i):
            try:
                barrier.wait()
                results[i]=connections[i].execute('SELECT public.claim_listing(%s,%s)',(lid,requests[i])).fetchone()[0]
                connections[i].commit()
            except Exception as e:
                results[i]={'exception':type(e).__name__,'sqlstate':getattr(e,'sqlstate',None)}
                connections[i].rollback()
        threads=[threading.Thread(target=invoke,args=(i,)) for i in (0,1)]
        for t in threads:t.start()
        barrier.wait()
        time.sleep(.25)
        with connect(row_factory=dict_row) as c:
            write(OUT/'wait-graph.json', c.execute("""SELECT pid,wait_event_type,wait_event,
              pg_blocking_pids(pid) blockers,query FROM pg_stat_activity
              WHERE datname=current_database() AND pid<>pg_backend_pid() ORDER BY pid""").fetchall())
            write(OUT/'waiting-locks.json',c.execute("""SELECT pid,locktype,mode,granted,
              relation::regclass::text relation,transactionid::text transaction_id,page,tuple
              FROM pg_locks WHERE pid<>pg_backend_pid() ORDER BY pid,locktype,mode""").fetchall())
        for t in threads:t.join(20)
        assert all(not t.is_alive() for t in threads)
        # The diagnostic pre-inserts are outside the RPC's inner savepoint.
        # Release them after observation; this is deliberately a forced schedule.
        with connect(row_factory=dict_row) as c:
            errors=c.execute("SELECT request_id::text,details FROM public.operation_failure_events WHERE listing_id=%s",(lid,)).fetchall()
            owners=c.execute("SELECT claim_status,count(*) n FROM public.donation_claims WHERE listing_id=%s GROUP BY 1",(lid,)).fetchall()
            unchanged=c.execute("SELECT md5(replace(prosrc,chr(13),'')) FROM pg_proc WHERE oid='public.claim_listing(uuid,uuid)'::regprocedure").fetchone()
        assert unchanged['md5']==old.CLAIM_HASH
        assert any(r.get('rollback_confirmed') is True for r in results)
        assert any(e['details'].get('sqlstate')=='40P01' for e in errors)
        # Primitive control: compatible NO KEY UPDATE upgrades with the same FK
        # inserts. This does not alter or substitute the actual SQL function.
        fixture2=old.create_listing(meta,'postgres','deadlock-review','diagnostic','compatible-lock-control')
        lid2=fixture2['listing_id']; control=[]
        for actor in actors:
            c=connect();control.append(c)
            c.execute("SET LOCAL lock_timeout='2s'")
            c.execute("INSERT INTO public.claim_requests(request_id,listing_id,ngo_user_id,request_digest) VALUES(%s,%s,%s,%s)",(str(uuid.uuid4()),lid2,actor,'primitive-control'))
        control[0].execute('SELECT 1 FROM public.listings WHERE listing_id=%s FOR NO KEY UPDATE',(lid2,))
        control[0].commit()
        control[1].execute('SELECT 1 FROM public.listings WHERE listing_id=%s FOR NO KEY UPDATE',(lid2,))
        control[1].commit()
        for c in control:c.close()
        write(OUT/'diagnostic.json',dict(actual_claim_hash=old.CLAIM_HASH,unchanged=True,
          actual_rpc_results=results,failure_audits=errors,committed_claims=owners,
          compatible_no_key_update_control='Both lock upgrades completed without deadlock',
          scope='Forced real-FK statement interleaving, not a replacement benchmark or proof of every historical lock graph',
          host='127.0.0.1',port=cls.port,remote_connections=0))
    finally:
        for c in connections:c.close()
        if cls is not None:
            stopped=subprocess.run([str(BIN/'pg_ctl.exe'),'-D',str(RUNTIME/'data'),'-m','fast','-w','stop'],capture_output=True)
            write(OUT/'cluster-stop.json',{'stopped':stopped.returncode==0,'remote_connections':0})

if __name__=='__main__':main()

