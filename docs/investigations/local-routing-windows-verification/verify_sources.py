"""Seal local selection evidence without changing any historical manifests."""
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    baseline = json.loads((ROOT/'docs/investigations/routing-render-implementation/BASELINE_SEALS.json').read_text())
    hashes = {p: digest(ROOT/p) for p in baseline}
    changes = [p for p in baseline if baseline[p] != hashes[p]]
    assert changes == ['backend/routing/worker_service/journal.py'], changes
    previous = json.loads((ROOT/'docs/investigations/routing-render-docker-validation/SHA256.json').read_text())
    assert hashes[changes[0]] == previous[changes[0]]
    hosted = json.loads((ROOT/'docs/investigations/routing-render-implementation/IMPLEMENTATION_SHA256.json').read_text())
    hosted_sources = [p for p in hosted if p.startswith('backend/')]
    assert all(digest(ROOT/p) == hosted[p] for p in hosted_sources)
    receipt = dict(verified_at_utc=datetime.now(timezone.utc).isoformat(),
        pre_hosting_source_files_checked=len(baseline), unchanged_pre_hosting_files=len(baseline)-len(changes),
        retained_prior_validated_journal_fix=changes,
        unchanged_hosted_source_files=len(hosted_sources), current_baseline_hashes=hashes,
        runtime_edits_in_this_review=False, database_access=False,
        outcome='LOCAL OFFLINE PASS / LIVE DB AND DEVICE OPERATION NOT TESTED')
    (HERE/'SOURCE_VERIFICATION.json').write_text(json.dumps(receipt, indent=2)+'\n')
    files = [
        'docs/LOCAL_ROUTING_WINDOWS.md',
        'docs/investigations/LOCAL_ROUTING_WINDOWS_VERIFICATION.md',
        'backend/routing/README.md', 'backend/routing/worker_service/README.md',
        'backend/routing/hosted/README.md',
        'backend/routing/worker_service/windows/Test-LocalRoutingSetup.ps1',
        'backend/routing/worker_service/windows/local_setup_check.py',
        'docs/investigations/ROUTING_RENDER_IMPLEMENTATION_READINESS.md',
        'docs/investigations/ROUTING_RENDER_DEPLOYMENT_GUIDE.md',
        'docs/investigations/ROUTING_RENDER_ARCHITECTURE_REVIEW.md',
        'docs/investigations/ROUTING_GRAPH_MEMORY_AND_FREE_HOSTING_REVIEW.md',
        'docs/investigations/ROUTING_HOSTING_RECOVERY_OPTIONS.md',
    ]
    paths = [ROOT/p for p in files]
    paths += [p for p in HERE.iterdir() if p.is_file() and p.name != 'SHA256.json']
    seals = {p.relative_to(ROOT).as_posix(): digest(p) for p in sorted(paths)}
    (HERE/'SHA256.json').write_text(json.dumps(seals, indent=2)+'\n')
    print(json.dumps(dict(receipt, sealed_review_files=len(seals)), indent=2))


if __name__ == '__main__':
    main()
