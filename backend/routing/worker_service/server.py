"""Small authenticated DEV API. Default startup is disabled and performs no DB I/O."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import hashlib
import json
import os
import secrets
import ssl
import threading
from datetime import datetime,timezone

from ..contract import ContractError
from .errors import WorkerError, check
from .graph_cache import GraphCache
from .journal import Journal
from .orchestrator import RoutingWorker
from .staged import ExactRouteWorkflow
from .transport import DEV, RoleRpc, SupabaseAuth, encode, uuid
from .validator import Validator, RemoteValidator


def request_event(value):
    # Fixed stage/error labels and UUIDs only. Never log headers, payloads or DSNs.
    safe={k:value[k] for k in ('stage','http_status','error_code','exception_type','role','rpc_phase') if k in value}
    code=value.get('sqlstate')
    if isinstance(code,str) and len(code)==5 and code.isalnum():safe['sqlstate']=code
    for key in ('request_id','snapshot_id'):
        try:safe[key]=uuid(value[key])
        except (KeyError,WorkerError):pass
    try:print(encode(dict(event='routing_request',at=datetime.now(timezone.utc).isoformat(),**safe)),flush=True)
    except OSError:pass # Diagnostic output must not change transaction outcomes.


def body_json(raw):
    def pairs(items):
        result={}
        for k,v in items:
            check(k not in result,'DUPLICATE_REQUEST_FIELD',400); result[k]=v
        return result
    try:
        return json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except WorkerError: raise
    except Exception: raise WorkerError('INVALID_JSON',400) from None


class Application:
    def __init__(self, *, auth=None, worker=None, validator=None, validator_token=None, active=False, combined_enabled=False, exact_enabled=False):
        self.auth,self.worker,self.validator=auth,worker,validator
        self._validator_token=validator_token
        self.active=active
        self.combined_enabled=combined_enabled
        self.exact_enabled=exact_enabled
        self._slots=threading.BoundedSemaphore(1)

    def dispatch(self,path,bearer,body):
        check(self.active,'WORKER_NOT_ACTIVATED',503)
        check(isinstance(body,dict),'INVALID_REQUEST',400)
        if self.validator is not None:
            check(path=='/v1/validate','NOT_FOUND',404)
            check(type(bearer) is str and type(self._validator_token) is str
                  and secrets.compare_digest(bearer,'Bearer '+self._validator_token),'VALIDATOR_AUTHENTICATION_REQUIRED',401)
            check(set(body)=={'candidate_id','snapshot_id','ngo_id'},'INVALID_REQUEST_FIELDS',400)
            return self.validator.validate(body['candidate_id'],body['snapshot_id'],body['ngo_id'])
        check(path in ('/v1/plan','/v1/authorize','/v1/planning-result','/v1/plan-and-authorize',
                      '/v1/authorization-result','/v1/authorization-capabilities',
                      '/v1/exact-route-plan','/v1/exact-route-authorize'),'NOT_FOUND',404)
        # Supabase validates the actual token; unverified JWT claims are unused.
        request_event(dict(stage='verify_ngo_jwt',**{k:body[k] for k in ('request_id','snapshot_id') if k in body}))
        session=self.auth.verify(bearer)
        request_event(dict(stage='ngo_authenticated',**{k:body[k] for k in ('request_id','snapshot_id') if k in body}))
        if path in ('/v1/exact-route-plan','/v1/exact-route-authorize'):
            check(self.exact_enabled,'EXACT_WORKFLOW_DISABLED',503)
            check(set(body)=={'request_id','scope'},'INVALID_REQUEST_FIELDS',400)
            uuid(body['request_id'])
            if not self._slots.acquire(blocking=False): raise WorkerError('WORKER_BUSY_RETRY_SAME_REQUEST',429,True)
            try:
                exact=ExactRouteWorkflow(self.worker)
                action=exact.plan if path=='/v1/exact-route-plan' else exact.authorize
                return action(session,body['request_id'],body['scope'])
            finally: self._slots.release()
        if path=='/v1/authorization-capabilities':
            check(set(body)=={'request_id'},'INVALID_REQUEST_FIELDS',400)
            return dict(self.worker.automatic_authorization_capabilities(session,body['request_id']),
                        combined_generation_enabled=self.combined_enabled,
                        exact_staged_enabled=self.exact_enabled)
        if path=='/v1/authorize':
            check(set(body)=={'request_id','candidate_id','departure_at'},'INVALID_REQUEST_FIELDS',400)
            return self.worker.authorize(session,body['request_id'],body['candidate_id'],body['departure_at'])
        expected={'request_id','snapshot_id','authorize_on_success'} if path=='/v1/plan-and-authorize' else {'request_id','snapshot_id'}
        check(set(body)==expected,'INVALID_REQUEST_FIELDS',400)
        if path=='/v1/plan-and-authorize':
            check(body['authorize_on_success'] is True,'EXPLICIT_AUTHORIZATION_INTENT_REQUIRED',400)
            check(self.combined_enabled,'COMBINED_WORKFLOW_DISABLED',503)
        uuid(body['request_id']);uuid(body['snapshot_id'])
        if path=='/v1/planning-result':
            return self.worker.saved_result(session,body['snapshot_id'],body['request_id'])
        if path=='/v1/authorization-result':
            return self.worker.authorization_result(session,body['snapshot_id'],body['request_id'])
        if not self._slots.acquire(blocking=False): raise WorkerError('WORKER_BUSY_RETRY_SAME_REQUEST',429,True)
        try:
            action=self.worker.plan_and_authorize if path=='/v1/plan-and-authorize' else self.worker.plan
            return action(session,body['snapshot_id'],body['request_id'])
        finally: self._slots.release()


def application_from_env(mode, env=os.environ, *, rpc_factory=RoleRpc):
    # Import/startup alone cannot write to DEV. An operator must explicitly
    # activate after deployment approval and provision scoped credentials.
    if env.get('GEOLOCK_ROUTING_ALLOW_DEV_WRITES')!='APPROVED':
        return Application(active=False)
    check(bool(env.get('GEOLOCK_ROUTING_ACTIVATION_REF','').strip()),'ACTIVATION_RECEIPT_REQUIRED',503)
    check(env.get('GEOLOCK_PROJECT_REF')==DEV,'DEV_PROJECT_REQUIRED',503)
    try:
        def runtime_rpc(dsn,role):
            rpc=rpc_factory(dsn,role)
            rpc.failure_observer=lambda error,phase:request_event(dict(stage='rpc_failed',role=role,
                rpc_phase=phase,exception_type=type(error).__name__,sqlstate=getattr(error,'sqlstate',None)))
            return rpc
        age=int(env.get('GEOLOCK_MAX_SNAPSHOT_AGE_SECONDS','300'))
        check(1<=age<=1800,'INVALID_FRESHNESS_LIMIT',503)
        token=env['GEOLOCK_VALIDATOR_TOKEN'];check(len(token)>=32,'VALIDATOR_SECRET_REQUIRED',503)
        if mode=='validator':
            dsn=env['GEOLOCK_VALIDATOR_DSN'];RoleRpc.validate_dsn(dsn)
            return Application(validator=Validator(runtime_rpc(dsn,'geolock_validator'),max_age_seconds=age),validator_token=token,active=True)
        gd,pd=env['GEOLOCK_GRAPH_DSN'],env['GEOLOCK_PLANNER_DSN']
        RoleRpc.validate_dsn(gd);RoleRpc.validate_dsn(pd)
        check(gd!=pd,'SEPARATE_DATABASE_LOGINS_REQUIRED',503)
        root=Path(env.get('GEOLOCK_WORKER_STATE',str(Path(__file__).parent/'.state')))
        graph=GraphCache(runtime_rpc(gd,'geolock_graph_worker'),env['GEOLOCK_GRAPH_ID'],root/'graphs')
        worker=RoutingWorker(runtime_rpc(pd,'geolock_planner'),graph,
            RemoteValidator(env['GEOLOCK_VALIDATOR_URL'],token),Journal(root/'journal'),max_age_seconds=age,observe=request_event)
        return Application(auth=SupabaseAuth(env['GEOLOCK_SUPABASE_PUBLISHABLE_KEY']),worker=worker,active=True,
                           combined_enabled=env.get('GEOLOCK_COMBINED_ROUTE_ENABLED')=='APPROVED',
                           exact_enabled=env.get('GEOLOCK_EXACT_ROUTE_ENABLED')=='APPROVED')
    except WorkerError: raise
    except Exception: raise WorkerError('MISSING_OR_INVALID_WORKER_CONFIGURATION',503) from None


def make_handler(app, *, origins=()):
    class Handler(BaseHTTPRequestHandler):
        server_version='GeoLockRouting/1'
        def log_message(self,*args): pass  # never log JWTs, query strings or payloads
        def _send(self,status,value):
            raw=encode(value).encode()
            self.send_response(status)
            self.send_header('Content-Type','application/json')
            self.send_header('Cache-Control','no-store')
            self.send_header('Content-Length',str(len(raw)))
            self.send_header('Connection','close')
            origin=self.headers.get('Origin')
            if origin in origins: self.send_header('Access-Control-Allow-Origin',origin);self.send_header('Vary','Origin')
            self.end_headers();self.wfile.write(raw)
        def do_GET(self):
            self._send(200 if self.path=='/health' else 404,
              {'status':'ACTIVE' if app.active else 'DISABLED','project_ref':DEV} if self.path=='/health' else {'error':{'code':'NOT_FOUND'}})
        def do_OPTIONS(self):
            if self.headers.get('Origin') not in origins:
                self._send(403,{'error':{'code':'ORIGIN_NOT_ALLOWED'}});return
            self.send_response(204)
            self.send_header('Access-Control-Allow-Origin',self.headers['Origin'])
            self.send_header('Access-Control-Allow-Methods','POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers','Authorization, Content-Type')
            self.end_headers()
        def do_POST(self):
            correlation={}
            try:
                self.connection.settimeout(150)
                origin=self.headers.get('Origin')
                check(origin is None or origin in origins,'ORIGIN_NOT_ALLOWED',403)
                check(self.headers.get_content_type()=='application/json','JSON_CONTENT_TYPE_REQUIRED',415)
                check(self.headers.get('Transfer-Encoding') is None,'CHUNKED_REQUEST_NOT_SUPPORTED',400)
                n=int(self.headers.get('Content-Length','0'));check(0<n<=4096,'REQUEST_TOO_LARGE',413)
                check(len(self.headers.get_all('Authorization',[]))==1,'AUTHENTICATION_REQUIRED',401)
                body=body_json(self.rfile.read(n))
                if isinstance(body,dict):correlation={k:body[k] for k in ('request_id','snapshot_id') if k in body}
                request_event(dict(correlation,stage='http_received'))
                value=app.dispatch(self.path,self.headers.get('Authorization'),body)
                request_event(dict(correlation,stage='http_response',http_status=200))
                self._send(200,value)
            except WorkerError as e:
                request_event(dict(correlation,stage='http_rejected',http_status=e.status,error_code=e.code))
                self._send(e.status,{'error':{'code':e.code,'retryable':e.retryable},'dispatch_authority_issued':False})
            except ContractError:
                request_event(dict(correlation,stage='http_rejected',http_status=422,error_code='ROUTING_INPUT_OR_OUTPUT_INVALID'))
                self._send(422,{'error':{'code':'ROUTING_INPUT_OR_OUTPUT_INVALID'},'dispatch_authority_issued':False})
            except Exception as error:
                request_event(dict(correlation,stage='http_failed',http_status=500,exception_type=type(error).__name__))
                self._send(500,{'error':{'code':'WORKER_REQUEST_FAILED'},'dispatch_authority_issued':False})
    return Handler


def main(*,rpc_factory=RoleRpc):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode',choices=('planner','validator'),default='planner')
    parser.add_argument('--host',default='127.0.0.1')
    parser.add_argument('--port',type=int)
    parser.add_argument('--check-config',action='store_true',help='No network calls or server startup')
    parser.add_argument('--warm-graph',action='store_true',help='Cache the existing frozen graph through read-only RPCs; no server startup')
    args=parser.parse_args()
    try:
        app=application_from_env(args.mode,rpc_factory=rpc_factory)
        if args.check_config:
            print(encode({'mode':args.mode,'project_ref':DEV,'status':'CONFIGURED_NOT_CONNECTED' if app.active else 'DISABLED'}));return
        if args.warm_graph:
            check(app.active and app.worker is not None,'ACTIVATED_PLANNER_REQUIRED',503)
            manifest,nodes,edges=app.worker.graph.load()
            print(encode({'graph_export_cached':True,'node_count':len(nodes),'edge_count':len(edges)}));return
        cert,key=os.environ.get('GEOLOCK_TLS_CERT'),os.environ.get('GEOLOCK_TLS_KEY')
        check(args.host in ('127.0.0.1','localhost','::1') or bool(cert and key),'TLS_REQUIRED_FOR_EXTERNAL_BIND',503)
        origins=tuple(filter(None,os.environ.get('GEOLOCK_CORS_ORIGINS','').split(',')))
        check('*' not in origins,'EXPLICIT_CORS_ORIGINS_REQUIRED',503)
        server=ThreadingHTTPServer((args.host,args.port or (8788 if args.mode=='validator' else 8787)),make_handler(app,origins=origins))
        server.daemon_threads=True
        if cert and key:
            context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.minimum_version=ssl.TLSVersion.TLSv1_2
            context.load_cert_chain(cert,key);server.socket=context.wrap_socket(server.socket,server_side=True)
        print(encode({'mode':args.mode,'status':'ACTIVE' if app.active else 'DISABLED','project_ref':DEV}),flush=True)
        try: server.serve_forever()
        finally: server.server_close()
    except WorkerError as e:
        parser.exit(2,e.code+'\n')


if __name__=='__main__': main()
