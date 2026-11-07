from dataclasses import replace
import json
import unittest
from unittest.mock import patch

from backend.routing.contract import ContractError
from backend.routing.generate_examples import build_mixed
from backend.routing.phase_b import proposed,OPERATIONAL_METHODS
from backend.routing.phase_c2 import freeze_graph,build_matrix,prepare_input,evaluate
from backend.routing.phase_c2.matrices import FrozenGraph


def graph(complete=True,edges=None):
    return freeze_graph(nodes=['a','b','c'],edges=edges if edges is not None else [
        dict(edge_id='ab',source_node='a',target_node='b',road_km=1,travel_minutes=10),
        dict(edge_id='bc',source_node='b',target_node='c',road_km=1,travel_minutes=10),
        dict(edge_id='ac',source_node='a',target_node='c',road_km=3,travel_minutes=1)],
        snapshot_id='SYNTHETIC-GRAPH',kind='SYNTHETIC_BENCHMARK',complete=complete,speed_profile='SYNTHETIC EXPLICIT EDGE TIMES')


def row(payload):
    v=payload['vehicles'][0]
    return dict(vehicle_id=v['vehicle_id'],ngo_user_id=payload['ngo_id'],vehicle_type='SYNTHETIC_TEST_VAN',
        payload_capacity_kg=40,fixed_cost_rm=5,distance_cost_rm_per_km=1,max_route_duration_min=240,
        active_flag=True,available_for_planning=True,depot_road_node_id=payload['depot']['road_node_id'],
        vehicle_version=1,updated_at='2026-10-24T00:00:00Z')


class MatrixTests(unittest.TestCase):
    def test_distance_and_time_same_path(self):
        matrix=build_matrix(graph(),['a','b','c'])
        self.assertEqual(matrix['distance_km'][0][2],2)
        self.assertEqual(matrix['travel_minutes'][0][2],20)

    def test_directed_no_reverse_invention(self):
        m=build_matrix(graph(),['a','b']); self.assertEqual(m['arc_status'][1][0],'UNREACHABLE')
        self.assertIsNone(m['distance_km'][1][0])

    def test_incomplete_search_is_missing(self):
        matrix=build_matrix(graph(False),['a','b'])
        self.assertEqual(matrix['arc_status'][1][0],'MISSING')
        self.assertEqual(matrix['arc_status'][0][1],'MISSING')
        self.assertIsNone(matrix['distance_km'][0][1])

    def test_zero_diagonal_only_known_node(self):
        self.assertEqual(build_matrix(graph(),['a'])['distance_km'],[[0]])
        with self.assertRaises(ContractError): build_matrix(graph(),['unknown'])

    def test_reproducible_hash_and_immutable_copy(self):
        g=graph(); copy=g.to_dict(); copy['nodes'].clear()
        self.assertEqual(g,graph()); self.assertEqual(g.to_dict()['nodes'],['a','b','c'])

    def test_digest_tamper_fails(self):
        with self.assertRaises(ContractError): build_matrix(FrozenGraph(graph().canonical_json,'0'*64),['a'])

    def test_negative_nonfinite_and_precision_rejected(self):
        for value in (-1,'NaN','Infinity',True,'0.0000001'):
            with self.subTest(value=value),self.assertRaises(ContractError):
                graph(edges=[dict(edge_id='x',source_node='a',target_node='b',road_km=value,travel_minutes=1)])

    def test_unknown_edge_endpoint(self):
        with self.assertRaises(ContractError): graph(edges=[dict(edge_id='x',source_node='x',target_node='b',road_km=1,travel_minutes=1)])

    def test_zero_cycles_terminate(self):
        g=graph(edges=[dict(edge_id='ab',source_node='a',target_node='b',road_km=0,travel_minutes=0),dict(edge_id='ba',source_node='b',target_node='a',road_km=0,travel_minutes=0)])
        self.assertEqual(build_matrix(g,['a','b'])['distance_km'],[[0,0],[0,0]])

    def test_shared_project_rejected(self):
        with self.assertRaises(ContractError): freeze_graph(nodes=['1'],edges=[],snapshot_id='OSM-OPS-x',kind='OPERATIONAL_ROAD_NETWORK',complete=True,project_ref='other',speed_profile='explicit')


