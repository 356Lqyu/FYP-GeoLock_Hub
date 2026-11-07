"""Approved bounded protected reads and read-only local journal inspection."""
import json
import os
from pathlib import Path
import re
import sqlite3
import sys

import importlib.util

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('inventory', ROOT / 'scripts/Inspect-ExistingV3Donations.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

if __name__ == '__main__':
    if sys.argv[1:] != ['--run']:
        print('LOCAL ONLY; explicit --run required')
        raise SystemExit(0)
    directory = ROOT / 'results/existing-v3-donations/20261030T113253Z-05a3bc'
    capture = json.loads((directory / 'result.json').read_text())
    token = m.phone.phone_session(m.OWNER)
    source = (ROOT / 'frontend/geolock_hub_app/lib/supabase_config.dart').read_text(encoding='utf-8')
    key = re.search(r"'(sb_publishable_[A-Za-z0-9_-]+)'", source).group(1)
    http = m.JsonHttp()
    details = []
    def scrub(value):
        if isinstance(value, dict):
            return {k: scrub(v) for k, v in value.items() if not any(x in k.lower() for x in ('photo', 'image', 'token', 'key'))}
        if isinstance(value, list):
            return [scrub(v) for v in value]
        return value
    for task in capture['overview']['eligible_tasks']:
        assert task['title'] in ('test', 'Book', 'Can')
        row = {'claim_id': task['claim_id']}
        for name in ('get_claimed_listing_detail', 'get_claimed_listing_constituents'):
            row[name] = scrub(http.request(m.BASE + '/rest/v1/rpc/' + name,
                token=token, key=key, body={'p_claim': task['claim_id']}))
        details.append(row)
    (directory / 'protected-claim-details.json').write_text(json.dumps(details, indent=2), encoding='utf-8')
    journals = []
    old_request = 'f4b11fd8-c8b3-4092-beb2-6da8d12be38e'
    base = Path(os.environ['LOCALAPPDATA']) / 'GeoLockHubRoutingDev'
    for path in base.rglob('jobs.sqlite3'):
        db = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)
        try:
            db.execute('PRAGMA query_only=ON')
            steps = db.execute('SELECT name FROM steps WHERE snapshot=? ORDER BY name', (old_request,)).fetchall()
            jobs = db.execute('SELECT count(*) FROM jobs WHERE request=? OR snapshot=?', (old_request,old_request)).fetchone()[0]
            journals.append({'path': str(path), 'request_id': old_request, 'step_names': [x[0] for x in steps], 'jobs_count': jobs})
        finally:
            db.close()
    (directory / 'journal-scope-review.json').write_text(json.dumps(journals, indent=2), encoding='utf-8')
    print(json.dumps({'status': 'READONLY DETAILS COMPLETE', 'claims': len(details), 'journals': journals}))
