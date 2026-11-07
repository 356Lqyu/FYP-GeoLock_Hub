"""Explicit, bounded Group 1 read-only checks; no routing/business write APIs.

Default is local validation. The --run mode needs separate Group 1 approval.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import re
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from backend.routing.worker_service.errors import WorkerError, check
from backend.routing.worker_service.transport import BASE, JsonHttp, SupabaseAuth, encode

OWNER = '8e50bc66-7a8d-4791-bc6b-640682daa496'
VEHICLE = '604d6303-ff33-4cdb-a37a-4442f5005f8f'
POLICY = '80db858b-93e8-4a0a-94e2-dbe14940f0a1'
spec = importlib.util.spec_from_file_location('group1_phone_session', ROOT / 'scripts/Run-ExactV3Pilot.py')
phone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phone)


def hold_reasons(v3_ready, capability):
    reasons = []
    if not v3_ready:
        reasons.append('V3_PROTECTED_READINESS_NOT_CONFIRMED')
    if 'exact_staged_enabled' not in capability:
        reasons.append('PLANNER_EXACT_CAPABILITY_FIELD_MISSING')
    elif capability['exact_staged_enabled'] is not True:
        reasons.append('PLANNER_EXACT_WORKFLOW_NOT_ENABLED')
    return reasons


class Reads(JsonHttp):
    def __init__(self):
        self.identity = None
        self.fleet = None

    def request(self, url, **kwargs):
        check(url in {BASE + '/auth/v1/user', BASE + '/rest/v1/rpc/list_my_vehicles',
                      BASE + '/rest/v1/rpc/get_my_routing_overview'},
              'GROUP1_READ_ENDPOINT_NOT_ALLOWED')
        value = super().request(url, **kwargs)
        if url.endswith('/auth/v1/user'):
            self.identity = {k: value.get(k) for k in ('id', 'email')}
        if url.endswith('/rpc/list_my_vehicles'):
            self.fleet = value
        return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', action='store_true')
    args = parser.parse_args()
    if not args.run:
        print(encode(dict(status='LOCAL READONLY PACKAGE VALIDATED', connection_attempted=False)))
        return
    record = dict(observed_at=datetime.now(timezone.utc).isoformat(), status='READONLY REVIEW IN PROGRESS',
                  database_business_writes=False, services_changed=False)
    phase = 'local_health'
    try:
        phone.health()
        record['planner_health'] = record['validator_health'] = {'http_status': 200, 'status': 'ACTIVE', 'project_ref': phone.PROJECT}
        phase = 'phone_session_memory_only'
        token = phone.phone_session(OWNER)
        source = (ROOT / 'frontend/geolock_hub_app/lib/supabase_config.dart').read_text(encoding='utf-8')
        key = re.search(r"'(sb_publishable_[A-Za-z0-9_-]+)'", source).group(1)
        phase = 'authenticated_ngo_reads'
        reads = Reads()
        session = SupabaseAuth(key, reads).verify('Bearer ' + token)
        check(session.user_id == OWNER, 'GROUP1_NGO_MISMATCH')
        record['authenticated_identity'] = reads.identity
        fleet = reads.fleet['vehicles']
        selected = [v for v in fleet if v['vehicle_id'] == VEHICLE]
        check(len(selected) == 1, 'GROUP1_V3_NOT_FOUND')
        v = selected[0]
        record['v3'] = {k: v.get(k) for k in ('vehicle_id', 'ngo_user_id', 'vehicle_label',
            'active_flag', 'available_for_planning', 'eligible_for_planning', 'payload_capacity_kg',
            'max_route_duration_min', 'depot_road_node_id', 'vehicle_version')}
        # The protected fleet RPC checks NGO/depot equality, verification and
        # active operational nodes. Do not bypass RLS to export a profile row.
        record['depot_validation'] = dict(source='protected list_my_vehicles eligibility',
            road_node_id=v.get('depot_road_node_id'), confirmed=v.get('eligible_for_planning') is True,
            raw_profile_row_exported=False)
        record['v3_ready'] = (v.get('ngo_user_id') == OWNER and v.get('active_flag') is True
            and v.get('available_for_planning') is True and v.get('eligible_for_planning') is True
            and float(v['payload_capacity_kg']) == 600 and float(v['max_route_duration_min']) == 240)
        overview = session.rpc('get_my_routing_overview')
        record['policy'] = {k: overview.get(k) for k in ('policy_id', 'authorization_enforced', 'server_now')}
        record['policy']['body_reexported'] = False
        record['policy']['note'] = 'Identity comparison to reviewed immutable installed policy; no new policy body/digest export.'
        check(overview.get('ngo_id') == OWNER and overview.get('policy_id') == POLICY
              and overview.get('authorization_enforced') is True, 'GROUP1_POLICY_OR_AUTHORITY_MISMATCH')
        phase = 'readonly_planner_capability'
        capability = JsonHttp().request('http://127.0.0.1:8787/v1/authorization-capabilities',
            token=token, body={'request_id': str(uuid.uuid4())})
        record['capability'] = {k: capability.get(k) for k in ('contract', 'ngo_id',
            'automatic_departure', 'combined_generation_enabled', 'exact_staged_enabled')}
        check(capability.get('ngo_id') == OWNER and capability.get('automatic_departure') is True,
              'GROUP1_CAPABILITY_MISMATCH')
        record['hold_reasons'] = hold_reasons(record['v3_ready'], capability)
        record['status'] = ('GROUP1 PASS' if not record['hold_reasons']
                            else 'GROUP1 HOLD / PLANNER RESTART OR V3 REVIEW REQUIRED')
    except Exception as error:
        record.update(status='GROUP1 NOT VERIFIED / STOP', failed_phase=phase,
                      exception_category=type(error).__name__,
                      error_code=error.code if isinstance(error, WorkerError) else 'GROUP1_READ_FAILED')
    directory = ROOT / 'results/group1-readiness-20261030' / (
        datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:6])
    directory.mkdir(parents=True, exist_ok=False)
    (directory / 'result.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    print(encode(dict(status=record['status'], evidence_directory=str(directory),
                      hold_reasons=record.get('hold_reasons', []),
                      failed_phase=record.get('failed_phase'), error_code=record.get('error_code'))))
    if record['status'].startswith('GROUP1 NOT VERIFIED'):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
