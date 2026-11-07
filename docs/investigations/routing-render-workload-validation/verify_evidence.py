"""Read-only source/evidence checks and a new local seal; never reseal old evidence."""
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def main():
    previous = read(ROOT/'docs/investigations/routing-render-docker-validation/SHA256.json')
    changed = [p for p, value in previous.items() if sha(ROOT/p) != value]
    expected = {
        'docs/investigations/ROUTING_RENDER_IMPLEMENTATION_READINESS.md',
        'docs/investigations/routing-render-docker-validation/MEASUREMENTS.md',
    }
    assert set(changed) == expected, changed
    hosted = read(ROOT/'docs/investigations/routing-render-implementation/IMPLEMENTATION_SHA256.json')
    sources = [p for p in hosted if p.startswith('backend/')]
    assert all(sha(ROOT/p) == hosted[p] for p in sources)
    manifest = read(HERE/'run2/WORKLOAD_MANIFEST.json')
    graph = ROOT/'results/worker-readiness/20261027T083653Z-5f56bb/graphs/eab1f7ee-a8e0-4bed-a0e1-2c4bff024936.jsonl'
    assert sha(graph) == manifest['graph_file_sha256']
    assert sha(ROOT/'experiments/repro_inputs/v33/road_nodes.csv') == manifest['source_road_nodes_sha256']
    assert sha(ROOT/'docs/investigations/routing-render-docker-validation/frozen-v33-sample.json') == manifest['source_frozen_fixture_sha256']
    assert manifest['legacy_csr_parity'] is True
    assert all(c['operational_approval'] is None and not c['observed_real_world_demand'] for c in manifest['cases'])
    rows = read(HERE/'run2/receipts.json')
    assert len(rows) == 34
    for row in rows:
        limits = row['limits']
        assert limits['NetworkMode'] == 'none' and limits['ReadonlyRootfs']
        assert limits['Memory'] == limits['MemorySwap']
    planner = [r for r in rows if r['label'].endswith('-planner')]
    validator = [r for r in rows if r['label'].endswith('-validator')]
    assert len(planner) == len(validator) == 16
    assert sum(r['external_timeout'] for r in rows) == 1
    assert not any(r['oom'] for r in rows)
    assert sum('result' in r for r in planner) == 15
    assert all(r['result']['all_plans_valid'] for r in planner if 'result' in r)
    assert read(HERE/'RESULTS_SUMMARY.json')['validators_all_valid']
    receipt = {
        'verified_at_utc': datetime.now(timezone.utc).isoformat(),
        'source_checks': 'PASS',
        'prior_sealed_files_checked': len(previous),
        'intentionally_updated_prior_reports': changed,
        'unchanged_hosted_source_files': len(sources),
        'graph_and_frozen_inputs_hashes_match': True,
        'full_100_node_legacy_compact_matrix_parity': True,
        'resource_cases': len(rows), 'planner_cases': len(planner), 'validator_cases': len(validator),
        'external_timeouts': 1, 'oom_kills': 0,
        'scope': 'OFFLINE_MODELED_ONLY_NOT_DB_AUTHORIZATION_OR_PRODUCTION_QUALIFICATION',
        'postgres_journal_redesign': 'DESIGN_ONLY_NOT_IMPLEMENTED',
        'decision': 'NO-GO FOR DEPLOYMENT; REVIEW BOUNDED FYP HOSTING CHOICE',
    }
    (HERE/'VERIFICATION_SUMMARY.json').write_text(json.dumps(receipt, indent=2)+'\n', encoding='utf-8')
    paths = [p for p in HERE.rglob('*') if p.is_file() and p.name != 'SHA256.json' and '__pycache__' not in p.parts]
    paths += [ROOT/p for p in expected]
    paths += [ROOT/'docs/investigations/ROUTING_HOSTING_RECOVERY_OPTIONS.md']
    seals = {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted(paths)}
    (HERE/'SHA256.json').write_text(json.dumps(seals, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(dict(receipt, newly_sealed_files=len(seals)), indent=2))


if __name__ == '__main__':
    main()
