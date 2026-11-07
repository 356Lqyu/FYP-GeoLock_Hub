"""OFFLINE unit transport only. No Supabase access or live auth assertions."""
from copy import deepcopy
from datetime import datetime,timezone,timedelta
import json
from pathlib import Path
import tempfile
import unittest
from urllib.parse import parse_qs,urlsplit
from uuid import uuid4

from fixture_state import Journal,Controller,ALIASES
from rpc_harness import PROJECT,expect


class OfflineAPI:
    def __init__(self,run):
        now=datetime.now(timezone.utc)
        self.receipt=dict(project_ref=PROJECT,run_id=run,batch_b_authorized=True,allow_identity_setup=True,max_vehicles=5,max_routes=12,recovery_ready=True,
            expires_at=(now+timedelta(hours=1)).isoformat(),password_rotation_confirmed_at=now.isoformat(),
            post_c1_recovery=dict(location='OFFLINE-UNIT-RECOVERY-NOT-A-REAL-BACKUP',created_at=now.isoformat(),usable_confirmed=True,includes_c1_v2=True),
            synthetic_depot=dict(node='42',latitude=3.1,longitude=101.1))
        self.tokens={}; self.users={}; self.tables={n:{} for n in ('user_profiles','ngo_profiles','vehicles','pickup_routes')}
        self.calls=[]; self.effects={}; self.jobs=0; self.fail_after=None; self.activity=False

    def effect(self,name):
        self.effects[name]=self.effects.get(name,0)+1
        if self.fail_after==name:
            self.fail_after=None; raise RuntimeError('OFFLINE simulated lost acknowledgement')

    def rpc(self,a,name,data): return self.request(a,'POST','/rest/v1/rpc/'+name,data)

    def request(self,a,method,path,data=None):
        self.calls.append((method,path))  # Deliberately no password/JWT payloads.
        if path.startswith('/auth/v1/admin/users/'):
            uid=path.rsplit('/',1)[-1]
            if uid not in self.users: return 404,{'code':'user_not_found'}
            if method=='PUT' and data.get('ban_duration'):
                self.users[uid]['banned_until']='2099-01-01T00:00:00+00:00'; self.effect('ban')
            if method=='PUT' and 'password' in data: self.effect('password_reset')
            return 200,deepcopy(self.users[uid])
        if path=='/auth/v1/admin/users':
            if data['id'] in self.users: return 422,{}
            self.users[data['id']]={k:deepcopy(data[k]) for k in ('id','email','app_metadata')}
            self.users[data['id']]['banned_until']=None; self.effect('account_create')
            return 200,deepcopy(self.users[data['id']])
        if path.startswith('/auth/v1/token'):
            user=next(u for u in self.users.values() if u['email']==data['email'])
            if user['banned_until']: return 403,{}
            return 200,{'access_token':'OFFLINE-UNIT-TOKEN','user':{'id':user['id']}}
        if path.startswith('/auth/v1/logout'):
            self.effect('logout'); return 204,None
        if path.startswith('/rest/v1/rpc/'):
            uid=next(u['id'] for u in self.users.values() if u['app_metadata']['c1_test_actor']==a)
            name=path.rsplit('/',1)[-1]
            if name=='register_role_profile':
                if uid in self.tables['user_profiles']: return 400,{}
                self.tables['user_profiles'][uid]={'user_id':uid,'role':data['p_role']}
                if data['p_role']=='NGO': self.tables['ngo_profiles'][uid]=dict(user_id=uid,active_flag=True,location_verified_at=None,road_node_id=None,latitude=None,longitude=None)
                self.effect('profile_create'); return 200,uid
            if name=='set_ngo_operating_location':
                self.tables['ngo_profiles'][uid].update(location_verified_at='2026-01-01T00:00:00Z',road_node_id='42',latitude=data['p_latitude'],longitude=data['p_longitude'])
                self.jobs+=1; self.effect('location_set'); return 200,{'location_status':'VERIFIED'}
            if name=='deactivate_my_vehicle':
                row=self.tables['vehicles'][data['p_vehicle_id']]
                if row['ngo_user_id']!=uid or row['vehicle_version']!=data['p_expected_version']: return 400,{}
                row.update(active_flag=False,available_for_planning=False,vehicle_version=row['vehicle_version']+1)
                self.effect('vehicle_retire'); return 200,deepcopy(row)
        url=urlsplit(path); table=url.path.rsplit('/',1)[-1]; query=parse_qs(url.query)
        if table in ('pickup_route_stops','active_task_route_assignments'):
            return 200,[{'route_id':'OFFLINE'}] if self.activity else []
        rows=list(self.tables[table].values())
        for key in ('user_id','ngo_user_id','route_id'):
            if key in query:
                value=query[key][0]
                allowed=value[4:-1].split(',') if value.startswith('in.(') else [value.removeprefix('eq.')]
                rows=[r for r in rows if r.get(key) in allowed]
        if method=='PATCH':
            for row in rows: row.update(data)
            self.effect('patch_'+table)
        elif method=='DELETE':
            for row in rows: del self.tables[table][row['route_id']]
            self.effect('route_delete')
        return 200,deepcopy(rows[:int(query.get('limit',[1000])[0])])


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.run=str(uuid4()); self.api=OfflineAPI(self.run)
        self.j=Journal(self.temp.name,self.run); self.c=Controller(self.api,self.j)

    def seed(self):
        self.c.provision(); uid=self.c.uid('A'); vid=str(uuid4()); rid=self.j.data['route_ids'][0]
        self.api.tables['vehicles'][vid]=dict(vehicle_id=vid,ngo_user_id=uid,registration_request_id=self.j.request_id('main'),vehicle_label='C1TEST:offline',vehicle_version=1,active_flag=True,available_for_planning=True)
        self.api.tables['pickup_routes'][rid]=dict(route_id=rid,ngo_user_id=uid,vehicle_id=vid,route_status='DRAFT')
        return vid,rid

    def resume(self): return Controller(self.api,Journal(self.temp.name,self.run))

    def test_journal_preallocates_exact_limits(self):
        self.assertEqual(len(self.j.data['identities']),5); self.assertEqual(len(self.j.data['route_ids']),12)

    def test_same_run_same_fixture_ids(self): self.assertEqual(self.j.data,Journal(self.temp.name,self.run).data)

    def test_wrong_run_refused(self):
        with self.assertRaises(AssertionError): Journal(self.temp.name,str(uuid4()))

    def test_wrong_project_refused(self):
        self.j.data['project_ref']='other'; self.j.save()
        with self.assertRaises(AssertionError): Journal(self.temp.name,self.run)

    def test_five_identity_budget_enforced(self):
        self.j.data['identities']['extra']={'id':str(uuid4()),'synthetic':True}; self.j.save()
        with self.assertRaises(AssertionError): Journal(self.temp.name,self.run)

    def test_secret_fields_in_journal_refused(self):
        self.j.data['access_token']='OFFLINE'; self.j.save()
        with self.assertRaises(AssertionError): Journal(self.temp.name,self.run)

    def test_duplicate_route_ids_refused(self):
        self.j.data['route_ids'][1]=self.j.data['route_ids'][0]; self.j.save()
        with self.assertRaises(AssertionError): Journal(self.temp.name,self.run)

    def test_process_lock_excludes_second_controller(self):
        with self.j.exclusive():
            with self.assertRaises((OSError,BlockingIOError)):
                with Journal(self.temp.name,self.run).exclusive(): pass

    def test_provision_resource_idempotency(self):
        self.c.provision(); self.resume().provision()
        self.assertEqual(self.api.effects['account_create'],5)
        self.assertEqual(self.api.effects['profile_create'],5); self.assertEqual(self.api.jobs,2)

    def test_account_lost_acknowledgement_recovers_without_duplicate(self):
        self.api.fail_after='account_create'
        with self.assertRaises(RuntimeError): self.c.provision()
        self.resume().provision(); self.assertEqual(len(self.api.users),5)

    def test_profile_lost_acknowledgement_recovers(self):
        self.api.fail_after='profile_create'
        with self.assertRaises(RuntimeError): self.c.provision()
        self.resume().provision(); self.assertEqual(self.api.effects['profile_create'],5)

    def test_location_lost_acknowledgement_no_duplicate_jobs(self):
        self.api.fail_after='location_set'
        with self.assertRaises(RuntimeError): self.c.provision()
        self.resume().provision(); self.assertEqual(self.api.jobs,2)

    def test_trusted_marker_required(self):
        self.c.provision(); self.api.users[self.c.uid('A')]['app_metadata']={}
        before=dict(self.api.effects)
        with self.assertRaises(AssertionError): self.resume().cleanup()
        self.assertEqual(self.api.effects,before)

    def test_exact_synthetic_email_required(self):
        self.c.provision(); self.api.users[self.c.uid('A')]['email']='real@example.com'
        with self.assertRaises(AssertionError): self.resume().cleanup()

    def test_no_real_user_listing(self):
        self.c.provision(); self.assertFalse(any('/admin/users?' in path for _,path in self.api.calls))

    def test_verification_drift_not_overwritten(self):
        self.c.provision(); self.api.tables['ngo_profiles'][self.c.uid('A')]['latitude']=99
        with self.assertRaises(AssertionError): self.resume().provision()
        self.assertEqual(self.api.jobs,2)

    def test_cleanup_repeated_is_no_op_for_mutations(self):
        self.seed(); self.c.cleanup(); before=dict(self.api.effects)
        result=self.resume().cleanup()
        self.assertEqual(before,self.api.effects); self.assertEqual(result['remaining_routes'],[])

    def test_cleanup_resumes_after_route_delete_lost_ack(self):
        self.seed(); self.api.fail_after='route_delete'
        with self.assertRaises(RuntimeError): self.c.cleanup()
        self.resume().cleanup(); self.assertEqual(self.api.effects['route_delete'],1)

    def test_cleanup_resumes_after_vehicle_retirement_lost_ack(self):
        self.seed(); self.api.fail_after='vehicle_retire'
        with self.assertRaises(RuntimeError): self.c.cleanup()
        self.resume().cleanup(); self.assertEqual(self.api.effects['vehicle_retire'],1)

    def test_cleanup_resumes_after_ban_lost_ack(self):
        self.seed(); self.api.fail_after='ban'
        with self.assertRaises(RuntimeError): self.c.cleanup()
        self.resume().cleanup(); self.assertEqual(self.api.effects['ban'],5)

    def test_task_activity_blocks_all_cleanup_writes(self):
        self.seed(); self.api.activity=True; before=dict(self.api.effects)
        with self.assertRaises(AssertionError): self.c.cleanup()
        self.assertEqual(before,self.api.effects)

    def test_unknown_route_refused(self):
        vid,rid=self.seed(); self.api.tables['pickup_routes'][rid]['route_id']=str(uuid4())
        with self.assertRaises(AssertionError): self.c.cleanup()

    def test_unknown_vehicle_registration_refused(self):
        vid,_=self.seed(); self.api.tables['vehicles'][vid]['registration_request_id']=str(uuid4())
        with self.assertRaises(AssertionError): self.c.cleanup()

    def test_vehicle_limit_refused_before_cleanup_writes(self):
        vid,_=self.seed(); template=self.api.tables['vehicles'][vid]
        for _ in range(5):
            key=str(uuid4()); self.api.tables['vehicles'][key]=dict(template,vehicle_id=key)
        before=dict(self.api.effects)
        with self.assertRaises(AssertionError): self.c.cleanup()
        self.assertEqual(before,self.api.effects)

    def test_retired_run_cannot_provision(self):
        self.c.provision(); self.c.cleanup()
        with self.assertRaises(AssertionError): self.resume().provision()

    def test_no_secrets_persisted(self):
        self.seed(); self.c.cleanup(); text=self.j.path.read_text()
        for secret in ('password','access_token','refresh_token','OFFLINE-UNIT-TOKEN'):
            self.assertNotIn(secret,text)

    def test_missing_rotation_evidence_blocks_before_transport(self):
        del self.api.receipt['password_rotation_confirmed_at']
        with self.assertRaises(AssertionError): Controller(self.api,self.j)
        self.assertEqual(self.api.calls,[])

    def test_pre_c1_backup_blocks_before_transport(self):
        self.api.receipt['post_c1_recovery']['includes_c1_v2']=False
        with self.assertRaises(AssertionError): Controller(self.api,self.j)
        self.assertEqual(self.api.calls,[])

    def test_unusable_backup_blocks_before_transport(self):
        self.api.receipt['post_c1_recovery']['usable_confirmed']=False
        with self.assertRaises(AssertionError): Controller(self.api,self.j)
        self.assertEqual(self.api.calls,[])

    def test_no_approved_creation_blocks_before_transport(self):
        self.api.receipt['allow_identity_setup']=False
        with self.assertRaises(AssertionError): self.c.provision()
        self.assertEqual(self.api.calls,[])

    def test_group_limit_check_two_scoped_reads(self):
        self.seed(); before=len(self.api.calls); self.c.check_limits()
        self.assertEqual(len(self.api.calls)-before,2)
        self.assertTrue(all('ngo_user_id=in.(' in path for _,path in self.api.calls[before:]))

    def test_group_limit_violation_fails_closed(self):
        vid,_=self.seed(); template=self.api.tables['vehicles'][vid]
        for _ in range(5):
            key=str(uuid4()); self.api.tables['vehicles'][key]=dict(template,vehicle_id=key)
        with self.assertRaises(AssertionError): self.c.check_limits()


if __name__=='__main__': unittest.main(verbosity=2)
