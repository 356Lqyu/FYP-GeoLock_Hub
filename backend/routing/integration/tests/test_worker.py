"""Explicit synthetic DB-shaped exports; no live authenticated evidence."""
from dataclasses import asdict, replace
import copy
import unittest
import ortools

from backend.routing.generate_examples import build_mixed
from backend.routing.integration import prepare_bundle, solve_bundle, validate_work_item
from backend.routing.contract import ContractError
from backend.routing.integration.graph_worker import matrix_from_export


def synthetic_bundle():
    p = build_mixed()
    p['matrix']['source_kind'] = 'OPERATIONAL_ROAD_NETWORK'
    p['matrix']['network_snapshot_id'] = 'OSM-OPS-SYNTHETIC-UNIT-ONLY'
    p['matrix']['node_order'] = ['101','102','103']
    p['matrix']['provenance'] = 'SYNTHETIC DB-shaped unit fixture, never live road measurements'
    obs = []
    for index, t in enumerate(p['tasks']):
        node = str(102+index)
        donations = [dict(donation_id=d['donation_id'], donation_status=d['donation_status'], pickup_road_node_id=node, collection_path='DIRECT_PICKUP' if index==0 else 'HUB_COLLECTION',
                          latitude=t['pickup']['latitude'], longitude=t['pickup']['longitude'],
                          availability_start=t['time_window']['start'], availability_end=t['time_window']['end']) for d in t['donations']]
        listing = dict(listing_id=t['listing_id'], listing_status=t['listing_status'],source_type=t['source_type'],
                       listing_weight_kg=t['weight_kg'],listing_version=2,listing_expires_at=None,pickup_road_node_id=node,
                       pickup_latitude=t['pickup']['latitude'],pickup_longitude=t['pickup']['longitude'],
                       donation_id=donations[0]['donation_id'] if index==0 else None,batch_id='TOY-BATCH' if index else None)
        obs.append(dict(task=dict(task_id=t['task_id'],claim_id=t['claim_id'],listing_id=t['listing_id'],ngo_user_id=p['ngo_id'],
                                  pickup_road_node_id=node,load_kg=t['weight_kg'],task_status='CONFIRMED',created_at=t['created_at']),
                        claim=dict(claim_id=t['claim_id'],listing_id=t['listing_id'],ngo_user_id=p['ngo_id'],claim_status='ACTIVE'),
                        lease=dict(lease_id=t['lease_id'],claim_id=t['claim_id'],lease_status='ACTIVE',issued_at=t['lease_issued_at'],expires_at=t['lease_expires_at']),
                        listing=listing,donations=donations,has_route_assignment=False,
                        batch=None if index==0 else dict(batch_id='TOY-BATCH',hub_id='TOY-HUB',batch_version=1,batch_status='PUBLISHED',batch_donation_count=len(donations),batch_weight_kg=t['weight_kg']),
                        hub=None if index==0 else dict(hub_id='TOY-HUB',road_node_id=node,latitude=t['pickup']['latitude'],longitude=t['pickup']['longitude'],active_flag=True),
                        inventory=[] if index==0 else [dict(donation_id=d['donation_id'],hub_id='TOY-HUB',inventory_status='BATCHED') for d in donations]))
    ngo = dict(user_id=p['ngo_id'],role='NGO',active_flag=True,road_node_id='101',latitude=3.,longitude=101.,
               location_generation=1,location_verified_at=p['ngo_location_verified_at'])
    fleet = [dict(vehicle_id=v['vehicle_id'],ngo_user_id=p['ngo_id'],vehicle_type=v['vehicle_type'],payload_capacity_kg=v['capacity_kg'],
                  fixed_cost_rm=v['fixed_cost'],distance_cost_rm_per_km=v['distance_cost_per_km'],max_route_duration_min=240,
                  depot_road_node_id='101',vehicle_version=1,updated_at='2026-10-24T00:00:00Z',active_flag=True,available_for_planning=True) for v in p['vehicles']]
    solver=p['solver']; solver['version']=ortools.__version__; solver['time_limit_seconds']=3
    policy=dict(mandatory=True,horizon_minutes=240,dispatch_margin_minutes=10,direct_service_minutes=10,hub_service_minutes=10,
                solver=solver,execution=dict(fixed_cost_weight=1,distance_cost_weight=1,deterministic_seconds_per_pass=.05))
    return dict(snapshot=dict(snapshot_id='SYNTHETIC-SNAPSHOT',ngo_id=p['ngo_id'],policy_id='SYNTHETIC-POLICY',matrix_id='SYNTHETIC-MATRIX',
                             sealed_at=p['cutoff'],cutoff=p['cutoff'],digest='a'*64,body=dict(ngo=ngo,policy=policy,observations=obs,vehicles=fleet)),
                matrix=dict(matrix_id='SYNTHETIC-MATRIX',digest='b'*64,body=p['matrix']))


