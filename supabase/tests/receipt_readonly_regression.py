"""Disposable loopback PostgreSQL 17 regression; never accepts a remote DSN."""
import hashlib,json,os,socket,subprocess,tempfile,unittest
from pathlib import Path
import psycopg

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'results/receipt-readonly-fix'
MIGRATION=ROOT/'docs/stage8/stage-a/forward-migrations/20261105_routing_receipt_readonly.sql'
OWNER='00000000-0000-0000-0000-000000000001'
OTHER='00000000-0000-0000-0000-000000000002'
DONOR='00000000-0000-0000-0000-000000000003'
INACTIVE='00000000-0000-0000-0000-000000000004'
REQ='10000000-0000-0000-0000-000000000001'

class ReceiptTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  OUT.mkdir(parents=True,exist_ok=True)
  cls.temp=tempfile.TemporaryDirectory(prefix='receipt-pg17-')
  cls.data=Path(cls.temp.name)/'data'
  cls.pg=Path('C:/Program Files/PostgreSQL/17/bin')
  cls.env={k:v for k,v in os.environ.items() if not k.upper().startswith(('PG','GEOLOCK','SUPABASE'))}
  cls.env['PGCLIENTENCODING']='UTF8'
  with socket.socket() as sock:
   sock.bind(('127.0.0.1',0));cls.port=sock.getsockname()[1]
  def run(name,*args):
   # Windows server children must not retain PIPE handles and block communicate.
   log=Path(cls.temp.name)/(name+'-operator.log')
   with log.open('w',encoding='utf-8') as stream:
    p=subprocess.run([str(cls.pg/(name+'.exe')),*map(str,args)],env=cls.env,stdout=stream,stderr=subprocess.STDOUT,timeout=40)
   if p.returncode:raise RuntimeError(name+' failed: '+log.read_text(encoding='utf-8',errors='replace')[-1500:])
  cls.runpg=staticmethod(run)
  run('initdb','-D',cls.data,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8')
  run('pg_ctl','-D',cls.data,'-l',Path(cls.temp.name)/'server.log','-o',f'-h 127.0.0.1 -p {cls.port}','-w','start')
  cls.addClassCleanup(cls.stop)
  catalog=json.loads((OUT/'deployed-catalog.json').read_text(encoding='utf-8'))
  cls.original=next(f['definition'] for f in catalog['functions'] if f['name']=='get_my_routing_authorization_receipt')
  guard=next(f['definition'] for f in catalog['functions'] if f['name']=='require_ngo')
  with cls.conn() as c:
   c.execute('CREATE ROLE authenticated; CREATE ROLE anon; CREATE ROLE service_role; CREATE SCHEMA auth; CREATE SCHEMA fleet_private; CREATE SCHEMA routing_private;')
   c.execute("CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$")
   c.execute('CREATE TABLE public.user_profiles(user_id uuid PRIMARY KEY,role text); CREATE TABLE public.ngo_profiles(user_id uuid PRIMARY KEY,role text,active_flag boolean); CREATE TABLE routing_private.requests(ngo_id uuid,request_id uuid,operation text,payload_digest text,result jsonb);')
   for uid,role,active in [(OWNER,'NGO',True),(OTHER,'NGO',True),(DONOR,'DONOR',True),(INACTIVE,'NGO',False)]:
    c.execute('INSERT INTO public.user_profiles VALUES(%s,%s)',(uid,role))
    c.execute('INSERT INTO public.ngo_profiles VALUES(%s,%s,%s)',(uid,role,active))
   c.execute(guard);c.execute(cls.original)
   c.execute('REVOKE ALL ON FUNCTION public.get_my_routing_authorization_receipt(uuid) FROM PUBLIC,anon,service_role; GRANT EXECUTE ON FUNCTION public.get_my_routing_authorization_receipt(uuid) TO authenticated;')
   c.execute("INSERT INTO routing_private.requests VALUES(%s,%s,'AUTHORIZE','synthetic',%s::jsonb)",(OWNER,REQ,json.dumps({'route_ids':['synthetic-route']})))
   c.execute("SELECT set_config('request.jwt.claim.sub',%s,false)",(OWNER,))
  # Confirm the original exact deployed body fails in PostgREST's access mode.
  with cls.conn() as c:
   c.execute('BEGIN READ ONLY');c.execute('SET LOCAL ROLE authenticated')
   c.execute("SELECT set_config('request.jwt.claim.sub',%s,true)",(OWNER,))
   try:c.execute('SELECT public.get_my_routing_authorization_receipt(%s)',(REQ,))
   except psycopg.errors.ReadOnlySqlTransaction:cls.reproduced=True;c.rollback()
   else:raise AssertionError('Original receipt unexpectedly accepted READ ONLY')
  with cls.conn() as c:c.execute(MIGRATION.read_text(encoding='utf-8'),prepare=False)
  with cls.conn() as c:
   cls.fingerprint=c.execute("SELECT md5(replace(prosrc,E'\\r\\n',E'\\n')) FROM pg_proc WHERE oid='public.get_my_routing_authorization_receipt(uuid)'::regprocedure").fetchone()[0]
 @classmethod
 def conn(cls):
  return psycopg.connect(host='127.0.0.1',hostaddr='127.0.0.1',port=cls.port,dbname='postgres',user='postgres',password='',sslmode='disable',options='',connect_timeout=3)
 @classmethod
 def stop(cls):
  cls.runpg('pg_ctl','-D',cls.data,'-m','fast','-w','stop');cls.temp.cleanup()
 def read(self,user=OWNER,request=REQ,role='authenticated'):
  with self.conn() as c:
   c.execute('BEGIN READ ONLY');c.execute('SET LOCAL ROLE '+role)
   c.execute("SELECT set_config('request.jwt.claim.sub',%s,true)",(user or '',))
   self.assertEqual(c.execute('SHOW transaction_read_only').fetchone()[0],'on')
   value=c.execute('SELECT public.get_my_routing_authorization_receipt(%s)',(request,)).fetchone()[0]
   c.rollback();return value
 def test_original_failure_reproduced(self):self.assertTrue(self.reproduced)
 def test_owner_found(self):self.assertEqual(self.read()['result'],{'route_ids':['synthetic-route']})
 def test_cross_owner(self):self.assertEqual(self.read(OTHER)['outcome'],'NOT_FOUND')
 def test_missing(self):self.assertEqual(self.read(request='10000000-0000-0000-0000-000000000002')['outcome'],'NOT_FOUND')
 def test_repeated_reads(self):self.assertEqual(self.read(),self.read())
 def test_null_user(self):
  with self.assertRaisesRegex(psycopg.Error,'UNAUTHENTICATED'):self.read(None)
 def test_donor(self):
  with self.assertRaisesRegex(psycopg.Error,'ACTIVE_NGO_PROFILE_REQUIRED'):self.read(DONOR)
 def test_inactive(self):
  with self.assertRaisesRegex(psycopg.Error,'ACTIVE_NGO_PROFILE_REQUIRED'):self.read(INACTIVE)
 def test_null_request(self):
  with self.assertRaisesRegex(psycopg.Error,'REQUEST_REQUIRED'):self.read(request=None)
 def test_grants(self):
  for role in ('anon','service_role'):
   with self.assertRaises(psycopg.errors.InsufficientPrivilege):self.read(role=role)
 def test_no_writes(self):
  self.read()
  with self.conn() as c:self.assertEqual(c.execute('SELECT count(*) FROM routing_private.requests').fetchone()[0],1)
 def test_stable(self):
  with self.conn() as c:self.assertEqual(c.execute("SELECT provolatile FROM pg_proc WHERE oid='public.get_my_routing_authorization_receipt(uuid)'::regprocedure").fetchone()[0],'s')
 def test_writer_guard_unchanged(self):
  with self.conn() as c:self.assertEqual(c.execute("SELECT md5(replace(prosrc,E'\\r\\n',E'\\n')) FROM pg_proc WHERE oid='fleet_private.require_ngo()'::regprocedure").fetchone()[0],'15d5c2547cabd5df199e104451f5c2d6')
 def test_exact_security_metadata(self):
  with self.conn() as c:
   row=c.execute("SELECT pg_get_userbyid(proowner),prosecdef,proconfig,proacl::text FROM pg_proc WHERE oid='public.get_my_routing_authorization_receipt(uuid)'::regprocedure").fetchone()
   self.assertEqual(row,('postgres',True,['search_path=pg_catalog, pg_temp','TimeZone=UTC'],'{postgres=X/postgres,authenticated=X/postgres}'))
 def test_reapply_is_rejected_without_changes(self):
  with self.assertRaisesRegex(psycopg.Error,'RECEIPT_SOURCE_OR_SECURITY_DRIFT'):
   with self.conn() as c:c.execute(MIGRATION.read_text(encoding='utf-8'),prepare=False)
  self.assertEqual(self.read()['outcome'],'FOUND')

if __name__=='__main__':
 result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ReceiptTests))
 (OUT/'test-result.json').write_text(json.dumps({'tests':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'fingerprint':getattr(ReceiptTests,'fingerprint',None),'original_failure_reproduced':getattr(ReceiptTests,'reproduced',False),'database':'disposable loopback PostgreSQL17','dev_writes':False},indent=2),encoding='utf-8')
 raise SystemExit(not result.wasSuccessful())
