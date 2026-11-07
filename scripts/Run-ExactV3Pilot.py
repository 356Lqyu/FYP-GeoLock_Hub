"""Separately approved operator stages; default is LOCAL validation only.

The connected debug app's DEV JWT is read in memory, sent only to the loopback
planner and never printed, persisted, hashed or passed on a command line.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from backend.routing.worker_service.errors import WorkerError, check
from backend.routing.worker_service.staged import ExactRouteWorkflow
from backend.routing.worker_service.staged_client import StagedPilotClient
from backend.routing.worker_service.transport import NoRedirect, encode

PROJECT = 'rcgyuwiidqvrgbxswhqj'
MANIFEST = ROOT / 'docs/stage8/functional-routing/V3_EXACT_ROUTE_PILOT.proposed.json'


def phone_session(owner):
    adb = Path(os.environ['LOCALAPPDATA']) / 'Android/Sdk/platform-tools/adb.exe'
    devices = subprocess.run([str(adb), 'devices'], capture_output=True, timeout=8)
    check(devices.returncode == 0, 'EXACT_PHONE_UNAVAILABLE')
    serials = re.findall(rb'^([^\s]+)\s+device\s*$', devices.stdout, re.M)
    check(len(serials) == 1, 'EXACT_ONE_AUTHORIZED_PHONE_REQUIRED')
    result = subprocess.run([str(adb), '-s', serials[0].decode(), 'shell', 'run-as',
                             'com.example.geolock_hub_app', 'cat',
                             'shared_prefs/FlutterSharedPreferences.xml'], capture_output=True, timeout=8)
    check(result.returncode == 0, 'EXACT_PHONE_SESSION_READ_FAILED')
    sessions = []
    for item in ET.fromstring(result.stdout):
        key = item.get('name', '')
        if PROJECT in key and 'auth-token' in key:
            session = json.loads(item.text or '{}')
            if session.get('user', {}).get('id') == owner:
                sessions.append(session)
    check(len(sessions) == 1 and isinstance(sessions[0].get('access_token'), str),
          'EXACT_MATCHING_DEV_SESSION_REQUIRED')
    return sessions[0]['access_token']  # Server independently verifies it.


def health(ports=(8787, 8788)):
    for port in ports:
        with urllib.request.build_opener(NoRedirect()).open(
                f'http://127.0.0.1:{port}/health', timeout=5) as response:
            value = json.loads(response.read(4096))
            check(response.status == 200 and value.get('status') == 'ACTIVE'
                  and value.get('project_ref') == PROJECT, 'EXACT_SERVICE_NOT_ACTIVE')


def call_with_token(token, path, body):
    check(path in ('/v1/exact-route-plan', '/v1/exact-route-authorize', '/v1/authorization-result'),
          'EXACT_ENDPOINT_NOT_ALLOWED')
    request = urllib.request.Request('http://127.0.0.1:8787' + path,
        data=encode(body).encode(), headers={'Authorization': 'Bearer ' + token,
                                           'Content-Type': 'application/json'})
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=180) as response:
            raw = response.read(8_000_001)
            check(len(raw) <= 8_000_000, 'EXACT_RESPONSE_TOO_LARGE')
            return json.loads(raw)
    except urllib.error.HTTPError as error:
        try:
            code = json.loads(error.read(65536)).get('error', {}).get('code', '')
        except Exception:
            code = ''
        # Fixed enum-like service code only; never raw exception or HTTP content.
        code = code if re.fullmatch(r'[A-Z][A-Z0-9_]{1,99}', code) else 'EXACT_HTTP_REJECTED'
        raise WorkerError(code, error.code) from None
    except WorkerError:
        raise
    except Exception:
        raise WorkerError('EXACT_HTTP_OUTCOME_UNCERTAIN', 503) from None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', choices=('check-local', 'plan', 'authorize', 'reconcile'), default='check-local')
    parser.add_argument('--approval-ref')
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text(encoding='utf-8'))
    scope = ExactRouteWorkflow.scope(manifest['scope'])
    if args.stage == 'check-local':
        print(encode(dict(status='LOCAL PACKAGE CHECK PASS', request_id=manifest['request_id'],
                          task_count=len(scope['task_ids']), connection_attempted=False)))
        return
    check(bool(args.approval_ref and args.approval_ref.strip()), 'EXPLICIT_STAGE_APPROVAL_REQUIRED')
    # A receipt read must remain possible when the validator is offline.
    health((8787,) if args.stage == 'reconcile' else (8787, 8788))
    token = phone_session(scope['ngo_id'])
    directory = Path(os.environ['LOCALAPPDATA']) / 'GeoLockHubRoutingDev/exact-pilot-client'
    client = StagedPilotClient(directory, manifest['request_id'], scope,
                               lambda path, body: call_with_token(token, path, body))
    result = getattr(client, args.stage)()
    # Full result/receipt is retained by the client journal. CLI exposes only IDs
    # and route summary; no JWT, credential, personal address or raw error.
    print(encode({k: result[k] for k in ('kind', 'ngo_id', 'request_id', 'snapshot_id',
        'candidate_id', 'authorization_request_id', 'validation_status', 'authorization',
        'presentation', 'operation_terminal', 'failure_code') if k in result}))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(encode(dict(status='STOP / NO RETRY',
            error_code=error.code if isinstance(error, WorkerError) else 'EXACT_OPERATOR_CHECK_FAILED',
            exception_category=type(error).__name__)))
        raise SystemExit(1)
