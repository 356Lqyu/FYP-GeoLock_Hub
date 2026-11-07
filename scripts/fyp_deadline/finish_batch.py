"""Finalize Batch 1 logs and preservation evidence; no test/process/database calls."""
import json
from pathlib import Path
import re
from experiments.fyp_deadline.evidence import fingerprint,write_once,manifest,EvidenceWriter,verify_run

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'results/accelerated-batch1/batch1-20261026-01'

def log(name):
    data=(OUT/name).read_bytes()
    return data.decode('utf-16' if data.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8-sig')

def main():
    prior=json.loads((OUT/'protected-before.json').read_text());mismatches=[]
    for row in prior:
        p=ROOT/row['path']
        if not p.is_file() or fingerprint(p)['sha256']!=row['sha256']:mismatches.append(row['path'])
    preservation={'checked':len(prior),'unchanged':len(prior)-len(mismatches),'mismatches':mismatches,'status':'FAIL' if mismatches else 'PASS',
        'scope':'All preexisting project source/data/docs plus existing text/JSON/SQL/CSV evidence; generated caches and PostgreSQL physical cluster files excluded'}
    write_once(OUT/'preservation-final.json',preservation)
    python=log('python-tests-final.log');flutter=log('flutter-tests-attempt-02.log');analyze=log('flutter-analyze.log');build=log('flutter-build-web-attempt-02.log')
    if not ('Ran 44 tests' in python and python.rstrip().endswith('OK')):raise RuntimeError('Python success not recorded')
    if '+125: All tests passed!' not in flutter:raise RuntimeError('Flutter success not recorded')
    if 'No issues found!' not in analyze:raise RuntimeError('Analyzer success not recorded')
    if 'Built build' not in build or (OUT/'flutter-build-web-attempt-02.exit.txt').read_text().strip()!='0':raise RuntimeError('Build success not recorded')
    verify_run(OUT/'preflight-02')
    inputs={p.relative_to(ROOT).as_posix():p for directory in ('experiments/fyp_deadline','scripts/fyp_deadline') for p in (ROOT/directory).rglob('*') if p.is_file()}
    for name in ('python-tests-final.log','flutter-tests-attempt-02.log','flutter-analyze.log','flutter-build-web-attempt-02.log','protected-before.json','preservation-final.json'):
        inputs[name]=OUT/name
    writer=EvidenceWriter(OUT/'batch-verification',manifest(inputs,{'batch':'ACCELERATED_1','scope':'LOCAL_IMPLEMENTATION_AND_CACHED_FLUTTER_VERIFICATION','formal_experiments':False,'database_access':False}))
    writer.check('python_synthetic_tests','PASS',{'passed':44,'failed':0,'skipped':0})
    writer.check('flutter_existing_tests','PASS',{'passed':125,'failed':0,'skipped':0,'scope':'Copied source; existing unit/widget tests; no live acceptance'})
    writer.check('flutter_analyzer','PASS','No issues found')
    writer.check('offline_web_build','PASS',{'output':str((OUT/'flutter-workspace/build/web').relative_to(ROOT)),'app_launched':False})
    writer.check('existing_source_data_evidence_preservation',preservation['status'],preservation)
    writer.check('integrated_or_database_changing_execution','BLOCKED','C.5/upgrade/backup verification and separate approvals outstanding')
    writer.check('training_and_formal_experiments','NOT RUN','Not authorized in this batch')
    writer.seal();verify_run(writer.root)
    result={'batch_implementation':'COMPLETE' if not mismatches else 'PARTIAL_PRESERVATION_MISMATCH',
        'python_tests':44,'flutter_tests':125,'analyzer':'PASS','offline_web_build':'PASS',
        'day1_offline_implementation':'GO','day1_integrated_acceptance_or_database_changes':'NO-GO',
        'preflight_outcomes':json.loads((OUT/'preflight-02/completion.json').read_text())['seal']['counts'],
        'preservation':preservation,'postgresql_or_c5_executions':0,'supabase_connections':0,'formal_experiments_executed':False,
        'model_training_executed':False,'backup_verified':False,'worker_activated':False}
    write_once(OUT/'results.json',result)
    print(json.dumps(result,indent=2))

if __name__=='__main__':main()
