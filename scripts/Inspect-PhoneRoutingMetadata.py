"""Read only: retain explicitly allowlisted routing metadata, never auth prefs."""
import json
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

ADB = r'C:\Users\User\AppData\Local\Android\Sdk\platform-tools\adb.exe'
PACKAGE = 'com.example.geolock_hub_app'
allowed = set('request_id policy_id vehicle_ids status intent phase snapshot_id candidate_id authorization_request_id authorization route_ids departure_mode owner route_id version attempt history id kind task_id outcome last_completed_task_id error_code http_status failure_code archived_at'.split())

def sanitize(value):
    if isinstance(value, dict):
        return {k: sanitize(v) for k, v in value.items() if k in allowed}
    if isinstance(value, list):
        return [sanitize(v) for v in value]
    return value

def main():
    result = subprocess.run([ADB, 'shell', 'run-as', PACKAGE, 'cat',
        'shared_prefs/FlutterSharedPreferences.xml'], capture_output=True)
    if result.returncode:
        raise SystemExit('Phone preference read failed; no raw output retained.')
    root = ET.fromstring(result.stdout)
    records = []
    identities = []
    for item in root:
        key = item.get('name', '')
        if 'rcgyuwiidqvrgbxswhqj' in key and 'auth-token' in key:
            try:
                session = json.loads(item.text or '{}')
                user = session.get('user', {}) if isinstance(session, dict) else {}
                if isinstance(user, dict) and user.get('id'):
                    identities.append({'user_id': user['id'], 'email': user.get('email'),
                                       'note': 'Persisted session identity; token validity not tested'})
            except (ValueError, TypeError):
                pass
        if not key.startswith(('flutter.ngo_route_operation_', 'flutter.ngo_route_execution_',
                               'flutter.ngo_planning_')):
            continue
        try:
            records.append({'preference_key': key, 'metadata': sanitize(json.loads(item.text or '{}'))})
        except (ValueError, TypeError):
            records.append({'preference_key': key, 'parse_status': 'UNREADABLE'})
    target = Path('results/ngo-routing-hold-review-20261030/phone-routing-metadata.json')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps({'database_writes': False, 'preferences_changed': False,
                                 'persisted_session_identities': identities,
                                 'records': records}, indent=2), encoding='utf-8')
    print(json.dumps({'status': 'SANITIZED METADATA CAPTURED', 'records': len(records), 'file': str(target)}))

if __name__ == '__main__':
    main()
