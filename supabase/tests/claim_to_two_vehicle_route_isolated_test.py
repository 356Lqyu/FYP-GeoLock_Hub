"""Protected claim -> two vehicle route workflow on a new disposable cluster.

This supplements the full-schema Stage B test with a second protected donor
publication/claim and a second independently authorized vehicle route while the
first vehicle is already executing. Synthetic Auth/Storage/road adapters are
local test doubles; this script cannot select a Supabase or external DSN.
"""
import argparse
from dataclasses import asdict
import json
from pathlib import Path
import sys
import unittest

import stage8_stage_b_isolated_test as stage_b

ROOT = stage_b.ROOT
sys.path.insert(0, str(ROOT))


class ClaimToTwoVehicleTests(stage_b.StageBTests):
    def test_claim_to_concurrent_vehicle_routes_and_independent_completion(self):
        from backend.routing.integration import solve_bundle, validate_work_item
        first = self.prepare()
        claim_request = self.query(
            f"SELECT request_id FROM public.donation_claims WHERE claim_id='{first['claim']}';"
        )
        replay = self.jrpc(
            f"public.claim_listing('{first['listing']}','{claim_request}')"
        )
        self.assertEqual(replay['outcome'], 'SUCCESS')
        self.assertTrue(replay['replayed'])

        conflicting = self.jrpc(
            f"public.claim_listing('{first['listing']}','{self.req()}')",
            user=stage_b.B,
        )
        self.assertEqual(conflicting['outcome'], 'CONFLICT')
        self.assertEqual(conflicting['reason_code'], 'CLAIM_CONFLICT')

        donor_request = self.req()
        image_path = f"{stage_b.D}/pending/{donor_request}/{self.req()}.jpg"
        self.query(
            "INSERT INTO storage.objects(bucket_id,name,metadata) "
            f"VALUES('geolock-donation-images','{image_path}',"
            "'{\"size\":100,\"mimetype\":\"image/jpeg\"}');"
        )
        items = [dict(
            category_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            item_name='LOCAL SECOND ITEM', quantity=1, unit_weight_kg=20,
        )]
        images = [dict(storage_path=image_path, content_type='image/jpeg', size_bytes=100)]
        second_donation = self.rpc(
            "public.create_donation_with_images("
            f"'{donor_request}','LOCAL SECOND DONATION','Second local item','LOCAL',"
            f"3.01,101.01,{self.literal(items)},'102',{self.literal(images)})",
            user=stage_b.D,
        )
        second_listing = self.query(
            f"SELECT listing_id FROM public.listings WHERE donation_id='{second_donation}';"
        )
        second_claim = self.jrpc(
            f"public.claim_listing('{second_listing}','{self.req()}')"
        )
        self.assertEqual(second_claim['outcome'], 'SUCCESS')

        vehicle_b = self.jrpc(
            f"public.register_my_vehicle('{self.req()}','LOCAL VAN B','VAN',"
            "100,10,1,240,true)"
        )
        first_route = self.authorize()
        self.rpc(f"public.start_pickup('{first['claim']}')")
        self.assertEqual(
            self.query(
                f"SELECT fleet_private.vehicle_has_hold('{first['vehicle']['vehicle_id']}');"
            ),
            't',
        )
        self.assertEqual(
            self.query(
                f"SELECT route_status FROM public.pickup_routes WHERE route_id='{first_route}';"
            ),
            'IN_PROGRESS',
        )

        policy_id = self.query(
            "SELECT policy_id FROM routing_private.snapshots "
            f"WHERE snapshot_id='{first['bundle']['snapshot']['snapshot_id']}';"
        )
        matrix_id = first['bundle']['matrix']['matrix_id']
        second_request = self.req()
        second_snapshot = self.jrpc(
            f"public.begin_my_routing_snapshot('{second_request}','{policy_id}',"
            f"ARRAY['{vehicle_b['vehicle_id']}'::uuid])"
        )
        observations = second_snapshot['body']['observations']
        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0]['claim']['claim_id'], second_claim['claim_id'])
        self.assertNotEqual(observations[0]['claim']['claim_id'], first['claim'])
        self.jrpc(
            f"public.seal_routing_snapshot('{second_snapshot['snapshot_id']}','{matrix_id}')",
            role='geolock_planner',
        )
        bundle_b = self.jrpc(
            f"public.read_routing_snapshot_bundle('{second_snapshot['snapshot_id']}')",
            role='geolock_planner',
        )
        comparison = solve_bundle(bundle_b)
        plan_b = comparison.proposed_candidate
        self.assertIsNotNone(plan_b)
        self.assertEqual(plan_b.optimization_objective,
                         'MAX_PICKUP_TASKS_THEN_MIN_DIRECTED_ROAD_KM')
        self.assertEqual(plan_b.optimization_status, 'OPTIMAL')
        self.assertEqual(len(plan_b.routes), 1)
        self.assertEqual(len(plan_b.routes[0].stops), 1)
        self.assertEqual(plan_b.routes[0].stops[0].task_id,
                         observations[0]['task']['task_id'])

        candidate = self.jrpc(
            f"public.submit_routing_candidate('{self.req()}','{second_snapshot['snapshot_id']}',"
            f"{self.literal(dict(plan=asdict(plan_b)))})",
            role='geolock_planner',
        )
        work = self.jrpc(
            f"public.read_routing_work_item('{candidate['candidate_id']}')",
            role='geolock_validator',
        )
        attestation = validate_work_item(work, validator_build='TWO-VEHICLE-LOCAL')
        self.assertTrue(attestation['valid'])
        self.assertTrue(attestation['feasible'])
        self.rpc(
            f"public.attest_routing_candidate('{candidate['candidate_id']}','{candidate['digest']}',"
            f"{self.literal(attestation)})",
            role='geolock_validator',
        )
        second_route = self.jrpc(
            f"public.authorize_my_routing_candidate('{self.req()}','{candidate['candidate_id']}',"
            "clock_timestamp()+interval '1 second')"
        )['route_ids'][0]
        self.query('SELECT pg_sleep(1.05);')
        self.rpc(f"public.start_pickup('{second_claim['claim_id']}')")
        self.assertEqual(
            self.query("SELECT count(*) FROM public.active_task_route_assignments;"),
            '2',
        )

        self.rpc(f"public.complete_pickup('{second_claim['claim_id']}',true)")
        self.rpc(f"public.complete_pickup('{first['claim']}',true)")
        self.assertEqual(
            self.query(
                "SELECT count(*) FROM public.pickup_tasks WHERE task_status='COLLECTED';"
            ),
            '2',
        )
        for route_id in (first_route, second_route):
            self.rpc(f"public.close_my_collected_route('{route_id}',true)")
        for vehicle_id in (first['vehicle']['vehicle_id'], vehicle_b['vehicle_id']):
            self.assertEqual(
                self.query(f"SELECT fleet_private.vehicle_has_hold('{vehicle_id}');"),
                'f',
            )
        self.assertEqual(
            self.query("SELECT count(*) FROM public.active_task_route_assignments;"),
            '0',
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated', required=True, action='store_true')
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    if not output.is_relative_to(ROOT.resolve()):
        parser.error('Workspace evidence directory required')
    output.mkdir(parents=True, exist_ok=False)
    stage_b.OUT = output
    stage_b.runtime.EVIDENCE_DIR = output
    ClaimToTwoVehicleTests.bins = {
        name: str(Path(r'C:\Program Files\PostgreSQL\17\bin') / f'{name}.exe')
        for name in ('initdb', 'pg_ctl', 'psql')
    }
    suite = unittest.TestSuite([
        ClaimToTwoVehicleTests(
            'test_claim_to_concurrent_vehicle_routes_and_independent_completion'
        )
    ])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    (output / 'results.json').write_text(json.dumps({
        'tests': result.testsRun,
        'failures': [str(test) + error for test, error in result.failures],
        'errors': [str(test) + error for test, error in result.errors],
        'supabase_connections': 0,
        'scope': 'LOCAL_DISPOSABLE_POSTGRESQL_PROTECTED_CLAIM_TO_TWO_VEHICLE_ROUTE',
    }, indent=2) + '\n')
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
