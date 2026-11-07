"""Reproducibly embed captured DEV bodies; no database client or credentials."""
from pathlib import Path
import hashlib
import json

HERE = Path(__file__).resolve().parent


def build():
    evidence = json.loads((HERE / 'dev-preparation-evidence.json').read_text())
    assert evidence['project_ref'] == 'rcgyuwiidqvrgbxswhqj'
    chunks = []
    pins = {}
    for name in ('start_pickup', 'complete_pickup', 'assign_task_to_route'):
        source = next(r['definition'] for r in evidence['functions'] if r['name'] == name)
        pins[name] = hashlib.sha256(source.encode()).hexdigest()
        if name == 'assign_task_to_route':
            continue
        source = source.replace('FUNCTION public.' + name, 'FUNCTION routing_private.legacy_' + name, 1)
        source = source.replace("SET search_path TO 'public', 'extensions', 'pg_temp'", "SET search_path TO 'pg_catalog', 'pg_temp'")
        source = source.replace("SET search_path TO 'pg_catalog', 'pg_temp'", "SET search_path TO 'pg_catalog', 'pg_temp'\n SET timezone TO 'UTC'\n SET extra_float_digits TO '0'")
        chunks.append(source + ';\n')
    (HERE / 'expected-lifecycle-source-hashes.json').write_text(json.dumps(pins, indent=2) + '\n')
    target = HERE / '003_pickup_enforcement_proposal.sql'
    prefix = target.read_text().split('-- LEGACY_BODIES_AND_COMMIT')[0]
    with target.open('w', newline='\n') as handle:
        handle.write(prefix + '-- LEGACY_BODIES_AND_COMMIT\n' + '\n'.join(chunks))
        handle.write('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA routing_private FROM PUBLIC,anon,authenticated,service_role;\nCOMMIT;\n')


if __name__ == '__main__':
    build()
