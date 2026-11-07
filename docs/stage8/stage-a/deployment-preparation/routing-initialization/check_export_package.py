"""Local final integrity checks and manifest update; never connects to a database."""
import ast
import json
from road_export_contract import HERE,ROOT,sha,reference_check

reference_check()
for path in HERE.glob('*.py'):
    ast.parse(path.read_text(encoding='utf-8'),filename=str(path))
write_hashes={
 'install_routing_policy.proposed.sql':'6f8312520c112a2993046645c84c50804edef0200aeb3001c7b17382ef930ba1',
 'freeze_routing_graph.proposed.sql':'cfa8b9b8ad1830e1cdcf0c0febf44d5baa848f8441cae973549bb36c60f17b95',
 'requests.proposed.json':'3d5f863bde7a7757f723b7ca4b4128833d29e40e2381364f75a3a5fa94289440'}
assert all(sha(HERE/name)==value for name,value in write_hashes.items()),'Existing proposed operation/request changed'
files={p.name:sha(p) for p in sorted(HERE.iterdir()) if p.is_file() and
       p.suffix in ('.json','.sql','.conf','.py','.md','.ps1') and p.name!='approval-file-hashes.json'}
(HERE/'approval-file-hashes.json').write_text(json.dumps(files,indent=2)+'\n',encoding='utf-8')
results=ROOT/'results/routing-initialization-preparation'
report={'status':'PREPARATION VALIDATION PASS / FULL DEV EQUIVALENCE NOT VERIFIED',
 'python_sources_parsed':len(list(HERE.glob('*.py'))),'package_files_hashed':len(files),
 'unit_tests_passed':6,'unit_test_scope':'In-memory/local-source checks only; export-tools-unittest.txt',
 'powershell_blocks':json.loads((results/'export-command-syntax.json').read_text(encoding='utf-8-sig')),
 'existing_proposed_write_wrappers_and_request_bytes_unchanged':True,
 'current_dev_nodes_edges_compared':False,'database_writes':False}
(results/'export-tools-validation.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
manifest={p.name:sha(p) for p in sorted(results.iterdir()) if p.is_file() and p.name!='evidence-manifest.json'}
(results/'evidence-manifest.json').write_text(json.dumps({'status':'PREPARATION / READ ONLY; FULL EQUIVALENCE PENDING','files':manifest},indent=2)+'\n',encoding='utf-8')
print(json.dumps(report,indent=2))
