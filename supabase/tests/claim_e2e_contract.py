"""Local contract assertions only. This module never opens a connection."""
from __future__ import annotations

import hashlib
import json
import re
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / 'supabase/migrations/20261031_claim_audit_and_failure_capture.sql'
PACKAGE = ROOT / 'supabase/tests/review-only/stage3j/two_actor'
VERSION = 'geolock-claim-audit-v1'
REUSE_REASON = 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'
ROLLBACK_REASON = 'CLAIM_TRANSACTION_ROLLED_BACK'


def check(ok, message):
    if not ok:
        raise RuntimeError(message)


def source_functions():
    """Read actual local definitions, not the migration's pre-deployment guards."""
    source = MIGRATION.read_text(encoding='utf-8')
    pattern = re.compile(
        r'CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+public\.(\w+)\s*'
        r'\((.*?)\)\s*(.*?)\bAS\s+(\$\w*\$)(.*?)\4\s*;', re.I | re.S)
    result = []
    for m in pattern.finditer(source):
        name, arguments, header, _, body = m.groups()
        args = [re.sub(r'\s+', ' ', a.strip()) for a in arguments.split(',')]
        types = [a.split()[1].lower() for a in args]
        result_type = re.search(r'RETURNS\s+(.*?)(?=\s+LANGUAGE)', header, re.I | re.S)[1]
        path = re.search(r'SET\s+search_path\s*(?:TO|=)\s*(.*)', header, re.I | re.S)[1]
        result.append(dict(
            identity=f"{name}({','.join(types)})", owner='postgres',
            security_definer=bool(re.search(r'\bSECURITY\s+DEFINER\b', header, re.I)),
            config=['search_path=' + ', '.join(x.strip().strip("'") for x in path.strip().split(','))],
            body_md5=hashlib.md5(body.replace('\r\n', '\n').encode()).hexdigest(),
            arguments=', '.join(args), **{'return': re.sub(r'\s+', ' ', result_type.strip())}))
    check(len(result) == 9, 'Current migration must define exactly nine function signatures.')
    return sorted(result, key=lambda f: (f['identity'].split('(')[0], f['arguments']))


def validate_function_contract(actual):
    expected = json.loads((PACKAGE / 'approved_functions.json').read_text(encoding='utf-8'))
    # The saved local expectations must still agree with the authoritative source.
    by_id = {f['identity']: f for f in expected}
    for f in source_functions():
        check(by_id.get(f['identity']) == f, 'Saved expectations differ from current migration definitions.')
    check(len(actual or []) == len(expected), 'Missing, extra or overloaded contract functions.')
    actual_by_id = {f['identity']: f for f in actual}
    check(set(actual_by_id) == set(by_id), 'Function signature set differs from reviewed contract.')
    for identity, f in by_id.items():
        check({k: actual_by_id[identity].get(k) for k in f} == f,
              'Function source, arguments, owner, security or search path drift: ' + identity)


def validate_health(snapshot, baseline):
    validate_function_contract(snapshot['functions'])
    check(snapshot['other_functions_md5'] == baseline['other_functions_md5'],
          'Reviewed other-function fingerprint changed.')
    check({f['identity']: f.get('acl') for f in snapshot['functions']} == baseline['function_acls'],
          'Reviewed function EXECUTE ACLs changed.')
    jobs = {j['jobid']: j for j in snapshot['jobs']}
    check(set(jobs) == {1, 2, 3} and jobs[1]['active'] and jobs[2]['active']
          and not jobs[3]['active'] and snapshot['active_recovery_jobs'] == 0,
          'Eligibility jobs must be active and all recovery cron jobs must remain disabled.')
    check(snapshot['recovery_history'] == baseline['recovery_history']
          and baseline['recovery_history']['failed'] == 0
          and baseline['recovery_history']['unfinished'] == 0,
          'Reviewed recovery history changed or contains failures/unfinished runs.')
    check(snapshot['healthy_eligibility_jobs'] == 2 and snapshot['lease_minutes'] == 360
          and snapshot['unresolved_cases'] == 0 and snapshot['overdue_active_pairs'] == 0,
          'Worker health, lease policy, unresolved cases or overdue claims require review.')
    check(snapshot['failure_contract_ok'] is True, 'Failure ledger/index or private-helper permissions differ.')


