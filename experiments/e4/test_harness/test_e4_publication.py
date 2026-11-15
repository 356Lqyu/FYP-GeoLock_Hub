"""Synthetic staging, publication, and recovery tests. No routes are solved."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run_e4 as runner


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.work = self.root / '.work'
        scope = patch.multiple(runner, E4=self.root, WORK=self.work)
        scope.start()
        self.addCleanup(scope.stop)
        for name in runner.RESULT_FILES:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f'old {name}', encoding='utf-8')
        self.manifest = dict(run_id='a' * 32, settings={}, input_sha256={},
                             source_sha256={}, snapshots={'s1': {}})
        self.stage = runner.run_directory(self.manifest['run_id'])
        for name in runner.RESULT_FILES.values():
            path = self.stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f'new {name}', encoding='utf-8')
        for method in runner.METHOD_DESTINATIONS:
            path = self.stage / 'methods' / method
            hashes = {name: runner.file_hash(path / name) for name in runner.METHOD_FILES
                      if name != 'run_manifest.json'}
            runner.persist_json(path / 'run_manifest.json', dict(self.manifest, artifact_sha256=hashes))
        runner.persist_json(self.stage / 'comparison/metrics.json',
                            dict(run_id=self.stage.name, realised_units=1,
                                 per_method={m: dict(independent_check_passed=1, violations=0)
                                             for m in runner.METHOD_DESTINATIONS}))
        (self.stage / 'comparison/summary.md').write_text(
            f'**Run ID:** {chr(96)}{self.stage.name}{chr(96)}', encoding='utf-8')

    def assert_previous(self):
        for name in runner.RESULT_FILES:
            self.assertEqual((self.root / name).read_text(encoding='utf-8'), f'old {name}')
        self.assertFalse((self.root / runner.ACTIVE_MANIFEST).exists())

    def test_success_replaces_stable_files_and_removes_stage(self):
        source = self.root / 'experiment_result/source_code/keep.py'
        source.parent.mkdir()
        source.write_text('source', encoding='utf-8')
        with runner.publication_lock():
            runner.publish(self.stage, self.manifest)
        self.assertEqual(runner.verify_active()['run_id'], self.stage.name)
        self.assertEqual(source.read_text(encoding='utf-8'), 'source')
        self.assertFalse(self.stage.exists())
        self.assertFalse((self.work / 'publication.json').exists())

    def test_missing_or_mixed_outputs_cannot_publish(self):
        metrics = self.stage / 'comparison/metrics.json'
        expected = metrics.read_bytes()
        runner.persist_json(metrics, dict(runner.read_json(metrics), run_id='b' * 32))
        with self.assertRaisesRegex(ValueError, 'comparison failed'):
            runner.publish(self.stage, self.manifest)
        metrics.write_bytes(expected)
        (self.stage / 'comparison/e4_fig1_tasks_served.pdf').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing or empty'):
            runner.publish(self.stage, self.manifest)
        self.assert_previous()

    def test_interrupt_exception_restores_previous_results(self):
        replace = runner.replace_file

        def interrupt(source, destination, scratch):
            if scratch.name == 'publish.tmp' and destination.name == 'metrics.json':
                raise KeyboardInterrupt()
            replace(source, destination, scratch)

        with runner.publication_lock(), patch.object(runner, 'replace_file', side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                runner.publish(self.stage, self.manifest)
        self.assert_previous()
        self.assertTrue((self.stage / 'failure.json').is_file())

    def test_hard_exit_during_file_replacement_restores_on_recovery(self):
        runner.persist_json(self.stage / 'test_manifest.json', self.manifest)
        code = """
import os, sys
from pathlib import Path
import run_e4 as runner
runner.E4 = Path(sys.argv[1])
runner.WORK = runner.E4 / '.work'
stage = runner.run_directory('a' * 32)
replace = runner.replace_file
def exit_after_replace(source, destination, scratch):
    replace(source, destination, scratch)
    if destination.name == 'metrics.json':
        os._exit(91)
runner.replace_file = exit_after_replace
with runner.publication_lock():
    runner.publish(stage, runner.read_json(stage / 'test_manifest.json'))
"""
        pythonpath = str(Path(__file__).resolve().parents[1])
        process = subprocess.run([sys.executable, '-B', '-c', code, str(self.root)],
                                 env={**os.environ, 'PYTHONPATH': pythonpath}, check=False)
        self.assertEqual(process.returncode, 91)
        self.assertTrue((self.work / 'publication.json').is_file())
        with runner.publication_lock():
            runner.recover_publication()
        self.assert_previous()
        self.assertTrue((self.stage / 'failure.json').is_file())
        self.assertFalse((self.work / 'publication.json').exists())

    def test_concurrent_owner_is_refused(self):
        with runner.publication_lock():
            with self.assertRaises(OSError), runner.publication_lock():
                self.fail('A second publisher obtained the E4 lock.')

    def test_driver_passes_one_run_id_and_keeps_failed_stage(self):
        import e4_shared

        admission = dict(snapshots={'s1': {}}, settings={}, input_sha256={})
        run_id = 'b' * 32
        invocations = []

        def invoke(command, *, check, cwd, env, stdout, stderr):
            invocations.append((command[-1], env['GEOLOCK_E4_RUN_ID']))
            if command[-1].endswith(runner.SCRIPTS[-1].replace('/', os.sep)):
                raise subprocess.CalledProcessError(1, command)

        with (patch.object(sys, 'argv', ['run_e4.py']),
              patch.object(e4_shared, 'preflight', return_value=admission),
              patch.object(e4_shared, 'source_fingerprints', return_value={}),
              patch.object(runner.uuid, 'uuid4', return_value=SimpleNamespace(hex=run_id)),
              patch.object(runner.subprocess, 'run', side_effect=invoke)):
            with self.assertRaises(subprocess.CalledProcessError):
                runner.main()
        self.assertEqual(invocations, [(str(self.root / script), run_id) for script in runner.SCRIPTS])
        self.assertTrue((self.work / run_id / 'execution.log').is_file())
        self.assert_previous()


if __name__ == '__main__':
    unittest.main()
