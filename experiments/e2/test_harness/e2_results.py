"""Verify and replace one complete E2 result directory under a caller-held lock."""
import json
from pathlib import Path
import shutil
import warnings

from e2_harness import _is_reparse_point, sha256, write_json


INVENTORY = 'result_sha256.json'
COMPARISON_FILES = {
    'summary.md', 'metrics.json', 'comparison_summary.csv', 'comparison_contention.csv',
    'comparison_lease.csv', 'comparison_geofence.csv', 'e2_fig1_duplicate_owners.png',
    'e2_fig2_response_time.png', 'e2_fig3_lease_recovery.png', 'e2_fig4_geofence_check.png',
}


def result_tree(path):
    """Enumerate files without traversing linked directories or special files."""
    if _is_reparse_point(path) or not path.is_dir():
        raise SystemExit(f'Unsafe or missing E2 result directory: {path}')
    for entry in path.iterdir():
        if _is_reparse_point(entry):
            raise SystemExit(f'E2 result contains a linked path: {entry}')
        if entry.is_dir():
            yield from result_tree(entry)
        elif entry.is_file():
            yield entry
        else:
            raise SystemExit(f'E2 result contains an unsupported entry: {entry}')


def result_hashes(path):
    return {file.relative_to(path).as_posix(): sha256(file)
            for file in result_tree(path) if file != path / INVENTORY}


def verify(path):
    """Check the complete retained file set and its run ID without touching a database."""
    hashes = result_hashes(path)
    inventory = json.loads((path / INVENTORY).read_text(encoding='utf-8'))
    manifest = json.loads((path / 'run_manifest.json').read_text(encoding='utf-8'))
    if (hashes != inventory.get('sha256') or manifest.get('status') != 'completed'
            or manifest.get('experiment_run_id') != inventory.get('experiment_run_id')):
        raise SystemExit(f'E2 result integrity check failed: {path}')
    return manifest


def seal(path, manifest, *, full):
    """Require the comparison outputs before sealing the completed result set."""
    if full:
        for name in sorted(COMPARISON_FILES):
            file = path / 'comparison' / name
            if not file.is_file() or file.stat().st_size == 0:
                raise SystemExit(f'E2 comparison output missing or empty: {file}')
    write_json(path / INVENTORY, {'experiment_run_id': manifest['experiment_run_id'],
                                  'sha256': result_hashes(path)})


class Publication:
    """Publish complete directories by rename and recover either interruption window."""

    def __init__(self, root, *, full=True):
        root = Path(root).absolute()
        if root.resolve() != root or _is_reparse_point(root):
            raise SystemExit(f'Unsafe E2 results root: {root}')
        name = 'latest' if full else 'standalone'
        self.active = root / name
        self.pending = root / f'.{name}.pending'
        self.previous = root / f'.{name}.previous'

    def recover(self):
        """Keep the published result, or restore the previous result if the rename was interrupted."""
        for path in (self.active, self.pending, self.previous):
            if _is_reparse_point(path) or (path.exists() and not path.is_dir()):
                raise SystemExit(f'Unsafe E2 publication path: {path}')
        if self.active.exists():
            verify(self.active)
        elif self.previous.exists():
            verify(self.previous)
            self.previous.rename(self.active)
        for path in (self.pending, self.previous):
            if path.exists():
                # Complete the safety walk before deleting any file.
                tuple(result_tree(path))
                shutil.rmtree(path)

    def publish(self):
        verify(self.pending)
        if self.active.exists():
            verify(self.active)
            self.active.rename(self.previous)
        try:
            self.pending.rename(self.active)
        except OSError:
            if self.previous.exists() and not self.active.exists():
                self.previous.rename(self.active)
            raise
        # The promotion rename is the commit point. If cleanup is interrupted,
        # recover() verifies the new active result before discarding the old copy.
        if self.previous.exists():
            tuple(result_tree(self.previous))
            try:
                shutil.rmtree(self.previous)
            except OSError as exc:
                warnings.warn(f'E2 result was published, but backup cleanup is pending: {exc}', stacklevel=2)
