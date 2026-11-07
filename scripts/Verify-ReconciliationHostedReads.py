"""One operator-approved hosted read pass. Default: local validation only.

Reuses the existing exact-pilot phone-session reader, in memory only. Never
refreshes authentication, stores tokens or invokes a mutation RPC.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import re
import ssl
import sys
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from backend.routing.worker_service.transport import NoRedirect

PROJECT = 'rcgyuwiidqvrgbxswhqj'
BASE = 'https://' + PROJECT + '.supabase.co'
NGO = '8e50bc66-7a8d-4791-bc6b-640682daa496'
V2 = 'db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'
V3 = '7dd2d00a-ff03-4021-994f-155bbfc8e12c'
DONOR_A = 'bc68e284-58eb-4ba7-91ca-f27bab108b71'
DONOR_B = '21d373a7-6551-4469-81d1-280198d4317e'
TEST10 = '9505c1ad-2116-42cf-961f-8b883cf1aa62'
TESTC = 'a09b3502-4113-4f5b-b74d-2eb7b01b6649'
TEST42 = '5ab67656-bd03-4e19-942f-59a2dd4e6f11'
ABSENT = '00000000-0000-0000-0000-000000000000'
IDENTITIES = {'ngo': NGO, 'donor-a': DONOR_A, 'donor-b': DONOR_B}
READ_RPCS = frozenset({'get_my_route_resolution', 'list_my_route_resolution_cases',
                      'get_my_authorized_route', 'get_my_donation_route_resolution',
                      'get_my_route_resolution_receipt', 'list_my_vehicles'})
SAFE_KEYS = frozenset('contract enabled status route_id case_id version cases is_owner '
    'vehicle_confirmed task_id claim_id initial_class my_assertion ngo_assertion source_assertion '
    'donation_id history_count history_truncated association_conflict contexts case_version '
    'resolution_status claim_reconciliation_status claim_status lease_status task_status '
    'route_status outcome action guidance action_guidance can_submit_evidence allowed_assertions '
    'donor_assertion donor_version donor_submitted_at ngo_version ngo_submitted_at '
    'resolved_at claim_resolved_at disposition released_at server_now candidate_id snapshot_id '
    'actual_started_at vehicle_label total_load_kg pickup_count validation_status '
    'vehicle_id departure_at total_distance_km total_duration_min authorization_confirmed '
    'dispatch_block_reason can_close can_cancel stops items stop_order source_type title '
    'load_kg planned_arrival can_start can_complete closed_at total_contexts '
    'action_block_reason block_reason source_evidence_status ngo_evidence_status '
    'request_id result vehicles vehicle_version ngo_user_id active_flag available_for_planning '
    'eligible_for_planning payload_capacity_kg max_route_duration_min depot_road_node_id fleet_outcome reason'.split())


def sanitize(value):
    if isinstance(value, dict):
        return {k: sanitize(v) for k, v in value.items() if k in SAFE_KEYS}
    if isinstance(value, list):
        return [sanitize(x) for x in value]
    return value


def run(participant, approval, expect_enabled=False, reported_case=None, report_request=None):
    result = dict(status='NOT VERIFIED', participant=participant, approval_ref=approval,
                  project_ref=PROJECT, observed_at=datetime.now(timezone.utc).isoformat(),
                  database_business_writes=False, authentication_refresh=False,
                  expected_backend_enabled=expect_enabled, reported_case=reported_case,
                  report_request=report_request, calls=[])
    phase = 'phone_session_memory_only'
    try:
        spec = importlib.util.spec_from_file_location('existing_phone_transport', ROOT / 'scripts/Run-ExactV3Pilot.py')
        phone = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(phone)
        token = phone.phone_session(IDENTITIES[participant])
        source = (ROOT / 'frontend/geolock_hub_app/lib/supabase_config.dart').read_text(encoding='utf-8-sig')
        key = re.search(r"'(sb_publishable_[A-Za-z0-9_-]+)'", source).group(1)
        opener = urllib.request.build_opener(NoRedirect(),
                    urllib.request.HTTPSHandler(context=ssl.create_default_context()))

        def request(path, params=None):
            if path != '/auth/v1/user':
                if not path.startswith('/rest/v1/rpc/') or path.rsplit('/', 1)[-1] not in READ_RPCS:
                    raise ValueError('READ_ENDPOINT_NOT_ALLOWED')
            req = urllib.request.Request(BASE + path,
                data=None if params is None else json.dumps(params).encode(),
                headers={'apikey': key, 'Authorization': 'Bearer ' + token,
                         'Content-Type': 'application/json'})
            try:
                with opener.open(req, timeout=20) as response:
                    raw = response.read(1_000_001)
                    if len(raw) > 1_000_000:
                        raise ValueError('RESPONSE_TOO_LARGE')
                    return response.status, json.loads(raw)
            except urllib.error.HTTPError as error:
                try:
                    body = json.loads(error.read(65536))
                except (ValueError, TypeError):
                    body = {}
                code = body.get('code')
                message = body.get('message')
                return error.code, dict(
                    sqlstate_or_code=code if isinstance(code, str) and re.fullmatch(r'[A-Za-z0-9_]{2,80}', code) else None,
                    backend_error=message if isinstance(message, str) and re.fullmatch(r'[A-Z][A-Z0-9_]{1,120}', message) else 'REDACTED_ERROR')

        phase = 'hosted_identity'
        http, identity = request('/auth/v1/user')
        result['identity_http_status'] = http
        if http != 200 or identity.get('id') != IDENTITIES[participant]:
            raise ValueError('HOSTED_IDENTITY_NOT_CONFIRMED')
        result['authenticated_user_id'] = identity['id']
        if reported_case:
            checks = [('get_my_route_resolution', {'p_route': V2}, 'reported_owner'),
                      ('list_my_route_resolution_cases', {}, 'reported_cases'),
                      ('get_my_route_resolution_receipt', {'p_request': report_request}, 'report_receipt'),
                      ('get_my_authorized_route', {'p_route': V2}, 'v2'),
                      ('get_my_authorized_route', {'p_route': V3}, 'v3'),
                      ('list_my_vehicles', {}, 'fleet')]
        elif participant == 'ngo':
            checks = [('get_my_route_resolution', {'p_route': V2}, 'owner'),
                      ('list_my_route_resolution_cases', {}, 'cases'),
                      ('get_my_authorized_route', {'p_route': V2}, 'v2'),
                      ('get_my_authorized_route', {'p_route': V3}, 'v3'),
                      ('get_my_donation_route_resolution', {'p_donation': TEST10}, 'denied'),
                      ('get_my_donation_route_resolution', {'p_donation': ABSENT}, 'denied')]
        else:
            owned = [TEST10, TESTC] if participant == 'donor-a' else [TEST42]
            foreign = TEST42 if participant == 'donor-a' else TEST10
            checks = [('get_my_donation_route_resolution', {'p_donation': d}, 'donor') for d in owned]
            checks += [('get_my_donation_route_resolution', {'p_donation': foreign}, 'denied'),
                       ('get_my_donation_route_resolution', {'p_donation': ABSENT}, 'denied')]
        for rpc, params, expected in checks:
            phase = rpc
            http, value = request('/rest/v1/rpc/' + rpc, params)
            entry = dict(rpc=rpc, parameters=params, http_status=http,
                         result=sanitize(value) if 200 <= http < 300 else value)
            result['calls'].append(entry)
            if expected == 'denied':
                valid = http == 403 and value.get('sqlstate_or_code') == '42501' and value.get('backend_error') == 'DONATION_NOT_FOUND_OR_FORBIDDEN'
            else:
                valid = http == 200 and isinstance(value, dict)
                if expected in ('owner', 'cases'):
                    valid = valid and value.get('contract') == 'geolock.route-resolution.v1'
                if expected == 'owner':
                    valid = valid and value.get('route_id') == V2 and value.get('enabled') is expect_enabled and value.get('status') == 'NOT_REPORTED'
                if expected == 'cases':
                    valid = valid and value.get('cases') == []
                if expected == 'reported_owner':
                    expected_items = {
                        '0cc74890-12b8-418f-a926-080f22602b51': ('73f345b8-c293-454e-8bea-16d91019fc3c', 'DISPATCHED'),
                        '8f5e5c00-aa15-4320-90ba-5db388ca9f14': ('7d5838a7-efd7-406e-9af7-5f71ea91b92c', 'NEVER_STARTED'),
                        '2d04a341-2929-4dfe-b75a-c639e00a558c': ('305d3708-43ca-4776-af9f-ee5afe67e9b8', 'NEVER_STARTED')}
                    items = value.get('items', [])
                    valid = valid and value.get('contract') == 'geolock.route-resolution.v1'
                    valid = valid and value.get('route_id') == V2 and value.get('case_id') == reported_case
                    valid = valid and type(value.get('version')) is int and value['version'] == 1
                    valid = valid and value.get('status') == 'AWAITING_EVIDENCE' and value.get('is_owner') is True
                    valid = valid and value.get('enabled') is expect_enabled and value.get('vehicle_confirmed') in (None, False)
                    valid = valid and 'vehicle_confirmed' in value and len(items) == 3
                    valid = valid and {x.get('task_id') for x in items} == set(expected_items)
                    valid = valid and all((x.get('claim_id'), x.get('initial_class')) == expected_items.get(x.get('task_id'))
                        and all(k in x and x[k] is None for k in ['my_assertion','ngo_assertion','source_assertion']) for x in items)
                if expected == 'reported_cases':
                    cases = value.get('cases', [])
                    valid = valid and value.get('contract') == 'geolock.route-resolution.v1' and len(cases) == 1
                    valid = valid and cases[0].get('case_id') == reported_case and cases[0].get('route_id') == V2
                    valid = valid and cases[0].get('version') == 1 and cases[0].get('status') == 'AWAITING_EVIDENCE'
                if expected == 'report_receipt':
                    valid = valid and value.get('outcome') == 'FOUND' and value.get('request_id') == report_request
                    valid = valid and value.get('result') == {
                        'contract':'geolock.route-resolution.v1','case_id':reported_case,'route_id':V2,
                        'version':1,'status':'AWAITING_EVIDENCE'}
                if expected == 'fleet':
                    vehicles = value.get('vehicles', [])
                    selected = [v for v in vehicles if v.get('vehicle_id') == 'c5c1836c-9d55-4004-8851-0f4ecf6d0f32']
                    valid = valid and len(selected) == 1 and selected[0].get('ngo_user_id') == NGO
                    valid = valid and selected[0].get('vehicle_label') == 'V2' and selected[0].get('vehicle_version') == 1
                    valid = valid and selected[0].get('active_flag') is True and selected[0].get('eligible_for_planning') is False
                if expected in ('v2', 'v3'):
                    valid = valid and value.get('route_id') == params['p_route']
                    valid = valid and value.get('route_status') == ('IN_PROGRESS' if expected == 'v2' else 'COMPLETED')
                    valid = valid and value.get('can_close') is False and value.get('can_cancel') is False
                    valid = valid and all(s.get('can_start') is False and s.get('can_complete') is False for s in value.get('stops', []))
                    valid = valid and [s.get('task_status') for s in value.get('stops', [])] == (['DISPATCHED','PLANNED','PLANNED'] if expected == 'v2' else ['COLLECTED'] * 3)
                if expected == 'donor':
                    valid = valid and value.get('contract') == 'geolock.donor-route-resolution.v1' and value.get('donation_id') == params['p_donation'] and value.get('enabled') is expect_enabled
                    valid = valid and not any(c.get('can_submit_evidence') is True for c in value.get('contexts', []))
            entry['expected_result_pass'] = bool(valid)
            if not valid:
                raise ValueError('READ_RESULT_REQUIRES_REVIEW')
        # Recheck the device still holds the selected identity, without a network refresh.
        phase = 'session_identity_retained'
        if phone.phone_session(IDENTITIES[participant]) != token:
            raise ValueError('PHONE_SESSION_CHANGED')
        result['status'] = 'AUTHENTICATED READ-ONLY PASS'
    except Exception as error:
        result.update(status='HOLD / STOP / NO RETRY', failed_phase=phase,
                      exception_type=type(error).__name__)
        if isinstance(error, ValueError) and str(error) in {
            'HOSTED_IDENTITY_NOT_CONFIRMED','READ_RESULT_REQUIRES_REVIEW','PHONE_SESSION_CHANGED',
            'READ_ENDPOINT_NOT_ALLOWED','RESPONSE_TOO_LARGE'}:
            result['error_code'] = str(error)
        # No raw exception, headers, auth response or token is persisted.
    directory = ROOT / 'results/reconciliation-hosted-readonly' / (
        datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:6])
    directory.mkdir(parents=True, exist_ok=False)
    (directory / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps({'status': result['status'], 'evidence_directory': str(directory),
                      'failed_phase': result.get('failed_phase'), 'calls': result['calls']}))
    return 0 if result['status'] == 'AUTHENTICATED READ-ONLY PASS' else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--participant', choices=tuple(IDENTITIES), default='ngo')
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--approval-ref')
    parser.add_argument('--expect-enabled', action='store_true',
                        help='Expect an already enabled backend; this changes no server configuration.')
    parser.add_argument('--reported-case', type=lambda value: str(uuid.UUID(value)))
    parser.add_argument('--report-request', type=lambda value: str(uuid.UUID(value)))
    args = parser.parse_args()
    if bool(args.reported_case) != bool(args.report_request):
        parser.error('Post-report reads require both existing case and persisted request IDs.')
    if args.reported_case and (args.participant != 'ngo' or not args.expect_enabled):
        parser.error('Post-report mode requires the NGO and an explicitly expected enabled backend.')
    if not args.run:
        print(json.dumps({'status':'LOCAL READ ALLOWLIST READY','connection_attempted':False,'rpcs':sorted(READ_RPCS)}))
    elif not args.approval_ref:
        parser.error('Explicit read-only approval reference required.')
    else:
        raise SystemExit(run(args.participant, args.approval_ref, args.expect_enabled,
                             args.reported_case, args.report_request))
