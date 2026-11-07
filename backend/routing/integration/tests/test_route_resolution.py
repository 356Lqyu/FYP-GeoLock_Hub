import unittest
from uuid import uuid4
from backend.routing.integration.route_resolution import ResolutionApi, RestrictedResolutionApi
from backend.routing.worker_service.errors import WorkerError


class Session:
    def __init__(self): self.calls = []; self.error = None
    def rpc(self, name, params):
        self.calls.append((name, params))
        if self.error: raise self.error
        return {'status': 'LOCAL_SYNTHETIC'}


class ResolutionApiTests(unittest.TestCase):
    def test_default_disabled_no_io(self):
        s = Session()
        with self.assertRaises(WorkerError): ResolutionApi(s).read(str(uuid4()))
        with self.assertRaises(WorkerError): RestrictedResolutionApi(s.rpc).read(str(uuid4()))
        self.assertEqual(s.calls, [])

    def test_fixed_report_contract_preserves_id(self):
        s = Session(); request, route = str(uuid4()), str(uuid4())
        ResolutionApi(s, enabled=True).report(route, 'VEHICLE_FAILURE', request)
        self.assertEqual(s.calls, [('report_my_route_interruption', {'p_route': route, 'p_reason': 'VEHICLE_FAILURE', 'p_request': request})])

    def test_unknown_outcome_never_retries(self):
        s = Session(); s.error = TimeoutError('local lost reply')
        with self.assertRaises(TimeoutError): ResolutionApi(s, enabled=True).report(str(uuid4()), 'VEHICLE_FAILURE', str(uuid4()))
        self.assertEqual(len(s.calls), 1)

    def test_invalid_assertion_or_version_denied_before_rpc(self):
        s = Session(); a = ResolutionApi(s, enabled=True)
        for value in [0, True, -1, '1']:
            with self.assertRaises(WorkerError): a.evidence(str(uuid4()), str(uuid4()), 'UNKNOWN_CUSTODY', value, str(uuid4()))
        with self.assertRaises(WorkerError): a.evidence(str(uuid4()), None, 'FORCE_RELEASE', 1, str(uuid4()))
        self.assertEqual(s.calls, [])

    def test_read_and_operator_surfaces_separate(self):
        s = Session(); a = ResolutionApi(s, enabled=True)
        self.assertFalse(hasattr(a, 'finalize'))
        case, req = str(uuid4()), str(uuid4())
        RestrictedResolutionApi(s.rpc, enabled=True).finalize(case, 3, req)
        self.assertEqual(s.calls[0], ('finalize_route_resolution', {'p_case': case, 'p_version': 3, 'p_request': req}))

    def test_participant_inbox_is_read_only_contract(self):
        s = Session()
        ResolutionApi(s, enabled=True).list_cases()
        self.assertEqual(s.calls, [('list_my_route_resolution_cases', {})])

    def test_terminal_incident_cannot_use_vehicle_statement(self):
        s = Session(); a = ResolutionApi(s, enabled=True)
        with self.assertRaises(WorkerError): a.incident(str(uuid4()), str(uuid4()), 'VEHICLE_RETURNED_TO_NGO_CONTROL', str(uuid4()))
        self.assertEqual(s.calls, [])


if __name__ == '__main__': unittest.main()
