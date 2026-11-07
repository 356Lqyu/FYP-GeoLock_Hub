import unittest
from copy import deepcopy
from dataclasses import asdict
from backend.routing.integration.tests.test_worker import synthetic_bundle
from backend.routing.integration import solve_bundle
from backend.routing.integration.presentation import planning_response


class PresentationTests(unittest.TestCase):
    def test_proposed_display_preserves_all_research_outputs_and_inputs(self):
        bundle=synthetic_bundle(); before_bundle=deepcopy(bundle)
        compared=solve_bundle(bundle); before=deepcopy(asdict(compared))
        response=planning_response(bundle,compared)
        self.assertEqual(asdict(compared),before)
        self.assertEqual(bundle,before_bundle)
        for projected,(method,plan,validation) in zip(response['methods'],compared.results):
            self.assertEqual(projected,dict(method=method,plan=asdict(plan),validation=asdict(validation)))
        self.assertEqual({r['method'] for r in response['methods']},{'fcfs','nearest_neighbour','proposed'})
        presentation=response['presentation']; self.assertEqual(presentation['geometry_status'],'UNAVAILABLE')
        proposed=next(r for r in response['methods'] if r['method']=='proposed')
        metrics=proposed['validation']['metrics']; routes=presentation['routes']
        self.assertAlmostEqual(sum(r['total_distance_km'] for r in routes),metrics['total_travel_km'])
        self.assertAlmostEqual(sum(r['total_duration_min'] for r in routes),metrics['total_route_minutes'])
        self.assertEqual(sum(r['pickup_count'] for r in routes),metrics['served_count'])
        observations={o['task']['task_id']:o for o in bundle['snapshot']['body']['observations']}
        for display,route in zip(routes,proposed['plan']['routes']):
            self.assertEqual(display['depot']['latitude'],bundle['snapshot']['body']['ngo']['latitude'])
            self.assertEqual([s['task_id'] for s in display['stops']],[s['task_id'] for s in route['stops']])
            self.assertAlmostEqual(display['total_load_kg'],sum(observations[s['task_id']]['task']['load_kg'] for s in display['stops']))
            for stop in display['stops']:
                self.assertEqual(stop['latitude'],observations[stop['task_id']]['listing']['pickup_latitude'])
            self.assertNotIn('polyline',display)

    def test_new_operational_methods_match_flutter_contract(self):
        bundle=synthetic_bundle(); compared=solve_bundle(bundle)
        response=planning_response(bundle,compared)
        self.assertEqual(len(response['methods']),3)
        self.assertFalse(response['dispatch_authority_issued'])
        self.assertEqual(response['validation_status'],'LOCAL_ONLY')
        self.assertNotIn('candidate_id',response)

    def test_database_receipt_still_never_issues_dispatch(self):
        bundle=synthetic_bundle(); compared=solve_bundle(bundle)
        candidate=dict(snapshot_id=bundle['snapshot']['snapshot_id'],candidate_id='synthetic-db-candidate',digest='c'*64,
                       body=dict(plan=dict(snapshot_sha256=compared.snapshot_sha256)))
        response=planning_response(bundle,compared,database_candidate=candidate,attested_digest='c'*64)
        self.assertEqual(response['validation_status'],'ATTESTED')
        self.assertFalse(response['dispatch_authority_issued'])
