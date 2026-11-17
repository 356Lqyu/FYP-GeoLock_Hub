import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

from ..artifact import load_export
from ...contract import ContractError
from ...worker_service.tests.test_graph_http import RoadRpc


class ArtifactPackagingTests(unittest.TestCase):
    def test_sealed_export_and_exclusive_compiler_output(self):
        rpc=RoadRpc()
        with TemporaryDirectory() as tmp:
            tmp=Path(tmp); source=tmp/'export.jsonl'; target=tmp/'graph.csr'
            source.write_text(json.dumps(dict(graph=rpc.manifest,nodes=rpc.nodes,edges=rpc.edges))+'\n',encoding='utf-8')
            seal=hashlib.sha256(source.read_bytes()).hexdigest()
            self.assertEqual(load_export(source,seal),(rpc.manifest,rpc.nodes,rpc.edges))
            with self.assertRaises(ContractError):load_export(source,'0'*64)
            args=[sys.executable,'-B','-m','backend.routing.hosted.artifact','--export',str(source),
                  '--export-sha256',seal,'--output',str(target)]
            first=subprocess.run(args,capture_output=True,text=True)
            self.assertEqual(first.returncode,0,first.stderr)
            self.assertEqual(json.loads(first.stdout)['artifact_sha256'],hashlib.sha256(target.read_bytes()).hexdigest())
            before=target.read_bytes()
            self.assertNotEqual(subprocess.run(args,capture_output=True).returncode,0)
            self.assertEqual(target.read_bytes(),before)

    def test_image_allowlisted_sources_import_both_disabled_modes_without_io(self):
        # Import closure test, NOT a Linux image build or dependency-wheel test.
        root=Path(__file__).resolve().parents[4]
        with TemporaryDirectory() as tmp:
            stage=Path(tmp)
            for directory in ('backend','backend/routing','backend/routing/phase_b','backend/routing/phase_c2',
                              'backend/routing/integration','backend/routing/worker_service','backend/routing/hosted'):
                source=root/directory
                for path in source.glob('*.py') if directory!='backend' else [source/'__init__.py']:
                    destination=stage/path.relative_to(root);destination.parent.mkdir(parents=True,exist_ok=True)
                    shutil.copyfile(path,destination)
            env={k:v for k,v in os.environ.items() if not k.startswith(('GEOLOCK_','PG'))}
            env['PYTHONPATH']=str(stage)
            for mode in ('planner','validator'):
                completed=subprocess.run([sys.executable,'-B','-m','backend.routing.hosted','--mode',mode,'--check-config'],
                                         cwd=stage,env=env,capture_output=True,text=True)
                self.assertEqual(completed.returncode,0,completed.stderr)
                self.assertEqual(json.loads(completed.stdout),dict(mode=mode,active=False,port=10000,connected=False))

    def test_docker_context_rejects_data_secrets_tests_and_windows_scripts(self):
        root=Path(__file__).resolve().parents[1]/'docker'
        for mode in ('planner','validator'):
            lines=(root/(mode+'.Dockerfile.dockerignore')).read_text().splitlines()
            rules=[line for line in lines if line and not line.startswith('#')]
            self.assertEqual(rules[0],'**')
            self.assertTrue(all(line.lstrip('!').startswith('backend/') for line in rules[1:]))
            self.assertFalse(any('**' in line for line in rules[1:]))
            for i,line in enumerate(rules):
                if line.startswith('!') and line.endswith('/'):
                    # Reinclusion of an ancestor must not implicitly admit its
                    # data/secret children; reset before specific file exceptions.
                    self.assertEqual(rules[i+1],line[1:]+'*')
            for forbidden in ('*.json','*.jsonl','*.env','tests/','windows/','*.csr','*.pem','*.backup'):
                self.assertFalse(any(forbidden in line for line in rules))
