"""Explicit NGO-protected read-only inventory; no claim/planning/write endpoints."""
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
V3 = '604d6303-ff33-4cdb-a37a-4442f5005f8f'
ALLOWED = {'list_my_vehicles', 'get_my_claim_cards_v2', 'get_my_routing_overview',
           'discover_eligible_listing_cards', 'get_eligible_listing_constituents',
           'get_claimed_listing_detail'}
sp = importlib.util.spec_from_file_location('existing_pilot_phone', ROOT / 'scripts/Run-ExactV3Pilot.py')
phone = importlib.util.module_from_spec(sp)
sp.loader.exec_module(phone)


class ReadHttp(JsonHttp):
    identity = None
    fleet = None

    def request(self, url, **kwargs):
        check(url == BASE + '/auth/v1/user' or url in {BASE + '/rest/v1/rpc/' + n for n in ALLOWED},
              'EXISTING_PILOT_READ_NOT_ALLOWED')
        value = super().request(url, **kwargs)
        if url.endswith('/auth/v1/user'):
            self.identity = {k: value.get(k) for k in ('id', 'email')}
        if url.endswith('/rpc/list_my_vehicles'):
            self.fleet = value
        return value


def select(row, keys):
    return {k: row.get(k) for k in keys.split()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', action='store_true')
    args = parser.parse_args()
    if not args.run:
        print(encode({'status': 'LOCAL READONLY PACKAGE READY', 'connection_attempted': False}))
        return
    result = dict(observed_at=datetime.now(timezone.utc).isoformat(), business_writes=False,
                  status='READONLY CAPTURE IN PROGRESS')
    phase = 'phone_session'
    try:
        token = phone.phone_session(OWNER)
        source = (ROOT / 'frontend/geolock_hub_app/lib/supabase_config.dart').read_text(encoding='utf-8')
        key = re.search(r"'(sb_publishable_[A-Za-z0-9_-]+)'", source).group(1)
        http = ReadHttp()
        phase = 'authenticated_identity_and_fleet'
        session = SupabaseAuth(key, http).verify('Bearer ' + token)
        check(session.user_id == OWNER, 'EXISTING_PILOT_WRONG_NGO')
        result['identity'] = http.identity
        result['v3'] = [select(v, 'vehicle_id ngo_user_id vehicle_label active_flag available_for_planning eligible_for_planning payload_capacity_kg max_route_duration_min depot_road_node_id vehicle_version')
                        for v in http.fleet['vehicles'] if v['vehicle_id'] == V3]

        def read(name, params=None):
            check(name in ALLOWED, 'EXISTING_PILOT_READ_NOT_ALLOWED')
            return http.request(BASE + '/rest/v1/rpc/' + name, token=token, key=key, body=params or {})

        phase = 'protected_overview'
        overview = read('get_my_routing_overview')
        check(overview.get('ngo_id') == OWNER, 'EXISTING_PILOT_WRONG_NGO')
        result['overview'] = {k: overview.get(k) for k in ('contract', 'ngo_id', 'server_now', 'policy_id', 'authorization_enforced', 'eligible_tasks')}
        phase = 'owned_claim_cards'
        cards = read('get_my_claim_cards_v2')
        result['claims'] = [select(c, 'claim_id listing_id claim_status claimed_at lease_id lease_status lease_expires_at task_status source_type listing_weight_kg title server_now lease_is_expired lease_recovery_pending') for c in cards]
        phase = 'protected_discovery'
        discovered = read('discover_eligible_listing_cards')
        result['available'] = [select(d, 'listing_id donation_id source_type title listing_weight_kg listing_created_at collection_path distance_m routing_status') for d in discovered]
        phase = 'bounded_constituent_reads'
        candidates = [d for d in discovered if d.get('source_type') == 'DIRECT_DONATION'
                      and d.get('collection_path') == 'DIRECT_PICKUP'
                      and 10 <= float(d.get('listing_weight_kg') or 0) <= 600]
        candidates.sort(key=lambda d: (not any(w in (d.get('title') or '').lower() for w in ('test', 'synthetic', 'fyp')), float(d.get('distance_m') or 999999)))
        result['available_details'] = []
        for candidate in candidates[:6]:
            members = read('get_eligible_listing_constituents', {'p_listing': candidate['listing_id']})
            result['available_details'].append({'listing_id': candidate['listing_id'], 'members': [select(m, 'donation_id title total_weight_kg donation_status') for m in members]})
        phase = 'bounded_owned_location_reads'
        admitted = {t['claim_id']: t for t in overview['eligible_tasks']}
        result['claimed_details'] = []
        for card in [c for c in cards if c['claim_id'] in admitted][:6]:
            detail = read('get_claimed_listing_detail', {'p_claim': card['claim_id']})
            result['claimed_details'].append({'claim_id': card['claim_id'], 'detail': select(detail, 'claim_id listing_id donation_id title listing_status source_type pickup_address pickup_latitude pickup_longitude pickup_road_node_id listing_expires_at availability_start availability_end')})
        result['status'] = 'READONLY CAPTURE COMPLETE / REVIEW REQUIRED'
    except Exception as error:
        result.update(status='READONLY CAPTURE INCOMPLETE / STOP', failed_phase=phase,
                      exception_category=type(error).__name__,
                      error_code=error.code if isinstance(error, WorkerError) else 'EXISTING_PILOT_READ_FAILED')
    directory = ROOT / 'results/existing-v3-donations' / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:6])
    directory.mkdir(parents=True, exist_ok=False)
    (directory / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(encode({'status': result['status'], 'evidence_directory': str(directory),
                  'failed_phase': result.get('failed_phase'), 'error_code': result.get('error_code')}))
    if 'INCOMPLETE' in result['status']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
