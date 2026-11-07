"""DEV-only real-HTTP fleet tests. Importing this module performs no I/O.

Batch B requires an external approval receipt AND synthetic-identity markers.
No tokens are written to evidence. No automatic retry, migration or repair.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import threading
from urllib.error import HTTPError
from urllib.request import Request, HTTPRedirectHandler, build_opener
from uuid import UUID, uuid4

PROJECT = 'rcgyuwiidqvrgbxswhqj'
BASE = f'https://{PROJECT}.supabase.co'
HERE = Path(__file__).resolve().parent
RPCS = {'register_my_vehicle', 'list_my_vehicles', 'update_my_vehicle',
        'set_my_vehicle_availability', 'deactivate_my_vehicle'}
PROFILE_KEYS = {'p_label':'vehicle_label', 'p_vehicle_type':'vehicle_type',
                'p_capacity_kg':'payload_capacity_kg', 'p_fixed_cost_rm':'fixed_cost_rm',
                'p_distance_cost_rm_per_km':'distance_cost_rm_per_km',
                'p_max_route_duration_min':'max_route_duration_min'}


def demand(condition, message):
    if not condition:
        raise AssertionError(message)


def approval(path):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    demand(data.get('project_ref') == PROJECT, 'Wrong approval project')
    demand(data.get('batch_b_authorized') is True, 'Batch B has not been approved')
    UUID(data['run_id'])
    expiry = datetime.fromisoformat(data['expires_at'])
    remaining = (expiry - datetime.now(timezone.utc)).total_seconds()
    demand(0 < remaining <= 86400, 'Approval must expire within 24 hours')
    demand(data.get('max_vehicles') == 5 and data.get('max_routes') == 12,
           'Unexpected fixture budget')
    demand(data.get('recovery_ready') is True, 'Recovery readiness not recorded')
    return data


def execution_gates(data):
    """Require recorded operator evidence; this cannot prove rotation/restore itself."""
    demand(data.get('project_ref')==PROJECT and data.get('batch_b_authorized') is True,'Batch B not approved for DEV')
    demand(data.get('max_vehicles')==5 and data.get('max_routes')==12,'Fixture budget mismatch')
    demand(data.get('recovery_ready') is True,'Recovery not ready')
    expiry=datetime.fromisoformat(data['expires_at'])
    demand(0<(expiry-datetime.now(timezone.utc)).total_seconds()<=86400,'Approval expired/unbounded')
    rotated=data.get('password_rotation_confirmed_at')
    recovery=data.get('post_c1_recovery',{})
    demand(bool(rotated),'DEV password rotation is unconfirmed')
    demand(type(recovery) is dict and recovery.get('usable_confirmed') is True and recovery.get('includes_c1_v2') is True and
           type(recovery.get('location')) is str and bool(recovery['location'].strip()),'Post-C1 recovery evidence missing')
    for stamp in (rotated,recovery.get('created_at')):
        demand(type(stamp) is str,'Timestamp evidence missing')
        value=datetime.fromisoformat(stamp.replace('Z','+00:00'))
        demand(value.tzinfo is not None and value<=datetime.now(timezone.utc),'Evidence timestamp invalid/future')


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError('Redirect refused; credentials remain on pinned DEV host')


class Client:
    """Fixed origin, fixed operation allowlist, thread-safe request budget."""
    def __init__(self, receipt, public_key, service_key, tokens=None, ledger=None, provisioning=False):
        demand(receipt.get('batch_b_authorized') is True, 'Mutation gate closed')
        demand(receipt.get('project_ref') == PROJECT, 'Wrong project')
        self.receipt, self.public_key, self.service_key = receipt, public_key, service_key
        self.tokens = tokens or {}
        self.ledger, self.provisioning = ledger, provisioning
        self.count = 0
        self.lock = threading.Lock()

    def request(self, actor, method, path, payload=None, private=False):
        rpc_name=path.removeprefix('/rest/v1/rpc/')
        allowed_rpc=rpc_name in RPCS | {'require_ngo'} | ({'register_role_profile','set_ngo_operating_location'} if self.provisioning else set())
        allowed = (path.startswith('/rest/v1/rpc/') and allowed_rpc) or path.startswith('/rest/v1/vehicles?') \
            or path.startswith('/rest/v1/audit_events?') or path.startswith('/rest/v1/pickup_routes?') \
            or path.startswith('/rest/v1/pickup_route_stops?') or path.startswith('/rest/v1/active_task_route_assignments?') \
            or path == '/auth/v1/user'
        if self.provisioning:
            allowed = allowed or path in {'/auth/v1/admin/users','/auth/v1/token?grant_type=password'}
            allowed = allowed or path.startswith('/rest/v1/ngo_profiles?user_id=eq.')
            allowed = allowed or (method=='GET' and path.startswith('/rest/v1/user_profiles?user_id=eq.'))
            if path.startswith('/auth/v1/admin/users/'):
                UUID(path.rsplit('/',1)[-1]); allowed=True
            allowed = allowed or path=='/auth/v1/logout?scope=global'
        demand(allowed and '..' not in path and '://' not in path and not path.startswith('//'),
               'Operation outside test allowlist')
        with self.lock:
            self.count += 1
            demand(self.count <= 1200, 'Request budget exhausted; stop and reconcile')
        headers = {'apikey':self.public_key, 'Content-Type':'application/json'}
        if actor == 'service':
            headers.update(apikey=self.service_key, Authorization='Bearer '+self.service_key)
        elif actor == 'invalid':
            headers['Authorization'] = 'Bearer invalid.c1.test'
        elif actor != 'anon':
            headers['Authorization'] = 'Bearer '+self.tokens[actor]
        if private:
            headers['Content-Profile'] = 'fleet_private'
        if method in {'PATCH', 'POST', 'DELETE'}:
            headers['Prefer'] = 'return=representation'
        body = None if payload is None else json.dumps(payload, allow_nan=False).encode()
        request = Request(BASE+path, data=body, method=method, headers=headers)
        try:
            with build_opener(NoRedirect()).open(request, timeout=30) as response:
                raw = response.read()
                result=response.status, json.loads(raw) if raw else None
        except HTTPError as error:
            raw = error.read()
            try:
                value = json.loads(raw)
            except ValueError:
                value = {'code':'NON_JSON_ERROR'}
            result=error.code,value
        except Exception:
            # Do not echo headers, credentials, request objects or raw exception bodies.
            raise RuntimeError('HTTP request unresolved; inspect server outcome before retry') from None
        if self.ledger:
            value=result[1]
            entry=dict(actor=actor,method=method,status=result[0],operation=path.split('?')[0])
            if isinstance(value,dict) and value.get('vehicle_id'):
                entry.update(vehicle_id=value['vehicle_id'],owner=value.get('ngo_user_id'))
            if path=='/auth/v1/admin/users' and isinstance(value,dict) and value.get('id'):
                entry['auth_user_id']=value['id']
            if isinstance(value,dict) and isinstance(value.get('code'),str):
                entry['error_code']=value['code']
                if isinstance(value.get('message'),str) and re.fullmatch('[A-Z_]+',value['message']):
                    entry['guard_error']=value['message']
            if isinstance(payload,dict) and payload.get('p_request_id'):
                entry['request_id']=payload['p_request_id']
            with self.lock:
                with Path(self.ledger).open('a',encoding='utf-8') as output:
                    output.write(json.dumps(entry)+'\n')
        return result

    def rpc(self, actor, name, payload=None):
        demand(name in RPCS, 'RPC outside fleet allowlist')
        return self.request(actor, 'POST', '/rest/v1/rpc/'+name, payload or {})


def expect(response, error=None):
    status, value = response
    if error:
        demand(400 <= status < 500, 'Expected client/DB rejection')
        if error != 'DENIED':
            demand(isinstance(value, dict) and value.get('message') == error,
                   'Unexpected rejection; expected '+error)
    else:
        demand(200 <= status < 300, 'Expected successful RPC')
        if isinstance(value, dict):
            demand('registration_payload' not in value, 'Private payload exposed')
    return value


def payload(run, request_id=None):
    return dict(p_request_id=request_id or str(uuid4()), p_label='C1TEST:'+run[:8],
                p_vehicle_type='SYNTHETIC_TEST_VAN', p_capacity_kg=12.345,
                p_fixed_cost_rm=7.5, p_distance_cost_rm_per_km=0.25,
                p_max_route_duration_min=90, p_available=False)


class Suite:
    def __init__(self, client, manifest, output, fixture_controller=None):
        self.c, self.m, self.output = client, manifest, Path(output)
        self.results, self.created, self.routes = [], {}, []
        self.controller=fixture_controller
        self.route_cursor=0
        self.initial = self.registration('main')

    def registration(self,key='main'):
        from uuid import uuid5
        return payload(self.m['run_id'],str(uuid5(UUID(self.m['run_id']),'vehicle:'+key)))

    def next_route(self):
        demand('route_ids' in self.m and self.route_cursor<len(self.m['route_ids']),'Route fixture budget exceeded')
        rid=self.m['route_ids'][self.route_cursor]; self.route_cursor+=1
        return rid

    def save(self):
        self.output.write_text(json.dumps(dict(project_ref=PROJECT, run_id=self.m['run_id'],
            evidence_kind='LIVE_HTTP_BATCH_B', results=self.results,
            vehicles=self.created, routes=self.routes), indent=2)+'\n', encoding='utf-8')

    def group(self, gid, action, scope='PARTIAL'):
        try:
            if self.controller: self.controller.check_limits()
            action()
            if self.controller: self.controller.check_limits()
        except Exception as exc:
            self.results.append(dict(group=gid, result='FAIL', scope=scope,
                                     error_type=type(exc).__name__,detail=str(exc)))
            self.save()
            raise RuntimeError('STOP: '+gid+' failed; no automatic cleanup/repair') from None
        self.results.append(dict(group=gid, result='PASS', scope=scope))
        self.save()

    def verify_identities(self):
        demand(self.m['project_ref'] == PROJECT and self.m['run_id'] == self.c.receipt['run_id'],
               'Fixture manifest mismatch')
        ids = []
        for actor in ('A','B','U','I','N'):
            user = expect(self.c.request(actor, 'GET', '/auth/v1/user'))
            uid = self.m['identities'][actor]['id']
            demand(user['id'] == uid and user.get('app_metadata', {}).get('c1_test_run') == self.m['run_id'],
                   'Refusing identity without trusted synthetic test marker')
            ids.append(uid)
        demand(len(set(ids)) == 5, 'Actors must be distinct')
        for actor in ('A','B','U'):
            result = expect(self.c.rpc(actor, 'list_my_vehicles'))
            demand(result['vehicles'] == [], 'Refusing nonempty starting test fleet')

    def listed(self, actor):
        result = expect(self.c.rpc(actor, 'list_my_vehicles'))
        rows = result['vehicles']
        demand(all(r['ngo_user_id'] == self.m['identities'][actor]['id'] and
                   'registration_payload' not in r for r in rows), 'Ownership/payload leak')
        demand([r['vehicle_id'] for r in rows] == sorted(r['vehicle_id'] for r in rows), 'Unordered list')
        demand(result['fleet_outcome']==('AVAILABLE_VEHICLES' if any(r['eligible_for_planning'] for r in rows) else 'NO_FEASIBLE_PLAN'),'Fleet outcome disagrees with eligibility')
        return result

    def current(self, actor, vid):
        return next(v for v in self.listed(actor)['vehicles'] if v['vehicle_id'] == vid)

    def profile(self, actor, vid, **changes):
        row = self.current(actor, vid)
        data = {key:row[column] for key,column in PROFILE_KEYS.items()}
        data.update(p_vehicle_id=vid, p_expected_version=row['vehicle_version'])
        data.update(changes)
        return data

    def observer(self, vid):
        row = expect(self.c.request('service','GET','/rest/v1/vehicles?vehicle_id=eq.'+vid+'&select=*'))
        events = expect(self.c.request('service','GET','/rest/v1/audit_events?entity_type=eq.VEHICLE&entity_id=eq.'+vid+'&select=event_type'))
        return row, len(events)

    def change(self, actor, name, data, error=None):
        vid = data['p_vehicle_id']
        before, audits = self.observer(vid)
        value = expect(self.c.rpc(actor,name,data),error)
        after, count = self.observer(vid)
        if error or before == after:
            demand(before == after and audits == count, 'Rejected/no-op request changed row/audit')
        else:
            demand(after[0]['vehicle_version'] == before[0]['vehicle_version']+1 and count == audits+1,
                   'Version/audit delta incorrect')
            for key in ('vehicle_id','ngo_user_id','registration_request_id','registration_payload'):
                demand(after[0][key]==before[0][key],'Immutable fleet identity changed')
        if not error and name=='deactivate_my_vehicle':
            demand(not after[0]['active_flag'] and not after[0]['available_for_planning'],'Deactivation flags incorrect')
        return value

    def register(self, actor, data, key):
        demand(len(self.created) < 5, 'Vehicle fixture budget reached')
        row = expect(self.c.rpc(actor,'register_my_vehicle',data))
        self.created[key] = dict(id=row['vehicle_id'], actor=actor)
        self.save()
        demand(row['vehicle_version'] == 1 and row['ngo_user_id'] == self.m['identities'][actor]['id'],
               'Registration state/owner incorrect')
        demand(row['active_flag'] and row['available_for_planning']==data.get('p_available',False),'Registration flags incorrect')
        demand(row['depot_road_node_id']==self.m['identities'][actor]['depot_node'],'Depot not derived from verified profile')
        demand(self.observer(row['vehicle_id'])[1]==1,'Registration audit count incorrect')
        return row

    def parallel(self, actions):
        barrier = threading.Barrier(len(actions))
        def run(action):
            barrier.wait(timeout=5)
            return action()
        with ThreadPoolExecutor(max_workers=len(actions)) as pool:
            return list(pool.map(run,actions))

    def run(self):
        demand(self.controller is not None and self.m==self.controller.j.data,'Use the journalled synthetic controller')
        self.verify_identities()
        self.group('F01',lambda: [demand(self.listed(a)['reason']=='NO_REGISTERED_VEHICLES','Empty fleet reason') for a in ('A','B')])
        self.group('D01',lambda: demand(self.listed('U')['fleet_outcome']=='NO_FEASIBLE_PLAN','Unverified empty fleet'))
        self.group('D02',lambda: [expect(self.c.rpc('U','register_my_vehicle',dict(self.registration(),p_available=b)), 'VERIFIED_OPERATIONAL_DEPOT_REQUIRED') for b in (False,True)])
        self.group('F02',lambda: self.register('A',{k:v for k,v in self.initial.items() if k!='p_available'},'main'))
        vid = self.created['main']['id']
        second = self.registration('second'); second['p_available']=True
        self.group('F03',lambda: self.register('A',second,'second'))
        self.group('F04',lambda: demand(expect(self.c.rpc('A','register_my_vehicle',self.initial))['vehicle_id']==vid,'Replay duplicate'))
        self.group('F05',lambda: expect(self.c.rpc('A','register_my_vehicle',dict(self.initial,p_label='C1TEST:conflict')),'REGISTRATION_REQUEST_CONFLICT'))
        self.group('F06',lambda: self.register('B',self.initial,'foreign'))
        other = self.created['foreign']['id']
        self.group('C03',lambda:demand(len({expect(r)['vehicle_id'] for r in self.parallel([lambda:self.c.rpc('A','register_my_vehicle',self.initial),lambda:self.c.rpc('B','register_my_vehicle',self.initial)])})==2,'Cross-owner retry isolation'))
        self.group('F07',lambda: [self.listed(a) for a in ('A','B')])
        self.group('F08',lambda: self.change('A','update_my_vehicle',self.profile('A',vid,p_label='C1TEST:updated',p_capacity_kg=13)))
        self.group('F09',lambda: self.change('A','update_my_vehicle',self.profile('A',vid)))
        def versions():
            for version in (None,0,999999):
                for name in ('update_my_vehicle','set_my_vehicle_availability','deactivate_my_vehicle'):
                    data = self.profile('A',vid) if name=='update_my_vehicle' else dict(p_vehicle_id=vid)
                    data['p_expected_version']=version
                    if name=='set_my_vehicle_availability': data['p_available']=True
                    self.change('A',name,data,'VEHICLE_VERSION_CONFLICT')
        self.group('F10',versions)
        def available():
            for value in (True,True,False,False):
                self.change('A','set_my_vehicle_availability',dict(p_vehicle_id=vid,p_expected_version=self.current('A',vid)['vehicle_version'],p_available=value))
        self.group('F11',available)
        def isolation():
            for actor,target in (('B',vid),('A',other)):
                for target_id in (target,str(uuid4())):
                    for name in ('update_my_vehicle','set_my_vehicle_availability','deactivate_my_vehicle'):
                        data = self.profile('A',vid) if name=='update_my_vehicle' else dict(p_available=False) if name=='set_my_vehicle_availability' else {}
                        data.update(p_vehicle_id=target_id,p_expected_version=1)
                        self.change(actor,name,data,'VEHICLE_NOT_FOUND')
        self.group('F15',isolation)
        def invalid_actors(actors):
            for actor in actors:
                for name in sorted(RPCS):
                    data = self.initial if name=='register_my_vehicle' else self.profile('A',vid) if name=='update_my_vehicle' else {} if name=='list_my_vehicles' else dict(p_vehicle_id=vid,p_expected_version=1)
                    if name=='set_my_vehicle_availability': data=dict(data,p_available=False)
                    expect(self.c.rpc(actor,name,data),'DENIED' if actor in ('anon','invalid') else 'ACTIVE_NGO_PROFILE_REQUIRED')
        self.group('F16',lambda:invalid_actors(('anon','invalid')))
        self.group('F17',lambda:invalid_actors(('N','I')))
        self.group('F18',lambda: expect(self.c.rpc('A','register_my_vehicle',dict(self.initial,p_ngo_user_id=self.m['identities']['B']['id'])),'DENIED'))
        def direct():
            for actor in ('A','anon'):
                path='/rest/v1/vehicles?vehicle_id=eq.'+vid
                for method,body in (('GET',None),('PATCH',{'vehicle_label':'C1TEST:forbidden'}),('DELETE',None),('POST',{'ngo_user_id':self.m['identities']['A']['id']})):
                    before=self.observer(vid)
                    expect(self.c.request(actor,method,path,body),'DENIED')
                    demand(self.observer(vid)==before,'Direct denied operation changed state')
        self.group('F19',direct)
        self.group('F20',lambda: (expect(self.c.rpc('service','list_my_vehicles'),'DENIED'),expect(self.c.request('A','POST','/rest/v1/rpc/require_ngo',{},private=True),'DENIED')))
        invalids = {
            'I01':[('p_label',None),('p_label',' '),('p_label','x'*121),('p_vehicle_type',None),('p_vehicle_type',' '),('p_vehicle_type','x'*81)],
            'I02':[('p_capacity_kg',x) for x in (None,0,-1,1000000000,1.0001)],
            'I03':[('p_fixed_cost_rm',x) for x in (None,-1,1.001)]+[('p_distance_cost_rm_per_km',x) for x in (None,-1,1.00001)],
            'I04':[('p_max_route_duration_min',x) for x in (None,0,-1,1.0001)]}
        for gid,variants in invalids.items():
            def invalid(variants=variants):
                for field,value in variants:
                    expect(self.c.rpc('A','register_my_vehicle',dict(self.registration(),**{field:value})),'INVALID_VEHICLE_FIELDS')
                    self.change('A','update_my_vehicle',self.profile('A',vid,**{field:value}),'INVALID_VEHICLE_FIELDS')
            self.group(gid,invalid)
        self.group('I05',lambda: [expect(self.c.rpc('A','register_my_vehicle',dict(self.registration(),p_capacity_kg=x)),'DENIED') for x in ('NaN','Infinity','-Infinity','not-a-number')])
        def nulls():
            for field in ('p_request_id','p_available'):
                expect(self.c.rpc('A','register_my_vehicle',dict(self.registration(),**{field:None})),'REQUEST_AND_AVAILABILITY_REQUIRED')
            self.change('A','set_my_vehicle_availability',dict(p_vehicle_id=vid,p_expected_version=self.current('A',vid)['vehicle_version'],p_available=None),'AVAILABILITY_REQUIRED')
        self.group('I06',nulls)
        def dup(conflict=False):
            data=self.registration('conflict' if conflict else 'duplicate'); alternate=dict(data,p_label='C1TEST:race-other') if conflict else data
            responses=self.parallel([lambda:self.c.rpc('A','register_my_vehicle',data),lambda:self.c.rpc('A','register_my_vehicle',alternate)])
            winners=[expect(r) for r in responses if 200 <= r[0] < 300]
            demand(len(winners)==(1 if conflict else 2),'Registration race winner count')
            demand(len({v['vehicle_id'] for v in winners})==1,'Duplicate registration rows')
            self.created['conflict' if conflict else 'duplicate']=dict(id=winners[0]['vehicle_id'],actor='A'); self.save()
            if conflict: expect(next(r for r in responses if r[0]>=400),'REGISTRATION_REQUEST_CONFLICT')
            found=[v for v in self.listed('A')['vehicles'] if v.get('registration_request_id')==data['p_request_id']]
            demand(len(found)==1,'Owner/key uniqueness failed')
            demand(found[0]['vehicle_version']==1 and self.observer(found[0]['vehicle_id'])[1]==1,'Concurrent registration version/audit count')
        self.group('C01',dup)
        self.group('C02',lambda:dup(True))
        def updates(mode):
            _,audits=self.observer(vid)
            left=self.profile('A',vid,p_label='C1TEST:race-'+str(uuid4())[:8])
            right=self.profile('A',vid,p_label='C1TEST:other-'+str(uuid4())[:8])
            name='update_my_vehicle'
            if mode=='availability':
                name='set_my_vehicle_availability'; right=dict(p_vehicle_id=vid,p_expected_version=left['p_expected_version'],p_available=not self.current('A',vid)['available_for_planning'])
            responses=self.parallel([lambda:self.c.rpc('A','update_my_vehicle',left),lambda:self.c.rpc('A',name,right)])
            demand(sum(200 <= r[0] < 300 for r in responses)==1,'Update race winner count')
            expect(next(r for r in responses if r[0]>=400),'VEHICLE_VERSION_CONFLICT')
            demand(self.current('A',vid)['vehicle_version']==left['p_expected_version']+1,'Lost update/version')
            demand(self.observer(vid)[1]==audits+1,'Concurrent update audit count')
        self.group('C04',lambda:updates('profile'))
        self.group('C05',lambda:updates('availability'))
        self.group('H01',lambda:self.route_holds(vid))
        self.group('H02',lambda:self.terminal_routes(vid))
        def deactivate_race():
            target=self.created['second']['id']
            data=self.profile('A',target,p_label='C1TEST:deactivation-race')
            _,audits=self.observer(target)
            responses=self.parallel([lambda:self.c.rpc('A','update_my_vehicle',data),lambda:self.c.rpc('A','deactivate_my_vehicle',dict(p_vehicle_id=target,p_expected_version=data['p_expected_version']))])
            demand(sum(200 <= r[0] < 300 for r in responses)==1,'Deactivation race winner count')
            if responses[0][0]<300:
                expect(responses[1],'VEHICLE_VERSION_CONFLICT')
            else:
                expect(responses[0],'VEHICLE_DEACTIVATED')
            demand(self.current('A',target)['vehicle_version']==data['p_expected_version']+1 and self.observer(target)[1]==audits+1,'Deactivation race state/audit')
        self.group('C06',deactivate_race)
        self.group('F12',lambda:self.change('A','deactivate_my_vehicle',dict(p_vehicle_id=vid,p_expected_version=self.current('A',vid)['vehicle_version'])))
        self.group('F13',lambda:self.change('A','deactivate_my_vehicle',dict(p_vehicle_id=vid,p_expected_version=self.current('A',vid)['vehicle_version'])))
        self.group('F14',lambda:(self.change('A','update_my_vehicle',self.profile('A',vid),'VEHICLE_DEACTIVATED'),self.change('A','set_my_vehicle_availability',dict(p_vehicle_id=vid,p_expected_version=0,p_available=True),'VEHICLE_DEACTIVATED'),demand(not expect(self.c.rpc('A','register_my_vehicle',self.initial))['active_flag'],'Replay revived vehicle')))

    def route_holds(self,vid):
        self.change('A','set_my_vehicle_availability',dict(p_vehicle_id=vid,p_expected_version=self.current('A',vid)['vehicle_version'],p_available=True))
        for status in ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS'):
            rid=self.next_route(); self.routes.append(rid); self.save()
            expect(self.c.request('service','POST','/rest/v1/pickup_routes?select=*',dict(route_id=rid,vehicle_id=vid,ngo_user_id=self.m['identities']['A']['id'],route_status=status)))
            self.change('A','update_my_vehicle',self.profile('A',vid,p_label='C1TEST:held'),'VEHICLE_HAS_ACTIVE_ROUTE')
            for name,data in [('set_my_vehicle_availability',dict(p_available=False)),('deactivate_my_vehicle',{})]:
                data.update(p_vehicle_id=vid,p_expected_version=self.current('A',vid)['vehicle_version'])
                self.change('A',name,data,'VEHICLE_HAS_ACTIVE_ROUTE')
            demand(not self.current('A',vid)['eligible_for_planning'],'Held vehicle listed eligible')
            self.remove_empty_route(rid,True)

    def remove_empty_route(self,rid,nonterminal=False):
        for table in ('pickup_route_stops','active_task_route_assignments'):
            rows=expect(self.c.request('service','GET','/rest/v1/'+table+'?route_id=eq.'+rid+'&select=route_id'))
            demand(not rows,'Unexpected route activity; stop instead of clearing it')
        if nonterminal:
            rows=expect(self.c.request('service','PATCH','/rest/v1/pickup_routes?route_id=eq.'+rid,{'route_status':'CANCELLED'}))
            demand(len(rows)==1,'Route teardown did not affect exact fixture')
        rows=expect(self.c.request('service','DELETE','/rest/v1/pickup_routes?route_id=eq.'+rid))
        demand(len(rows)==1,'Route delete did not affect exact fixture')
        self.routes.remove(rid); self.save()

    def terminal_routes(self,vid):
        for status in ('COMPLETED','CANCELLED','STALE'):
            rid=self.next_route(); self.routes.append(rid); self.save()
            expect(self.c.request('service','POST','/rest/v1/pickup_routes?select=*',dict(route_id=rid,vehicle_id=vid,ngo_user_id=self.m['identities']['A']['id'],route_status=status)))
            self.change('A','update_my_vehicle',self.profile('A',vid,p_label='C1TEST:terminal-'+status))
            self.remove_empty_route(rid)

    def cleanup(self):
        demand(self.controller is not None,'Cleanup requires the synthetic fixture journal')
        return self.controller.cleanup()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approval',type=Path,required=True)
    parser.add_argument('--fixtures',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.parse_args()
    raise SystemExit('Use provision_synthetic.py --mode run|cleanup; direct legacy runner disabled to enforce recovery/synthetic-ID gates')


if __name__=='__main__': main()