def load_manifest(path, subjects, listings, donations, label, purpose):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    check(data.get('project_ref') == 'rcgyuwiidqvrgbxswhqj'
          and data.get('purpose') == purpose
          and isinstance(data.get('approval_ref'), str) and data['approval_ref'].strip()
          and isinstance(data.get('operator'), str) and data['operator'].strip(),
          'Reviewed DEV manifest, purpose, approval reference and operator required.')
    check(all('<' not in data[k] and '>' not in data[k] for k in ('approval_ref','operator','fixture_label')),
          'Manifest review/operator/label placeholders must be replaced.')
    check(len(subjects) == len(set(subjects)) and data.get('actor_ids') == subjects,
          'Manifest actors must exactly match distinct configured NGO subjects.')
    check(data.get('fixture_label') == label and label.startswith('STAGE3J-')
          and 10 <= len(label) <= 55, 'Dedicated manifest fixture label required.')
    fixtures = data.get('fixtures', [])
    check(fixtures == [dict(listing_id=l, donation_id=d) for l, d in zip(listings, donations)]
          and len(fixtures) == len(listings) == len(donations)
          and len(set(donations)) == len(donations), 'Manifest fixture mappings differ.')
    check(all(str(uuid.UUID(x)) == x for x in subjects + listings + donations),
          'Manifest identities must use canonical UUIDs.')
    baseline = data.get('health_baseline', {})
    check(baseline.get('migration_sha256') == hashlib.sha256(MIGRATION.read_bytes()).hexdigest(),
          'Manifest migration hash differs from current local source.')
    check(re.fullmatch('[0-9a-f]{32}', baseline.get('other_functions_md5', '')) is not None,
          'A separately reviewed other-function baseline is required; never auto-adopt it.')
    check(isinstance(baseline.get('function_acls'), dict)
          and isinstance(baseline.get('recovery_history'), dict)
          and set(baseline['recovery_history']) == {'total', 'failed', 'unfinished'}
          and all(type(v) is int and v >= 0 for v in baseline['recovery_history'].values()),
          'Reviewed ACL and recovery-history baselines required.')
    return data


def confirmed_receipt(status, result, reason=None):
    check(status == 200 and isinstance(result, dict),
          'UNCONFIRMED: no authoritative receipt; retain request UUID and inspect committed state.')
    check(result.get('outcome') == 'ERROR' and result.get('rollback_confirmed') is True
          and result.get('claim_id') is None and result.get('replayed') is False
          and result.get('reason_code') in (REUSE_REASON, ROLLBACK_REASON),
          'Malformed or unconfirmed failure receipt.')
    try:
        check(str(uuid.UUID(result['failure_audit_id'])) == result['failure_audit_id'],
              'Noncanonical failure receipt ID.')
    except (KeyError, ValueError, TypeError, AttributeError):
        raise RuntimeError('Missing or invalid failure receipt ID.') from None
    check(reason is None or result['reason_code'] == reason, 'Unexpected failure receipt reason.')
    return result


def classify(status, result):
    if status != 200 or not isinstance(result, dict):
        return 'UNCONFIRMED'
    if result.get('outcome') == 'ERROR':
        try:
            confirmed_receipt(status, result)
            return 'CONFIRMED_ROLLBACK'
        except RuntimeError:
            return 'UNCONFIRMED'
    if result.get('outcome') in ('CONFLICT', 'INELIGIBLE', 'REJECTED'):
        return 'BUSINESS_REJECTION'
    return 'SUCCESS' if result.get('outcome') == 'SUCCESS' else 'UNCONFIRMED'


def failure_record(receipt, rows, actor, listing, request, donation):
    matches = [r for r in rows if r.get('actor_user_id') == actor
               and r.get('request_id') == request and r.get('listing_id') == listing
               and r.get('operation_name') == 'claim_listing'
               and r.get('reason_code') == receipt['reason_code']]
    check(len(matches) == 1, 'Failure event missing or duplicate five-column deduplication key.')
    row = matches[0]; detail = row.get('details') or {}
    check(row.get('failure_id') == receipt['failure_audit_id']
          and row.get('actor_role') == 'NGO' and row.get('claim_id') is None
          and row.get('donation_id') == donation and bool(row.get('occurred_at'))
          and detail.get('rollback_confirmed') is True and detail.get('outcome') == 'ERROR'
          and detail.get('lease_id') is None and detail.get('correlation_id') == request
          and detail.get('software_version') == VERSION and bool(detail.get('transaction_id'))
          and bool(detail.get('sqlstate')), 'Failure event does not match its confirmed rollback receipt.')
    check('message' not in detail and 'error_message' not in detail,
          'Private error text must not enter failure receipts.')
    check('STAGE2_TEST_FAILPOINT:' not in json.dumps(row), 'Injected exception text leaked into durable failure evidence.')
    return row


def failure_append(before, after, failure_id):
    old = {r['failure_id']: r for r in before}
    current = {r['failure_id']: r for r in after}
    check(len(current) == len(after) == len(before)+1
          and set(current)-set(old) == {failure_id}
          and all(current.get(key) == value for key, value in old.items()),
          'Failure append changed historical evidence or added an unexpected deduplication key.')


def donation_link(event, attempt, claim, lease, actor, listing, donation):
    check(event.get('event_type') == 'DONATION_STATUS_CHANGED'
          and event.get('entity_type') == 'DONATION' and event.get('entity_id') == donation
          and event.get('actor_user_id') == actor and event.get('actor_role') == 'NGO'
          and event.get('claim_id') == claim and event.get('lease_id') == lease
          and event.get('request_id') == event.get('correlation_id') == attempt['request_id']
          and event.get('reason_code') == 'CLAIM_ACCEPTED' and event.get('outcome') == 'SUCCESS'
          and event.get('software_version') == VERSION and bool(event.get('configuration_version'))
          and event.get('previous_state') == 'AVAILABLE'
          and event.get('requested_state') == event.get('resulting_state') == 'CLAIMED'
          and event.get('details', {}).get('listing_id') == listing
          and event.get('details', {}).get('donation_id') == donation
          and bool(event.get('details', {}).get('transaction_id')),
          'Donation transition audit lacks exact claim/request/lease/actor linkage.')