class OrchestrationTests(unittest.TestCase):
    def test_complete_synthetic_graph_projection_comparison_pipeline(self):
        from backend.routing.phase_c2.__main__ import demonstration
        result=demonstration()
        self.assertTrue(result['synthetic'])
        self.assertTrue(result['proposed_candidate_available'])
        self.assertFalse(result['dispatch_authority_issued'])
        self.assertEqual(len(result['methods']),3)
        self.assertTrue(all(r['validation']['valid'] for r in result['methods']))

    def test_all_four_identical_frozen_inputs_and_independent_validity(self):
        payload=build_mixed(); before=json.dumps(payload,sort_keys=True)
        prepared=prepare_input(payload); result=evaluate(prepared)
        self.assertEqual(len(result.results),3)
        self.assertEqual({p.snapshot_sha256 for _,p,_ in result.results},{prepared.snapshot.sha256})
        self.assertTrue(all(v.valid for _,_,v in result.results))
        self.assertIsNotNone(result.proposed_candidate)
        self.assertFalse(result.dispatch_authority_issued)
        self.assertEqual(json.dumps(payload,sort_keys=True),before)

    def test_zero_fleet_no_defaults(self):
        prepared=prepare_input(build_mixed(),fleet_rows=[])
        self.assertEqual(prepared.snapshot.readiness,'NO_FEASIBLE_PLAN')
        self.assertIsNone(evaluate(prepared).proposed_candidate)

    def test_c1_projection_and_version_binding(self):
        p=build_mixed(); r=row(p)
        first=prepare_input(p,fleet_rows=[r],held_vehicle_ids=[]); r['vehicle_version']=2
        second=prepare_input(p,fleet_rows=[r],held_vehicle_ids=[])
        self.assertNotEqual(first.snapshot.sha256,second.snapshot.sha256)
        self.assertEqual(len(first.snapshot.available_vehicle_ids),1)

    def test_held_unavailable_deactivated_and_incomplete_excluded(self):
        p=build_mixed()
        for patch_data,holds in (({'active_flag':False},()),({'available_for_planning':False},()),({'fixed_cost_rm':None},()),({},(row(p)['vehicle_id'],)),({'depot_road_node_id':'other'},())):
            r=row(p); r.update(patch_data)
            value=prepare_input(p,fleet_rows=[r],held_vehicle_ids=holds)
            self.assertEqual(value.snapshot.readiness,'NO_FEASIBLE_PLAN')
            self.assertEqual(len(value.excluded_vehicles),1)

    def test_foreign_fleet_rejected(self):
        p=build_mixed(); r=row(p); r['ngo_user_id']='foreign'
        with self.assertRaises(ContractError): prepare_input(p,fleet_rows=[r],held_vehicle_ids=[])

    def test_invalid_vehicle_fields(self):
        p=build_mixed()
        for field,value in (('payload_capacity_kg',0),('fixed_cost_rm',-1),('distance_cost_rm_per_km',1.00001),('max_route_duration_min',0),('vehicle_version',True),('active_flag',1),('updated_at','invalid'),('updated_at','2026-10-24T00:06:00Z')):
            r=row(p); r[field]=value
            with self.subTest(field=field),self.assertRaises(ContractError): prepare_input(p,fleet_rows=[r],held_vehicle_ids=[])

    def test_capacity_infeasible_no_candidate(self):
        p=build_mixed(); r=row(p); r['payload_capacity_kg']=0.001
        self.assertIsNone(evaluate(prepare_input(p,fleet_rows=[r],held_vehicle_ids=[])).proposed_candidate)

    def test_no_eligible_tasks(self):
        p=build_mixed()
        for t in p['tasks']: t['claim_status']='EXPIRED'
        prepared=prepare_input(p)
        self.assertEqual(prepared.snapshot.readiness,'NO_VALID_TASKS')
        self.assertIsNone(evaluate(prepared).proposed_candidate)

    def test_missing_roads_fail_closed(self):
        p=build_mixed(); p['matrix']['unavailable_policy']='FAIL_SCENARIO'
        p['matrix']['arc_status'][0][1]='MISSING'; p['matrix']['distance_km'][0][1]=None; p['matrix']['travel_minutes'][0][1]=None
        self.assertIsNone(evaluate(prepare_input(p)).proposed_candidate)

    def test_tampered_solver_output_rejected(self):
        prepared=prepare_input(build_mixed()); plan=proposed(prepared.snapshot)
        with patch('backend.routing.phase_c2.orchestration.OPERATIONAL_METHODS',dict(OPERATIONAL_METHODS,proposed=lambda s,c:replace(plan,dispatch_authority_issued=True))):
            with self.assertRaises(ContractError): evaluate(prepared)

    def test_missing_hold_facts_fail_closed(self):
        p=build_mixed()
        with self.assertRaises(ContractError): prepare_input(p,fleet_rows=[row(p)])

    def test_rpc_ineligible_flag_cannot_be_overridden(self):
        p=build_mixed(); r=row(p); r['eligible_for_planning']=False
        self.assertEqual(prepare_input(p,fleet_rows=[r],held_vehicle_ids=[]).snapshot.readiness,'NO_FEASIBLE_PLAN')

    def test_hub_location_not_replaceable(self):
        p=build_mixed(); task=next(t for t in p['tasks'] if t['source_type']=='HUB_BATCH')
        task['pickup']=p['depot']
        prepared=prepare_input(p)
        self.assertIn(task['task_id'],dict(prepared.snapshot.excluded_tasks))


if __name__=='__main__': unittest.main()
