"""Only new scheduling cases; disposable loopback PostgreSQL, never DEV."""
from datetime import timedelta
import argparse
import json
import sys
import unittest

import stage8_integration_isolated_test as source
from backend.routing.integration.worker import timestamp


def microseconds(delta):
    return (delta.days*86400+delta.seconds)*1_000_000+delta.microseconds


class DepartureTests(source.IntegrationTests):
    def test_departure_retimes_waiting_when_cutoff_departure_window_differ(self):
        f=self.prepare(window_start_delay=20,window_length=2)
        snap=f['bundle']['snapshot'];cut=timestamp(snap['cutoff'])
        depart=cut+timedelta(minutes=10)
        window=timestamp(snap['body']['observations'][0]['donations'][0]['availability_start'])
        self.assertLess(cut,depart);self.assertLess(depart,window)
        original=f['candidate']['body']['plan']['routes'][0]
        receipt=self.jrpc(f"public.authorize_my_routing_candidate('{self.req()}','{f['candidate']['candidate_id']}','{depart.isoformat()}')")
        rid=receipt['route_ids'][0]
        state=json.loads(self.query(f"""SELECT jsonb_build_object('plan',b.plan,'minutes',r.total_duration_min,'arrival',p.planned_arrival)
          FROM routing_private.bindings b JOIN public.pickup_routes r USING(route_id)
          JOIN public.pickup_route_stops p USING(route_id) WHERE b.route_id='{rid}';"""))
        stop=state['plan']['stops'][0]
        self.assertEqual(original['departure_us'],0)
        self.assertEqual(original['stops'][0]['service_start_us'],microseconds(window-cut))
        self.assertEqual(stop['arrival_us'],60_000_000)
        self.assertEqual(stop['service_start_us'],microseconds(window-depart))
        self.assertEqual(stop['departure_us'],microseconds(window-depart)+60_000_000)
        self.assertEqual(state['plan']['return_us'],microseconds(window-depart)+120_000_000)
        self.assertEqual(timestamp(state['arrival']),depart+timedelta(minutes=1))
        self.assertLess(abs(state['minutes']-state['plan']['return_us']/60_000_000),.00051)
        self.assertEqual(original['stops'][0]['service_start_us']-stop['service_start_us'],600_000_000)
        # Authorization must not overwrite the independently attested candidate.
        stored=json.loads(self.query(f"SELECT body->'plan'->'routes'->0 FROM routing_private.candidates WHERE candidate_id='{f['candidate']['candidate_id']}';"))
        self.assertEqual(stored,original)

    def test_departure_after_window_closes_rolls_back_all_reservations(self):
        f=self.prepare(window_start_delay=20,window_length=2)
        depart=timestamp(f['bundle']['snapshot']['cutoff'])+timedelta(minutes=25)
        self.rpc(f"public.authorize_my_routing_candidate('{self.req()}','{f['candidate']['candidate_id']}','{depart.isoformat()}')",error='ROUTE_SCHEDULE_INVALID')
        self.assertEqual(self.query('SELECT count(*) FROM public.pickup_routes;'),'0')
        self.assertEqual(self.query('SELECT count(*) FROM public.active_task_route_assignments;'),'0')
        self.assertEqual(self.query('SELECT count(*) FROM routing_private.bindings;'),'0')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated',required=True,action='store_true');parser.parse_args()
    names=[n for n in unittest.defaultTestLoader.getTestCaseNames(DepartureTests) if n.startswith('test_departure_')]
    result=unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(DepartureTests(n) for n in names))
    sys.exit(not result.wasSuccessful())