class WorkerTests(unittest.TestCase):
    def setUp(self): self.bundle=synthetic_bundle()

    def test_three_methods_and_no_authority(self):
        comparison=solve_bundle(self.bundle)
        self.assertEqual(len(comparison.results),3)
        self.assertEqual({x[1].snapshot_sha256 for x in comparison.results},{comparison.snapshot_sha256})
        self.assertTrue(all(x[2].valid for x in comparison.results))
        self.assertFalse(comparison.dispatch_authority_issued)

    def work(self):
        candidate=solve_bundle(self.bundle).proposed_candidate
        return dict(**copy.deepcopy(self.bundle),candidate=dict(snapshot_id='SYNTHETIC-SNAPSHOT',digest='c'*64,body=dict(plan=asdict(candidate))))

    def test_separate_validation_binds_both_hash_domains(self):
        work=self.work(); report=validate_work_item(work,validator_build='SYNTHETIC-UNIT')
        self.assertEqual(report['snapshot_digest'],'a'*64)
        self.assertNotEqual(report['input_sha256'],report['snapshot_digest'])
        self.assertFalse(report['dispatch_authority_issued'])

    def test_validator_rejects_duplicate_task(self):
        w=self.work(); w['candidate']['body']['plan']['routes'][0]['stops']*=2
        with self.assertRaises(ContractError): validate_work_item(w,validator_build='unit')

    def test_validator_rebuilds_source_and_rejects_changed_cost(self):
        w=self.work(); w['matrix']['body']['distance_km'][0][1]+=1
        with self.assertRaises(ContractError): validate_work_item(w,validator_build='unit')

    def test_validator_rejects_authority_claim(self):
        w=self.work(); w['candidate']['body']['plan']['dispatch_authority_issued']=True
        with self.assertRaises(ContractError): validate_work_item(w,validator_build='unit')

    def test_empty_fleet_no_default(self):
        self.bundle['snapshot']['body']['vehicles']=[]
        comparison=solve_bundle(self.bundle)
        self.assertIsNone(comparison.proposed_candidate)
        self.assertTrue(all(not p.feasible for _,p,_ in comparison.results))

    def test_empty_tasks_no_dispatch_candidate(self):
        self.bundle['snapshot']['body']['observations']=[]
        self.assertIsNone(solve_bundle(self.bundle).proposed_candidate)

    def test_unverified_depot_denied(self):
        self.bundle['snapshot']['body']['ngo']['location_verified_at']=None
        with self.assertRaises(ContractError): prepare_bundle(self.bundle)

    def test_foreign_ownership_denied(self):
        self.bundle['snapshot']['body']['observations'][0]['claim']['ngo_user_id']='OTHER'
        with self.assertRaises(ContractError): prepare_bundle(self.bundle)

    def test_wrong_hub_node_denied(self):
        self.bundle['snapshot']['body']['observations'][1]['hub']['road_node_id']='102'
        with self.assertRaises(ContractError): prepare_bundle(self.bundle)

    def test_wrong_inventory_member_denied(self):
        self.bundle['snapshot']['body']['observations'][1]['inventory'][0]['donation_id']='OTHER'
        with self.assertRaises(ContractError): prepare_bundle(self.bundle)

    def test_unsealed_and_wrong_matrix_denied(self):
        for field,value in [('sealed_at',None),('matrix_id','OTHER')]:
            b=copy.deepcopy(self.bundle); b['snapshot'][field]=value
            with self.subTest(field=field),self.assertRaises(ContractError): prepare_bundle(b)

    def test_missing_arc_fails_closed(self):
        m=self.bundle['matrix']['body']; m['arc_status'][1][0]='MISSING'; m['distance_km'][1][0]=m['travel_minutes'][1][0]=None
        self.assertIsNone(solve_bundle(self.bundle).proposed_candidate)

    def test_expired_lease_and_existing_assignment_excluded(self):
        obs=self.bundle['snapshot']['body']['observations']
        obs[0]['lease']['expires_at']='2026-10-24T00:04:00Z'; obs[1]['has_route_assignment']=True
        self.assertEqual(prepare_bundle(self.bundle).snapshot.readiness,'NO_VALID_TASKS')

    def test_frozen_export_not_mutated(self):
        before=copy.deepcopy(self.bundle); prepare_bundle(self.bundle)
        self.assertEqual(before,self.bundle)

    def test_expired_service_window_explicitly_excluded_without_hiding_valid_task(self):
        self.bundle['snapshot']['body']['observations'][0]['donations'][0]['availability_end']='2026-10-24T00:04:00Z'
        prepared=prepare_bundle(self.bundle)
        self.assertEqual(prepared.excluded_observations,(('TOY-DIRECT','NO_SERVICE_WINDOW_IN_HORIZON'),))
        self.assertEqual(prepared.snapshot.admitted_task_ids,('TOY-HUB-TASK',))


