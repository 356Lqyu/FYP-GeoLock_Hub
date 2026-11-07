"""Default-disabled resolution API adapter over an already verified NGO session.

The database derives actors and permissions. This module does not issue tokens,
accept actor IDs, start a service, select a DSN, retry writes or expose finalization
to NGO endpoints. Import has no I/O. Hosted JWT/PostgREST verification remains a
separate deployment check; local tests use explicit auth adapters.
"""
from ..worker_service.errors import check
from ..worker_service.transport import uuid

REASONS = frozenset({'EXECUTION_BUDGET_EXCEEDED', 'VEHICLE_FAILURE',
                     'PICKUP_UNAVAILABLE', 'OTHER_REQUIRES_REVIEW'})
ASSERTIONS = frozenset({'NO_HANDOVER_SOURCE_RETAINS_GOODS', 'HANDOVER_TO_NGO_CONFIRMED',
                       'UNKNOWN_CUSTODY', 'VEHICLE_RETURNED_TO_NGO_CONTROL'})


class ResolutionApi:
    def __init__(self, verified_session, *, enabled=False):
        self.session, self.enabled = verified_session, enabled

    def _call(self, name, params):
        check(self.enabled, 'ROUTE_RESOLUTION_DISABLED', 503)
        # Exactly one call. Unknown commit outcomes are returned to the caller;
        # receipt reads, never a different request UUID, reconcile them.
        return self.session.rpc(name, params)

    def read(self, route_id):
        return self._call('get_my_route_resolution', {'p_route': uuid(route_id)})

    def list_cases(self):
        return self._call('list_my_route_resolution_cases', {})

    def receipt(self, request_id):
        return self._call('get_my_route_resolution_receipt', {'p_request': uuid(request_id)})

    def report(self, route_id, reason, request_id):
        check(reason in REASONS, 'INTERRUPTION_REASON_REQUIRED', 400)
        return self._call('report_my_route_interruption', {
            'p_route': uuid(route_id), 'p_reason': reason, 'p_request': uuid(request_id)})

    def evidence(self, case_id, task_id, assertion, version, request_id):
        check(assertion in ASSERTIONS, 'CUSTODY_ASSERTION_REQUIRED', 400)
        check(type(version) is int and version >= 1, 'CASE_VERSION_REQUIRED', 400)
        return self._call('submit_route_resolution_evidence', {
            'p_case': uuid(case_id), 'p_task': None if task_id is None else uuid(task_id),
            'p_assertion': assertion, 'p_version': version, 'p_request': uuid(request_id)})

    def incident(self, case_id, task_id, assertion, request_id):
        check(assertion in ASSERTIONS - {'VEHICLE_RETURNED_TO_NGO_CONTROL'}, 'CUSTODY_ASSERTION_REQUIRED', 400)
        return self._call('report_route_resolution_incident', {
            'p_case': uuid(case_id), 'p_task': uuid(task_id),
            'p_assertion': assertion, 'p_request': uuid(request_id)})


class RestrictedResolutionApi:
    """Operator-only surface. Supply the dedicated principal's fixed RPC adapter.

    No HTTP route or environment connection is activated here. DB role AND named
    operator mapping remain mandatory even if an untrusted caller instantiates it.
    """
    def __init__(self, resolver_rpc, *, enabled=False):
        self.rpc, self.enabled = resolver_rpc, enabled

    def read(self, case_id):
        check(self.enabled, 'ROUTE_RESOLUTION_DISABLED', 503)
        return self.rpc('get_route_resolution_for_operator', {'p_case': uuid(case_id)})

    def finalize(self, case_id, version, request_id):
        check(self.enabled, 'ROUTE_RESOLUTION_DISABLED', 503)
        check(type(version) is int and version >= 1, 'CASE_VERSION_REQUIRED', 400)
        return self.rpc('finalize_route_resolution', {
            'p_case': uuid(case_id), 'p_version': version, 'p_request': uuid(request_id)})
