"""Resumable synthetic fixture ownership boundary. No I/O on import.

Only explicit provision/cleanup calls can write through a supplied client.
Unit transports are labelled offline and are never live authentication evidence.
"""
from contextlib import contextmanager
from datetime import datetime,timezone
import json
import os
from pathlib import Path
import secrets
import threading
from uuid import UUID,uuid4,uuid5

from rpc_harness import PROJECT,demand,expect,execution_gates

ALIASES=('A','B','U','I','N')


class Journal:
    def __init__(self,folder,run_id):
        UUID(run_id)
        self.folder=Path(folder); self.folder.mkdir(parents=True,exist_ok=True)
        self.path=self.folder/'fixtures.json'; self.lock=threading.RLock()
        if self.path.exists():
            self.data=json.loads(self.path.read_text(encoding='utf-8'))
        else:
            self.data=dict(project_ref=PROJECT,run_id=run_id,identities={a:{'id':str(uuid4()),'synthetic':True} for a in ALIASES},
                           route_ids=[str(uuid4()) for _ in range(12)],revoked=[],test_execution='NOT_STARTED',retired=False)
            self.save()
        d=self.data
        demand(set(d)=={'project_ref','run_id','identities','route_ids','revoked','test_execution','retired'},'Unknown journal fields')
        demand(d['project_ref']==PROJECT and d['run_id']==run_id,'Journal scope mismatch')
        demand(set(d['identities'])==set(ALIASES),'Exactly five synthetic identities required')
        ids=[d['identities'][a]['id'] for a in ALIASES]+d['route_ids']
        demand(len(d['route_ids'])==12 and len(set(ids))==17,'Fixture ID collision/budget error')
        for uid in ids: UUID(uid)
        demand(all(set(item)<= {'id','synthetic','depot_node'} and item.get('synthetic') is True for item in d['identities'].values()),'Invalid identity journal')

    def save(self):
        with self.lock:
            temp=self.path.with_suffix('.tmp')
            with temp.open('w',encoding='utf-8') as output:
                json.dump(self.data,output,indent=2); output.write('\n'); output.flush(); os.fsync(output.fileno())
            os.replace(temp,self.path)

    @contextmanager
    def exclusive(self):
        """OS lock releases on process death; stale lock files need no deletion."""
        with (self.folder/'controller.lock').open('a+b') as handle:
            handle.seek(0); handle.write(b'0'); handle.flush(); handle.seek(0)
            if os.name=='nt':
                import msvcrt
                msvcrt.locking(handle.fileno(),msvcrt.LK_NBLCK,1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
            try:
                yield
            finally:
                handle.seek(0)
                if os.name=='nt': msvcrt.locking(handle.fileno(),msvcrt.LK_UNLCK,1)
                else: fcntl.flock(handle.fileno(),fcntl.LOCK_UN)

    def request_id(self,key):
        demand(key in ('main','second','duplicate','conflict'),'Unknown registration slot')
        return str(uuid5(UUID(self.data['run_id']),'vehicle:'+key))

    def email(self,alias):
        return f"c1test.{self.data['run_id']}.{alias.lower()}@example.invalid"


class Controller:
    def __init__(self,client,journal):
        self.c,self.j=client,journal
        execution_gates(client.receipt)
        demand(client.receipt['project_ref']==PROJECT and client.receipt['run_id']==journal.data['run_id'],'Controller scope mismatch')

    def uid(self,a): return self.j.data['identities'][a]['id']

    def user(self,alias,missing=False):
        uid=self.uid(alias)
        response=self.c.request('service','GET','/auth/v1/admin/users/'+uid)
        if response[0]==404 and missing: return None
        user=expect(response)
        metadata=user.get('app_metadata',{})
        demand(user['id']==uid and user.get('email')==self.j.email(alias) and
               metadata.get('c1_test_run')==self.j.data['run_id'] and metadata.get('c1_test_actor')==alias,
               'Refusing identity without exact trusted synthetic markers')
        return user

    def rows(self,table,alias,columns='*',limit=13):
        key='user_id' if table in ('user_profiles','ngo_profiles') else 'ngo_user_id'
        return expect(self.c.request('service','GET',f'/rest/v1/{table}?{key}=eq.{self.uid(alias)}&select={columns}&limit={limit}'))

    def login(self,alias,password=None):
        user=self.user(alias)
        banned=user.get('banned_until')
        demand(not banned or datetime.fromisoformat(banned.replace('Z','+00:00'))<=datetime.now(timezone.utc),'Retired identity cannot be reopened')
        if password is None:
            password=secrets.token_urlsafe(32)
            expect(self.c.request('service','PUT','/auth/v1/admin/users/'+self.uid(alias),{'password':password}))
        session=expect(self.c.request('anon','POST','/auth/v1/token?grant_type=password',{'email':self.j.email(alias),'password':password}))
        demand(session.get('user',{}).get('id')==self.uid(alias),'Unexpected login subject')
        self.c.tokens[alias]=session['access_token']

    def provision(self):
        demand(self.c.receipt.get('allow_identity_setup') is True,'Identity setup is not approved')
        demand(not self.j.data['retired'],'Retired run cannot be reprovisioned')
        for alias in ALIASES:
            user=self.user(alias,missing=True); password=None
            if user is None:
                # ID and marker are durable BEFORE POST. A lost acknowledgement
                # is recovered by exact-ID GET; never list/search real accounts.
                password=secrets.token_urlsafe(32)
                expect(self.c.request('service','POST','/auth/v1/admin/users',dict(id=self.uid(alias),email=self.j.email(alias),password=password,
                    email_confirm=True,app_metadata={'c1_test_run':self.j.data['run_id'],'c1_test_actor':alias})))
                self.user(alias)
            self.login(alias,password)
            role='DONOR' if alias=='N' else 'NGO'
            profiles=self.rows('user_profiles',alias,'user_id,role')
            if not profiles:
                expect(self.c.request(alias,'POST','/rest/v1/rpc/register_role_profile',dict(p_full_name='C1TEST '+self.j.data['run_id']+' '+alias,p_role=role,
                    p_ngo_name='C1TEST '+self.j.data['run_id']+' '+alias if role=='NGO' else None)))
                profiles=self.rows('user_profiles',alias,'user_id,role')
            demand(len(profiles)==1 and profiles[0]['role']==role,'Profile ownership/role mismatch')
        depot=self.c.receipt['synthetic_depot']
        for alias in ('A','B'):
            rows=self.rows('ngo_profiles',alias)
            demand(len(rows)==1 and rows[0]['active_flag'],'Unexpected inactive/missing synthetic NGO')
            ngo=rows[0]
            if ngo['location_verified_at'] is None:
                result=expect(self.c.request(alias,'POST','/rest/v1/rpc/set_ngo_operating_location',dict(p_operating_address='C1TEST synthetic depot',p_latitude=depot['latitude'],p_longitude=depot['longitude'])))
                demand(result['location_status']=='VERIFIED','Depot verification failed')
                ngo=self.rows('ngo_profiles',alias)[0]
            demand(ngo['latitude']==depot['latitude'] and ngo['longitude']==depot['longitude'] and ngo['road_node_id']==depot['node'],'Depot drift: do not enqueue another refresh')
            self.j.data['identities'][alias]['depot_node']=ngo['road_node_id']; self.j.save()
        unverified=self.rows('ngo_profiles','U')[0]
        demand(unverified['location_verified_at'] is None and unverified['active_flag'],'Unverified test actor drift')
        inactive=self.rows('ngo_profiles','I')[0]
        if inactive['active_flag']:
            changed=expect(self.c.request('service','PATCH','/rest/v1/ngo_profiles?user_id=eq.'+self.uid('I'),{'active_flag':False}))
            demand(len(changed)==1 and not changed[0]['active_flag'],'Inactive actor setup failed')
        return self.j.data

    def inspect_fixtures(self):
        vehicles=[]; routes=[]
        for alias in ALIASES:
            user=self.user(alias,missing=True)
            if user is None: continue
            owned=self.rows('vehicles',alias,limit=6)
            for row in owned:
                demand(row['ngo_user_id']==self.uid(alias),'Foreign vehicle in fixture export')
                allowed={self.j.request_id(k) for k in ('main','second','duplicate','conflict')}
                demand(row['registration_request_id'] in allowed and row['vehicle_label'].startswith('C1TEST:'),'Refusing unrecognized vehicle')
                vehicles.append((alias,row))
            for row in self.rows('pickup_routes',alias,limit=13):
                demand(row['route_id'] in self.j.data['route_ids'] and row['ngo_user_id']==self.uid(alias),'Refusing unrecognized route')
                routes.append(row)
        demand(len(vehicles)<=5 and len(routes)<=12,'Fixture budget violated')
        ids={row['vehicle_id'] for _,row in vehicles}
        for route in routes:
            demand(route['vehicle_id'] in ids,'Unrecognized route vehicle')
            for table in ('pickup_route_stops','active_task_route_assignments'):
                rows=expect(self.c.request('service','GET',f"/rest/v1/{table}?route_id=eq.{route['route_id']}&select=route_id&limit=1"))
                demand(not rows,'Route activity found: no destructive cleanup permitted')
        return vehicles,routes

    def check_limits(self):
        """Two bounded, synthetic-owner-only reads between test groups.

        Full trusted-identity/activity verification still precedes cleanup. Avoid
        exhausting the HTTP budget by rediscovering every account twice per group.
        """
        owners={self.uid(a) for a in ALIASES}
        owner_filter='in.('+','.join(sorted(owners))+')'
        rows=expect(self.c.request('service','GET','/rest/v1/vehicles?ngo_user_id='+owner_filter+'&select=*&limit=6'))
        routes=expect(self.c.request('service','GET','/rest/v1/pickup_routes?ngo_user_id='+owner_filter+'&select=*&limit=13'))
        demand(len(rows)<=5 and len(routes)<=12,'Fixture budget violated')
        requests={self.j.request_id(k) for k in ('main','second','duplicate','conflict')}
        for row in rows:
            demand(row['ngo_user_id'] in owners and row['registration_request_id'] in requests and row['vehicle_label'].startswith('C1TEST:'),'Unrecognized fixture vehicle')
        bindings={(r['vehicle_id'],r['ngo_user_id']) for r in rows}
        demand(all(r['route_id'] in self.j.data['route_ids'] and (r['vehicle_id'],r['ngo_user_id']) in bindings for r in routes),'Unrecognized route binding')

    def cleanup(self):
        # Reconstruct truth from exact synthetic owners, not success flags or a
        # partial response ledger. Preflight ALL fixtures before any cleanup.
        vehicles,routes=self.inspect_fixtures()
        for route in routes:
            rid=route['route_id']
            if route['route_status'] in ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS'):
                changed=expect(self.c.request('service','PATCH','/rest/v1/pickup_routes?route_id=eq.'+rid,{'route_status':'CANCELLED'}))
                demand(len(changed)==1,'Route cancellation cardinality mismatch')
            deleted=expect(self.c.request('service','DELETE','/rest/v1/pickup_routes?route_id=eq.'+rid))
            demand(len(deleted)==1,'Route deletion cardinality mismatch')
        for alias,previous in vehicles:
            rows=self.rows('vehicles',alias,limit=6)
            row=next(v for v in rows if v['vehicle_id']==previous['vehicle_id'])
            if row['active_flag']:
                if alias not in self.c.tokens: self.login(alias)
                result=expect(self.c.rpc(alias,'deactivate_my_vehicle',{'p_vehicle_id':row['vehicle_id'],'p_expected_version':row['vehicle_version']}))
                demand(not result['active_flag'] and not result['available_for_planning'],'Vehicle retirement failed')
            else:
                demand(not row['available_for_planning'],'Inactive vehicle still available')
        for alias in ALIASES:
            if self.user(alias,missing=True) is None: continue
            if alias!='N':
                profiles=self.rows('ngo_profiles',alias)
                if profiles and profiles[0]['active_flag']:
                    changed=expect(self.c.request('service','PATCH','/rest/v1/ngo_profiles?user_id=eq.'+self.uid(alias),{'active_flag':False}))
                    demand(len(changed)==1 and not changed[0]['active_flag'],'NGO retirement failed')
            if alias not in self.j.data['revoked']:
                if alias not in self.c.tokens: self.login(alias)
                expect(self.c.request(alias,'POST','/auth/v1/logout?scope=global',{}))
                self.j.data['revoked'].append(alias); self.j.save()
            user=self.user(alias)
            banned=user.get('banned_until')
            if not banned or datetime.fromisoformat(banned.replace('Z','+00:00'))<=datetime.now(timezone.utc):
                expect(self.c.request('service','PUT','/auth/v1/admin/users/'+self.uid(alias),{'ban_duration':'876000h'}))
            checked=self.user(alias)
            demand(checked.get('banned_until') and datetime.fromisoformat(checked['banned_until'].replace('Z','+00:00'))>datetime.now(timezone.utc),'Ban not confirmed')
        remaining,left=self.inspect_fixtures()
        demand(not left and all(not r['active_flag'] and not r['available_for_planning'] for _,r in remaining),'Cleanup postconditions failed')
        self.j.data['retired']=True; self.j.save()
        return dict(retained_vehicles=[r['vehicle_id'] for _,r in remaining],remaining_routes=[],auth_session_revocation='Successful global logout recorded; access JWTs can persist until expiry')