class GraphWorkerTests(unittest.TestCase):
    def setUp(self):
        self.manifest=dict(graph_id='SYNTHETIC-UNIT',content_digest='d'*64,precision_policy='EXACT_MAX_6_DECIMALS',float_output_profile='PG_REAL_OUTPUT_0',node_count=3,edge_count=3,
                           coverage_snapshot='OSM-OPS-SYNTHETIC-UNIT-ONLY',speed_profile='SYNTHETIC explicit paired costs')
        self.nodes=[dict(osm_node_id=i,active_flag=True,network_snapshot_id=self.manifest['coverage_snapshot']) for i in (101,102,103)]
        self.edges=[dict(edge_id=1,source_node=101,target_node=102,road_km=1,travel_minutes=4),
                    dict(edge_id=2,source_node=102,target_node=103,road_km=1,travel_minutes=4),
                    dict(edge_id=3,source_node=101,target_node=103,road_km=3,travel_minutes=1)]

    def test_reuses_directed_same_path_matrix(self):
        m=matrix_from_export(self.manifest,self.nodes,self.edges,['101','103'])
        self.assertEqual(m['distance_km'][0][1],2)
        self.assertEqual(m['travel_minutes'][0][1],8)
        self.assertEqual(m['arc_status'][1][0],'UNREACHABLE')

    def test_truncated_export_rejected(self):
        with self.assertRaises(ContractError): matrix_from_export(self.manifest,self.nodes,self.edges[:-1],['101'])

    def test_duplicate_rows_rejected(self):
        with self.assertRaises(ContractError): matrix_from_export(self.manifest,self.nodes,[self.edges[0]]*3,['101'])

    def test_inactive_pickup_not_invented(self):
        self.nodes[2]['active_flag']=False
        with self.assertRaises(ContractError): matrix_from_export(self.manifest,self.nodes,self.edges,['101','103'])


if __name__=='__main__': unittest.main()
